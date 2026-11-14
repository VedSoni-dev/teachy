//
//  DictationAudioRecorder.swift
//  leanring-buddy
//
//  Records the microphone for one dictation: keeps 16 kHz mono PCM for the final
//  publik transcription and feeds Apple's on-device recognizer for the live text.
//  Uses its own AVAudioEngine so the Control+Option push-to-talk engine in
//  BuddyDictationManager is never touched. The audio tap runs on an audio thread,
//  so this type is nonisolated and guards its state with a lock.
//

import AVFoundation
import Foundation
import Speech

nonisolated final class DictationAudioRecorder: @unchecked Sendable {
    struct RecorderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Called from background threads with the live on-device text so far.
    var onLiveText: (@Sendable (String) -> Void)?
    /// Called from the audio thread with the loudness of the last buffer, 0...1.
    var onLevel: (@Sendable (Double) -> Void)?

    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(DictationAudioFormat.sampleRate),
        channels: 1,
        interleaved: true
    )!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pcm = Data()
    private var isRecording = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var contextualStrings: [String] = []
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Bumped whenever a recognition request is replaced, so late callbacks are ignored.
    private var recognitionGeneration = 0
    private var committedText = ""
    private var currentSegmentText = ""
    private var heardSomethingInSegment = false
    private var segmentStartedAt = Date()
    private var hasFinalText = false

    var liveText: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.join(committedText, currentSegmentText)
    }

    private var isLiveTextFinal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasFinalText
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    // MARK: - Start / stop

    /// `useOnDeviceSpeech` is false when Speech Recognition isn't granted; the
    /// recording still works, there is just no live text.
    func start(contextualStrings: [String], useOnDeviceSpeech: Bool) throws {
        cancel()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError(message: "No microphone found.")
        }

        lock.lock()
        pcm = Data()
        converter = nil
        converterInputFormat = nil
        committedText = ""
        currentSegmentText = ""
        hasFinalText = false
        isRecording = true
        self.contextualStrings = contextualStrings
        self.engine = engine
        lock.unlock()

        if useOnDeviceSpeech {
            speechRecognizer = Self.makeSpeechRecognizer()
            startRecognitionSegment()
        } else {
            lock.lock()
            hasFinalText = true
            lock.unlock()
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    /// Stops the microphone and returns the 16 kHz mono PCM recorded.
    func stop() -> Data {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        isRecording = false
        let recorded = pcm
        pcm = Data()
        let request = recognitionRequest
        if request == nil { hasFinalText = true }
        lock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        return recorded
    }

    /// Stops everything and throws the recording away.
    func cancel() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        isRecording = false
        pcm = Data()
        recognitionGeneration += 1
        let task = recognitionTask
        recognitionTask = nil
        recognitionRequest = nil
        hasFinalText = true
        lock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        task?.cancel()
    }

    /// The on-device text once the recognizer has finished, or whatever it had
    /// after `timeout` seconds. Call after `stop()`.
    func finalLiveText(timeout: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isLiveTextFinal { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return liveText
    }

    // MARK: - Audio thread

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = recognitionRequest
        let recording = isRecording
        lock.unlock()
        guard recording else { return }

        request?.append(buffer)

        guard let chunk = convertToPCM16(buffer) else { return }
        lock.lock()
        if isRecording { pcm.append(chunk) }
        lock.unlock()
        onLevel?(DictationSilenceGate.rms(pcm16: chunk))
    }

    /// Only called from the audio thread, so the converter needs no lock.
    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var hasProvidedBuffer = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if hasProvidedBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedBuffer = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0,
              let bytes = output.audioBufferList.pointee.mBuffers.mData
        else { return nil }
        return Data(bytes: bytes, count: Int(output.frameLength) * 2)
    }

    // MARK: - On-device live text

    private static func makeSpeechRecognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.autoupdatingCurrent, Locale(identifier: "en-US")] {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable { return recognizer }
        }
        return nil
    }

    /// The recognizer ends a request after a pause. Hands-free dictation can run
    /// for minutes, so each ended segment is kept and a new one started.
    private func startRecognitionSegment() {
        guard let speechRecognizer else {
            lock.lock()
            hasFinalText = true
            lock.unlock()
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        lock.lock()
        request.contextualStrings = contextualStrings
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionRequest = request
        currentSegmentText = ""
        heardSomethingInSegment = false
        segmentStartedAt = Date()
        lock.unlock()

        let task = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error, generation: generation)
        }
        lock.lock()
        if generation == recognitionGeneration { recognitionTask = task }
        lock.unlock()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        lock.lock()
        guard generation == recognitionGeneration else {
            lock.unlock()
            return
        }
        if let result {
            currentSegmentText = result.bestTranscription.formattedString
            if !currentSegmentText.isEmpty { heardSomethingInSegment = true }
        }
        let segmentEnded = result?.isFinal == true || error != nil
        var shouldRestart = false
        if segmentEnded {
            committedText = Self.join(committedText, currentSegmentText)
            currentSegmentText = ""
            recognitionRequest = nil
            recognitionTask = nil
            // A recognizer that fails straight away must not restart in a loop, so
            // restart only if this segment heard something or lasted a while.
            if isRecording && (heardSomethingInSegment || Date().timeIntervalSince(segmentStartedAt) > 1) {
                shouldRestart = true
            } else {
                hasFinalText = true
            }
        }
        let text = Self.join(committedText, currentSegmentText)
        lock.unlock()

        onLiveText?(text)
        if shouldRestart { startRecognitionSegment() }
    }
}
