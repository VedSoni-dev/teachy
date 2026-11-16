// Tests for screen-tap recognition and webcam gaze math. Run with scripts/tests/run_touch_gaze_tests.sh.
// Synthetic sensor streams only: no hardware, no camera, no app.
import CoreGraphics
import Foundation
import simd

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL (line \(line)): \(message)") }
}

// MARK: - Synthetic sensor streams

/// Builds an interleaved, time-ordered stream like the real sensors: motion at 800 Hz,
/// light at 20 Hz, lid angle at 10 Hz.
struct SyntheticSession {
    var durationInSeconds: Double = 6
    var lidAngle: (Double) -> Double? = { _ in 110 }
    var lux: (Double) -> Double = { _ in 120 }
    var acceleration: (Double) -> SIMD3<Double> = { _ in SIMD3(0, 0, -1) }
    var rotation: (Double) -> SIMD3<Double> = { _ in .zero }
    /// Tiny deterministic noise so the adaptive floor has something to learn.
    var noiseAmplitude: Double = 0.0002

    func run(sensitivity: ScreenTapSensitivity = .standard, motionStallBetween: ClosedRange<Double>? = nil) -> [Double] {
        var recognizer = ScreenTapRecognizer(sensitivity: sensitivity)
        var tapTimes: [Double] = []
        let motionStep = 1.0 / 800
        var nextLightTime = 0.0
        var nextLidTime = 0.0
        var time = 0.0
        var sampleIndex = 0
        while time < durationInSeconds {
            if time >= nextLidTime {
                recognizer.addLidReading(angleInDegrees: lidAngle(time), at: time)
                nextLidTime += 0.1
            }
            let isStalled = motionStallBetween?.contains(time) ?? false
            if !isStalled {
                let wobble = sin(Double(sampleIndex) * 1.7) * noiseAmplitude
                recognizer.addAccelerometerSample(acceleration(time) + SIMD3(wobble, -wobble, wobble), at: time)
                recognizer.addGyroscopeSample(rotation(time) + SIMD3(wobble * 100, wobble * 50, -wobble * 80), at: time + 0.0002)
            }
            if time >= nextLightTime {
                if recognizer.addAmbientLightSample(lux: lux(time), at: time + 0.0004) { tapTimes.append(time) }
                nextLightTime += 0.05
            }
            time += motionStep
            sampleIndex += 1
        }
        return tapTimes
    }
}

/// A damped knock starting at `knockTime`: a few milliseconds of ringing.
func knock(at knockTime: Double, strength: Double) -> (Double) -> Double {
    { time in
        let elapsed = time - knockTime
        guard elapsed >= 0, elapsed < 0.04 else { return 0 }
        return strength * exp(-elapsed / 0.008) * sin(elapsed * 2 * .pi * 120)
    }
}

/// The light sensor shaded from `start` for `duration` seconds.
func shadow(start: Double, duration: Double, baseline: Double = 120, shadedFraction: Double = 0.45) -> (Double) -> Double {
    { time in (time >= start && time < start + duration) ? baseline * shadedFraction : baseline }
}

func tapSession(knocks: [Double], shadows: [(Double, Double)], knockStrengthG: Double = 0.02, knockStrengthGyro: Double = 3) -> SyntheticSession {
    var session = SyntheticSession()
    let accelKnocks = knocks.map { knock(at: $0, strength: knockStrengthG) }
    let gyroKnocks = knocks.map { knock(at: $0, strength: knockStrengthGyro) }
    session.acceleration = { time in SIMD3(0, accelKnocks.reduce(0) { $0 + $1(time) }, -1) }
    session.rotation = { time in SIMD3(gyroKnocks.reduce(0) { $0 + $1(time) }, 0, 0) }
    let shadowFunctions = shadows.map { shadow(start: $0.0, duration: $0.1) }
    session.lux = { time in shadowFunctions.map { $0(time) }.min() ?? 120 }
    return session
}

