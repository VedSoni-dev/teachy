//
//  GazeMath.swift
//  leanring-buddy
//
//  The pure parts of webcam eye tracking, kept free of AVFoundation and Vision
//  so they can be tested with synthetic data (scripts/tests/run_touch_gaze_tests.sh):
//
//  - `GazeEyeFeatures`: turns eye landmarks (pupils, eye outlines) and head pose
//    from one camera frame into a fixed-length feature vector.
//  - `GazeRegressionModel`: a ridge regression fitted during calibration that maps
//    a feature vector to a point on the screen (0…1 in each direction).
//  - `GazeOneEuroFilter`: smooths the jittery per-frame estimate without lag on
//    real eye movements.
//  - `GazeFixationFinder`: groups gaze samples into fixations (places the eyes
//    rested), which is what becomes part of the question.
//
//  A webcam is not an eye tracker: expect accuracy of a few centimetres on screen,
//  which is why gaze is described to the model as a region, never a pixel.
//

import CoreGraphics
import Foundation

// MARK: - Features

nonisolated struct GazeEyeFeatures: Equatable, Sendable {
    /// Feature values in a fixed order; see `featureNames`.
    let values: [Double]
    /// Eye height / width averaged over both eyes; small when blinking.
    let eyeOpenness: Double

    static let featureNames = [
        "leftPupilOffsetX", "leftPupilOffsetY", "rightPupilOffsetX", "rightPupilOffsetY",
        "headYaw", "headPitch", "faceCenterX", "faceCenterY", "faceWidth",
        "pupilOffsetXSquared", "pupilOffsetXTimesY", "pupilOffsetYSquared",
    ]
    static var featureCount: Int { featureNames.count }

    /// An eye whose height is under this fraction of its width is treated as closed.
    static let blinkOpennessThreshold = 0.12

    var isBlink: Bool { eyeOpenness < Self.blinkOpennessThreshold }

    /// All points are in camera image coordinates normalised to 0…1.
    /// Returns nil when an eye outline is too small to measure.
    static func make(
        leftPupil: CGPoint, leftEyeOutline: [CGPoint],
        rightPupil: CGPoint, rightEyeOutline: [CGPoint],
        headYawInRadians: Double, headPitchInRadians: Double,
        faceBoundingBox: CGRect
    ) -> GazeEyeFeatures? {
        guard let leftEye = EyeMeasurement(pupil: leftPupil, outline: leftEyeOutline),
              let rightEye = EyeMeasurement(pupil: rightPupil, outline: rightEyeOutline) else { return nil }

        let averageOffsetX = (leftEye.pupilOffsetX + rightEye.pupilOffsetX) / 2
        let averageOffsetY = (leftEye.pupilOffsetY + rightEye.pupilOffsetY) / 2
        let values = [
            leftEye.pupilOffsetX, leftEye.pupilOffsetY, rightEye.pupilOffsetX, rightEye.pupilOffsetY,
            headYawInRadians, headPitchInRadians,
            Double(faceBoundingBox.midX), Double(faceBoundingBox.midY), Double(faceBoundingBox.width),
            averageOffsetX * averageOffsetX, averageOffsetX * averageOffsetY, averageOffsetY * averageOffsetY,
        ]
        guard values.allSatisfy(\.isFinite) else { return nil }
        return GazeEyeFeatures(values: values, eyeOpenness: (leftEye.openness + rightEye.openness) / 2)
    }

    /// Where the pupil sits inside one eye's outline, measured in eye widths
    /// from the outline's centre, so it does not depend on distance to the camera.
    private struct EyeMeasurement {
        let pupilOffsetX: Double
        let pupilOffsetY: Double
        let openness: Double

        init?(pupil: CGPoint, outline: [CGPoint]) {
            guard outline.count >= 4 else { return nil }
            let outlineXValues = outline.map { Double($0.x) }
            let outlineYValues = outline.map { Double($0.y) }
            let eyeWidth = outlineXValues.max()! - outlineXValues.min()!
            let eyeHeight = outlineYValues.max()! - outlineYValues.min()!
            guard eyeWidth > 1e-4 else { return nil }
            let eyeCenterX = outlineXValues.reduce(0, +) / Double(outlineXValues.count)
            let eyeCenterY = outlineYValues.reduce(0, +) / Double(outlineYValues.count)
            pupilOffsetX = (Double(pupil.x) - eyeCenterX) / eyeWidth
            pupilOffsetY = (Double(pupil.y) - eyeCenterY) / eyeWidth
            openness = eyeHeight / eyeWidth
        }
    }
}

