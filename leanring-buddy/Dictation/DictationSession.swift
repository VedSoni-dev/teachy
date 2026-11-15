//
//  DictationSession.swift
//  leanring-buddy
//
//  One dictation, from the first word to the final text in the field.
//
//  Speed first (see DictationSpeedPolicy.swift for the setting):
//    while speaking   the on-device recognizer's stable words are typed into the
//                     focused field through Accessibility (a "live region" that
//                     remembers exactly what it typed and where);
//    on release       the on-device final text completes the region at once and
//                     the person can carry on (measured: under 200 ms);
//    afterwards       publik's transcript (plus cleanup when it needs any) comes
//                     back and replaces the region in place, only when it differs
//                     meaningfully and the region is still intact.
//  Fields that can't be typed into safely (Chromium, Electron, terminals): the
//  live words stay in the pill; a short, confident on-device text is pasted at
//  once, anything else waits for publik and is inserted once.
//
//  Accuracy first: nothing is typed until publik and cleanup are back.
//
//  Hands-free (both modes): the recording is cut at pauses into sentence-sized
//  segments; each is transcribed and typed while the person keeps talking.
//

import AppKit
import Foundation

/// Runs async pieces of work one after another on the main actor.
@MainActor
final class DictationSerialQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func run<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}

@MainActor
final class DictationSession {
    /// Speculative transcriptions are only worth it for clips this short.
    private static let maximumSpeculationClipSeconds = 30.0
    private static let maximumSpeculationsPerSession = 3

    let mode: DictationSpeedMode
    var isHandsFree = false

    /// Called once, when the person has their text (or there is none) and can
    /// dictate again. `notice` is a short message for the pill, or nil.
    var onFinishedForUser: ((_ notice: String?) -> Void)?
    /// Called when more than a moment of waiting starts (show "Finishing").
    var onWaiting: (() -> Void)?

    private let recorder: DictationAudioRecorder
    private let correctionWatcher: DictationCorrectionWatcher
    private let dictionaryPrompt: String?
    private let languageCode: String?
    private let cleanupEnabled: Bool
    private let typesWhileSpeaking: Bool

    /// The field focused when the dictation started, when it can be edited safely.
    private var liveField: DictationAXField?
    private var regions: [Int: DictationLiveRegion] = [:]
    private var stablePrefixes: [Int: DictationStablePrefix] = [:]
    private var liveTargets: [Int: String] = [:]
    /// Segments whose audio has ended; their text now comes from `deliver`.
    private var closedSegments: Set<Int> = []
    private let edits = DictationSerialQueue()
    private let deliveries = DictationSerialQueue()

    private var detector = DictationPauseDetector()
    private var recordedSeconds = 0.0
    private var cutCount = 0
    private var speculation: Task<DictationPipeline.Transcript, Never>?
    private var speculationCount = 0

    private var releasedAt: Date?
    private var firstLiveTextAt: Date?
    private var hasFinishedForUser = false
    private var isCancelled = false

    init(mode: DictationSpeedMode, recorder: DictationAudioRecorder, correctionWatcher: DictationCorrectionWatcher) {
        self.mode = mode
        self.recorder = recorder
        self.correctionWatcher = correctionWatcher
        self.dictionaryPrompt = DictationDictionary.shared.transcriptionPrompt
        self.languageCode = TeachySettingsStorage.dictationLanguageCode()
        self.cleanupEnabled = TeachySettingsStorage.dictationCleanupEnabled()
        self.typesWhileSpeaking = mode == .speedFirst && DictationSpeedMode.liveInsertionEnabled()
        if mode == .speedFirst {
            liveField = DictationTextInserter.focusedEditableField()
        }
    }

