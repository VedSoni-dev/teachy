//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let proxyURL: String
    private let session: URLSession
    var model: String

    /// When true, calls OpenRouter directly with the user's API key (no proxy).
    private var useDirectAPI: Bool { TeachyAPIKeyStore.isConfigured }

    /// The effective URL — OpenRouter direct or proxy.
    private var effectiveURL: URL {
        if useDirectAPI {
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        }
        return URL(string: proxyURL)!
    }

    init(proxyURL: String, model: String = "claude-sonnet-4-6") {
        self.proxyURL = proxyURL
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: effectiveURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if useDirectAPI, let apiKey = TeachyAPIKeyStore.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("https://teachy.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Teachy", forHTTPHeaderField: "X-Title")
        }

        return request
    }

    // MARK: - Anthropic → OpenAI format conversion (for direct API)

    /// Converts an Anthropic-format request body to OpenAI Chat Completions format.
    private func convertToOpenAIFormat(
        anthropicBody: [String: Any]
    ) -> [String: Any] {
        let model = anthropicBody["model"] as? String ?? self.model
        let maxTokens = anthropicBody["max_tokens"] as? Int ?? 1024
        let stream = anthropicBody["stream"] as? Bool ?? true
        let systemPrompt = anthropicBody["system"] as? String
        let anthropicMessages = anthropicBody["messages"] as? [[String: Any]] ?? []

        var openAIMessages: [[String: Any]] = []

        // System prompt → system message
        if let systemPrompt, !systemPrompt.isEmpty {
            openAIMessages.append(["role": "system", "content": systemPrompt])
        }

        // Convert each message
        for message in anthropicMessages {
            let role = message["role"] as? String ?? "user"
            let content = message["content"]

            if let textContent = content as? String {
                // Simple text message
                openAIMessages.append(["role": role, "content": textContent])
            } else if let contentBlocks = content as? [[String: Any]] {
                // Multi-block content (images + text)
                var openAIContent: [[String: Any]] = []
                for block in contentBlocks {
                    guard let type = block["type"] as? String else { continue }
                    if type == "text", let text = block["text"] as? String {
                        openAIContent.append(["type": "text", "text": text])
                    } else if type == "image", let source = block["source"] as? [String: Any],
                              let data = source["data"] as? String,
                              let mediaType = source["media_type"] as? String {
                        openAIContent.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                        ])
                    }
                }
                // Flatten single-text content to a string for OpenAI compatibility
                if openAIContent.count == 1, let first = openAIContent.first,
                   first["type"] as? String == "text" {
                    openAIMessages.append(["role": role, "content": first["text"] as? String ?? ""])
                } else {
                    openAIMessages.append(["role": role, "content": openAIContent])
                }
            }
        }

        // Resolve model for OpenRouter
        let resolvedModel = resolveOpenRouterModelID(model, hasImages: anthropicMessages.contains { msg in
            if let blocks = msg["content"] as? [[String: Any]] {
                return blocks.contains { ($0["type"] as? String) == "image" }
            }
            return false
        })

        var body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": maxTokens,
            "stream": stream,
            "messages": openAIMessages,
        ]
        return body
    }

    /// Resolves model ID for direct OpenRouter calls.
    private func resolveOpenRouterModelID(_ requestedModel: String, hasImages: Bool) -> String {
        // If the model already has a provider prefix (e.g. "google/gemini-2.5-flash"), use it directly
        if requestedModel.contains("/") {
            // For text-only models with images, upgrade to vision-capable
            if hasImages && !requestedModel.contains("gemini") && !requestedModel.contains("gemma")
                && !requestedModel.contains("qwen") && !requestedModel.contains("vision") {
                return "google/gemini-2.5-flash"
            }
            return requestedModel
        }
        // Legacy Anthropic model names → OpenRouter equivalents
        if requestedModel.contains("claude") {
            return "anthropic/claude-sonnet-4"
        }
        // Default
        return "google/gemini-2.5-flash"
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: effectiveURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        // Build Anthropic-format messages
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let anthropicBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        // Convert to OpenAI format when calling OpenRouter directly
        let body: [String: Any]
        if useDirectAPI {
            body = convertToOpenAIFormat(anthropicBody: anthropicBody)
        } else {
            body = anthropicBody
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if useDirectAPI {
                // OpenAI SSE format: {"choices":[{"delta":{"content":"..."}}]}
                if let choices = eventPayload["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let textChunk = delta["content"] as? String {
                    accumulatedResponseText += textChunk
                    let currentAccumulatedText = accumulatedResponseText
                    await onTextChunk(currentAccumulatedText)
                }
            } else {
                // Anthropic SSE format: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
                guard let eventType = eventPayload["type"] as? String else { continue }
                if eventType == "content_block_delta",
                   let delta = eventPayload["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String,
                   deltaType == "text_delta",
                   let textChunk = delta["text"] as? String {
                    accumulatedResponseText += textChunk
                    let currentAccumulatedText = accumulatedResponseText
                    await onTextChunk(currentAccumulatedText)
                }
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let anthropicBody: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "stream": false,
            "system": systemPrompt,
            "messages": messages
        ]

        let body: [String: Any]
        if useDirectAPI {
            body = convertToOpenAIFormat(anthropicBody: anthropicBody)
        } else {
            body = anthropicBody
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if useDirectAPI {
            // OpenAI format: {"choices":[{"message":{"content":"..."}}]}
            guard let choices = json?["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
                )
            }
            let duration = Date().timeIntervalSince(startTime)
            return (text: text, duration: duration)
        } else {
            // Anthropic format: {"content":[{"type":"text","text":"..."}]}
            guard let content = json?["content"] as? [[String: Any]],
                  let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
                  let text = textBlock["text"] as? String else {
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
                )
            }
            let duration = Date().timeIntervalSince(startTime)
            return (text: text, duration: duration)
        }
    }

    /// Simple text-only completion (no images, no streaming). Used for course plan generation.
    func generateText(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 2048
    ) async throws -> String {
        var request = makeAPIRequest()

        let messages: [[String: Any]] = [
            ["role": "user", "content": userPrompt]
        ]

        let anthropicBody: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": false,
            "system": systemPrompt,
            "messages": messages
        ]

        let body: [String: Any]
        if useDirectAPI {
            body = convertToOpenAIFormat(anthropicBody: anthropicBody)
        } else {
            body = anthropicBody
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(
                domain: "ClaudeAPI",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(statusCode)): \(errorBody)"]
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"]
            )
        }

        // OpenAI format: {"choices":[{"message":{"content":"..."}}]}
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        // Anthropic format: {"content":[{"type":"text","text":"..."}]}
        if let content = json["content"] as? [[String: Any]],
           let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
           let text = textBlock["text"] as? String {
            return text
        }

        throw NSError(
            domain: "ClaudeAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected response format"]
        )
    }
}