// MARK: - Regression

/// Maps eye features to a screen position. Each feature is standardised, then a
/// ridge regression (least squares with a small penalty on large weights, which
/// keeps it stable with the few hundred calibration samples we get) is fitted
/// separately for the horizontal and vertical screen position.
nonisolated struct GazeRegressionModel: Codable, Equatable, Sendable {
    let featureMeans: [Double]
    let featureStandardDeviations: [Double]
    /// Bias first, then one weight per feature.
    let horizontalWeights: [Double]
    let verticalWeights: [Double]

    struct TrainingSample: Sendable {
        let features: [Double]
        /// Where the person was looking, 0…1 across and 0…1 down the screen.
        let screenPosition: CGPoint
    }

    static let defaultRidgePenalty = 0.5

    static func fit(samples: [TrainingSample], ridgePenalty: Double = defaultRidgePenalty) -> GazeRegressionModel? {
        guard let featureCount = samples.first?.features.count, featureCount > 0,
              samples.count > featureCount, samples.allSatisfy({ $0.features.count == featureCount }) else { return nil }

        var featureMeans = [Double](repeating: 0, count: featureCount)
        var featureStandardDeviations = [Double](repeating: 1, count: featureCount)
        for featureIndex in 0..<featureCount {
            let column = samples.map { $0.features[featureIndex] }
            let mean = column.reduce(0, +) / Double(column.count)
            let variance = column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(column.count)
            featureMeans[featureIndex] = mean
            // A feature that never changed (e.g. the person never moved their head) gets weight ~0 instead of dividing by zero.
            featureStandardDeviations[featureIndex] = variance > 1e-12 ? variance.squareRoot() : 1
        }

        let designRows = samples.map { sample in
            [1.0] + (0..<featureCount).map { (sample.features[$0] - featureMeans[$0]) / featureStandardDeviations[$0] }
        }
        guard let horizontalWeights = solveRidge(designRows: designRows, targets: samples.map { Double($0.screenPosition.x) }, ridgePenalty: ridgePenalty),
              let verticalWeights = solveRidge(designRows: designRows, targets: samples.map { Double($0.screenPosition.y) }, ridgePenalty: ridgePenalty)
        else { return nil }

        return GazeRegressionModel(
            featureMeans: featureMeans, featureStandardDeviations: featureStandardDeviations,
            horizontalWeights: horizontalWeights, verticalWeights: verticalWeights
        )
    }

    /// Screen position 0…1 (may fall slightly outside when looking off-screen).
    func predictScreenPosition(features: [Double]) -> CGPoint? {
        guard features.count == featureMeans.count else { return nil }
        let standardizedRow = [1.0] + features.indices.map { (features[$0] - featureMeans[$0]) / featureStandardDeviations[$0] }
        let horizontal = zip(standardizedRow, horizontalWeights).reduce(0) { $0 + $1.0 * $1.1 }
        let vertical = zip(standardizedRow, verticalWeights).reduce(0) { $0 + $1.0 * $1.1 }
        guard horizontal.isFinite, vertical.isFinite else { return nil }
        return CGPoint(x: horizontal, y: vertical)
    }

    /// Solves (XᵀX + λI) w = Xᵀy. The bias (column 0) is not penalised.
    private static func solveRidge(designRows: [[Double]], targets: [Double], ridgePenalty: Double) -> [Double]? {
        let columnCount = designRows[0].count
        var normalMatrix = [[Double]](repeating: [Double](repeating: 0, count: columnCount), count: columnCount)
        var rightHandSide = [Double](repeating: 0, count: columnCount)
        for (row, target) in zip(designRows, targets) {
            for rowIndex in 0..<columnCount {
                rightHandSide[rowIndex] += row[rowIndex] * target
                for columnIndex in 0..<columnCount {
                    normalMatrix[rowIndex][columnIndex] += row[rowIndex] * row[columnIndex]
                }
            }
        }
        for diagonalIndex in 1..<columnCount { normalMatrix[diagonalIndex][diagonalIndex] += ridgePenalty }
        return solveLinearSystem(normalMatrix, rightHandSide)
    }

    /// Gaussian elimination with partial pivoting.
    static func solveLinearSystem(_ coefficientMatrix: [[Double]], _ rightHandSide: [Double]) -> [Double]? {
        let size = rightHandSide.count
        var augmented = coefficientMatrix.enumerated().map { $0.element + [rightHandSide[$0.offset]] }
        for pivotIndex in 0..<size {
            let bestRowIndex = (pivotIndex..<size).max { abs(augmented[$0][pivotIndex]) < abs(augmented[$1][pivotIndex]) }!
            guard abs(augmented[bestRowIndex][pivotIndex]) > 1e-12 else { return nil }
            augmented.swapAt(pivotIndex, bestRowIndex)
            for rowIndex in (pivotIndex + 1)..<size {
                let factor = augmented[rowIndex][pivotIndex] / augmented[pivotIndex][pivotIndex]
                guard factor != 0 else { continue }
                for columnIndex in pivotIndex...size {
                    augmented[rowIndex][columnIndex] -= factor * augmented[pivotIndex][columnIndex]
                }
            }
        }
        var solution = [Double](repeating: 0, count: size)
        for rowIndex in stride(from: size - 1, through: 0, by: -1) {
            var remainder = augmented[rowIndex][size]
            for columnIndex in (rowIndex + 1)..<size { remainder -= augmented[rowIndex][columnIndex] * solution[columnIndex] }
            solution[rowIndex] = remainder / augmented[rowIndex][rowIndex]
        }
        return solution.allSatisfy(\.isFinite) ? solution : nil
    }
}

