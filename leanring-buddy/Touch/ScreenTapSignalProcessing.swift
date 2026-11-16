//
//  ScreenTapSignalProcessing.swift
//  leanring-buddy
//
//  Pure signal processing behind "tap the screen to talk". A MacBook has no touch
//  digitiser, but a fingertip on the display near the camera housing does two things
//  the Mac can measure at once:
//    1. it shades the ambient light sensor that sits in the camera housing, so the
//       light reading dips and then recovers when the finger lifts, and
//    2. it knocks the lid, so the built-in accelerometer and gyroscope see a short jolt.
//  Either signal alone is common (a hand passing by, typing on the keyboard); both
//  together, at the same moment, are a tap. Nothing in here touches hardware, so the
//  whole recognizer can be tested with synthetic samples
//  (scripts/tests/run_touch_gaze_tests.sh).
//
//  The idea of fusing the light sensor with motion comes from Sentient OS's
//  "physical notch tap". This file is Teachy's own implementation; no Sentient OS
//  code (AGPL) is copied.
//

import Foundation
import simd

// MARK: - Sensor report decoding

/// Decodes the raw HID reports of the Apple Silicon sensor processor (SPU).
/// The byte layouts are properties of the hardware, documented here so the
/// reader in `ScreenTapSensor` stays free of magic numbers.
nonisolated enum ScreenTapSensorReportDecoder {
    /// Accelerometer and gyroscope reports are 22 bytes long. X, Y and Z are
    /// little-endian signed 32-bit fixed-point numbers (16 fractional bits)
    /// starting at byte 6. Accelerometer units are g, gyroscope units are deg/s.
    static let motionReportLengthInBytes = 22
    static let motionAxisOffsetsInBytes = [6, 10, 14]

    /// Ambient light reports are 122 bytes long; lux is a little-endian
    /// 32-bit float at byte 40.
    static let ambientLightReportLengthInBytes = 122
    static let ambientLightLuxOffsetInBytes = 40

    static func motionVector(fromReportBytes reportBytes: [UInt8]) -> SIMD3<Double>? {
        guard reportBytes.count == motionReportLengthInBytes else { return nil }
        let axisValues = motionAxisOffsetsInBytes.map { byteOffset -> Double in
            let rawBits = littleEndianUInt32(reportBytes, at: byteOffset)
            return Double(Int32(bitPattern: rawBits)) / 65_536.0
        }
        return SIMD3(axisValues[0], axisValues[1], axisValues[2])
    }

    static func ambientLightLux(fromReportBytes reportBytes: [UInt8]) -> Double? {
        guard reportBytes.count == ambientLightReportLengthInBytes else { return nil }
        let rawBits = littleEndianUInt32(reportBytes, at: ambientLightLuxOffsetInBytes)
        let luxValue = Double(Float(bitPattern: rawBits))
        guard luxValue.isFinite, luxValue >= 0 else { return nil }
        return luxValue
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at byteOffset: Int) -> UInt32 {
        UInt32(bytes[byteOffset])
            | UInt32(bytes[byteOffset + 1]) << 8
            | UInt32(bytes[byteOffset + 2]) << 16
            | UInt32(bytes[byteOffset + 3]) << 24
    }
}

// MARK: - Sensitivity

nonisolated enum ScreenTapSensitivity: String, CaseIterable, Identifiable, Sendable {
    case gentle, standard, firm
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gentle: return "Light touch"
        case .standard: return "Standard"
        case .firm: return "Firm tap"
        }
    }

    /// Multiplies every threshold. Below 1 accepts lighter taps (and more false
    /// taps); above 1 needs a firmer, more deliberate tap.
    var thresholdMultiplier: Double {
        switch self {
        case .gentle: return 0.8
        case .standard: return 1.0
        case .firm: return 1.35
        }
    }
}

// MARK: - Motion jolt detection

