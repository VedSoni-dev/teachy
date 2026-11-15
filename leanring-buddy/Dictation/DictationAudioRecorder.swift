//
//  DictationAudioRecorder.swift
//  leanring-buddy
//
//  Records the microphone for one dictation: keeps 16 kHz mono PCM for the final
//  publik transcription and feeds Apple's on-device recognizer for the live text.
//  A dictation is a list of segments. A short one has a single segment; a long
//  hands-free one is cut at pauses (`cutSegment`) so each sentence-sized piece can
//  be transcribed and typed while the person keeps talking. Each segment has its
//  own audio and its own on-device text and confidence.
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
    /// Called from background threads when one segment's on-device text changes.
    var onSegmentText: (@Sendable (_ segment: Int, _ text: String, _ isFinal: Bool) -> Void)?
    /// Called from the audio thread with the loudness of the last buffer, 0...1.
    var onLevel: (@Sendable (Double) -> Void)?
    /// Called from the audio thread with the loudness and length (seconds) of each buffer.
    var onAudioFrame: (@Sendable (_ rms: Double, _ seconds: Double) -> Void)?

    /// The on-device recognizer's text for one segment.
    struct OnDeviceResult: Sendable {
        var text: String
        /// Per-word confidence, 0...1. Empty until the recognizer has finished.
        var confidences: [Double]
        var isFinal: Bool
    }

    private struct SegmentState {
        var committedText = ""
        var currentText = ""
        var confidences: [Double] = []
        var isFinal = false
        /// The recognition request allowed to write to this segment.
        var requestToken = 0
        var heardSomethingInRequest = false
        var requestStartedAt = Date()

        var text: String { DictationAudioRecorder.join(committedText, currentText) }
    }

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
    /// The request the microphone is feeding now (the active segment's).
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    /// Every recognition task still running, by request token.
    private var recognitionTasks: [Int: SFSpeechRecognitionTask] = [:]
    private var nextRequestToken = 1
    /// Bumped by `start` and `cancel` so callbacks from an older dictation are ignored.
    private var sessionGeneration = 0
    private var segments: [SegmentState] = [SegmentState()]
    private var usesOnDeviceSpeech = false

    /// All segments' on-device text, in order.
    var liveText: String {
        lock.lock()
        defer { lock.unlock() }
        return segments.reduce("") { Self.join($0, $1.text) }
    }

    var activeSegmentIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count - 1
    }

    private var isLiveTextFinal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return segments.allSatisfy(\.isFinal)
    }

    func onDeviceResult(forSegment index: Int) -> OnDeviceResult {
        lock.lock()
        defer { lock.unlock() }
        guard segments.indices.contains(index) else { return OnDeviceResult(text: "", confidences: [], isFinal: true) }
        let segment = segments[index]
        return OnDeviceResult(text: segment.text, confidences: segment.confidences, isFinal: segment.isFinal)
    }

    /// One segment's on-device text once its recognizer has finished, or whatever
    /// it had after `timeout` seconds.
    func finalOnDeviceResult(forSegment index: Int, timeout: TimeInterval) async -> OnDeviceResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if onDeviceResult(forSegment: index).isFinal { break }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return onDeviceResult(forSegment: index)
    }

    /// The audio of the active segment so far, without stopping anything.
    func pcmSnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return pcm
    }

    /// Closes the active segment in the middle of a dictation and starts the next
    /// one. Returns the closed segment's index and audio. Its on-device text
    /// becomes final a moment later (`finalOnDeviceResult`).
    func cutSegment() -> (index: Int, pcm: Data)? {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return nil
        }
        let index = segments.count - 1
        let recorded = pcm
        pcm = Data()
        let request = recognitionRequest
        recognitionRequest = nil
        if request == nil { segments[index].isFinal = true }
        segments.append(SegmentState())
        if !usesOnDeviceSpeech { segments[index + 1].isFinal = true }
        let shouldRecognize = usesOnDeviceSpeech
        lock.unlock()

        request?.endAudio()
        if shouldRecognize { startRecognitionRequest() }
        return (index, recorded)
    }

    fileprivate static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    // MARK: - Start / stop

    /// `useOnDeviceSpeech` is false when Speech Recognition isn't granted; the
    /// recording still works, there is just no live text.
    /// `languageCode` is the dictation language from Settings ("es", "de"…), or nil
    /// to follow the Mac's language.
    func start(contextualStrings: [String], useOnDeviceSpeech: Bool, languageCode: String? = nil) throws {
        cancel()

        let engine = AVAudioEngine()
        // Use the microphone chosen in Settings (or the Mac's input when following the system).
        MicrophoneCenter.applyWithFailover(to: engine)
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError(message: "No microphone found.")
        }

        lock.lock()
        pcm = Data()
        converter = nil
        converterInputFormat = nil
        segments = [SegmentState()]
        sessionGeneration += 1
        isRecording = true
        usesOnDeviceSpeech = useOnDeviceSpeech
        self.contextualStrings = contextualStrings
        self.engine = engine
        lock.unlock()

        if useOnDeviceSpeech {
            speechRecognizer = Self.makeSpeechRecognizer(languageCode: languageCode)
            startRecognitionRequest()
        } else {
            lock.lock()
            segments[0].isFinal = true
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

    /// Stops the microphone and returns the 16 kHz mono PCM of the active (last) segment.
    func stop() -> Data {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        isRecording = false
        let recorded = pcm
        pcm = Data()
        let request = recognitionRequest
        recognitionRequest = nil
        if request == nil { segments[segments.count - 1].isFinal = true }
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
        sessionGeneration += 1
        let tasks = Array(recognitionTasks.values)
        recognitionTasks = [:]
        recognitionRequest = nil
        for index in segments.indices { segments[index].isFinal = true }
        lock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        tasks.forEach { $0.cancel() }
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
        let level = DictationSilenceGate.rms(pcm16: chunk)
        onLevel?(level)
        onAudioFrame?(level, DictationSilenceGate.seconds(pcm16ByteCount: chunk.count, sampleRate: DictationAudioFormat.sampleRate))
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

    /// The recognizer for the chosen dictation language when the Mac can run it on
    /// the device, else the Mac's own language, else US English.
    private static func makeSpeechRecognizer(languageCode: String?) -> SFSpeechRecognizer? {
        var locales: [Locale] = []
        if let languageCode, !languageCode.isEmpty {
            let current = Locale.autoupdatingCurrent
            if current.language.languageCode?.identifier == languageCode {
                locales.append(current)
            } else if let match = SFSpeechRecognizer.supportedLocales()
                .filter({ $0.language.languageCode?.identifier == languageCode })
                .sorted(by: { $0.identifier < $1.identifier }).first {
                locales.append(match)
            }
        }
        locales += [Locale.autoupdatingCurrent, Locale(identifier: "en-US")]
        for locale in locales {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable { return recognizer }
        }
        return nil
    }

    /// Starts a recognition request for the active segment. The recognizer ends a
    /// request after a pause; hands-free dictation can run for minutes, so an
    /// ended request's text is kept and a new one started for the same segment.
    private func startRecognitionRequest() {
        guard let speechRecognizer else {
            lock.lock()
            for index in segments.indices { segments[index].isFinal = true }
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
        let generation = sessionGeneration
        let token = nextRequestToken
        nextRequestToken += 1
        let segmentIndex = segments.count - 1
        segments[segmentIndex].requestToken = token
        segments[segmentIndex].currentText = ""
        segments[segmentIndex].heardSomethingInRequest = false
        segments[segmentIndex].requestStartedAt = Date()
        recognitionRequest = request
        lock.unlock()

        let task = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error, generation: generation, segmentIndex: segmentIndex, token: token)
        }
        lock.lock()
        if generation == sessionGeneration { recognitionTasks[token] = task }
        lock.unlock()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, generation: Int, segmentIndex: Int, token: Int) {
        lock.lock()
        guard generation == sessionGeneration, segments.indices.contains(segmentIndex),
              segments[segmentIndex].requestToken == token, !segments[segmentIndex].isFinal
        else {
            lock.unlock()
            return
        }
        if let result {
            segments[segmentIndex].currentText = result.bestTranscription.formattedString
            if !segments[segmentIndex].currentText.isEmpty { segments[segmentIndex].heardSomethingInRequest = true }
        }
        let requestEnded = result?.isFinal == true || error != nil
        var shouldRestart = false
        if requestEnded {
            if let result {
                segments[segmentIndex].confidences += result.bestTranscription.segments.map { Double($0.confidence) }
            }
            segments[segmentIndex].committedText = segments[segmentIndex].text
            segments[segmentIndex].currentText = ""
            recognitionTasks.removeValue(forKey: token)
            let isActiveSegment = segmentIndex == segments.count - 1
            if isActiveSegment { recognitionRequest = nil }
            // A recognizer that fails straight away must not restart in a loop, so
            // restart only if this request heard something or lasted a while.
            let segment = segments[segmentIndex]
            if isActiveSegment && isRecording
                && (segment.heardSomethingInRequest || Date().timeIntervalSince(segment.requestStartedAt) > 1) {
                shouldRestart = true
            } else {
                segments[segmentIndex].isFinal = true
            }
        }
        let segmentText = segments[segmentIndex].text
        let segmentIsFinal = segments[segmentIndex].isFinal
        let text = segments.reduce("") { Self.join($0, $1.text) }
        lock.unlock()

        onLiveText?(text)
        onSegmentText?(segmentIndex, segmentText, segmentIsFinal)
        if shouldRestart { startRecognitionRequest() }
    }
}
