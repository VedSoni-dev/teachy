//
//  DictationController.swift
//  leanring-buddy
//
//  System-wide dictation. Hold Fn+Control and speak; release and the text lands in
//  whatever field has the caret. Double-tap Fn+Control for hands-free, double-tap
//  again to stop, Escape to cancel.
//
//  Flow: hotkey tap -> state machine -> record -> DictationSession (live typing,
//  publik transcription with on-device text as fallback, faithful cleanup,
//  insert or in-place correction, local backup) -> watch the field for 20 s to
//  learn corrected words. This file owns the hotkey, the microphone and the pill.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class DictationController {
    static let shared = DictationController()

    /// Hands-free sessions end by themselves after this long.
    private static let maximumRecordingSeconds: TimeInterval = 600
    private static let permissionPollSeconds: TimeInterval = 3

    private enum Phase {
        case idle
        case recording
        case processing
    }

    private var machine = DictationHotkeyStateMachine()
    private let monitor = DictationHotkeyMonitor()

    // MARK: - Changing the shortcut

    enum ShortcutRecordingResult {
        case saved([UInt16])
        case cancelled
        case rejected(String)
    }

    /// Records the next keys the person holds and saves them as the dictation shortcut.
    /// Times out after 10 seconds. Needs the hotkey monitor (Accessibility permission).
    func recordShortcut(completion: @escaping (ShortcutRecordingResult) -> Void) {
        guard monitor.start() else {
            completion(.rejected("Teachy needs Accessibility permission before it can listen for keys."))
            return
        }
        cancelCurrentDictationForShortcutRecording()
        monitor.beginRecordingShortcut { recordedKeys in
            guard let recordedKeys else {
                completion(.cancelled)
                return
            }
            if let problem = DictationShortcut.validationProblem(recordedKeys, pushToTalk: PushToTalkShortcutKeys.currentShortcutKeyCodes) {
                completion(.rejected(problem))
                return
            }
            DictationShortcut.save(recordedKeys)
            completion(.saved(DictationShortcut.current()))
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.monitor.isRecordingShortcut else { return }
            self.monitor.cancelRecordingShortcut()
        }
    }

    func cancelShortcutRecording() {
        monitor.cancelRecordingShortcut()
    }

    /// A dictation in progress would fight the recorder for the same key presses.
    private func cancelCurrentDictationForShortcutRecording() {
        if phase == .recording {
            handle(.escape, at: ProcessInfo.processInfo.systemUptime)
        }
    }
    private let recorder = DictationAudioRecorder()
    private let pill = DictationPillController()
    private let correctionWatcher = DictationCorrectionWatcher()

    private var phase: Phase = .idle
    private var session: DictationSession?
    private var hasStarted = false
    private var readinessSubscription: AnyCancellable?
    private var permissionTimer: Timer?
    private var deadlineTimer: Timer?
    private var maximumLengthTimer: Timer?

    private init() {}

    // MARK: - Start-up

    /// Call once at launch. Waits for the publik gate, then for Accessibility and
    /// Microphone to be granted (it never asks for them itself), then starts
    /// listening for the hotkey.
    func startWhenReady() {
        guard !hasStarted else { return }
        hasStarted = true

        recorder.onLiveText = { [weak self] text in
            Task { @MainActor in self?.pill.model.liveText = text }
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.pill.model.level = level }
        }
        // The main queue keeps these in the order they happened.
        recorder.onSegmentText = { [weak self] index, text, isFinal in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.phase == .recording else { return }
                    self.session?.segmentTextChanged(index: index, text: text, isFinal: isFinal)
                }
            }
        }
        recorder.onAudioFrame = { [weak self] rms, seconds in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.phase == .recording else { return }
                    self.session?.audioFrame(rms: rms, seconds: seconds)
                }
            }
        }
        monitor.onEvent = { [weak self] event, time in
            self?.handle(event, at: time)
        }

        readinessSubscription = TeachyPublikSession.shared.$isReady
            .removeDuplicates()
            .sink { [weak self] isReady in
                if isReady {
                    self?.startMonitoringWhenPermitted()
                } else {
                    self?.stop()
                }
            }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        deadlineTimer?.invalidate()
        maximumLengthTimer?.invalidate()
        monitor.stop()
        session?.cancel()
        session = nil
        recorder.cancel()
        pill.hide()
        machine.reset()
        phase = .idle
    }

    private static var hasRequiredPermissions: Bool {
        WindowPositionManager.hasAccessibilityPermission()
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func startMonitoringWhenPermitted() {
        if Self.hasRequiredPermissions, monitor.start() { return }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: Self.permissionPollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Self.hasRequiredPermissions, self.monitor.start() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    // MARK: - Hotkey events

    private func handle(_ event: DictationHotkeyStateMachine.Event, at time: TimeInterval) {
        for action in machine.handle(event, at: time) {
            switch action {
            case .startRecording: beginRecording()
            case .enterHandsFree: enterHandsFree()
            case .finish: finishRecording()
            case .cancel: cancelRecording()
            }
        }
        scheduleDeadlineTick()
    }

    /// The state machine has no clock; this wakes it when a double-tap window ends.
    private func scheduleDeadlineTick() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = machine.deadline else { return }
        let delay = max(0.01, deadline - ProcessInfo.processInfo.systemUptime + 0.01)
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handle(.tick, at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        // Still finishing the last dictation, or the mic permission was taken
        // away: this press does nothing. The later finish/cancel is ignored too
        // because the phase never became `.recording`.
        guard phase == .idle else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            pill.flash("Microphone access is off")
            return
        }

        correctionWatcher.finish()
        do {
            try recorder.start(
                contextualStrings: DictationDictionary.shared.words,
                useOnDeviceSpeech: SFSpeechRecognizer.authorizationStatus() == .authorized,
                languageCode: TeachySettingsStorage.dictationLanguageCode()
            )
        } catch {
            print("⚠️ Dictation: couldn't start the microphone: \(error.localizedDescription)")
            pill.flash("Microphone unavailable")
            return
        }

        // Created after the microphone starts, so the focused field is read once
        // and the first words go where the caret is now.
        session = DictationSession(mode: DictationSpeedMode.current(), recorder: recorder, correctionWatcher: correctionWatcher)
        phase = .recording
        pill.show(.dictating)
        maximumLengthTimer?.invalidate()
        maximumLengthTimer = Timer.scheduledTimer(withTimeInterval: Self.maximumRecordingSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.machine.reset()
                self.finishRecording()
            }
        }
    }

    private func enterHandsFree() {
        guard phase == .recording else { return }
        session?.isHandsFree = true
        pill.model.mode = .handsFree
    }

    private func cancelRecording() {
        guard phase == .recording else { return }
        maximumLengthTimer?.invalidate()
        session?.cancel()
        session = nil
        recorder.cancel()
        phase = .idle
        pill.hide()
    }

    private func finishRecording() {
        guard phase == .recording, let session else { return }
        maximumLengthTimer?.invalidate()
        phase = .processing

        let pcm = recorder.stop()
        session.onWaiting = { [weak self] in
            self?.pill.show(.working)
        }
        // In speed mode this fires as soon as the on-device text is complete in
        // the field; the session then reconciles with publik in the background
        // while the next dictation can already start.
        session.onFinishedForUser = { [weak self, weak session] notice in
            guard let self, let session, self.session === session else { return }
            self.session = nil
            self.phase = .idle
            if let notice {
                self.pill.flash(notice)
            } else {
                self.pill.hide()
            }
        }
        session.finish(lastSegmentPCM: pcm)
    }
}

