import Foundation
import CoreGraphics

struct CameraCalibrationSample {
    let feature: CGPoint
    let target: CGPoint
}

/// A per-session affine estimate, never a substitute for successful calibration.
struct CameraGazeCalibration {
    let meanError: Double
    private let featureCenter: CGPoint
    private let featureScale: CGPoint
    private let targetCenter: CGPoint
    private let horizontalWeights: CGPoint
    private let verticalWeights: CGPoint

    static func fit(samples: [CameraCalibrationSample]) -> CameraGazeCalibration? {
        guard samples.count >= 5,
              samples.allSatisfy({ sample in
                  finite(sample.feature) && finite(sample.target)
                      && (0...1).contains(sample.target.x) && (0...1).contains(sample.target.y)
              }) else { return nil }
        let count = Double(samples.count)
        let featureCenter = CGPoint(x: samples.reduce(0) { $0 + $1.feature.x } / count,
                                    y: samples.reduce(0) { $0 + $1.feature.y } / count)
        let targetCenter = CGPoint(x: samples.reduce(0) { $0 + $1.target.x } / count,
                                   y: samples.reduce(0) { $0 + $1.target.y } / count)
        let varianceX = samples.reduce(0.0) { $0 + pow($1.feature.x - featureCenter.x, 2) } / count
        let varianceY = samples.reduce(0.0) { $0 + pow($1.feature.y - featureCenter.y, 2) } / count
        let scale = CGPoint(x: sqrt(varianceX), y: sqrt(varianceY))
        // Near-static features amplify sensor noise into full-screen jumps.
        guard finite(scale), scale.x >= 0.0001, scale.y >= 0.0001 else { return nil }
        var covariance = 0.0
        var horizontal = CGPoint.zero
        var vertical = CGPoint.zero
        for sample in samples {
            let featureX = (sample.feature.x - featureCenter.x) / scale.x
            let featureY = (sample.feature.y - featureCenter.y) / scale.y
            covariance += featureX * featureY / count
            horizontal.x += featureX * (sample.target.x - targetCenter.x) / count
            horizontal.y += featureY * (sample.target.x - targetCenter.x) / count
            vertical.x += featureX * (sample.target.y - targetCenter.y) / count
            vertical.y += featureY * (sample.target.y - targetCenter.y) / count
        }
        // Centering removes the intercept; scaling gives a unit-diagonal 2×2
        // system. Reject ill-conditioned axes rather than inventing gaze points.
        let determinant = 1 - covariance * covariance
        guard determinant.isFinite, determinant > 0.001 else { return nil }
        func solve(_ values: CGPoint) -> CGPoint {
            CGPoint(x: (values.x - covariance * values.y) / determinant,
                    y: (values.y - covariance * values.x) / determinant)
        }
        let horizontalWeights = solve(horizontal)
        let verticalWeights = solve(vertical)
        guard finite(horizontalWeights), finite(verticalWeights) else { return nil }
        let preliminary = CameraGazeCalibration(meanError: 0, featureCenter: featureCenter,
                                               featureScale: scale, targetCenter: targetCenter,
                                               horizontalWeights: horizontalWeights,
                                               verticalWeights: verticalWeights)
        let error = samples.reduce(0.0) { total, sample in
            let estimated = preliminary.unclippedProjection(sample.feature)
            return total + hypot(estimated.x - sample.target.x, estimated.y - sample.target.y) / count
        }
        guard error.isFinite, error <= 0.18 else { return nil }
        return CameraGazeCalibration(meanError: error, featureCenter: featureCenter,
                                     featureScale: scale, targetCenter: targetCenter,
                                     horizontalWeights: horizontalWeights,
                                     verticalWeights: verticalWeights)
    }

    func project(_ feature: CGPoint) -> CGPoint? {
        guard Self.finite(feature) else { return nil }
        let estimated = unclippedProjection(feature)
        guard Self.finite(estimated) else { return nil }
        return CGPoint(x: min(1, max(0, estimated.x)), y: min(1, max(0, estimated.y)))
    }

    private func unclippedProjection(_ feature: CGPoint) -> CGPoint {
        let featureX = (feature.x - featureCenter.x) / featureScale.x
        let featureY = (feature.y - featureCenter.y) / featureScale.y
        return CGPoint(x: targetCenter.x + horizontalWeights.x * featureX + horizontalWeights.y * featureY,
                       y: targetCenter.y + verticalWeights.x * featureX + verticalWeights.y * featureY)
    }

    private static func finite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

/// Requires an observed open hand before each pinch, including after tracking loss.
struct CameraPinchGate {
    private var isArmed = false
    private var closedSampleCount = 0
    private var lastEventTime: TimeInterval?
    private var lastSampleTime: TimeInterval?

    mutating func update(ratio: Double?, timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite,
              lastSampleTime.map({ timestamp > $0 }) ?? true,
              let ratio, ratio.isFinite, ratio >= 0 else {
            isArmed = false
            closedSampleCount = 0
            if timestamp.isFinite, lastSampleTime.map({ timestamp > $0 }) ?? true {
                lastSampleTime = timestamp
            }
            return false
        }
        lastSampleTime = timestamp
        if ratio > 0.42 {
            isArmed = true
            closedSampleCount = 0
            return false
        }
        guard ratio < 0.28, isArmed else {
            closedSampleCount = 0
            return false
        }
        closedSampleCount += 1
        guard closedSampleCount >= 2 else { return false }
        isArmed = false
        closedSampleCount = 0
        guard lastEventTime.map({ timestamp - $0 >= 0.5 }) ?? true else { return false }
        lastEventTime = timestamp
        return true
    }

    mutating func reset() {
        self = CameraPinchGate()
    }
}

struct CameraPointSmoother {
    private var previous: CGPoint?

    mutating func update(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite else {
            reset()
            return nil
        }
        let clamped = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        let result: CGPoint
        if let previous {
            result = CGPoint(x: previous.x + 0.35 * (clamped.x - previous.x),
                             y: previous.y + 0.35 * (clamped.y - previous.y))
        } else {
            result = clamped
        }
        previous = result
        return result
    }

    mutating func reset() { previous = nil }
}
