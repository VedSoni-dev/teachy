import Foundation
import CoreGraphics

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(message)")
}
func near(_ actual: CGPoint?, _ expected: CGPoint, tolerance: Double = 0.000001) -> Bool {
    guard let actual else { return false }
    return hypot(actual.x - expected.x, actual.y - expected.y) < tolerance
}
let grid: [CGPoint] = [0.1, 0.5, 0.9].flatMap { y in [0.1, 0.5, 0.9].map { CGPoint(x: $0, y: y) } }
let identity = grid.map { CameraCalibrationSample(feature: $0, target: $0) }
let direct = CameraGazeCalibration.fit(samples: identity)
expect(direct != nil, "well-spread nine-point calibration succeeds")
expect(near(direct?.project(CGPoint(x: 0.37, y: 0.62)), CGPoint(x: 0.37, y: 0.62)), "affine interpolation predicts an unseen point")
expect((direct?.meanError ?? 1) < 0.000001, "exact fit reports negligible error")
let transformed = grid.map { target in
    CameraCalibrationSample(feature: CGPoint(x: 0.1 - target.x * 0.04 + target.y * 0.01,
                                             y: -0.02 + target.y * 0.03 + target.x * 0.008), target: target)
}
let mirrored = CameraGazeCalibration.fit(samples: transformed)
expect(mirrored != nil, "mirrored, translated, scaled and sheared features calibrate")
let target = CGPoint(x: 0.73, y: 0.32)
let feature = CGPoint(x: 0.1 - target.x * 0.04 + target.y * 0.01,
                      y: -0.02 + target.y * 0.03 + target.x * 0.008)
expect(near(mirrored?.project(feature), target), "mirrored transform predicts held-out coordinates")
expect(near(direct?.project(CGPoint(x: -2, y: 3)), CGPoint(x: 0, y: 1)), "projection clamps to practice-pad boundaries")
expect(direct?.project(CGPoint(x: CGFloat.nan, y: 0)) == nil, "nonfinite feature cannot produce gaze")
expect(CameraGazeCalibration.fit(samples: Array(identity.prefix(4))) == nil, "fewer than five samples are rejected")
expect(CameraGazeCalibration.fit(samples: grid.map { CameraCalibrationSample(feature: .zero, target: $0) }) == nil, "static eyes cannot fake calibration")
expect(CameraGazeCalibration.fit(samples: grid.map { CameraCalibrationSample(feature: CGPoint(x: $0.x, y: $0.x * 2), target: $0) }) == nil, "collinear feature axes are rejected")
expect(CameraGazeCalibration.fit(samples: grid.map { CameraCalibrationSample(feature: CGPoint(x: $0.x * 0.000001, y: $0.y * 0.000001), target: $0) }) == nil, "negligible motion is rejected")
var invalid = identity
invalid[0] = CameraCalibrationSample(feature: CGPoint(x: CGFloat.infinity, y: 1), target: .zero)
expect(CameraGazeCalibration.fit(samples: invalid) == nil, "nonfinite calibration samples are rejected")
invalid = identity
invalid[0] = CameraCalibrationSample(feature: .zero, target: CGPoint(x: CGFloat.nan, y: 1))
expect(CameraGazeCalibration.fit(samples: invalid) == nil, "nonfinite targets are rejected")
let scrambled = grid.enumerated().map { index, point in
    CameraCalibrationSample(feature: point, target: CGPoint(x: index % 2 == 0 ? 0 : 1, y: index % 3 == 0 ? 1 : 0))
}
expect(CameraGazeCalibration.fit(samples: scrambled) == nil, "inconsistent gaze calibration fails quality threshold")
var gate = CameraPinchGate()
expect(!gate.update(ratio: 0.1, timestamp: 0) && !gate.update(ratio: 0.1, timestamp: 0.1), "starting with pinched fingers does not activate")
expect(!gate.update(ratio: 0.5, timestamp: 0.2), "opening arms without activating")
expect(!gate.update(ratio: 0.1, timestamp: 0.3), "one closed sample does not activate")
expect(gate.update(ratio: 0.1, timestamp: 0.4), "second closed sample activates once")
expect(!gate.update(ratio: 0.1, timestamp: 1.1), "held pinch does not repeat after cooldown")
expect(!gate.update(ratio: nil, timestamp: 1.2) && !gate.update(ratio: 0.1, timestamp: 1.3) && !gate.update(ratio: 0.1, timestamp: 1.4), "tracking loss cannot rearm a held pinch")
_ = gate.update(ratio: 0.5, timestamp: 1.5)
_ = gate.update(ratio: 0.1, timestamp: 1.6)
expect(gate.update(ratio: 0.1, timestamp: 1.7), "open hand after loss permits a new pinch")
_ = gate.update(ratio: 0.5, timestamp: 1.8)
_ = gate.update(ratio: 0.1, timestamp: 1.9)
expect(!gate.update(ratio: 0.1, timestamp: 2.0), "cooldown suppresses a rapid second pinch")
expect(!gate.update(ratio: 0.1, timestamp: 2.5), "cooldown suppression does not defer activation until a held pinch ages")
_ = gate.update(ratio: 0.5, timestamp: 2.6)
_ = gate.update(ratio: 0.1, timestamp: 2.7)
_ = gate.update(ratio: 0.35, timestamp: 2.8)
expect(!gate.update(ratio: 0.1, timestamp: 2.9), "threshold jitter resets consecutive closed count")
expect(gate.update(ratio: 0.1, timestamp: 3.0), "two fresh closed samples after jitter activate")
_ = gate.update(ratio: 0.5, timestamp: 3.1)
_ = gate.update(ratio: 0.1, timestamp: 3.2)
expect(!gate.update(ratio: 0.1, timestamp: 3.2), "duplicate timestamps cannot count as another frame")
expect(!gate.update(ratio: 0.1, timestamp: 3.9), "duplicate frame disarms rather than creating a delayed click")
gate.reset()
expect(!gate.update(ratio: 0.1, timestamp: 0), "reset requires another observed release")
_ = gate.update(ratio: 0.6, timestamp: 0.1)
expect(!gate.update(ratio: Double.nan, timestamp: 0.2), "invalid pinch ratio is ignored and disarms")
expect(!gate.update(ratio: 0.1, timestamp: 0.3) && !gate.update(ratio: 0.1, timestamp: 0.4), "invalid sample cannot rearm a pinch")
var smoother = CameraPointSmoother()
expect(near(smoother.update(CGPoint(x: 0.2, y: 0.2)), CGPoint(x: 0.2, y: 0.2)), "first point has no stale smoothing delay")
expect(near(smoother.update(CGPoint(x: 0.8, y: 0.8)), CGPoint(x: 0.41, y: 0.41)), "smoothing damps a sudden movement")
expect(smoother.update(nil) == nil, "tracking loss removes the pointer")
expect(near(smoother.update(CGPoint(x: 0.8, y: 0.8)), CGPoint(x: 0.8, y: 0.8)), "reacquisition does not animate from stale location")
expect(smoother.update(CGPoint(x: CGFloat.nan, y: 0)) == nil, "invalid points clear smoothing state")
expect(near(smoother.update(CGPoint(x: -1, y: 2)), CGPoint(x: 0, y: 1)), "smoother clamps finite coordinates")
smoother.reset()
expect(near(smoother.update(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5)), "manual reset clears prior history")
print("\(checks - failures)/\(checks) CAMERA INPUT CHECKS PASSED")
exit(failures == 0 ? 0 : 1)