/// Finds short jolts in one motion stream (accelerometer or gyroscope).
/// Gravity and slow tilting are removed with a high-pass filter; the remaining
/// magnitude is compared against a noise floor that adapts to the desk the Mac
/// sits on, so a Mac on a vibrating table does not tap itself.
nonisolated struct ScreenTapMotionJoltDetector {
    /// Below this the stream is too quiet to call anything a jolt, whatever the noise floor says.
    let absoluteMinimumJoltMagnitude: Double
    /// A jolt must rise this many times above the adaptive noise floor.
    let noiseFloorMultiplier: Double

    private var slowMovingAverage: SIMD3<Double>?
    private var previousSampleTime: Double?
    private var adaptiveNoiseFloor: Double = 0
    private(set) var mostRecentJoltTime: Double = -.infinity

    /// How quickly the high-pass filter forgets: anything slower than ~15 ms is "not a jolt".
    private static let highPassTimeConstantInSeconds = 0.015
    /// How quickly the noise floor follows the background vibration level.
    private static let noiseFloorTimeConstantInSeconds = 1.5
    /// A gap this long means the stream stalled; start over rather than see a fake jolt.
    static let maximumSampleGapInSeconds = 0.08

    init(absoluteMinimumJoltMagnitude: Double, noiseFloorMultiplier: Double) {
        self.absoluteMinimumJoltMagnitude = absoluteMinimumJoltMagnitude
        self.noiseFloorMultiplier = noiseFloorMultiplier
    }

    /// Feeds one sample. Returns true when this sample is part of a jolt.
    mutating func addSample(_ motionVector: SIMD3<Double>, at sampleTime: Double, thresholdMultiplier: Double) -> Bool {
        guard motionVector.x.isFinite, motionVector.y.isFinite, motionVector.z.isFinite, sampleTime.isFinite else { return false }

        guard let previousTime = previousSampleTime, let currentAverage = slowMovingAverage,
              sampleTime > previousTime, sampleTime - previousTime < Self.maximumSampleGapInSeconds else {
            // First sample, out of order, or after a stall: just re-anchor the filter.
            slowMovingAverage = motionVector
            previousSampleTime = sampleTime
            return false
        }

        let elapsedSeconds = sampleTime - previousTime
        previousSampleTime = sampleTime

        let highPassedVector = motionVector - currentAverage
        let averageBlend = 1 - exp(-elapsedSeconds / Self.highPassTimeConstantInSeconds)
        slowMovingAverage = currentAverage + highPassedVector * averageBlend

        let joltMagnitude = simd_length(highPassedVector)
        let requiredMagnitude = max(absoluteMinimumJoltMagnitude, adaptiveNoiseFloor * noiseFloorMultiplier) * thresholdMultiplier
        let isJolt = joltMagnitude >= requiredMagnitude

        // Only quiet samples teach the noise floor, so a burst of taps cannot raise it.
        if !isJolt {
            let noiseBlend = 1 - exp(-elapsedSeconds / Self.noiseFloorTimeConstantInSeconds)
            adaptiveNoiseFloor += (joltMagnitude - adaptiveNoiseFloor) * noiseBlend
        } else {
            mostRecentJoltTime = sampleTime
        }
        return isJolt
    }

    var lastSampleTime: Double { previousSampleTime ?? -.infinity }
}

// MARK: - Light dip detection

