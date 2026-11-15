//
//  UtteranceTranscriber.swift
//  leanring-buddy
//
//  Turns one finished always-on utterance into text. The Mac's own on-device
//  recogniser goes first because it answers in a fraction of a second and costs
//  nothing; publik transcription is used when the Mac can't do it on-device (or
//  speech recognition isn't allowed), when it failed, or when it wasn't confident.
//  If the Mac heard no words at all, the sound is taken to be noise and nothing is
//  sent anywhere. The rule is `TranscriptChoice.decide`. Never shows a permission prompt.
//

import AVFoundation
import Foundation
import Speech

@MainActor
enum UtteranceTranscriber {
    struct Outcome: Equatable {
        let text: String
        /// "on-device" or "publik", for the log.
        let source: String
    }

    /// Mono float samples at `sampleRate`. Returns nil when nothing was said.
    static func transcribe(samples: [Float], sampleRate: Double) async -> Outcome? {
        guard !samples.isEmpty else { return nil }
        let replyLanguage = TeachySettingsStorage.replyLanguage()
        let dictationLanguage = TeachySettingsStorage.dictationLanguageCode()

        let recognizer = onDeviceRecognizer(locale: TeachySettingsStorage.speechRecognizerLocale())
        var onDevice: (text: String, confidence: Float?)?
        if let recognizer {
            onDevice = await recognizeOnDevice(samples: samples, sampleRate: sampleRate, recognizer: recognizer)
        }

        switch TranscriptChoice.decide(
            onDeviceAvailable: recognizer != nil,
            onDeviceText: onDevice?.text,
            onDeviceConfidence: onDevice?.confidence
        ) {
        case .useOnDevice:
            return Outcome(text: onDevice?.text ?? "", source: "on-device")
        case .nothingSaid:
            return nil
        case .askPublik:
            let wav = wavData(samples: samples, sampleRate: sampleRate)
            let language = TeachyReplyLanguages.transcriptionLanguageCode(replyLanguage: replyLanguage, dictationLanguage: dictationLanguage)
            do {
                let text = try await PublikAudio.transcribe(wavData: wav, language: language)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Outcome(text: text, source: "publik")
            } catch {
                print("⚠️ Always-on: publik transcription failed: \(error.localizedDescription)")
                // A low-confidence local transcript beats nothing.
                if let text = onDevice?.text, !text.isEmpty { return Outcome(text: text, source: "on-device") }
                return nil
            }
        }
    }

    /// A recogniser that works entirely on this Mac, or nil (not allowed, not available,
    /// or this language isn't supported on-device).
    private static func onDeviceRecognizer(locale: Locale?) -> SFSpeechRecognizer? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        // A fixed language the Mac can't recognise goes to publik, not to the wrong recogniser.
        guard let recognizer = locale.map({ SFSpeechRecognizer(locale: $0) }) ?? SFSpeechRecognizer(locale: .autoupdatingCurrent),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
        return recognizer
    }

    /// The final transcript and its average word confidence. Nil on an error or after 4 seconds.
    private static func recognizeOnDevice(
        samples: [Float], sampleRate: Double, recognizer: SFSpeechRecognizer
    ) async -> (text: String, confidence: Float?)? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.append(buffer)
        request.endAudio()

        final class Box: @unchecked Sendable {
            var continuation: CheckedContinuation<(text: String, confidence: Float?)?, Never>?
            var task: SFSpeechRecognitionTask?
            let lock = NSLock()
            func finish(_ value: (text: String, confidence: Float?)?) {
                lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
                pending?.resume(returning: value)
            }
        }
        let box = Box()
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let segments = result.bestTranscription.segments
                    let confidences = segments.map(\.confidence).filter { $0 > 0 }
                    let average = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
                    box.finish((result.bestTranscription.formattedString, average))
                } else if let error {
                    // "No speech detected" arrives as an error: that is an answer, an empty one.
                    let nsError = error as NSError
                    let noSpeech = nsError.domain == "kAFAssistantErrorDomain" && [1110, 203].contains(nsError.code)
                    box.finish(noSpeech ? ("", nil) : nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                box.task?.cancel()
                box.finish(nil)
            }
        }
    }

    /// 16-bit mono WAV, resampled down to 16 kHz when the microphone ran faster (smaller upload).
    static func wavData(samples: [Float], sampleRate: Double) -> Data {
        var source = samples
        var rate = sampleRate
        if sampleRate > 16_000 {
            let step = sampleRate / 16_000
            let count = Int(Double(samples.count) / step)
            var resampled = [Float](repeating: 0, count: count)
            // Average each stretch of input samples: a simple low-pass before dropping the rate.
            for index in 0..<count {
                let from = Int(Double(index) * step)
                let to = min(samples.count, max(from + 1, Int(Double(index + 1) * step)))
                var sum: Float = 0
                for sampleIndex in from..<to { sum += samples[sampleIndex] }
                resampled[index] = sum / Float(to - from)
            }
            source = resampled
            rate = 16_000
        }
        var pcm = Data(capacity: source.count * 2)
        for sample in source {
            var value = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        let sampleRateValue = UInt32(rate)
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRateValue); append(sampleRateValue * 2); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }
}
