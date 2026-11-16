import AppKit
import Combine
import SwiftUI

@MainActor
final class CameraInputController: ObservableObject {
    let capture = CameraTrackingCapture()
    @Published private(set) var handPoint: CGPoint?
    @Published private(set) var gazePoint: CGPoint?
    @Published private(set) var pinchCount = 0
    @Published private(set) var targetIndex: Int?
    @Published private(set) var calibrationMessage = "Calibrate your eyes, then test the gaze dot in the practice area."
    @Published private(set) var isCalibrated = false
    @Published private(set) var isSampling = false
    @Published private(set) var eyesVisible = false

    let targets: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.5, y: 0.15), CGPoint(x: 0.85, y: 0.15),
        CGPoint(x: 0.85, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.15, y: 0.5),
        CGPoint(x: 0.15, y: 0.85), CGPoint(x: 0.5, y: 0.85), CGPoint(x: 0.85, y: 0.85)
    ]
    private var calibration: CameraGazeCalibration?
    private var samples: [CGPoint] = []
    private var handSmoother = CameraPointSmoother()
    private var eyeSmoother = CameraPointSmoother()
    private var pinchGate = CameraPinchGate()
    private var subscriptions: Set<AnyCancellable> = []
    private var calibrationTask: Task<Void, Never>?

    init() {
        capture.$sample.sink { [weak self] sample in self?.consume(sample) }.store(in: &subscriptions)
        capture.$state.sink { [weak self] state in
            if state != .running { self?.resetTracking() }
        }.store(in: &subscriptions)
    }

    func start() { capture.start() }
    func stop() {
        cancelCalibration()
        capture.stop()
        resetTracking()
    }
    func cancelCalibration() {
        if targetIndex != nil { calibrationMessage = "Calibration canceled. Choose Calibrate eyes when you’re ready." }
        calibrationTask?.cancel()
        calibrationTask = nil
        targetIndex = nil
        isSampling = false
        samples.removeAll()
    }
    func invalidateEyeCalibration() {
        cancelCalibration()
        calibration = nil
        isCalibrated = false
        gazePoint = nil
        eyeSmoother.reset()
        calibrationMessage = "Calibrate your eyes in this window position, then test the gaze dot."
    }
    private func resetTracking() {
        cancelCalibration()
        calibration = nil
        isCalibrated = false
        handPoint = nil
        gazePoint = nil
        eyesVisible = false
        calibrationMessage = "Calibrate your eyes, then test the gaze dot in the practice area."
        handSmoother.reset()
        eyeSmoother.reset()
        pinchGate.reset()
    }
    private func consume(_ sample: CameraTrackingSample) {
        handPoint = handSmoother.update(sample.handPoint)
        eyesVisible = sample.eyeFeature != nil
        gazePoint = eyeSmoother.update(sample.eyeFeature.flatMap { calibration?.project($0) })
        if pinchGate.update(ratio: sample.pinchRatio, timestamp: sample.timestamp) { pinchCount += 1 }
        if isSampling, let feature = sample.eyeFeature { samples.append(feature) }
    }

    func calibrate() {
        guard capture.state == .running else { return }
        cancelCalibration()
        calibration = nil
        isCalibrated = false
        gazePoint = nil
        eyeSmoother.reset()
        calibrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var observations: [CameraCalibrationSample] = []
            for (index, target) in targets.enumerated() {
                guard !Task.isCancelled else { return }
                targetIndex = index
                calibrationMessage = "Look at the blue dot. Keep your head still. \(index + 1) of \(targets.count)"
                isSampling = false
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                samples.removeAll()
                isSampling = true
                // Missing eyes do not count as samples. Give each target time to recover.
                for _ in 0..<40 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    if samples.count >= 12 { break }
                }
                isSampling = false
                guard samples.count >= 12 else {
                    calibrationMessage = "I lost your eyes. Face the camera in even light, then try again."
                    targetIndex = nil
                    return
                }
                let count = CGFloat(samples.count)
                let mean = CGPoint(x: samples.reduce(0) { $0 + $1.x } / count,
                                   y: samples.reduce(0) { $0 + $1.y } / count)
                observations.append(CameraCalibrationSample(feature: mean, target: target))
            }
            targetIndex = nil
            samples.removeAll()
            guard let fitted = CameraGazeCalibration.fit(samples: observations) else {
                calibrationMessage = "The eye signal wasn't distinct enough. Improve the lighting, keep your head still, and recalibrate."
                return
            }
            calibration = fitted
            isCalibrated = true
            calibrationMessage = "Calibration ready. Look around the practice area to test the green dot. Recalibrate if it drifts."
        }
    }
}

@MainActor
final class CameraInputWindowController: NSObject, NSWindowDelegate {
    static let shared = CameraInputWindowController()
    private var window: NSWindow?
    private var model: CameraInputController?
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = CameraInputController()
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Teachy · Camera input"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.workspaceBackground)
        window.contentView = NSHostingView(rootView: CameraInputSetupView(model: model))
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        model?.stop()
    }
    func windowDidMove(_ notification: Notification) {
        model?.invalidateEyeCalibration()
    }
    func windowWillClose(_ notification: Notification) {
        model?.stop()
        window = nil
        model = nil
    }
}