print("— report decoding")
var motionReport = [UInt8](repeating: 0, count: 22)
func putInt32(_ value: Int32, at offset: Int, in bytes: inout [UInt8]) {
    let bits = UInt32(bitPattern: value)
    for byteIndex in 0..<4 { bytes[offset + byteIndex] = UInt8((bits >> (8 * UInt32(byteIndex))) & 0xFF) }
}
putInt32(65_536, at: 6, in: &motionReport)
putInt32(-32_768, at: 10, in: &motionReport)
putInt32(0, at: 14, in: &motionReport)
expect(ScreenTapSensorReportDecoder.motionVector(fromReportBytes: motionReport) == SIMD3(1, -0.5, 0), "fixed-point axes decode")
expect(ScreenTapSensorReportDecoder.motionVector(fromReportBytes: [UInt8](repeating: 0, count: 21)) == nil, "wrong length rejected")
var lightReport = [UInt8](repeating: 0, count: 122)
let luxBits = Float(321.5).bitPattern
for byteIndex in 0..<4 { lightReport[40 + byteIndex] = UInt8((luxBits >> (8 * UInt32(byteIndex))) & 0xFF) }
expect(ScreenTapSensorReportDecoder.ambientLightLux(fromReportBytes: lightReport) == 321.5, "lux float decodes")
let nanBits = Float.nan.bitPattern
for byteIndex in 0..<4 { lightReport[40 + byteIndex] = UInt8((nanBits >> (8 * UInt32(byteIndex))) & 0xFF) }
expect(ScreenTapSensorReportDecoder.ambientLightLux(fromReportBytes: lightReport) == nil, "NaN lux rejected")

print("— taps")
let oneTap = tapSession(knocks: [3.5], shadows: [(3.48, 0.2)]).run()
expect(oneTap.count == 1, "a knock with a shadow is one tap: \(oneTap)")
if let tapTime = oneTap.first { expect(tapTime > 3.5 && tapTime < 4.0, "tap lands when the finger lifts: \(tapTime)") }

let twoTaps = tapSession(knocks: [3.0, 4.2], shadows: [(2.98, 0.2), (4.18, 0.2)]).run()
expect(twoTaps.count == 2, "two separate taps: \(twoTaps)")

expect(tapSession(knocks: [3.5], shadows: []).run().isEmpty, "a knock alone (typing, bumping the desk) is not a tap")
expect(tapSession(knocks: [], shadows: [(3.5, 0.2)]).run().isEmpty, "a shadow alone (hand passing) is not a tap")
expect(tapSession(knocks: [2.0], shadows: [(3.5, 0.2)]).run().isEmpty, "a knock long before the shadow is not a tap")
expect(tapSession(knocks: [3.5], shadows: [(3.48, 1.6)]).run().isEmpty, "a finger resting for over a second is not a tap")
expect(tapSession(knocks: [1.0], shadows: [(0.98, 0.2)]).run().isEmpty, "no taps before the lid has settled after start")

var movingLid = tapSession(knocks: [3.5], shadows: [(3.48, 0.2)])
movingLid.lidAngle = { time in time < 3.0 ? 100 + time * 4 : 112 }
expect(movingLid.run().isEmpty, "no taps right after the lid moved")
var closedLid = tapSession(knocks: [3.5], shadows: [(3.48, 0.2)])
closedLid.lidAngle = { _ in 5 }
expect(closedLid.run().isEmpty, "no taps with the lid nearly closed")
var noLid = tapSession(knocks: [3.5], shadows: [(3.48, 0.2)])
noLid.lidAngle = { _ in nil }
expect(noLid.run().isEmpty, "no taps without a lid reading")

expect(tapSession(knocks: [3.5], shadows: [(3.48, 0.2)]).run(motionStallBetween: 3.3...3.8).isEmpty,
       "a stalled motion stream blocks taps")

var darkRoom = tapSession(knocks: [3.5], shadows: [])
darkRoom.lux = { time in (time >= 3.48 && time < 3.68) ? 0.05 : 0.1 }
expect(darkRoom.run().isEmpty, "in a dark room the light sensor is ignored")

let softKnock = tapSession(knocks: [3.5], shadows: [(3.48, 0.2)], knockStrengthG: 0.0016, knockStrengthGyro: 0.2)
expect(softKnock.run(sensitivity: .gentle).count == 1, "a soft tap counts on Light touch")
expect(softKnock.run(sensitivity: .firm).isEmpty, "a soft tap does not count on Firm")

var vibratingDesk = tapSession(knocks: [3.5], shadows: [])
vibratingDesk.noiseAmplitude = 0.003
expect(vibratingDesk.run().isEmpty, "background vibration plus a bump without a shadow is not a tap")

