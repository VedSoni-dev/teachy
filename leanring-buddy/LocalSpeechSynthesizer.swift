//
//  LocalSpeechSynthesizer.swift
//  leanring-buddy
//
//  Human-sounding TTS for Teachy.
//  Priority: the person's own ElevenLabs key → publik realtime voice → publik speech →
//  macOS AVSpeech neural → NSSpeech.
//  Streamed replies are spoken sentence by sentence (see "Streaming speech").
//
//  Before any reply, `SpokenOutputGate` is asked whether to make sound at all. When the
//  Mac is muted, or the person is on a call and didn't hold the talk key, the reply is
//  shown as captions at speaking pace and copied to the clipboard instead.
//

import AppKit
import AVFoundation
import Foundation
import NaturalLanguage

@MainActor
final class LocalSpeechSynthesizer: NSObject {
    // MARK: - What always-on mode needs to know

    /// Posted when any synthesizer starts or stops speaking.
    static let speakingDidChangeNotification = Notification.Name("TeachySpeakingDidChange")
    private static let liveInstances = NSHashTable<LocalSpeechSynthesizer>.weakObjects()

    /// True while any synthesizer is speaking (or showing a silent reply's captions).
    static var isAnySpeaking: Bool {
        liveInstances.allObjects.contains { $0.isPlaying || $0.isStreamSpeaking }
    }

    /// Stops every synthesizer at once: the person started talking over Teachy.
    static func stopAllPlayback() {
        for instance in liveInstances.allObjects { instance.stopPlayback() }
    }

