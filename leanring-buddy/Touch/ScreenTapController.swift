//
//  ScreenTapController.swift
//  leanring-buddy
//
//  Owns "tap the screen to talk" for the app: starts and stops `ScreenTapSensor`
//  from the setting, pauses it while the Mac sleeps, the screen sleeps or the
//  session is locked, and hands each recognised tap to `onTap` on the main actor.
//  `CompanionManager` wires `onTap` to the same path as the push-to-talk key:
//  first tap starts listening, the next tap sends the question.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ScreenTapController: ObservableObject {
    static let shared = ScreenTapController()

    @Published private(set) var status: ScreenTapSensor.Status = .stopped
    /// When the last tap was recognised; the settings page uses it as live feedback.
    @Published private(set) var lastRecognizedTapDate: Date?

    /// Called on the main actor for every recognised tap.
    var onTap: (() -> Void)?

    /// Read once; the sensors of a Mac do not come and go.
    let isSupportedOnThisMac = ScreenTapSensor.isSupportedOnThisMac

    private let sensor = ScreenTapSensor()
    private var settingsCancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pauseReasons: Set<String> = []
    private var hasStarted = false

    private init() {
        sensor.onTap = { [weak self] in
            Task { @MainActor [weak self] in self?.deliverTap() }
        }
        sensor.onStatusChange = { [weak self] newStatus in
            Task { @MainActor [weak self] in self?.status = newStatus }
        }
    }

    /// Call once at launch. Follows the setting from then on.
    func startFollowingSettings() {
        guard !hasStarted else { return }
        hasStarted = true
        let settings = TeachySettings.shared
        settings.$screenTapEnabled.combineLatest(settings.$screenTapSensitivity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.applyCurrentState() }
            .store(in: &settingsCancellables)
        observeSleepAndLock()
        applyCurrentState()
    }

    var statusDescription: String {
        guard isSupportedOnThisMac else {
            return "Needs a MacBook with Apple silicon; this Mac has no light and motion sensors."
        }
        switch status {
        case .stopped: return "Off."
        case .starting: return "Starting the sensors…"
        case .settling: return "Hold the lid still for a moment."
        case .ready: return "Ready. Tap the screen just beside the camera."
        case .unavailable: return "The sensors could not be opened on this Mac."
        }
    }

    private func deliverTap() {
        guard TeachySettings.shared.screenTapEnabled, pauseReasons.isEmpty else { return }
        lastRecognizedTapDate = Date()
        onTap?()
    }

    private func applyCurrentState() {
        let settings = TeachySettings.shared
        let shouldRun = isSupportedOnThisMac && settings.screenTapEnabled && pauseReasons.isEmpty
        if shouldRun {
            sensor.start(sensitivity: settings.screenTapSensitivity)
            sensor.updateSensitivity(settings.screenTapSensitivity)
        } else {
            sensor.stop()
        }
    }

    private func setPaused(_ isPaused: Bool, reason: String) {
        if isPaused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        applyCurrentState()
    }

    private func observeSleepAndLock() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let pausePairs: [(pause: Notification.Name, resume: Notification.Name, reason: String, center: NotificationCenter)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep", workspaceCenter),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screenSleep", workspaceCenter),
            (Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), "locked", DistributedNotificationCenter.default()),
        ]
        for pausePair in pausePairs {
            workspaceObservers.append(pausePair.center.addObserver(forName: pausePair.pause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setPaused(true, reason: pausePair.reason) }
            })
            workspaceObservers.append(pausePair.center.addObserver(forName: pausePair.resume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setPaused(false, reason: pausePair.reason) }
            })
        }
    }
}