print("— gaze features")
let eyeOutline: (CGFloat, CGFloat) -> [CGPoint] = { centerX, centerY in
    [CGPoint(x: centerX - 0.03, y: centerY), CGPoint(x: centerX, y: centerY + 0.008),
     CGPoint(x: centerX + 0.03, y: centerY), CGPoint(x: centerX, y: centerY - 0.008)]
}
let openEyes = GazeEyeFeatures.make(
    leftPupil: CGPoint(x: 0.415, y: 0.55), leftEyeOutline: eyeOutline(0.4, 0.55),
    rightPupil: CGPoint(x: 0.615, y: 0.55), rightEyeOutline: eyeOutline(0.6, 0.55),
    headYawInRadians: 0.1, headPitchInRadians: -0.05, faceBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.5)
)
expect(openEyes?.values.count == GazeEyeFeatures.featureCount, "feature vector has every feature")
expect(abs((openEyes?.values[0] ?? 0) - 0.25) < 1e-9, "pupil offset measured in eye widths")
expect(openEyes?.isBlink == false, "open eyes are not a blink")
let closedEyes = GazeEyeFeatures.make(
    leftPupil: CGPoint(x: 0.4, y: 0.55), leftEyeOutline: [CGPoint(x: 0.37, y: 0.55), CGPoint(x: 0.4, y: 0.551), CGPoint(x: 0.43, y: 0.55), CGPoint(x: 0.4, y: 0.549)],
    rightPupil: CGPoint(x: 0.6, y: 0.55), rightEyeOutline: [CGPoint(x: 0.57, y: 0.55), CGPoint(x: 0.6, y: 0.551), CGPoint(x: 0.63, y: 0.55), CGPoint(x: 0.6, y: 0.549)],
    headYawInRadians: 0, headPitchInRadians: 0, faceBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.5)
)
expect(closedEyes?.isBlink == true, "squashed eyes are a blink")
expect(GazeEyeFeatures.make(leftPupil: .zero, leftEyeOutline: [], rightPupil: .zero, rightEyeOutline: [],
                            headYawInRadians: 0, headPitchInRadians: 0, faceBoundingBox: .zero) == nil, "no outline, no features")

print("— regression")
expect(GazeRegressionModel.solveLinearSystem([[2, 1], [1, 3]], [3, 5]).map { abs($0[0] - 0.8) < 1e-9 && abs($0[1] - 1.4) < 1e-9 } == true, "solves a 2×2 system")
expect(GazeRegressionModel.solveLinearSystem([[1, 2], [2, 4]], [1, 2]) == nil, "singular systems return nil")

// A synthetic person: pupils move with the target, plus a little head turn and noise.
var randomState: UInt64 = 42
func noise(_ amplitude: Double) -> Double {
    randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
    return (Double(randomState >> 11) / Double(1 << 53) - 0.5) * 2 * amplitude
}
func syntheticFeatures(lookingAt target: CGPoint) -> [Double] {
    let offsetX = (Double(target.x) - 0.5) * 0.3 + noise(0.006)
    let offsetY = (Double(target.y) - 0.5) * 0.18 + noise(0.006)
    return [offsetX, offsetY, offsetX + noise(0.004), offsetY + noise(0.004),
            (Double(target.x) - 0.5) * 0.15 + noise(0.01), (Double(target.y) - 0.5) * 0.1 + noise(0.01),
            0.5 + noise(0.003), 0.55 + noise(0.003), 0.4 + noise(0.002),
            offsetX * offsetX, offsetX * offsetY, offsetY * offsetY]
}
var trainingSamples: [GazeRegressionModel.TrainingSample] = []
for target in GazeCalibrationTargets.positions {
    for _ in 0..<25 { trainingSamples.append(.init(features: syntheticFeatures(lookingAt: target), screenPosition: target)) }
}
expect(GazeCalibrationTargets.positions.count == 9, "nine calibration dots")
let model = GazeRegressionModel.fit(samples: trainingSamples)
expect(model != nil, "calibration fits")
if let model {
    var totalErrorInPoints = 0.0
    let screenSize = CGSize(width: 1512, height: 982)
    let testTargets = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.6), CGPoint(x: 0.5, y: 0.85), CGPoint(x: 0.15, y: 0.5)]
    for target in testTargets {
        let predicted = model.predictScreenPosition(features: syntheticFeatures(lookingAt: target))!
        totalErrorInPoints += Double(hypot((predicted.x - target.x) * screenSize.width, (predicted.y - target.y) * screenSize.height))
    }
    let averageError = totalErrorInPoints / Double(testTargets.count)
    expect(averageError < 90, "predicts unseen positions within a cell or so: \(Int(averageError)) pt")
    let encoded = try! JSONEncoder().encode(model)
    expect((try? JSONDecoder().decode(GazeRegressionModel.self, from: encoded)) == model, "model round-trips through JSON")
    expect(model.predictScreenPosition(features: [1, 2]) == nil, "wrong feature count rejected")
}
expect(GazeRegressionModel.fit(samples: Array(trainingSamples.prefix(5))) == nil, "too few samples to fit")
var constantFeatureSamples = trainingSamples
constantFeatureSamples = constantFeatureSamples.map { sample in
    var features = sample.features
    features[4] = 0
    features[5] = 0
    return .init(features: features, screenPosition: sample.screenPosition)
}
expect(GazeRegressionModel.fit(samples: constantFeatureSamples) != nil, "a feature that never changes (no head pose) still fits")

