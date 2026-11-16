//
//  ClaudeAPI.swift
//  Vision + text model client with streaming support.
//
//  The name is historical. Every call goes through `TeachyAIRouter`, which sends it
//  to publik (OpenAI-compatible) and picks the tier for the job. Callers never choose
//  a model; the `model` property is kept only so older call sites still compile.
//

import Foundation

/// Vision + text model client with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    /// publik's body limit is 4 MB; base64 screenshots are kept under this budget.
    private static let imageBase64BudgetBytes = 3_300_000

    private let session: URLSession

    /// Ignored: `TeachyAIRouter` picks the model. Kept for source compatibility.
    var model: String

    init(proxyURL: String = "", model: String = "") {
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

        // Pre-establish the TLS connection so the first real call (which carries a
        // large image payload) doesn't need a cold handshake.
        warmUpTLSConnectionIfNeeded()
    }

    // MARK: - Message building (OpenAI Chat Completions format)

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Keeps images in order until the base64 budget is spent. The first image is the
    /// cursor screen by convention, so it always survives; extra displays drop first.
    private func imagesWithinBudget(_ images: [(data: Data, label: String)]) -> [(data: Data, label: String)] {
        var kept: [(data: Data, label: String)] = []
        var spentBytes = 0
        for image in images {
            let base64Bytes = (image.data.count + 2) / 3 * 4
            if !kept.isEmpty && spentBytes + base64Bytes > Self.imageBase64BudgetBytes {
                print("🌐 TeachyAI: dropped \"\(image.label)\" to stay under publik's request size limit")
                continue
            }
            kept.append(image)
            spentBytes += base64Bytes
        }
        return kept
    }

    private func buildMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> (messages: [[String: Any]], hasImages: Bool) {
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        let attachedImages = imagesWithinBudget(images)
        guard !attachedImages.isEmpty else {
            messages.append(["role": "user", "content": userPrompt])
            return (messages, false)
        }

        var contentBlocks: [[String: Any]] = []
        for image in attachedImages {
            contentBlocks.append([
                "type": "image_url",
                "image_url": ["url": "data:\(detectImageMediaType(for: image.data));base64,\(image.data.base64EncodedString())"]
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }
        contentBlocks.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": contentBlocks])
        return (messages, true)
    }

    private static func assistantText(fromResponseData data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw NSError(domain: "ClaudeAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format"])
        }
        if let text = message["content"] as? String {
            return text
        }
        // Some providers return content as text blocks.
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
        return ""
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

        guard shouldStartTLSWarmup, let warmupURL = URL(string: Publik.origin) else { return }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in }.resume()
    }

    // MARK: - Calls

    /// Vision request with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        job: TeachyAIJob = .coach,
        reasoningEffort: String? = nil,
        maxTokens: Int = 1024,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let (messages, hasImages) = buildMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        var body: [String: Any] = [
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messages,
        ]
        // Overrides the job's default effort (the router only fills it in when absent).
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }

        print("🌐 TeachyAI streaming \(job.rawValue): \(images.count) image(s)")
        let byteStream = try await TeachyAIRouter.openStream(
            job: job,
            hasImages: hasImages,
            session: session,
            body: body
        )

        // Parse SSE: {"choices":[{"delta":{"content":"..."}}]}
        var accumulatedResponseText = ""
        // Guarded: some tiers finish the answer but never close the connection.
        for try await line in StreamIdleGuard.lines(from: byteStream) {
            guard line.hasPrefix("data:") else { continue }
            let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard jsonString != "[DONE]" else { break }
            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String,
                  !textChunk.isEmpty
            else { continue }
            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        return (text: accumulatedResponseText, duration: Date().timeIntervalSince(startTime))
    }

    /// Non-streaming call for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        job: TeachyAIJob = .quickCheck
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let (messages, hasImages) = buildMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        let body: [String: Any] = [
            "max_tokens": 256,
            "stream": false,
            "messages": messages,
        ]

        print("🌐 TeachyAI \(job.rawValue): \(images.count) image(s)")
        let data = try await TeachyAIRouter.sendJSON(job: job, hasImages: hasImages, session: session, body: body)
        let text = try Self.assistantText(fromResponseData: data)
        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    /// Screen-grounded planning: routed to the strongest tier, with an optional
    /// grid-annotated screenshot. Returns the raw assistant text (JSON from the planner).
    /// `modelID` is ignored; the router picks the tier.
    func generateReasonedPlanJSON(
        systemPrompt: String,
        userPrompt: String,
        imageJPEGData: Data?,
        imageLabel: String?,
        screenshotWidthInPixels: Int = 0,
        screenshotHeightInPixels: Int = 0,
        modelID: String = ""
    ) async throws -> String {
        let userMessageContent: Any
        if let rawJPEGData = imageJPEGData {
            // Annotate with the coordinate grid the same way BackgroundAgentManager does,
            // so the planner can reference specific screen regions.
            let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
                originalJPEGData: rawJPEGData,
                screenshotWidthInPixels: screenshotWidthInPixels,
                screenshotHeightInPixels: screenshotHeightInPixels,
                mouseOutlinePointsInScreenshotSpace: [],
                highlightedGridCellLabels: []
            ) ?? rawJPEGData

            var contentBlocks: [[String: Any]] = [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(annotatedImageData.base64EncodedString())"]]
            ]
            if let imageLabel, !imageLabel.isEmpty {
                let dimensionInfo = screenshotWidthInPixels > 0
                    ? " (image dimensions: \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels, grid overlay: columns A-X, rows 1-16)"
                    : ""
                contentBlocks.append(["type": "text", "text": imageLabel + dimensionInfo])
            }
            contentBlocks.append(["type": "text", "text": userPrompt])
            userMessageContent = contentBlocks
        } else {
            userMessageContent = userPrompt
        }

        let body: [String: Any] = [
            "max_tokens": 4096,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessageContent],
            ],
            // Honoured on the own-key (OpenRouter) path; the router strips it for publik.
            "reasoning": ["effort": "high"],
        ]

        print("🧠 TeachyAI plan: hasScreenshot=\(imageJPEGData != nil)")
        let data = try await TeachyAIRouter.sendJSON(
            job: .plan,
            hasImages: imageJPEGData != nil,
            session: session,
            body: body
        )
        return try Self.assistantText(fromResponseData: data)
    }

    /// Simple text-only completion (no images, no streaming). Used for the fast walkthrough planner fallback.
    func generateText(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 2048
    ) async throws -> String {
        let body: [String: Any] = [
            "max_tokens": maxTokens,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        let data = try await TeachyAIRouter.sendJSON(job: .write, hasImages: false, session: session, body: body)
        return try Self.assistantText(fromResponseData: data)
    }
}
