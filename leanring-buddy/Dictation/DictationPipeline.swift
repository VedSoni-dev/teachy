//
//  DictationPipeline.swift
//  leanring-buddy
//
//  Recorded audio in, text to insert out: publik transcription (Apple on-device
//  text as the fallback), then one faithful cleanup call through TeachyAIRouter.
//  Every wait has a timeout. No AppKit.
//

import Foundation

enum DictationPipeline {
    static let sampleRate = DictationAudioFormat.sampleRate
    /// publik takes clips up to about 4 MB; 100 s of 16 kHz mono is 3.2 MB.
    static let maximumChunkSeconds: Double = 100

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "Dictation timed out." }
    }

    struct Transcript {
        let text: String
        /// "publik" or "apple".
        let source: String
        let milliseconds: Int
    }

    struct Cleaned {
        let text: String
        let usedCleanup: Bool
        let milliseconds: Int
    }

    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    /// How long to wait for publik before using the on-device text.
    static func transcriptionTimeout(audioSeconds: Double) -> Double {
        min(45, 8 + audioSeconds * 0.5)
    }

    /// publik first; on any failure (not signed in, offline, out of balance, slow)
    /// the on-device text from `appleFallback` is used.
    static func transcribe(
        pcm16: Data,
        dictionaryPrompt: String?,
        language: String? = nil,
        appleFallback: @escaping @Sendable () async -> String
    ) async -> Transcript {
        let start = Date()
        do {
            let chunks = DictationAudioChunker.split(pcm16: pcm16, sampleRate: sampleRate, maximumSeconds: maximumChunkSeconds)
            var pieces: [String] = []
            for chunk in chunks {
                let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: chunk, sampleRate: sampleRate)
                let seconds = DictationSilenceGate.seconds(pcm16ByteCount: chunk.count, sampleRate: sampleRate)
                let text = try await withTimeout(seconds: transcriptionTimeout(audioSeconds: seconds)) {
                    try await PublikAudio.transcribe(wavData: wav, prompt: dictionaryPrompt, language: language)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !DictationSilenceGate.isEmptyTranscript(trimmed, dictionaryPrompt: dictionaryPrompt) {
                    pieces.append(trimmed)
                }
            }
            return Transcript(text: pieces.joined(separator: " "), source: "publik", milliseconds: elapsedMilliseconds(since: start))
        } catch {
            print("⚠️ Dictation: publik transcription unavailable (\(error.localizedDescription)); using on-device text")
            let text = await appleFallback().trimmingCharacters(in: .whitespacesAndNewlines)
            return Transcript(text: text, source: "apple", milliseconds: elapsedMilliseconds(since: start))
        }
    }

    /// One cleanup call. Anything that goes wrong returns the transcript unchanged.
    /// `skipWhenAlreadyClean` (speed mode) saves the call, about 1.3 s, when the
    /// transcript has no filler sounds and is already punctuated.
    static func cleanUp(raw: String, skipWhenAlreadyClean: Bool = false) async -> Cleaned {
        let start = Date()
        guard !DictationCleanup.shouldSkip(raw: raw),
              !(skipWhenAlreadyClean && DictationCleanupSkip.looksAlreadyClean(raw))
        else {
            return Cleaned(text: DictationCleanup.finalText(raw: raw, modelOutput: nil).text, usedCleanup: false, milliseconds: 0)
        }
        var modelOutput: String?
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: DictationCleanup.requestBody(raw: raw))
            let response = try await withTimeout(seconds: DictationCleanup.timeoutSeconds) {
                let body = (try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                return try await TeachyAIRouter.sendJSON(
                    job: .cleanup,
                    hasImages: false,
                    timeout: DictationCleanup.timeoutSeconds,
                    body: body
                )
            }
            modelOutput = DictationCleanup.content(fromResponse: response)
        } catch {
            print("⚠️ Dictation: cleanup skipped (\(error.localizedDescription))")
        }
        let result = DictationCleanup.finalText(raw: raw, modelOutput: modelOutput)
        return Cleaned(text: result.text, usedCleanup: result.usedCleanup, milliseconds: elapsedMilliseconds(since: start))
    }
}
