//
//  CallDetector.swift
//  leanring-buddy
//
//  "Quiet on calls": knows when the person is on a call, so always-on pauses and
//  answers turn into captions instead of sound.
//
//  The signal is which other apps have the microphone open (CoreAudio's per-process
//  list). A call app (Zoom, FaceTime, Teams, Slack, Discord …) or a browser with the
//  microphone open is a call; a recorder, a dictation tool or an unknown app is not.
//  When macOS won't say which apps they are, it falls back to "the input device is
//  in use and a known call app is running". The rule is `CallDecision.isInCall`.
//
//  What this can't know: screen sharing with the microphone off, and what a browser
//  tab is doing with the microphone (any browser microphone use counts as a call).
//

import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class CallDetector: ObservableObject {
    static let shared = CallDetector()

    @Published private(set) var isInCall = false
    /// The app that made it a call, for display ("On a call in Zoom").
    @Published private(set) var callAppName: String?

    /// Set by whoever has the microphone open inside Teachy (push-to-talk, always-on),
    /// so Teachy's own use is never mistaken for a call on Macs without the per-app list.
    var teachyIsRecording: () -> Bool = { false }

    private var deviceObservation: AudioHardware.Observation?
    private var systemObservation: AudioHardware.Observation?
    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        watchDefaultInputDevice()
        systemObservation = AudioHardware.observe(
            object: AudioObjectID(kAudioObjectSystemObject),
            selectors: [
                (kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal),
                (kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal),
            ]
        ) { [weak self] in
            Task { @MainActor in
                self?.watchDefaultInputDevice()
                self?.refresh()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    /// Checks again right now. Cheap (a few CoreAudio reads); speech calls it before each reply.
    @discardableResult
    func refresh() -> Bool {
        let others = AudioHardware.otherBundleIDsUsingMicrophone()
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let decided = CallDecision.isInCall(
            otherBundleIDsUsingMicrophone: others,
            inputDeviceInUse: AudioHardware.isDefaultInputInUse(),
            teachyIsRecording: teachyIsRecording(),
            runningBundleIDs: running,
            previous: isInCall
        )
        let appName = decided ? Self.callAppName(among: others ?? running) : nil
        if decided != isInCall { isInCall = decided }
        if appName != callAppName { callAppName = appName }
        updatePolling()
        return decided
    }

    private static func callAppName(among bundleIDs: [String]) -> String? {
        guard let bundleID = bundleIDs.first(where: { CallDecision.kind(ofBundleID: $0) == .call }) else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        // A helper process (a browser's audio helper) shares its app's bundle prefix.
        let match = apps.first { $0.bundleIdentifier == bundleID }
            ?? apps.first { app in app.bundleIdentifier.map { bundleID.hasPrefix($0) } ?? false }
        return match?.localizedName
    }

    private func watchDefaultInputDevice() {
        deviceObservation?.cancel()
        guard let deviceID = AudioHardware.defaultInputDeviceID() else { return }
        deviceObservation = AudioHardware.observe(
            object: deviceID,
            selectors: [(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal)]
        ) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// While a call is on, or while Teachy records (when the device signal can't change),
    /// look again every few seconds so the end of the call is noticed.
    private func updatePolling() {
        let shouldPoll = isInCall || teachyIsRecording()
        if shouldPoll, pollTimer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !shouldPoll, pollTimer != nil {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}