    private static func sleep(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    // MARK: - While speaking

    /// The on-device text of one segment changed.
    func segmentTextChanged(index: Int, text: String, isFinal: Bool) {
        guard typesWhileSpeaking, liveField != nil, !isCancelled, !isFinal, !closedSegments.contains(index) else { return }
        let target = stablePrefixes[index, default: DictationStablePrefix()].feed(text)
        guard !target.isEmpty, target != liveTargets[index] else { return }
        liveTargets[index] = target
        edits.enqueue { [weak self] in
            // Reads the newest target, so a backlog collapses into one edit.
            guard let self, !self.closedSegments.contains(index), !self.isCancelled,
                  let newest = self.liveTargets[index] else { return }
            _ = await self.setRegion(index, to: newest)
        }
    }

    /// One buffer of microphone audio arrived.
    func audioFrame(rms: Double, seconds: Double) {
        guard releasedAt == nil, !isCancelled else { return }
        recordedSeconds += seconds
        for event in detector.feed(rms: rms, seconds: seconds) {
            switch event {
            case .pause: startSpeculationIfUseful()
            case .segmentBoundary: if isHandsFree { cutSegment() }
            }
        }
    }

    /// The person paused. Send what they said so far, so that if they let go
    /// without saying more, the transcript is already on its way.
    private func startSpeculationIfUseful() {
        guard mode == .speedFirst, !isHandsFree, cutCount == 0,
              speculationCount < Self.maximumSpeculationsPerSession,
              recordedSeconds <= Self.maximumSpeculationClipSeconds
        else { return }
        speculation?.cancel()
        speculationCount += 1
        detector.markSpeculation()
        let pcm = recorder.pcmSnapshot()
        let dictionaryPrompt = dictionaryPrompt
        let languageCode = languageCode
        speculation = Task {
            await DictationPipeline.transcribe(pcm16: pcm, dictionaryPrompt: dictionaryPrompt, language: languageCode) { "" }
        }
    }

    private func cutSegment() {
        guard let cut = recorder.cutSegment() else { return }
        cutCount += 1
        speculation?.cancel()
        speculation = nil
        closedSegments.insert(cut.index)
        deliveries.enqueue { [weak self] in
            await self?.deliver(index: cut.index, pcm: cut.pcm, isLast: false)
        }
    }

    // MARK: - Ending

    /// The person let go (or double-tapped to stop). `pcm` is the last segment's audio.
    func finish(lastSegmentPCM pcm: Data) {
        releasedAt = Date()
        let index = recorder.activeSegmentIndex
        closedSegments.insert(index)
        deliveries.enqueue { [weak self] in
            await self?.deliver(index: index, pcm: pcm, isLast: true)
        }
    }

    /// Escape: take back the words of the segment in progress, if they are intact.
    func cancel() {
        isCancelled = true
        speculation?.cancel()
        let index = recorder.activeSegmentIndex
        closedSegments.insert(index)
        edits.enqueue { [weak self] in
            guard let self, let region = self.regions[index], region.state == .active else { return }
            _ = await self.setRegion(index, to: "", evenIfCancelled: true)
        }
    }

    private func finishForUser(notice: String? = nil) {
        guard !hasFinishedForUser else { return }
        hasFinishedForUser = true
        onFinishedForUser?(notice)
    }

    // MARK: - Editing the field

    /// Makes segment `index`'s typed text equal `text`. Runs on the `edits` queue.
    private func setRegion(_ index: Int, to text: String, evenIfCancelled: Bool = false) async -> Bool {
        guard let liveField, evenIfCancelled || !isCancelled else { return false }
        let region: DictationLiveRegion
        if let existing = regions[index] {
            region = existing
        } else {
            guard let created = DictationLiveRegion(field: liveField) else {
                self.liveField = nil
                return false
            }
            regions[index] = created
            region = created
        }
        let succeeded = await region.update(to: text, wait: Self.sleep)
        if succeeded {
            if firstLiveTextAt == nil { firstLiveTextAt = Date() }
            let delta = region.lastDelta
            if delta != 0 {
                for (otherIndex, other) in regions where otherIndex > index { other.shift(by: delta) }
            }
        } else if region.state == .unsupported {
            // This app accepted the edit and changed nothing: stop trying here.
            DictationInsertRouteMemory().markIgnoresAccessibilityInsert(bundleIdentifier: liveField.bundleIdentifier)
            regions[index] = nil
            self.liveField = nil
        }
        return succeeded
    }

    // MARK: - One segment: provisional text, accurate text, reconcile

    private func deliver(index: Int, pcm: Data, isLast: Bool) async {
        let onDeviceResult = await recorder.finalOnDeviceResult(forSegment: index, timeout: isLast ? 0.5 : 1.0)
        // Nothing more is needed from the recorder after the last segment's text.
        // Releasing it here lets the next dictation start while this one reconciles.
        if isLast { recorder.cancel() }
        guard !isCancelled else { return }

        let silenceGate = DictationSilenceGate()
        let isSilent = isLast && cutCount == 0
            ? silenceGate.shouldDiscard(pcm16: pcm, sampleRate: DictationAudioFormat.sampleRate, liveText: onDeviceResult.text)
            : DictationScript.units(in: onDeviceResult.text).isEmpty
                && silenceGate.voicedSeconds(pcm16: pcm, sampleRate: DictationAudioFormat.sampleRate) < silenceGate.minimumVoicedSeconds
        if isSilent {
            if isLast { finishForUser() }
            return
        }

        let bundleIdentifier = liveField?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isTerminal = DictationInsertionRules.isTerminal(bundleIdentifier: bundleIdentifier)
        let onDevice = DictationReleasePolicy.OnDevice(text: onDeviceResult.text, confidences: onDeviceResult.confidences)
        var insertionLabel = "none"
        var provisionalMilliseconds: Int?

        // 1. Speed first: the on-device text goes in now.
        if mode == .speedFirst {
            let provisional = DictationInsertionRules.textToInsert(
                DictationOnDevicePolish.polish(onDeviceResult.text, addPeriod: !isTerminal),
                bundleIdentifier: bundleIdentifier
            )
            if !provisional.isEmpty {
                if liveField != nil {
                    let typed = await edits.run { await self.setRegion(index, to: provisional) }
                    if typed { insertionLabel = "live" }
                }
                let hasTypedText = regions[index]?.hasTypedText ?? false
                if !hasTypedText, isLast, cutCount == 0, DictationReleasePolicy.isTrustworthy(onDevice) {
                    // No way to correct this field afterwards, and the on-device
                    // text is short and confident: it is the final text.
                    speculation?.cancel()
                    let outcome = await DictationTextInserter.insert(provisional)
                    log(bundleIdentifier: bundleIdentifier, raw: onDeviceResult.text, cleaned: provisional, transcriber: "apple", insertion: outcome.historyLabel)
                    report(isLast: true, label: "on-device, \(outcome.historyLabel)", provisionalMilliseconds: nil)
                    finish(after: outcome, text: provisional)
                    return
                }
                if hasTypedText, isLast {
                    provisionalMilliseconds = millisecondsSinceRelease()
                    finishForUser()
                }
            }
        }
        if isLast, !hasFinishedForUser { onWaiting?() }

        // 2. The accurate pass.
        let transcript: DictationPipeline.Transcript
        if isLast, cutCount == 0, let speculation, detector.speculationCoversEverything() {
            let speculated = await speculation.value
            if speculated.source == "publik", !DictationSilenceGate.isEmptyTranscript(speculated.text, dictionaryPrompt: dictionaryPrompt) {
                transcript = speculated
            } else {
                transcript = await transcribe(pcm, onDeviceText: onDeviceResult.text)
            }
        } else {
            speculation?.cancel()
            transcript = await transcribe(pcm, onDeviceText: onDeviceResult.text)
        }
        guard !isCancelled else { return }

        let hasTranscript = !DictationSilenceGate.isEmptyTranscript(transcript.text, dictionaryPrompt: dictionaryPrompt)
        var cleaned = DictationPipeline.Cleaned(text: transcript.text, usedCleanup: false, milliseconds: 0)
        if hasTranscript, cleanupEnabled {
            cleaned = await DictationPipeline.cleanUp(raw: transcript.text, skipWhenAlreadyClean: mode == .speedFirst)
        }
        let textToInsert = hasTranscript ? DictationInsertionRules.textToInsert(cleaned.text, bundleIdentifier: bundleIdentifier) : ""

        // 3. Reconcile with what is in the field.
        let region = regions[index]
        let action = DictationReleasePolicy.decide(
            insertedText: (region?.hasTypedText ?? false) ? region?.text : nil,
            onDevice: mode == .speedFirst ? onDevice : nil,
            publikText: hasTranscript && transcript.source == "publik" ? transcript.text : nil,
            cleanedText: textToInsert.isEmpty ? nil : textToInsert,
            rangeIntact: region?.isIntact ?? false
        )

        var finalOutcome: DictationInsertionOutcome?
        var finalText = region?.text ?? ""
        switch action {
        case .replace(let text):
            let replaced = await edits.run { await self.setRegion(index, to: text) }
            insertionLabel = replaced ? "live, corrected" : "live"
            if replaced { finalText = text }
        case .insert(let text):
            let outcome = await DictationTextInserter.insert(text)
            finalOutcome = outcome
            insertionLabel = outcome.historyLabel
            finalText = text
        case .keep, .nothing:
            break
        }

        if action != .nothing {
            log(bundleIdentifier: bundleIdentifier, raw: transcript.text, cleaned: finalText, transcriber: transcript.source, insertion: insertionLabel)
        }
        report(
            isLast: isLast,
            label: "\(transcript.source) \(transcript.milliseconds) ms, cleanup \(cleaned.usedCleanup ? "\(cleaned.milliseconds) ms" : "not used"), \(insertionLabel)",
            provisionalMilliseconds: provisionalMilliseconds
        )

        guard isLast else { return }
        if let finalOutcome {
            finish(after: finalOutcome, text: finalText)
        } else {
            if let region, region.state == .active, !region.text.isEmpty, let liveField,
               let baseline = region.lastVerifiedValue {
                correctionWatcher.watch(
                    element: liveField.element,
                    baseline: baseline,
                    insertedRange: NSRange(location: region.location, length: (region.text as NSString).length)
                )
            }
            finishForUser()
        }
    }

    private func transcribe(_ pcm: Data, onDeviceText: String) async -> DictationPipeline.Transcript {
        await DictationPipeline.transcribe(pcm16: pcm, dictionaryPrompt: dictionaryPrompt, language: languageCode) { onDeviceText }
    }

    /// The end of a dictation whose text went in through `DictationTextInserter.insert`.
    private func finish(after outcome: DictationInsertionOutcome, text: String) {
        switch outcome {
        case .accessibility(let element, let baseline, let insertedRange):
            if let baseline, let insertedRange {
                correctionWatcher.watch(element: element, baseline: baseline, insertedRange: insertedRange)
            }
            finishForUser()
        case .pasted:
            finishForUser()
        case .copiedToClipboard:
            finishForUser(notice: "Copied")
        case .failed:
            // Nothing is lost: the text is in the backup file, and now on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            finishForUser(notice: "Copied")
        }
    }

    // MARK: - Backup and timing

    private func log(bundleIdentifier: String?, raw: String, cleaned: String, transcriber: String, insertion: String) {
        DictationHistoryLog.shared.append(DictationHistoryLog.Entry(
            appBundleIdentifier: bundleIdentifier,
            raw: raw,
            cleaned: cleaned,
            transcriber: transcriber,
            insertion: insertion
        ))
    }

    private func millisecondsSinceRelease() -> Int? {
        releasedAt.map { Int((Date().timeIntervalSince($0) * 1000).rounded()) }
    }

    /// Timing is measured per utterance: release to first text, release to final text.
    private func report(isLast: Bool, label: String, provisionalMilliseconds: Int?) {
        guard isLast, let releasedAt else {
            print("🎙️ Dictation segment: \(label)")
            return
        }
        let firstText: String
        if let firstLiveTextAt, firstLiveTextAt < releasedAt {
            firstText = "first text typed while speaking"
        } else if let provisionalMilliseconds {
            firstText = "first text \(provisionalMilliseconds) ms after release"
        } else {
            firstText = "first text with the final text"
        }
        let provisional = provisionalMilliseconds.map { ", on-device text complete at \($0) ms" } ?? ""
        print("🎙️ Dictation (\(mode.rawValue)): \(firstText)\(provisional), final text \(millisecondsSinceRelease() ?? 0) ms after release. \(label)")
    }
}
