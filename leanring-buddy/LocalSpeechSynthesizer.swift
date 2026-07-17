//
//  LocalSpeechSynthesizer.swift
//  leanring-buddy
//
//  Human-sounding TTS for Teachy.
//  Priority: cloud neural (ElevenLabs / OpenAI via proxy) → macOS AVSpeech neural → NSSpeech.
//

import AppKit
import AVFoundation
import Foundation

@MainActor
final class LocalSpeechSynthesizer: NSObject {
    private let legacySynthesizer: NSSpeechSynthesizer
    private let avSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    private(set) var isPlaying = false

    /// Slightly slower than default — reads more like a person sitting next to you.
    private static let localSpeechRate: Float = 0.47
    private static let localSpeechPitch: Float = 1.03

    override init() {
        self.legacySynthesizer = NSSpeechSynthesizer()
        super.init()
        legacySynthesizer.delegate = self
        avSynthesizer.delegate = self
        if let voice = Self.preferredNSVoice() {
            legacySynthesizer.setVoice(voice)
        }
    }

    func speakText(_ text: String) async throws {
        let cleaned = Self.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        stopPlayback()
        isPlaying = true

        // 1a) User's own ElevenLabs key, called directly (bypasses the Teachy proxy
        // entirely so a user's voice usage never lands on the developer's bill)
        if let audioData = await Self.fetchDirectElevenLabsAudio(text: cleaned) {
            do {
                try await playAudioData(audioData)
                isPlaying = false
                return
            } catch {
                print("⚠️ Direct ElevenLabs playback failed, falling back: \(error)")
            }
        }

        // 1b) Cloud neural TTS via Teachy proxy (ElevenLabs preferred, OpenAI fallback on proxy)
        if let audioData = await Self.fetchCloudTTSAudio(text: cleaned) {
            do {
                try await playAudioData(audioData)
                isPlaying = false
                return
            } catch {
                print("⚠️ Cloud TTS playback failed, falling back to local: \(error)")
            }
        }

        // 2) macOS neural / enhanced voices
        if await speakWithAVSpeech(cleaned) {
            return
        }

        // 3) Legacy NSSpeech last resort
        let success = legacySynthesizer.startSpeaking(cleaned)
        if !success {
            isPlaying = false
            throw NSError(
                domain: "LocalSpeechSynthesizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start speech synthesis"]
            )
        }

        while isPlaying {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
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
              let voiceID = TeachyElevenLabsKeyStore.voiceID,
              !apiKey.isEmpty, !voiceID.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")
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

    private static func fetchCloudTTSAudio(text: String) async -> Data? {
        guard let url = URL(string: ClickyWorkerConfiguration.ttsEndpointURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            guard let http = response as? HTTPURLResponse else { return nil }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if http.statusCode == 200, contentType.contains("audio") || looksLikeAudio(data) {
                return data
            }

            // Stub / not configured returns JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["ok"] as? Bool == true {
                return nil
            }

            if http.statusCode != 200 {
                let snippet = String(data: data.prefix(180), encoding: .utf8) ?? ""
                print("⚠️ Cloud TTS HTTP \(http.statusCode): \(snippet)")
            }
            return nil
        } catch {
            print("⚠️ Cloud TTS request failed: \(error.localizedDescription)")
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

    private func playAudioData(_ data: Data) async throws {
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

        while isPlaying {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: - Local neural speech

    private func speakWithAVSpeech(_ text: String) async -> Bool {
        guard let voice = Self.preferredAVVoice() else { return false }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.localSpeechRate
        utterance.pitchMultiplier = Self.localSpeechPitch
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.08
        utterance.volume = 1.0

        isPlaying = true
        avSynthesizer.speak(utterance)

        while isPlaying {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return true
    }

    // MARK: - Voice selection

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

extension LocalSpeechSynthesizer: NSSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}

extension LocalSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}

extension LocalSpeechSynthesizer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.isPlaying = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.isPlaying = false
            if let error {
                print("⚠️ TTS decode error: \(error.localizedDescription)")
            }
        }
    }
}
