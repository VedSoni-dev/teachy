import AppKit
import Foundation

@MainActor
final class LocalSpeechSynthesizer: NSObject {
    private let synthesizer: NSSpeechSynthesizer
    private(set) var isPlaying = false

    override init() {
        self.synthesizer = NSSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
        if let voice = NSSpeechSynthesizer.availableVoices.first(where: {
            $0.rawValue.contains("Samantha") || $0.rawValue.contains("Alex")
        }) {
            synthesizer.setVoice(voice)
        }
    }

    func speakText(_ text: String) async throws {
        isPlaying = true
        let success = synthesizer.startSpeaking(text)
        if !success {
            isPlaying = false
            throw NSError(domain: "LocalSpeechSynthesizer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start speech synthesis"])
        }

        // Wait until didFinishSpeaking (or stopPlayback) so course beats stay sequential.
        while isPlaying {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func stopPlayback() {
        synthesizer.stopSpeaking()
        isPlaying = false
    }
}

extension LocalSpeechSynthesizer: NSSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}
