//
//  GazeTracker.swift
//  leanring-buddy
//
//  Webcam eye tracking for the voice turn. While the setting is on, the camera
//  runs, each frame becomes a gaze estimate on screen (through the person's
//  calibration), and the last few seconds are kept in memory. When a question
//  is asked, `consumeQuestionGaze()` returns where they looked while asking, and
//  `CompanionGazeContext` turns that into "they were looking at cells K7–L8".
//
//  Privacy: frames never leave `GazeCameraReader`; only screen positions are
//  kept, for a few seconds, in memory. The calibration (a handful of regression
//  weights, no images) is stored in UserDefaults. The camera light is on while
//  eye tracking is on, and it pauses while the Mac sleeps or is locked.
//

import AppKit
import Combine
import Foundation

@MainActor
final class GazeTracker: ObservableObject {
    static let shared = GazeTracker()

    enum State: Equatable {
        case off
        case starting
        case needsCameraPermission
        case noCamera
        case needsCalibration
        case calibrating
        case tracking
        /// Tracking, but no face has been seen for a moment.
        case lookingForFace
    }

    @Published private(set) var state: State = .off
    @Published private(set) var calibration: SavedCalibration?

    struct SavedCalibration: Codable, Equatable {
        let model: GazeRegressionModel
        /// The screen it was calibrated on, in global AppKit coordinates. Predictions land on this rectangle.
        let screenFrame: CGRect
        let calibratedAt: Date
        /// Average distance between the dots and the predictions, in points.
        let averageErrorInPoints: Double
    }

    private static let calibrationDefaultsKey = "teachyGazeCalibration"
    /// How much gaze history is kept, in seconds.
    private static let historyDurationInSeconds = 12.0
    /// Gaze from just before the talk key is pressed counts too: people look first, then ask.
    private static let leadInBeforeQuestionInSeconds = 1.2
    /// With no talk-key window (hands-free or typed questions), use this much recent gaze.
    private static let recentGazeWindowInSeconds = 3.0

    private let cameraReader = GazeCameraReader()
    private var smoothingFilter = GazeOneEuroFilter()
    private var gazeHistory: [GazeSample] = []
    private var lastFaceSeenTime: Double = -.infinity
    private var questionStartTime: Double?
    private var questionEndTime: Double?
    private var settingsCancellable: AnyCancellable?
    private var sleepObservers: [NSObjectProtocol] = []
    private var pauseReasons: Set<String> = []
    private var isCameraRunning = false
    private var hasStarted = false

    /// Receives raw features while calibrating, instead of the tracking path.
    private var calibrationFeatureSink: ((GazeEyeFeatures) -> Void)?

    /// The newest smoothed gaze point, for the calibration check dot.
    private(set) var latestGazePointInGlobalCoordinates: CGPoint?

    private init() {
        calibration = Self.loadCalibration()
        cameraReader.onFrame = { [weak self] features, frameTime in
            Task { @MainActor [weak self] in self?.handleFrame(features: features, frameTime: frameTime) }
        }
    }

