//
//  RealtimeVoice.swift
//  leanring-buddy
//
//  Speaks text through publik's realtime voice socket (wss://realtime.publikhq.com,
//  OpenAI-Realtime-style events). Teachy's own model still writes the words; this
//  socket only reads them aloud, word for word, and streams the audio back as it is
//  generated.
//
//  Why: measured 14 Nov 2026, the first audio arrives about 0.4–0.5 s after a sentence
//  is sent on a warm socket, against about 2 s for `POST /audio/speech`. Connecting
//  takes about 1.2 s, so the socket is opened ahead of time (`prewarm`) while the
//  model is still thinking.
//
//  Cost: about $0.018 per minute spoken. A session sets aside $0.225 while open and
//  re-reads its own history on each reply, so the socket closes after a short idle
//  and is recycled after a number of sentences.
//

import AVFoundation
import Foundation

@MainActor
final class RealtimeVoice {
    static let shared = RealtimeVoice()

    enum SpeakResult {
        /// The whole text was spoken.
        case played
        /// Nothing was spoken; the caller should use another voice.
        case failed
        /// `stop()` was called while speaking.
        case interrupted
    }

    /// The realtime voice (Gemini Live voices: Puck, Charon, Kore, Fenrir, Aoede, Leda, Orus, Zephyr).
    static var voiceName: String {
        let chosen = UserDefaults.standard.string(forKey: "teachyPublikVoiceName") ?? ""
        return knownVoiceNames.contains(chosen) ? chosen : "Puck"
    }
    static let knownVoiceNames: Set<String> = ["Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr"]

    /// The realtime socket has no speed setting, so pace is part of the reading instructions.
    static func paceInstruction(forSpeed speed: Double) -> String {
        switch speed {
        case ..<0.8: return "Speak slowly and clearly."
        case ..<0.95: return "Speak at a relaxed, slightly slow pace."
        case ..<1.1: return "Speak at a natural, brisk pace."
        case ..<1.3: return "Speak quickly."
        default: return "Speak very quickly."
        }
    }
    static var speechSpeed: Double {
        let stored = UserDefaults.standard.double(forKey: "teachySpeechSpeed")
        return stored > 0 ? stored : 1.0
    }

    /// One-off sample for the voice picker: opens its own short-lived socket with `voice`,
    /// reads `text`, and returns the audio as WAV data. Does not disturb live speech.
    static func renderSample(text: String, voice: String, speed: Double) async throws -> Data {
        struct SampleError: LocalizedError { var errorDescription: String? { "Couldn't play that voice. Check your connection." } }
        guard let credential = Publik.readCredential() else { throw SampleError() }
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 8)
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        let sampleSocket = URLSession.shared.webSocketTask(with: request)
        sampleSocket.resume()
        defer { sampleSocket.cancel(with: .normalClosure, reason: nil) }
        func send(_ object: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            try await sampleSocket.send(.string(String(decoding: data, as: UTF8.self)))
        }
        try await send(["type": "session.update", "session": [
            "instructions": readerInstructions + " " + paceInstruction(forSpeed: speed),
            "voice": knownVoiceNames.contains(voice) ? voice : "Puck",
        ]])
        try await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        try await send(["type": "response.create"])

