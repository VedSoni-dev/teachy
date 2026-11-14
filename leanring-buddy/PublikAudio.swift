//
//  PublikAudio.swift
//  leanring-buddy
//
//  Speech-to-text and text-to-speech on publik (OpenAI-compatible audio endpoints).
//  Billed at the provider's price. Measured 14 Nov 2026: an 8 s clip transcribes in
//  about 1.5 s with gpt-4o-transcribe (3.0 s with whisper-1); one spoken sentence
//  takes about 1.9 s with tts-1.
//

import Foundation

enum PublikAudio {
    struct AudioError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Models to try for transcription, best first.
    static let transcriptionModels = ["gpt-4o-transcribe", "whisper-1"]

    private static func publikRoute() throws -> TeachyAIRoute {
        guard let route = try TeachyAIRouter.routes(for: .voice, hasImages: false).first, route.isPublik else {
            throw AudioError(message: "Speech needs publik. Sign in with publik in the Teachy panel.")
        }
        return route
    }

    /// Transcribes a short clip (WAV, under about 4 MB). `prompt` biases spelling toward
    /// the person's dictionary words; `language` is a code like "en" or nil to auto-detect.
    static func transcribe(wavData: Data, prompt: String? = nil, language: String? = nil) async throws -> String {
        let route = try publikRoute()
        var lastError: Error = AudioError(message: "Transcription failed.")
        for model in transcriptionModels {
            let boundary = "teachy-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("model", model)
            if let prompt, !prompt.isEmpty { field("prompt", prompt) }
            if let language, !language.isEmpty { field("language", language) }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(wavData)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            var request = URLRequest(url: URL(string: "\(route.baseURL)/audio/transcriptions")!, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 402 { try reportBilling(data) }
                guard (200...299).contains(status),
                      let text = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["text"] as? String
                else {
                    lastError = AudioError(message: "Transcription answered \(status).")
                    continue
                }
                return text
            } catch let error as TeachyAIBillingError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Speaks `text`. Returns MP3 data.
    static func speech(text: String, voice: String = "alloy", speed: Double = 1.0) async throws -> Data {
        let route = try publikRoute()
        var request = URLRequest(url: URL(string: "\(route.baseURL)/audio/speech")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "tts-1", "voice": voice, "input": text, "speed": speed,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 402 { try reportBilling(data) }
        guard (200...299).contains(status), !data.isEmpty else {
            throw AudioError(message: "Speech answered \(status).")
        }
        return data
    }

    private static func reportBilling(_ data: Data) throws {
        let billing = Publik.topUpURLFrom402(data)
        let error = TeachyAIBillingError(message: billing.message, topUpURL: billing.url)
        Task { @MainActor in TeachyPublikSession.shared.reportBilling(error) }
        throw error
    }
}