// MARK: - Smoothing

/// The One Euro filter (Casiez et al., 2012): heavy smoothing while the gaze is
/// still, light smoothing while it moves, so the estimate is steady without lagging saccades.
/// The constants are tuned for positions in screen fractions (0…1), not points.
nonisolated struct GazeOneEuroFilter {
    var minimumCutoffFrequency = 0.6
    var speedCoefficient = 0.4
    var derivativeCutoffFrequency = 1.0

    private var previousValue: CGPoint?
    private var previousDerivative = CGPoint.zero
    private var previousTime: Double = 0

    mutating func reset() { previousValue = nil }

    mutating func filter(_ value: CGPoint, at time: Double) -> CGPoint {
        guard let previousValue, time > previousTime else {
            self.previousValue = value
            previousTime = time
            return value
        }
        let elapsedSeconds = time - previousTime
        previousTime = time

        let rawDerivative = CGPoint(x: (value.x - previousValue.x) / elapsedSeconds, y: (value.y - previousValue.y) / elapsedSeconds)
        let derivativeBlend = Self.smoothingFactor(elapsedSeconds: elapsedSeconds, cutoffFrequency: derivativeCutoffFrequency)
        let smoothedDerivative = Self.blend(previousDerivative, rawDerivative, by: derivativeBlend)
        previousDerivative = smoothedDerivative

        let speed = Double(hypot(smoothedDerivative.x, smoothedDerivative.y))
        let cutoffFrequency = minimumCutoffFrequency + speedCoefficient * speed
        let valueBlend = Self.smoothingFactor(elapsedSeconds: elapsedSeconds, cutoffFrequency: cutoffFrequency)
        let smoothedValue = Self.blend(previousValue, value, by: valueBlend)
        self.previousValue = smoothedValue
        return smoothedValue
    }

    private static func smoothingFactor(elapsedSeconds: Double, cutoffFrequency: Double) -> Double {
        let timeConstant = 1 / (2 * Double.pi * cutoffFrequency)
        return 1 / (1 + timeConstant / elapsedSeconds)
    }

    private static func blend(_ from: CGPoint, _ to: CGPoint, by factor: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * factor, y: from.y + (to.y - from.y) * factor)
    }
}

// MARK: - Fixations

nonisolated struct GazeSample: Equatable, Sendable {
    let time: Double
    /// Global AppKit coordinates (origin bottom-left of the main display), in points.
    let pointInGlobalCoordinates: CGPoint
}

nonisolated struct GazeFixation: Equatable, Sendable {
    let centerInGlobalCoordinates: CGPoint
    let startTime: Double
    let endTime: Double
    var durationInSeconds: Double { endTime - startTime }
}