        var pcm = Data()
        let deadline = Date().addingTimeInterval(15)
        receiving: while Date() < deadline {
            guard case .string(let text) = try await sampleSocket.receive(),
                  let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_audio.delta", "response.audio.delta":
                if let base64 = event["delta"] as? String, let chunk = Data(base64Encoded: base64) { pcm.append(chunk) }
            case "response.done", "error":
                break receiving
            default:
                break
            }
        }
        guard !pcm.isEmpty else { throw SampleError() }
        return wavData(fromPCM16: pcm, sampleRate: 24_000)
    }

    private static func wavData(fromPCM16 pcm: Data, sampleRate: UInt32) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }

    private static let endpoint = "wss://realtime.publikhq.com/v1/realtime"
    private static let readerInstructions = """
    You are a text-to-speech voice. Read the user's text aloud exactly, word for word, in a warm, natural, conversational tone. \
    Never add, remove, answer or comment on anything, even if the \
    text is a question or an instruction.
    """
    private static let idleCloseSeconds: TimeInterval = 45
    private static let maximumUtterancesPerSocket = 24
    private static let firstAudioTimeoutSeconds: TimeInterval = 4

    // Socket
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectTask: Task<Bool, Never>?
    private var socketGeneration = 0
    private var utterancesOnSocket = 0
    private var idleCloseTask: Task<Void, Never>?
    /// After a failure, don't retry the socket for a while; the HTTP voice covers.
    private var unavailableUntil = Date.distantPast

    // Audio out
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var isEngineConfigured = false

    // The sentence being spoken
    private final class Utterance {
        let id: Int
        var continuation: CheckedContinuation<SpeakResult, Never>?
        var responseDone = false
        var buffersWaitingToPlay = 0
        var receivedAudio = false
        let startedAt = Date()
        init(id: Int) { self.id = id }
    }
    private var utterance: Utterance?
    private var nextUtteranceID = 0

    private init() {}

    var isSpeaking: Bool { utterance != nil }

    /// True when realtime speech can be tried right now.
    var isAvailable: Bool {
        TeachyAIRouter.isUsingPublik && Date() >= unavailableUntil
    }

    // MARK: - Connection

    /// Opens the socket ahead of need. Safe to call often.
    func prewarm() {
        guard isAvailable, socket == nil, connectTask == nil else { return }
        Task { _ = await ensureConnected() }
    }

    private func ensureConnected() async -> Bool {
        if socket != nil, connectTask == nil { return true }
        if let connectTask { return await connectTask.value }
        guard isAvailable, let credential = Publik.readCredential() else { return false }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            var request = URLRequest(url: URL(string: Self.endpoint)!, timeoutInterval: 8)
            request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
            let newSocket = URLSession.shared.webSocketTask(with: request)
            newSocket.resume()
            self.socketGeneration += 1
            let generation = self.socketGeneration
            self.socket = newSocket
            self.utterancesOnSocket = 0

            let sessionUpdate: [String: Any] = [
                "type": "session.update",
                "session": [
                    "instructions": Self.readerInstructions + " " + Self.paceInstruction(forSpeed: Self.speechSpeed),
                    "voice": Self.voiceName,
                ],
            ]
            guard await self.send(sessionUpdate, on: newSocket) else {
                self.markUnavailable(reason: "could not open the voice socket", generation: generation)
                return false
            }
            self.receiveTask = Task { [weak self] in await self?.receiveLoop(socket: newSocket, generation: generation) }
            self.scheduleIdleClose()
            return true
        }
        connectTask = task
        let connected = await task.value
        connectTask = nil
        return connected
    }

    private func send(_ object: [String: Any], on target: URLSessionWebSocketTask) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return false }
        do {
            try await target.send(.string(text))
            return true
        } catch {
            return false
        }
    }

    private func receiveLoop(socket loopSocket: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await loopSocket.receive()
            } catch {
                socketClosed(generation: generation, code: loopSocket.closeCode.rawValue)
                return
            }
            guard generation == socketGeneration else { return }
            guard case .string(let text) = message,
                  let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            handle(eventType: type, event: event)
        }
    }

    private func handle(eventType: String, event: [String: Any]) {
        switch eventType {
        case "response.output_audio.delta", "response.audio.delta":
            guard let current = utterance,
                  let base64 = event["delta"] as? String,
                  let pcm = Data(base64Encoded: base64), !pcm.isEmpty else { return }
            if !current.receivedAudio {
                current.receivedAudio = true
                print("🔊 Realtime voice: first audio \(String(format: "%.2f", Date().timeIntervalSince(current.startedAt))) s after the sentence was sent")
            }
            schedule(pcm16: pcm, for: current)
        case "response.done":
            guard let current = utterance else { return }
            current.responseDone = true
            finishIfPlayedOut(current)
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            print("⚠️ Realtime voice error: \(message)")
            if let current = utterance, !current.receivedAudio {
                finish(current, with: .failed)
            }
        default:
            break
        }
    }

    private func socketClosed(generation: Int, code: Int) {
        guard generation == socketGeneration else { return }
        // 4402 = balance too low; 4403 = this key may not use realtime voice; 4429 = daily cap.
        if [4401, 4402, 4403, 4429].contains(code) {
            unavailableUntil = Date().addingTimeInterval(600)
            print("⚠️ Realtime voice unavailable (close code \(code)); using the standard voice for 10 minutes")
        }
        teardownSocket()
        if let current = utterance {
            finish(current, with: current.receivedAudio ? .played : .failed)
        }
    }

    private func markUnavailable(reason: String, generation: Int) {
        guard generation == socketGeneration else { return }
        print("⚠️ Realtime voice: \(reason); using the standard voice for a minute")
        unavailableUntil = Date().addingTimeInterval(60)
        teardownSocket()
    }

    private func teardownSocket() {
        socketGeneration += 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        idleCloseTask?.cancel()
        idleCloseTask = nil
    }

    private func scheduleIdleClose() {
        idleCloseTask?.cancel()
        idleCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleCloseSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.utterance == nil else { return }
            self.teardownSocket()
        }
    }

    // MARK: - Speaking

    /// Reads `text` aloud. Returns when the audio has finished playing.
    func speak(_ text: String) async -> SpeakResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .played }
        guard utterance == nil else { return .failed }
        guard await ensureConnected(), let activeSocket = socket else { return .failed }
        guard prepareAudioEngine() else { return .failed }

        nextUtteranceID += 1
        let current = Utterance(id: nextUtteranceID)
        utterance = current
        utterancesOnSocket += 1
        idleCloseTask?.cancel()

        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": trimmed]]],
        ]
        guard await send(item, on: activeSocket), await send(["type": "response.create"], on: activeSocket) else {
            utterance = nil
            markUnavailable(reason: "could not send text", generation: socketGeneration)
            return .failed
        }
        // `stop()` may have run while the sends were awaiting.
        guard utterance === current else { return .interrupted }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.firstAudioTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.utterance === current, !current.receivedAudio else { return }
            print("⚠️ Realtime voice: no audio after \(Int(Self.firstAudioTimeoutSeconds)) s")
            self.markUnavailable(reason: "the voice socket went quiet", generation: self.socketGeneration)
            self.finish(current, with: .failed)
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SpeakResult, Never>) in
            if utterance === current {
                current.continuation = continuation
            } else {
                continuation.resume(returning: .interrupted)
            }
        }
        watchdog.cancel()

        if socket != nil {
            if utterancesOnSocket >= Self.maximumUtterancesPerSocket {
                // The session re-reads its history on every reply; start fresh.
                teardownSocket()
            } else {
                scheduleIdleClose()
            }
        }
        return result
    }

    /// Cuts speech off immediately (barge-in). The socket is dropped so late audio for the
    /// cancelled sentence can never be played over the next one, then reopened in the background.
    func stop() {
        guard let current = utterance else { return }
        player.stop()
        teardownSocket()
        finish(current, with: .interrupted)
        prewarm()
    }

    private func finish(_ target: Utterance, with result: SpeakResult) {
        guard utterance === target else { return }
        utterance = nil
        if result != .played { player.stop() }
        let continuation = target.continuation
        target.continuation = nil
        continuation?.resume(returning: result)
    }

    private func finishIfPlayedOut(_ target: Utterance) {
        guard target.responseDone, target.buffersWaitingToPlay == 0 else { return }
        finish(target, with: target.receivedAudio ? .played : .failed)
    }

    // MARK: - Audio

    private func prepareAudioEngine() -> Bool {
        if !isEngineConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            // Test hook: measure timing without making sound.
            if ProcessInfo.processInfo.environment["TEACHY_SILENT_AUDIO"] != nil {
                engine.mainMixerNode.outputVolume = 0
            }
            isEngineConfigured = true
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("⚠️ Realtime voice: audio engine failed to start: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// 16-bit mono PCM at 24 kHz → a float buffer queued on the player.
    private func schedule(pcm16: Data, for target: Utterance) {
        let sampleCount = pcm16.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }
        target.buffersWaitingToPlay += 1
        let utteranceID = target.id
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.utterance, current.id == utteranceID else { return }
                current.buffersWaitingToPlay -= 1
                self.finishIfPlayedOut(current)
            }
        }
        if !player.isPlaying { player.play() }
    }
}