    /// Call once at launch. Follows the setting from then on.
    func startFollowingSettings() {
        guard !hasStarted else { return }
        hasStarted = true
        settingsCancellable = TeachySettings.shared.$eyeTrackingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor [weak self] in await self?.applyCurrentState() } }
        observeSleepAndLock()
    }

    var isCalibrated: Bool { calibration != nil }

    var stateDescription: String {
        switch state {
        case .off: return "Off."
        case .starting: return "Starting the camera…"
        case .needsCameraPermission: return "Teachy needs camera access. Allow it in System Settings → Privacy & Security → Camera."
        case .noCamera: return "No camera found. Connect one or use your iPhone as a Continuity Camera."
        case .needsCalibration: return "Calibrate once so Teachy knows where you're looking."
        case .calibrating: return "Calibrating…"
        case .tracking: return "On. Teachy sees roughly where you look while you ask."
        case .lookingForFace: return "Looking for your face. Sit in front of the camera."
        }
    }

    // MARK: - Question window

    /// The talk key went down (or the screen was tapped to talk).
    func questionStarted() {
        questionStartTime = Self.now()
        questionEndTime = nil
    }

    /// The talk key came up.
    func questionEnded() {
        guard questionStartTime != nil else { return }
        questionEndTime = Self.now()
    }

    /// The gaze samples that belong to the question being answered, then forgets the window.
    /// Empty when eye tracking is off or uncalibrated.
    func consumeQuestionGaze() -> [GazeSample] {
        guard state == .tracking || state == .lookingForFace else { return [] }
        let now = Self.now()
        let windowStart: Double
        let windowEnd: Double
        if let questionStartTime, now - questionStartTime < 120 {
            windowStart = questionStartTime - Self.leadInBeforeQuestionInSeconds
            windowEnd = questionEndTime ?? now
        } else {
            windowStart = now - Self.recentGazeWindowInSeconds
            windowEnd = now
        }
        questionStartTime = nil
        questionEndTime = nil
        return gazeHistory.filter { $0.time >= windowStart && $0.time <= windowEnd }
    }

    // MARK: - Calibration

    /// Starts the camera if needed and routes raw features to `sink` until `endCalibrationCapture`.
    func beginCalibrationCapture(sink: @escaping (GazeEyeFeatures) -> Void) async -> Bool {
        calibrationFeatureSink = sink
        state = .calibrating
        let cameraStarted = await startCameraIfNeeded()
        if !cameraStarted { calibrationFeatureSink = nil }
        return cameraStarted
    }

    func endCalibrationCapture(saving newCalibration: SavedCalibration?) {
        calibrationFeatureSink = nil
        if let newCalibration {
            calibration = newCalibration
            if let encoded = try? JSONEncoder().encode(newCalibration) {
                UserDefaults.standard.set(encoded, forKey: Self.calibrationDefaultsKey)
            }
            smoothingFilter.reset()
            gazeHistory.removeAll()
        }
        // Leave the calibrating state so `applyCurrentState` decides afresh (and stops the camera if the setting is off).
        state = .off
        Task { await applyCurrentState() }
    }

    func forgetCalibration() {
        calibration = nil
        UserDefaults.standard.removeObject(forKey: Self.calibrationDefaultsKey)
        gazeHistory.removeAll()
        Task { await applyCurrentState() }
    }

    private static func loadCalibration() -> SavedCalibration? {
        guard let data = UserDefaults.standard.data(forKey: calibrationDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SavedCalibration.self, from: data)
    }

    // MARK: - Frames

    private func handleFrame(features: GazeEyeFeatures?, frameTime: Double) {
        let now = Self.now()
        guard let features, !features.isBlink else {
            if state == .tracking, now - lastFaceSeenTime > 1.5 { state = .lookingForFace }
            return
        }
        lastFaceSeenTime = now

        if let calibrationFeatureSink {
            calibrationFeatureSink(features)
            return
        }
        guard let calibration,
              let normalizedPosition = calibration.model.predictScreenPosition(features: features.values) else { return }
        if state == .lookingForFace { state = .tracking }

        // 0…1 across and down the calibrated screen → global AppKit points (origin bottom-left).
        let screenFrame = calibration.screenFrame
        let clampedPosition = CGPoint(
            x: min(max(normalizedPosition.x, -0.05), 1.05),
            y: min(max(normalizedPosition.y, -0.05), 1.05)
        )
        // The filter is tuned in screen fractions, so smooth before converting to points.
        let smoothedPosition = smoothingFilter.filter(clampedPosition, at: now)
        let smoothedPoint = CGPoint(
            x: screenFrame.minX + smoothedPosition.x * screenFrame.width,
            y: screenFrame.maxY - smoothedPosition.y * screenFrame.height
        )
        latestGazePointInGlobalCoordinates = smoothedPoint
        gazeHistory.append(GazeSample(time: now, pointInGlobalCoordinates: smoothedPoint))
        gazeHistory.removeAll { now - $0.time > Self.historyDurationInSeconds }
    }

    // MARK: - Lifecycle

    private func applyCurrentState() async {
        guard state != .calibrating else { return }
        let shouldRun = TeachySettings.shared.eyeTrackingEnabled && pauseReasons.isEmpty
        guard shouldRun else {
            stopCamera()
            state = .off
            return
        }
        guard calibration != nil else {
            stopCamera()
            state = .needsCalibration
            return
        }
        state = .starting
        if await startCameraIfNeeded() {
            state = .tracking
        }
    }

    /// Returns false (and sets the state to say why) when the camera cannot run.
    private func startCameraIfNeeded() async -> Bool {
        guard !isCameraRunning else { return true }
        do {
            try await cameraReader.start()
            isCameraRunning = true
            lastFaceSeenTime = Self.now()
            return true
        } catch GazeCameraReader.StartFailure.cameraPermissionDenied {
            state = .needsCameraPermission
        } catch {
            state = .noCamera
        }
        return false
    }

    private func stopCamera() {
        guard isCameraRunning else { return }
        cameraReader.stop()
        isCameraRunning = false
        gazeHistory.removeAll()
        smoothingFilter.reset()
        latestGazePointInGlobalCoordinates = nil
    }

    private func observeSleepAndLock() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let pausePairs: [(pause: Notification.Name, resume: Notification.Name, reason: String, center: NotificationCenter)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep", workspaceCenter),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screenSleep", workspaceCenter),
            (Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), "locked", DistributedNotificationCenter.default()),
        ]
        for pausePair in pausePairs {
            sleepObservers.append(pausePair.center.addObserver(forName: pausePair.pause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pauseReasons.insert(pausePair.reason)
                    await self?.applyCurrentState()
                }
            })
            sleepObservers.append(pausePair.center.addObserver(forName: pausePair.resume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pauseReasons.remove(pausePair.reason)
                    await self?.applyCurrentState()
                }
            })
        }
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}
