//
//  StreamingSpeechFeeder.swift
//  leanring-buddy
//
//  Glue between a streaming model reply and the speech queue: each time more text
//  arrives, any sentence that just completed is queued to be spoken.
//

import Foundation

@MainActor
final class StreamingSpeechFeeder {
    private var segmenter = StreamingSpeechSegmenter()
    private let synthesizer: LocalSpeechSynthesizer
    private let streamToken: Int
    private let onFirstSentence: () -> Void
    private var hasSpoken = false
    private let startedAt = Date()

    /// Starts a new spoken stream on `synthesizer` (interrupting anything playing).
    init(synthesizer: LocalSpeechSynthesizer, onFirstSentence: @escaping () -> Void) {
        self.synthesizer = synthesizer
        self.onFirstSentence = onFirstSentence
        self.streamToken = synthesizer.beginStream()
    }

    /// Call with the whole reply so far, every time it grows.
    func feed(_ accumulated: String) {
        speak(segmenter.feed(accumulated: accumulated))
    }

    /// Call once with the complete reply. Queues whatever is left to say.
    func finish(_ fullText: String) {
        speak(segmenter.finish(accumulated: fullText))
    }

    private func speak(_ sentences: [String]) {
        for sentence in sentences {
            if !hasSpoken {
                hasSpoken = true
                print("🗣️ First sentence ready \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s after the request")
                onFirstSentence()
            }
            synthesizer.enqueueStreamSentence(sentence, streamToken: streamToken)
        }
    }
}