    private static var spokenLog: [(at: Date, text: String)] = []
    private static func noteSpoken(_ text: String) {
        spokenLog.append((Date(), text))
        if spokenLog.count > 12 { spokenLog.removeFirst(spokenLog.count - 12) }
    }
    /// The sentences spoken in the last `seconds`, to recognise Teachy's own voice coming
    /// back through the microphone.
    static func recentlySpokenSentences(within seconds: TimeInterval = 20) -> [String] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return spokenLog.filter { $0.at >= cutoff }.map(\.text)
    }

    private let legacySynthesizer: NSSpeechSynthesizer
    private let avSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { NotificationCenter.default.post(name: Self.speakingDidChangeNotification, object: self) } }
    }

    /// Monotonically increasing interruption token — bumped by every
    /// `stopPlayback()` and every new `speakText`. An interrupted speech turn
    /// re-checks its captured generation after every await so it can never
    /// resurrect itself (the old bug: interrupting during the ElevenLabs fetch
    /// made the cancelled fetch fall through to the LOCAL voice, which started
    /// speaking the stale line over the new turn).
    private var playbackGeneration = 0
    /// The AVSpeech utterance currently on stage — delegate callbacks for any
    /// other (stopped/stale) utterance are ignored so they can't stomp the
    /// `isPlaying` state of a newer speech turn.
    private var activeAVSpeechUtterance: AVSpeechUtterance?
    /// Generation snapshot for the legacy NSSpeech path (single shared
    /// synthesizer instance, so utterance-identity comparison isn't possible).
    private var legacySpeechGeneration = -1

    /// Slightly slower than default — reads more like a person sitting next to you.
    private static let localSpeechRate: Float = 0.47
    private static let localSpeechPitch: Float = 1.03

    override init() {
        self.legacySynthesizer = NSSpeechSynthesizer()
        super.init()
        legacySynthesizer.delegate = self
        avSynthesizer.delegate = self
        Self.liveInstances.add(self)
        if let voice = Self.preferredNSVoice() {
            legacySynthesizer.setVoice(voice)
        }
    }

    func speakText(_ text: String) async throws {
        let cleaned = Self.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        stopPlayback()
        playbackGeneration += 1
        let speechGeneration = playbackGeneration

        // Muted Mac, or on a call: show it and copy it instead of playing it.
        if case .captionsAndClipboard = SpokenOutputGate.shared.decideForNextReply() {
            let pasteboardChangeCount = NSPasteboard.general.changeCount
            CaptionPresenter.shared.forceNextReply()
            var segmenter = StreamingSpeechSegmenter()
            let sentences = segmenter.finish(accumulated: cleaned)
            isPlaying = true
            for sentence in sentences.isEmpty ? [cleaned] : sentences {
                guard await showSilently(sentence, generation: speechGeneration) else { throw CancellationError() }
            }
            isPlaying = false
            CaptionPresenter.shared.speechEnded()
            SpokenOutputGate.shared.copyReplyToClipboard(cleaned, ifPasteboardUnchangedSince: pasteboardChangeCount)
            return
        }
        isPlaying = true
        Self.noteSpoken(cleaned)

        // Interrupted (stopPlayback bumped the generation) or cancelled while
        // this turn was awaiting something — bail WITHOUT falling through to a
        // slower backend, and never touch state a newer turn now owns.
        func wasInterrupted() -> Bool {
            speechGeneration != playbackGeneration || Task.isCancelled
        }

        // 1a) User's own ElevenLabs key, called directly (bypasses the Teachy proxy
        // entirely so a user's voice usage never lands on the developer's bill)
        if let audioData = await Self.fetchDirectElevenLabsAudio(text: cleaned) {
            if wasInterrupted() { throw CancellationError() }
            do {
                try await playAudioData(audioData, speechGeneration: speechGeneration)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("⚠️ Direct ElevenLabs playback failed, falling back: \(error)")
            }
        }
        if wasInterrupted() { throw CancellationError() }

        // 1b) publik realtime voice: audio starts streaming ~0.5 s after the text is sent.
        if RealtimeVoice.shared.isAvailable {
            switch await Self.speakWithRealtimeVoice(cleaned) {
            case .played:
                if speechGeneration == playbackGeneration { isPlaying = false }
                return
            case .interrupted:
                throw CancellationError()
            case .failed:
                break
            }
        }
        if wasInterrupted() { throw CancellationError() }

        // 1c) publik speech (slower, about 2 s per sentence)
        if let audioData = await Self.fetchCloudTTSAudio(text: cleaned) {
            if wasInterrupted() { throw CancellationError() }
            do {
                try await playAudioData(audioData, speechGeneration: speechGeneration)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("⚠️ Cloud TTS playback failed, falling back to local: \(error)")
            }
        }
        if wasInterrupted() { throw CancellationError() }

        // 2) macOS neural / enhanced voices
        if await speakWithAVSpeech(cleaned, speechGeneration: speechGeneration) {
            return
        }
        if wasInterrupted() { throw CancellationError() }

        // 3) Legacy NSSpeech last resort
        legacySpeechGeneration = speechGeneration
        let success = legacySynthesizer.startSpeaking(cleaned)
        if !success {
            isPlaying = false
            throw NSError(
                domain: "LocalSpeechSynthesizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start speech synthesis"]
            )
        }

        while isPlaying, speechGeneration == playbackGeneration {
            if Task.isCancelled {
                legacySynthesizer.stopSpeaking()
                isPlaying = false
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Streaming speech (sentence by sentence)

    private struct QueuedSentence {
        let text: String
        /// Nil when the realtime voice will read it (no download needed up front).
        let audioFetch: Task<Data?, Never>?
    }

    /// True when this stream is shown, not spoken (muted Mac, or on a call).
    private var streamIsSilent = false
    private var silentStreamText: [String] = []
    private var pasteboardChangeCountAtStreamStart = 0

    /// Shows one sentence as a caption for about as long as it would take to say.
    /// Returns false if the reply was interrupted meanwhile.
    private func showSilently(_ sentence: String, generation: Int) async -> Bool {
        CaptionPresenter.shared.show(sentence: sentence)
        let seconds = SpokenOutputDecision.captionSeconds(for: sentence, speed: TeachySettingsStorage.speechSpeed())
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard generation == playbackGeneration, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return generation == playbackGeneration && !Task.isCancelled
    }

    /// Reads text through the realtime voice, stopping it if the calling task is cancelled.
    private static func speakWithRealtimeVoice(_ text: String) async -> RealtimeVoice.SpeakResult {
        await withTaskCancellationHandler {
            await RealtimeVoice.shared.speak(text)
        } onCancel: {
            Task { @MainActor in RealtimeVoice.shared.stop() }
        }
    }
    private var streamQueue: [QueuedSentence] = []
    private var streamGeneration = -1
    private var streamInputEnded = true
    private var streamDrainTask: Task<Void, Never>?
    /// True from the first queued sentence until the last one has been spoken.
    private(set) var isStreamSpeaking = false {
        didSet { if oldValue != isStreamSpeaking { NotificationCenter.default.post(name: Self.speakingDidChangeNotification, object: self) } }
    }

    /// Starts a streamed reply: sentences are spoken as they arrive instead of after
    /// the whole answer. Interrupts anything already playing.
    /// Returns a token; only sentences queued with this token are spoken, so a
    /// cancelled turn can never talk over the turn that replaced it.
    @discardableResult
    func beginStream() -> Int {
        stopPlayback()
        playbackGeneration += 1
        streamGeneration = playbackGeneration
        streamInputEnded = false
        silentStreamText = []
        pasteboardChangeCountAtStreamStart = NSPasteboard.general.changeCount
        if case .captionsAndClipboard = SpokenOutputGate.shared.decideForNextReply() {
            streamIsSilent = true
            CaptionPresenter.shared.forceNextReply()
        } else {
            streamIsSilent = false
            // The model needs about a second before its first sentence; connect the voice now.
            RealtimeVoice.shared.prewarm()
        }
        return streamGeneration
    }

    /// Queues one sentence. Its audio starts downloading immediately, so it is usually
    /// ready by the time the sentence before it finishes playing.
    func enqueueStreamSentence(_ sentence: String, streamToken: Int) {
        guard streamToken == streamGeneration, streamGeneration == playbackGeneration, !streamInputEnded else { return }
        let cleaned = Self.prepareForSpeech(sentence)
        guard !cleaned.isEmpty else { return }
        let audioFetch: Task<Data?, Never>? = streamIsSilent || RealtimeVoice.shared.isAvailable
            ? nil
            : Task { await Self.fetchCloudTTSAudio(text: cleaned) }
        streamQueue.append(QueuedSentence(text: cleaned, audioFetch: audioFetch))
        isStreamSpeaking = true
        if streamDrainTask == nil {
            let generation = streamGeneration
            streamDrainTask = Task { [weak self] in
                await self?.drainStream(generation: generation)
            }
        }
    }

    /// Call when the reply is complete. Returns once every queued sentence has been spoken
    /// (or the stream was interrupted).
    func finishStream() async {
        streamInputEnded = true
        let drain = streamDrainTask
        await drain?.value
    }

    private func drainStream(generation: Int) async {
        defer {
            if generation == playbackGeneration {
                streamDrainTask = nil
                isStreamSpeaking = false
            }
        }
        while generation == playbackGeneration, !Task.isCancelled {
            guard !streamQueue.isEmpty else {
                if streamInputEnded {
                    CaptionPresenter.shared.speechEnded()
                    if streamIsSilent {
                        SpokenOutputGate.shared.copyReplyToClipboard(
                            silentStreamText.joined(separator: " "),
                            ifPasteboardUnchangedSince: pasteboardChangeCountAtStreamStart
                        )
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            let next = streamQueue.removeFirst()
            if streamIsSilent {
                silentStreamText.append(next.text)
                isPlaying = true
                guard await showSilently(next.text, generation: generation) else { return }
                isPlaying = false
                continue
            }
            Self.noteSpoken(next.text)
            CaptionPresenter.shared.show(sentence: next.text)
            var audioData: Data?
            if let audioFetch = next.audioFetch {
                audioData = await audioFetch.value
            } else {
                isPlaying = true
                let realtimeResult = await Self.speakWithRealtimeVoice(next.text)
                guard generation == playbackGeneration, !Task.isCancelled else { return }
                isPlaying = false
                switch realtimeResult {
                case .played: continue
                case .interrupted: return
                case .failed: audioData = await Self.fetchCloudTTSAudio(text: next.text)
                }
            }
            guard generation == playbackGeneration, !Task.isCancelled else { return }
            if let audioData {
                do {
                    try await playAudioData(audioData, speechGeneration: generation)
                    continue
                } catch is CancellationError {
                    return
                } catch {
                    print("⚠️ Stream sentence playback failed, using the local voice: \(error)")
                }
            }
            guard generation == playbackGeneration else { return }
            _ = await speakWithAVSpeech(next.text, speechGeneration: generation)
        }
    }

    func stopPlayback() {
        // Invalidate any in-flight speakText turn FIRST so its post-await
        // checks see the interruption before any audio object is touched.
        playbackGeneration += 1
        CaptionPresenter.shared.hide()
        for queued in streamQueue { queued.audioFetch?.cancel() }
        RealtimeVoice.shared.stop()
        streamQueue.removeAll()
        streamInputEnded = true
        streamDrainTask = nil
        isStreamSpeaking = false
        audioPlayer?.stop()
        audioPlayer = nil
        activeAVSpeechUtterance = nil
        avSynthesizer.stopSpeaking(at: .immediate)
        legacySynthesizer.stopSpeaking()
        isPlaying = false
    }

    // MARK: - Cloud TTS

    /// Calls ElevenLabs directly with the user's own API key + voice ID, if
    /// configured (see `TeachyElevenLabsKeyStore`). This intentionally bypasses
    /// the Teachy proxy so a user's own voice usage is billed to their own
    /// ElevenLabs account, not the developer's. Falls through to `nil` (and
    /// therefore to `fetchCloudTTSAudio`'s worker path) if the user hasn't
    /// configured their own key, or if the direct call fails for any reason.
    private static func fetchDirectElevenLabsAudio(text: String) async -> Data? {
        guard let apiKey = TeachyElevenLabsKeyStore.apiKey,
              !apiKey.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(TeachyElevenLabsKeyStore.voiceID)")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        request.timeoutInterval = 28

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.4,
                "similarity_boost": 0.8,
                "style": 0.4,
                "use_speaker_boost": true,
            ],
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// The voice used for publik speech. Changeable later from settings.
    static var publikVoiceName: String {
        // The picker now chooses a realtime voice (see RealtimeVoice.voiceName). This slower
        // endpoint is only the fallback and keeps one fixed voice.
        "alloy"
    }

    /// Neural speech from publik (`POST /audio/speech`). Nil when not signed in or on any error,
    /// so the caller falls back to the Mac's own voices.
    private static func fetchCloudTTSAudio(text: String) async -> Data? {
        do {
            return try await PublikAudio.speech(text: text, voice: publikVoiceName, speed: TeachySettingsStorage.speechSpeed())
        } catch is TeachyAIBillingError {
            return nil
        } catch {
            print("⚠️ publik speech failed, using the local voice: \(error.localizedDescription)")
            return nil
        }
    }

    private static func looksLikeAudio(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        if data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 { return true }
        if data.starts(with: [0x49, 0x44, 0x33]) { return true }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return true }
        return false
    }

    private func playAudioData(_ data: Data, speechGeneration: Int) async throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        isPlaying = true

        guard player.play() else {
            audioPlayer = nil
            isPlaying = false
            throw NSError(
                domain: "LocalSpeechSynthesizer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer failed to start"]
            )
        }

        while isPlaying, speechGeneration == playbackGeneration {
            if Task.isCancelled {
                // Stop OUR audio on cancellation — checkCancellation alone would
                // throw out of here while the player kept talking.
                player.stop()
                if audioPlayer === player { audioPlayer = nil }
                isPlaying = false
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        // Superseded mid-play by a newer turn: the newer turn owns all state
        // now (stopPlayback already silenced this player) — just leave.
        if speechGeneration != playbackGeneration {
            throw CancellationError()
        }
        isPlaying = false
    }

    // MARK: - Local neural speech

    private func speakWithAVSpeech(_ text: String, speechGeneration: Int) async -> Bool {
        guard let voice = Self.preferredAVVoice(for: text) else { return false }
        // Interrupted before this fallback even started — report handled so
        // the caller doesn't cascade into the legacy voice with stale text.
        guard speechGeneration == playbackGeneration, !Task.isCancelled else { return true }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.localSpeechRate
        utterance.pitchMultiplier = Self.localSpeechPitch
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.08
        utterance.volume = 1.0

        isPlaying = true
        activeAVSpeechUtterance = utterance
        avSynthesizer.speak(utterance)

        while isPlaying, speechGeneration == playbackGeneration {
            if Task.isCancelled {
                avSynthesizer.stopSpeaking(at: .immediate)
                if activeAVSpeechUtterance === utterance { activeAVSpeechUtterance = nil }
                isPlaying = false
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return true
    }

    // MARK: - Voice selection

    /// A Mac voice for the language the text is in: the fixed reply language if one is
    /// set, otherwise whatever the text looks like. English keeps the hand-picked list below.
    private static func preferredAVVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let fixed = TeachyReplyLanguages.language(for: TeachySettingsStorage.replyLanguage())
        let languageCode = fixed?.code ?? NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        if !languageCode.hasPrefix("en") {
            let identifier = fixed?.localeIdentifier
                ?? TeachyReplyLanguages.language(for: String(languageCode.prefix(2)))?.localeIdentifier
                ?? languageCode
            if let voice = AVSpeechSynthesisVoice(language: identifier) { return voice }
        }
        return preferredAVVoice()
    }

    private static func preferredAVVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }

        let preferredNames = [
            "Samantha", "Nora", "Zoe", "Ava", "Allison", "Susan",
            "Tom", "Aaron", "Nicky", "Evan", "Alex",
        ]

        let enhanced = voices.filter { voice in
            if #available(macOS 13.0, *) {
                return voice.quality == .enhanced || voice.quality == .premium
            }
            return voice.quality == .enhanced
        }

        for name in preferredNames {
            if let match = enhanced.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match
            }
        }
        if let best = enhanced.first { return best }

        for name in preferredNames {
            if let match = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match
            }
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func preferredNSVoice() -> NSSpeechSynthesizer.VoiceName? {
        let voices = NSSpeechSynthesizer.availableVoices
        let preferred = ["Samantha", "Alex", "Karen", "Moira", "Daniel", "Fiona"]
        for name in preferred {
            if let voice = voices.first(where: { $0.rawValue.localizedCaseInsensitiveContains(name) }) {
                return voice
            }
        }
        return voices.first
    }

    /// Strip tags / markdown so TTS never reads plumbing aloud.
    static func prepareForSpeech(_ text: String) -> String {
        var s = text
        let patterns = [
            #"\[/?INFO\]"#,
            #"\[/?TODO\]"#,
            #"\[POINT:[^\]]*\]"#,
            #"\[DRAW:[^\]]*\]"#,
            #"\[MEMORY:[^\]]*\]"#,
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\*+|`+|__+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "→", with: ",")
        s = s.replacingOccurrences(of: "—", with: ", ")
        s = s.replacingOccurrences(of: "…", with: "...")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Delegates

// All delegate callbacks land asynchronously on the main actor, so a callback
// for STOPPED/stale audio can arrive after a newer speech turn already started.
// Every handler therefore verifies it belongs to the CURRENT audio (player
// identity / utterance identity / legacy generation) before clearing state —
// otherwise an old callback would mark the new speech as finished while it's
// still talking (overlap + early-idle glitches).

extension LocalSpeechSynthesizer: NSSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            guard self.legacySpeechGeneration == self.playbackGeneration else { return }
            self.isPlaying = false
        }
    }
}

extension LocalSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.activeAVSpeechUtterance else { return }
            self.activeAVSpeechUtterance = nil
            self.isPlaying = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.activeAVSpeechUtterance else { return }
            self.activeAVSpeechUtterance = nil
            self.isPlaying = false
        }
    }
}

extension LocalSpeechSynthesizer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.audioPlayer else { return }
            self.audioPlayer = nil
            self.isPlaying = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.audioPlayer else { return }
            self.audioPlayer = nil
            self.isPlaying = false
            if let error {
                print("⚠️ TTS decode error: \(error.localizedDescription)")
            }
        }
    }
}