/// Finds a finger-shaped shadow on the ambient light sensor: a drop well below
/// the recent baseline that recovers within a second.
nonisolated struct ScreenTapLightDipDetector {
    struct CompletedDip: Equatable {
        let startTime: Double
        let deepestTime: Double
        let endTime: Double
    }

    private struct DipInProgress {
        let startTime: Double
        let baselineLux: Double
        var deepestLux: Double
        var deepestTime: Double
    }

    /// The fraction of the baseline the light must drop by to count as shaded.
    static let minimumRelativeDrop = 0.18
    /// In very dark rooms there is nothing to shade; below this the sensor is ignored.
    static let minimumUsableBaselineLux = 0.25
    static let minimumAbsoluteDropLux = 0.08
    /// A finger resting longer than this is not a tap.
    static let maximumDipDurationInSeconds = 0.9
    /// The light must come back at least this far from the deepest point toward the baseline.
    static let recoveryFraction = 0.6
    private static let baselineTimeConstantInSeconds = 0.35

    private var baselineLux: Double?
    private var previousSampleTime: Double = -.infinity
    private var dipInProgress: DipInProgress?

    mutating func reset() {
        self = ScreenTapLightDipDetector()
    }

    /// Feeds one light sample. Returns the dip when this sample completes one.
    mutating func addSample(lux: Double, at sampleTime: Double, thresholdMultiplier: Double) -> CompletedDip? {
        guard lux.isFinite, lux >= 0, sampleTime.isFinite, sampleTime > previousSampleTime else { return nil }
        let elapsedSeconds = sampleTime - previousSampleTime
        previousSampleTime = sampleTime

        // Light sensors report slowly (around 10–20 Hz) but a long silence means a stall.
        if elapsedSeconds > 0.7 {
            baselineLux = lux
            dipInProgress = nil
            return nil
        }

        if var dip = dipInProgress {
            if lux < dip.deepestLux {
                dip.deepestLux = lux
                dip.deepestTime = sampleTime
            }
            if sampleTime - dip.startTime > Self.maximumDipDurationInSeconds {
                // Too long: a hand resting or the room went dark. Adopt the new level.
                dipInProgress = nil
                baselineLux = lux
                return nil
            }
            let recoveryLevel = dip.deepestLux + (dip.baselineLux - dip.deepestLux) * Self.recoveryFraction
            if lux >= recoveryLevel {
                dipInProgress = nil
                return CompletedDip(startTime: dip.startTime, deepestTime: dip.deepestTime, endTime: sampleTime)
            }
            dipInProgress = dip
            return nil
        }

        guard let currentBaseline = baselineLux else {
            baselineLux = lux
            return nil
        }

        let requiredDrop = max(Self.minimumAbsoluteDropLux, currentBaseline * Self.minimumRelativeDrop) * thresholdMultiplier
        if currentBaseline >= Self.minimumUsableBaselineLux, currentBaseline - lux >= requiredDrop {
            dipInProgress = DipInProgress(startTime: sampleTime, baselineLux: currentBaseline, deepestLux: lux, deepestTime: sampleTime)
            return nil
        }

        let baselineBlend = 1 - exp(-elapsedSeconds / Self.baselineTimeConstantInSeconds)
        baselineLux = currentBaseline + (lux - currentBaseline) * baselineBlend
        return nil
    }
}

// MARK: - Lid stability

/// Moving the lid shades the light sensor and shakes the motion sensors all at once,
/// which looks exactly like a tap. Taps only count once the lid has held still.
nonisolated struct ScreenTapLidStabilityGuard {
    static let settleDurationInSeconds = 2.5
    static let movementToleranceInDegrees = 1.0
    /// Lid angles outside this range mean closed, folded flat, or a bad reading.
    static let usableLidAngleRangeInDegrees: ClosedRange<Double> = 25...175

    private var referenceAngleInDegrees: Double?
    private var stillSinceTime: Double = .infinity
    private var lastReadingTime: Double = -.infinity

    mutating func reset() {
        self = ScreenTapLidStabilityGuard()
    }

    mutating func addReading(angleInDegrees: Double?, at readingTime: Double) {
        guard readingTime.isFinite, readingTime > lastReadingTime else { return }
        lastReadingTime = readingTime
        guard let angleInDegrees, angleInDegrees.isFinite,
              Self.usableLidAngleRangeInDegrees.contains(angleInDegrees) else {
            referenceAngleInDegrees = nil
            stillSinceTime = .infinity
            return
        }
        guard let referenceAngle = referenceAngleInDegrees,
              abs(angleInDegrees - referenceAngle) < Self.movementToleranceInDegrees else {
            referenceAngleInDegrees = angleInDegrees
            stillSinceTime = readingTime
            return
        }
    }

    func isSettled(at time: Double) -> Bool {
        referenceAngleInDegrees != nil
            && time - stillSinceTime >= Self.settleDurationInSeconds
            && time - lastReadingTime <= 0.5
    }
}

// MARK: - The recognizer

