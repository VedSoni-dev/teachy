//
//  VoicePreviewPlayer.swift
//  leanring-buddy
//
//  Plays the short "this is how I sound" sample for the voice picker. The audio
//  comes from whatever `fetch` is given (publik speech in the app, see
//  VoicePreviewPlayer+Publik.swift) and is kept in memory, so pressing play on
//  the same voice and speed twice only asks publik once.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class VoicePreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    typealias Fetch = @Sendable (_ text: String, _ voice: String, _ speed: Double) async throws -> Data

    enum State: Equatable {
        case idle
        case loading(voice: String)
        case playing(voice: String)
    }

    @Published private(set) var state: State = .idle
    /// Shown under the picker when a sample couldn't be fetched or played.
    @Published private(set) var errorMessage: String?

    private let fetch: Fetch
    private var cachedSamples: [String: Data] = [:]
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    /// Bumped on every toggle so a slow download can't start playing after
    /// the person has moved on to another voice.
    private var requestGeneration = 0

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    func isLoading(_ voice: String) -> Bool { state == .loading(voice: voice) }
    func isPlaying(_ voice: String) -> Bool { state == .playing(voice: voice) }

    /// Plays the sample for `voice`, or stops it if that voice is already loading or playing.
    func toggle(voice: String, speed: Double) {
        let wasThisVoice = isLoading(voice) || isPlaying(voice)
        stop()
        guard !wasThisVoice else { return }

        errorMessage = nil
        requestGeneration += 1
        let generation = requestGeneration
        let cacheKey = "\(voice)|\(TeachySpeechSpeed.label(speed))"

        if let cached = cachedSamples[cacheKey] {
            play(cached, voice: voice)
            return
        }

        state = .loading(voice: voice)
        let fetch = self.fetch
        loadTask = Task { [weak self] in
            do {
                let data = try await fetch(TeachyVoiceCatalog.previewSentence, voice, TeachySpeechSpeed.normalized(speed))
                guard let self, generation == self.requestGeneration else { return }
                self.cachedSamples[cacheKey] = data
                self.play(data, voice: voice)
            } catch {
                guard let self, generation == self.requestGeneration else { return }
                self.state = .idle
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't play the preview. Check your connection and try again."
            }
        }
    }

    func stop() {
        requestGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        player?.stop()
        player = nil
        state = .idle
    }

    private func play(_ data: Data, voice: String) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            state = .playing(voice: voice)
        } catch {
            player = nil
            state = .idle
            errorMessage = "Couldn't play the preview."
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, case .playing = self.state else { return }
            self.player = nil
            self.state = .idle
        }
    }
}