print("— smoothing")
var filter = GazeOneEuroFilter()
var lastFiltered = CGPoint.zero
var jitterTotal = 0.0
// Screen fractions on a 1512 pt wide screen: ±0.0165 is ±25 pt of jitter.
let screenWidthInPoints = 1512.0
for frameIndex in 0..<60 {
    let jittery = CGPoint(x: 0.33 + (frameIndex % 2 == 0 ? 0.0165 : -0.0165), y: 0.4)
    let filtered = filter.filter(jittery, at: Double(frameIndex) / 30)
    if frameIndex > 30 { jitterTotal += abs(Double(filtered.x - lastFiltered.x)) * screenWidthInPoints }
    lastFiltered = filtered
}
expect(jitterTotal / 29 < 12, "jitter of ±25 pt is damped while still: \(jitterTotal / 29) pt per frame")
for frameIndex in 60..<75 { lastFiltered = filter.filter(CGPoint(x: 0.73, y: 0.4), at: Double(frameIndex) / 30) }
expect(lastFiltered.x > 0.66, "a real eye jump is followed within half a second: \(lastFiltered.x)")

print("— fixations")
var gazeSamples: [GazeSample] = []
for frameIndex in 0..<30 { gazeSamples.append(GazeSample(time: Double(frameIndex) / 30, pointInGlobalCoordinates: CGPoint(x: 300 + noise(15), y: 600 + noise(15)))) }
for frameIndex in 30..<33 { gazeSamples.append(GazeSample(time: Double(frameIndex) / 30, pointInGlobalCoordinates: CGPoint(x: 300 + Double(frameIndex - 29) * 200, y: 600))) }
for frameIndex in 33..<48 { gazeSamples.append(GazeSample(time: Double(frameIndex) / 30, pointInGlobalCoordinates: CGPoint(x: 1000 + noise(15), y: 300 + noise(15)))) }
let foundFixations = GazeFixationFinder.fixations(in: gazeSamples)
expect(foundFixations.count == 2, "two places looked at: \(foundFixations.count)")
let dominant = GazeFixationFinder.dominantFixations(in: gazeSamples)
expect(dominant.first.map { abs($0.centerInGlobalCoordinates.x - 300) < 30 } == true, "the longest look comes first")
expect(dominant.first.map { $0.durationInSeconds > 0.8 } == true, "dwell is measured: \(dominant.first?.durationInSeconds ?? 0)")
var revisits = gazeSamples
for frameIndex in 48..<60 { revisits.append(GazeSample(time: Double(frameIndex) / 30, pointInGlobalCoordinates: CGPoint(x: 1000 + noise(15), y: 300 + noise(15)))) }
for frameIndex in 60..<80 { revisits.append(GazeSample(time: Double(frameIndex) / 30, pointInGlobalCoordinates: CGPoint(x: 1010 + noise(15), y: 310 + noise(15)))) }
expect(GazeFixationFinder.dominantFixations(in: revisits).first.map { abs($0.centerInGlobalCoordinates.x - 1000) < 40 } == true,
       "looking back at the same place adds up")
var saccades: [GazeSample] = []
for frameIndex in 0..<30 { saccades.append(GazeSample(time: Double(frameIndex) / 30, pointInGlobalCoordinates: CGPoint(x: Double(frameIndex) * 60, y: 400))) }
expect(GazeFixationFinder.fixations(in: saccades).isEmpty, "constant sweeping is not a fixation")
expect(GazeFixationFinder.fixations(in: []).isEmpty, "no samples, no fixations")

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASSED")
