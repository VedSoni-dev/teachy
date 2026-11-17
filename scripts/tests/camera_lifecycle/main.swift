import AppKit
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(message)")
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Task { @MainActor in
    let model = CameraInputController()
    expect(model.capture.state == .idle, "setup does not start the camera")
    model.calibrate()
    expect(model.targetIndex == nil, "calibration cannot begin with the camera off")
    model.start()
    model.capture.feed(CameraTrackingSample(handPoint: CGPoint(x: 0.3, y: 0.4), eyeFeature: CGPoint(x: 0.1, y: 0.1), timestamp: 1))
    expect(model.handPoint != nil && model.eyesVisible, "valid tracking reaches the preview")
    model.calibrate()
    try? await Task.sleep(for: .milliseconds(30))
    expect(model.targetIndex == 0, "calibration starts at the first target")
    model.cancelCalibration()
    expect(model.targetIndex == nil && !model.isSampling, "cancel removes the calibration target")
    expect(model.calibrationMessage.contains("canceled"), "cancel replaces the look-at-dot instruction")
    try? await Task.sleep(for: .milliseconds(1000))
    expect(!model.isSampling && model.targetIndex == nil, "cancelled calibration cannot resume after its delay")

    model.calibrate()
    var timestamp = 2.0
    for _ in 0..<700 {
        try? await Task.sleep(for: .milliseconds(20))
        if let index = model.targetIndex, model.isSampling {
            let target = model.targets[index]
            timestamp += 0.02
            model.capture.feed(CameraTrackingSample(eyeFeature: CGPoint(x: 0.2 + target.x * 0.3, y: 0.1 + target.y * 0.2), timestamp: timestamp))
        }
        if model.isCalibrated { break }
    }
    expect(model.isCalibrated, "nine valid targets produce calibration")
    timestamp += 1
    model.capture.feed(CameraTrackingSample(eyeFeature: CGPoint(x: 0.35, y: 0.2), timestamp: timestamp))
    expect(model.gazePoint.map { abs($0.x - 0.5) < 0.01 && abs($0.y - 0.5) < 0.01 } ?? false,
           "calibrated eyes project to a held-out practice point")
    model.capture.feed(CameraTrackingSample(timestamp: timestamp + 1))
    expect(model.gazePoint == nil && !model.eyesVisible, "lost eyes remove the gaze dot")
    model.invalidateEyeCalibration()
    expect(!model.isCalibrated && model.gazePoint == nil, "moving the window invalidates calibration")
    model.calibrate()
    try? await Task.sleep(for: .milliseconds(30))
    model.stop()
    try? await Task.sleep(for: .milliseconds(1000))
    expect(model.capture.state == .idle && model.targetIndex == nil && !model.isSampling,
           "stop cancels delayed calibration and camera work")
    expect(model.handPoint == nil && model.gazePoint == nil && !model.eyesVisible,
           "stop clears all tracked output")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