/// Combines the three detectors. A tap is a completed light dip with an
/// accelerometer jolt and a gyroscope jolt, close together, near the dip.
nonisolated struct ScreenTapRecognizer {
    var sensitivity: ScreenTapSensitivity = .standard

    private var accelerometerJoltDetector = ScreenTapMotionJoltDetector(absoluteMinimumJoltMagnitude: 0.0012, noiseFloorMultiplier: 2.0)
    private var gyroscopeJoltDetector = ScreenTapMotionJoltDetector(absoluteMinimumJoltMagnitude: 0.15, noiseFloorMultiplier: 1.7)
    private var lightDipDetector = ScreenTapLightDipDetector()
    private(set) var lidGuard = ScreenTapLidStabilityGuard()

    /// Recent jolt times per stream, newest last. Kept short.
    private var accelerometerJoltTimes: [Double] = []
    private var gyroscopeJoltTimes: [Double] = []
    private var lastAcceptedTapTime: Double = -.infinity

    /// How far before the shadow starts the jolt may land (the knock can come first).
    static let joltLeadWindowInSeconds = 0.3
    /// How far after the darkest moment the jolt may land.
    static let joltTrailWindowInSeconds = 0.15
    /// Accelerometer and gyroscope must agree on the moment of the knock.
    static let maximumJoltPairGapInSeconds = 0.06
    /// Two taps closer than this are one tap.
    static let tapDebounceInSeconds = 0.35
    /// Motion older than this means a motion stream is stalled and the light alone cannot be trusted.
    static let maximumMotionStalenessInSeconds = 0.1

    init(sensitivity: ScreenTapSensitivity = .standard) {
        self.sensitivity = sensitivity
    }

    mutating func reset() {
        self = ScreenTapRecognizer(sensitivity: sensitivity)
    }

    mutating func addLidReading(angleInDegrees: Double?, at time: Double) {
        lidGuard.addReading(angleInDegrees: angleInDegrees, at: time)
    }

    mutating func addAccelerometerSample(_ accelerationInG: SIMD3<Double>, at time: Double) {
        if accelerometerJoltDetector.addSample(accelerationInG, at: time, thresholdMultiplier: sensitivity.thresholdMultiplier) {
            Self.remember(time, in: &accelerometerJoltTimes)
        }
    }

    mutating func addGyroscopeSample(_ rotationInDegreesPerSecond: SIMD3<Double>, at time: Double) {
        if gyroscopeJoltDetector.addSample(rotationInDegreesPerSecond, at: time, thresholdMultiplier: sensitivity.thresholdMultiplier) {
            Self.remember(time, in: &gyroscopeJoltTimes)
        }
    }

    /// Feeds one light sample. Returns true exactly when this sample completes a tap.
    mutating func addAmbientLightSample(lux: Double, at time: Double) -> Bool {
        let motionIsFresh = time - accelerometerJoltDetector.lastSampleTime <= Self.maximumMotionStalenessInSeconds
            && time - gyroscopeJoltDetector.lastSampleTime <= Self.maximumMotionStalenessInSeconds
        guard motionIsFresh, lidGuard.isSettled(at: time) else {
            lightDipDetector.reset()
            return false
        }

        guard let completedDip = lightDipDetector.addSample(lux: lux, at: time, thresholdMultiplier: sensitivity.thresholdMultiplier) else {
            return false
        }

        let windowStart = completedDip.startTime - Self.joltLeadWindowInSeconds
        let windowEnd = completedDip.deepestTime + Self.joltTrailWindowInSeconds
        let accelerometerJoltsInWindow = accelerometerJoltTimes.filter { $0 >= windowStart && $0 <= windowEnd }
        let gyroscopeJoltsInWindow = gyroscopeJoltTimes.filter { $0 >= windowStart && $0 <= windowEnd }
        let hasAgreeingJoltPair = accelerometerJoltsInWindow.contains { accelerometerJoltTime in
            gyroscopeJoltsInWindow.contains { abs($0 - accelerometerJoltTime) <= Self.maximumJoltPairGapInSeconds }
        }
        guard hasAgreeingJoltPair, time - lastAcceptedTapTime >= Self.tapDebounceInSeconds else { return false }

        lastAcceptedTapTime = time
        // One knock, one tap: the same jolt cannot vouch for a second dip.
        accelerometerJoltTimes.removeAll()
        gyroscopeJoltTimes.removeAll()
        return true
    }

    private static func remember(_ joltTime: Double, in joltTimes: inout [Double]) {
        // Consecutive samples of one jolt collapse into a single entry.
        if let newestJoltTime = joltTimes.last, joltTime - newestJoltTime < 0.01 { return }
        joltTimes.append(joltTime)
        joltTimes.removeAll { joltTime - $0 > 1.5 }
    }
}