/// Dispersion-threshold fixation finding (I-DT): a run of samples that stays
/// within a small area for long enough is one fixation.
nonisolated enum GazeFixationFinder {
    /// Webcam gaze wobbles, so the area is generous (about a thumb's width on a laptop screen).
    static let defaultMaximumDispersionInPoints: CGFloat = 110
    static let defaultMinimumDurationInSeconds = 0.18

    static func fixations(
        in samples: [GazeSample],
        maximumDispersionInPoints: CGFloat = defaultMaximumDispersionInPoints,
        minimumDurationInSeconds: Double = defaultMinimumDurationInSeconds
    ) -> [GazeFixation] {
        let orderedSamples = samples.sorted { $0.time < $1.time }
        var foundFixations: [GazeFixation] = []
        var windowStartIndex = 0
        while windowStartIndex < orderedSamples.count {
            var windowEndIndex = windowStartIndex
            // Grow the window until it spans the minimum duration.
            while windowEndIndex + 1 < orderedSamples.count,
                  orderedSamples[windowEndIndex].time - orderedSamples[windowStartIndex].time < minimumDurationInSeconds {
                windowEndIndex += 1
            }
            let initialWindow = orderedSamples[windowStartIndex...windowEndIndex]
            guard orderedSamples[windowEndIndex].time - orderedSamples[windowStartIndex].time >= minimumDurationInSeconds,
                  dispersion(of: initialWindow) <= maximumDispersionInPoints else {
                windowStartIndex += 1
                continue
            }
            // Keep growing while the samples stay together.
            while windowEndIndex + 1 < orderedSamples.count,
                  dispersion(of: orderedSamples[windowStartIndex...(windowEndIndex + 1)]) <= maximumDispersionInPoints {
                windowEndIndex += 1
            }
            let fixationSamples = orderedSamples[windowStartIndex...windowEndIndex]
            let sampleCount = CGFloat(fixationSamples.count)
            let center = CGPoint(
                x: fixationSamples.reduce(0) { $0 + $1.pointInGlobalCoordinates.x } / sampleCount,
                y: fixationSamples.reduce(0) { $0 + $1.pointInGlobalCoordinates.y } / sampleCount
            )
            foundFixations.append(GazeFixation(
                centerInGlobalCoordinates: center,
                startTime: orderedSamples[windowStartIndex].time,
                endTime: orderedSamples[windowEndIndex].time
            ))
            windowStartIndex = windowEndIndex + 1
        }
        return foundFixations
    }

    /// The places looked at longest, longest first. Nearby fixations (revisits) are merged first.
    static func dominantFixations(in samples: [GazeSample], maximumCount: Int = 2) -> [GazeFixation] {
        var mergedFixations: [GazeFixation] = []
        for fixation in fixations(in: samples) {
            if let revisitedIndex = mergedFixations.firstIndex(where: {
                hypot($0.centerInGlobalCoordinates.x - fixation.centerInGlobalCoordinates.x,
                      $0.centerInGlobalCoordinates.y - fixation.centerInGlobalCoordinates.y) <= defaultMaximumDispersionInPoints
            }) {
                let existing = mergedFixations[revisitedIndex]
                let totalDuration = max(existing.durationInSeconds + fixation.durationInSeconds, 1e-6)
                let existingWeight = existing.durationInSeconds / totalDuration
                let mergedCenter = CGPoint(
                    x: existing.centerInGlobalCoordinates.x * existingWeight + fixation.centerInGlobalCoordinates.x * (1 - existingWeight),
                    y: existing.centerInGlobalCoordinates.y * existingWeight + fixation.centerInGlobalCoordinates.y * (1 - existingWeight)
                )
                // Duration is what matters for ranking; keep the start and stretch the end by the added dwell.
                mergedFixations[revisitedIndex] = GazeFixation(
                    centerInGlobalCoordinates: mergedCenter,
                    startTime: existing.startTime,
                    endTime: existing.startTime + totalDuration
                )
            } else {
                mergedFixations.append(fixation)
            }
        }
        return Array(mergedFixations.sorted { $0.durationInSeconds > $1.durationInSeconds }.prefix(maximumCount))
    }

    private static func dispersion(of samples: ArraySlice<GazeSample>) -> CGFloat {
        let xValues = samples.map(\.pointInGlobalCoordinates.x)
        let yValues = samples.map(\.pointInGlobalCoordinates.y)
        return (xValues.max()! - xValues.min()!) + (yValues.max()! - yValues.min()!)
    }
}

// MARK: - Calibration targets

nonisolated enum GazeCalibrationTargets {
    /// Nine dots: corners, edge midpoints and centre, inset so they sit on the visible screen.
    /// Positions are 0…1 across and 0…1 down.
    static let positions: [CGPoint] = {
        let insets: [CGFloat] = [0.08, 0.5, 0.92]
        var points: [CGPoint] = []
        for verticalPosition in insets {
            for horizontalPosition in insets { points.append(CGPoint(x: horizontalPosition, y: verticalPosition)) }
        }
        // A snake order keeps each eye movement short.
        return [points[4], points[0], points[1], points[2], points[5], points[8], points[7], points[6], points[3]]
    }()
}
