//
//  DictationController.swift
//  leanring-buddy
//
//  System-wide dictation. Hold Fn+Control and speak; release and the text lands in
//  whatever field has the caret. Double-tap Fn+Control for hands-free, double-tap
//  again to stop, Escape to cancel.
//
//  Flow: hotkey tap -> state machine -> record (live on-device text in the pill)
//  -> publik transcription (on-device text as fallback) -> faithful cleanup ->
//  insert -> local backup -> watch the field for 20 s to learn corrected words.
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
    private let recorder = DictationAudioRecorder()
    private let pill = DictationPillController()
    private let correctionWatcher = DictationCorrectionWatcher()

    private var phase: Phase = .idle
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
        monitor.onEvent = { [weak self] event, time in
            self?.handle(event, at: time)
        }

        readinessSubscription = TeachyPublikSession.shared.$isReady
            .filter { $0 }
            .first()
            .sink { [weak self] _ in self?.startMonitoringWhenPermitted() }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        deadlineTimer?.invalidate()
        maximumLengthTimer?.invalidate()
        monitor.stop()
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
                useOnDeviceSpeech: SFSpeechRecognizer.authorizationStatus() == .authorized
            )
        } catch {
            print("⚠️ Dictation: couldn't start the microphone: \(error.localizedDescription)")
            pill.flash("Microphone unavailable")
            return
        }

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
        pill.model.mode = .handsFree
    }

    private func cancelRecording() {
        guard phase == .recording else { return }
        maximumLengthTimer?.invalidate()
        recorder.cancel()
        phase = .idle
        pill.hide()
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        maximumLengthTimer?.invalidate()
        phase = .processing

        let pcm = recorder.stop()
        let liveText = recorder.liveText
        if DictationSilenceGate().shouldDiscard(pcm16: pcm, sampleRate: DictationAudioFormat.sampleRate, liveText: liveText) {
            recorder.cancel()
            phase = .idle
            pill.hide()
            return
        }

        pill.show(.working)
        Task { @MainActor in
            await self.transcribeCleanAndInsert(pcm: pcm)
            self.phase = .idle
        }
    }

    // MARK: - Transcribe, clean, insert

    private func transcribeCleanAndInsert(pcm: Data) async {
        let recorder = self.recorder
        let dictionaryPrompt = DictationDictionary.shared.transcriptionPrompt

        let transcript = await DictationPipeline.transcribe(pcm16: pcm, dictionaryPrompt: dictionaryPrompt) {
            await recorder.finalLiveText(timeout: 2)
        }
        recorder.cancel()

        guard !DictationSilenceGate.isEmptyTranscript(transcript.text, dictionaryPrompt: dictionaryPrompt) else {
            pill.hide()
            return
        }

        let cleaned = await DictationPipeline.cleanUp(raw: transcript.text)

        // The app in front now is where the text goes (it may have changed
        // while the person was speaking).
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let textToInsert = DictationInsertionRules.textToInsert(cleaned.text, bundleIdentifier: bundleIdentifier)
        guard !textToInsert.isEmpty else {
            pill.hide()
            return
        }

        let outcome = await DictationTextInserter.insert(textToInsert)

        DictationHistoryLog.shared.append(DictationHistoryLog.Entry(
            appBundleIdentifier: bundleIdentifier,
            raw: transcript.text,
            cleaned: cleaned.text,
            transcriber: transcript.source,
            insertion: outcome.historyLabel
        ))
        print("🎙️ Dictation: \(transcript.source) \(transcript.milliseconds) ms, cleanup \(cleaned.usedCleanup ? "\(cleaned.milliseconds) ms" : "not used"), inserted via \(outcome.historyLabel)")

        switch outcome {
        case .accessibility(let element, let baseline, let insertedRange):
            pill.hide()
            if let baseline, let insertedRange {
                correctionWatcher.watch(element: element, baseline: baseline, insertedRange: insertedRange)
            }
        case .pasted:
            pill.hide()
        case .copiedToClipboard:
            pill.flash("Copied")
        case .failed:
            // Nothing is lost: the text is in the backup file, and now on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToInsert, forType: .string)
            pill.flash("Copied")
        }
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