/// After an Accessibility insertion, watches the same field for 20 seconds. If the
/// person fixes one word inside the dictated text, that word joins the dictionary.
@MainActor
final class DictationCorrectionWatcher {
    private static let watchSeconds: TimeInterval = 20
    private static let pollSeconds: TimeInterval = 1

    private var element: AXUIElement?
    private var baseline = ""
    private var insertedRange = NSRange(location: 0, length: 0)
    private var timer: Timer?
    private var startedAt = Date()
    private var latestCorrection: DictationEditDiff.Correction?
    /// A correction seen on two polls in a row; kept even if the field is
    /// cleared afterwards (the message was sent).
    private var settledCorrection: DictationEditDiff.Correction?

    func watch(element: AXUIElement, baseline: String, insertedRange: NSRange) {
        finish()
        self.element = element
        self.baseline = baseline
        self.insertedRange = insertedRange
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Ends the watch now and saves what was learned, if anything.
    func finish() {
        guard element != nil else { return }
        timer?.invalidate()
        timer = nil
        element = nil
        let correction = latestCorrection ?? settledCorrection
        latestCorrection = nil
        settledCorrection = nil
        guard let correction else { return }

        let isKnownWord: (String) -> Bool = { word in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        }
        guard DictationEditDiff.isWorthLearning(correction.corrected, isKnownWord: isKnownWord) else { return }
        if DictationDictionary.shared.add(correction.corrected) {
            print("📖 Dictation: learned a corrected word")
        }
    }

    private func poll() {
        guard let element else { return }
        if let current = DictationTextInserter.stringAttribute(element, kAXValueAttribute as String) {
            let correction = DictationEditDiff.correction(baseline: baseline, current: current, insertedRange: insertedRange)
            if let correction, correction == latestCorrection { settledCorrection = correction }
            latestCorrection = correction
        }
        if Date().timeIntervalSince(startedAt) >= Self.watchSeconds { finish() }
    }
}
