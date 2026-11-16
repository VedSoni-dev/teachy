//
//  TeachyAIRouter.swift
//  leanring-buddy
//
//  Every model call in Teachy goes through here. People never pick a model:
//  Teachy picks a publik tier for each job and falls back on its own.
//
//    quickCheck / cleanup   YES/NO checks, dictation cleanup      → publik-fast
//    voice / coach / agent / scene / plan   anything waited on  → publik-smart
//    write       background text (walkthrough steps, notices)      → publik-balanced
//
//  Fallback: if a tier errors (provider down, rate limit, tier not allowed for
//  this account) the call moves to the next tier. If a tier answers that it
//  can't read images, Teachy remembers that for a few days and sends screenshots
//  to another tier. A 402 never falls back: it is shown with publik's one link.
//
//  publik is the only provider by default. The "Use my own key" button on
//  publik's sign-in screen (required by publik) keeps working: it uses the
//  person's OpenRouter key with fixed open-weight models, still chosen per job.
//

import AppKit
import Combine
import Foundation

enum TeachyAIJob: String {
    case quickCheck
    case coach
    case agent
    case write
    case plan
    /// A spoken answer the person is waiting on (voice turn, pointing, walkthrough step).
    case voice
    /// A scene script for the drawing engine.
    case scene
    /// Faithful cleanup of dictated text.
    case cleanup
}

struct TeachyAIRoute {
    let url: URL
    let baseURL: String
    let apiKey: String
    let model: String
    let isPublik: Bool
}

/// publik answered 402: show the message and its one link.
struct TeachyAIBillingError: LocalizedError {
    let message: String
    let topUpURL: URL?
    var errorDescription: String? { message }
}

struct TeachyAINotReadyError: LocalizedError {
    var errorDescription: String? {
        "Teachy isn't connected to AI yet. Open the Teachy panel and sign in with publik."
    }
}

enum TeachyAIRouter {
    static let openRouterBaseURL = "https://openrouter.ai/api/v1"

    /// publik's request body limit is 4 MB including base64 images. Leave headroom for JSON.
    static let maximumRequestBodyBytes = 3_900_000

    /// Floor for max_tokens on publik calls, so reasoning tiers still reach the answer.
    static let minimumPublikMaxTokens = 2_048

    // MARK: - Routing

    /// The tiers to try for a job, best first.
    static func publikTierOrder(for job: TeachyAIJob) -> [String] {
        let fast = Publik.models.fast, balanced = Publik.models.balanced, smart = Publik.models.smart
        // Measured 14 Nov 2026 on a spoken answer with a screenshot: smart 1.5 s to first
        // text, fast 1.3 s (streams sometimes don't close), balanced 21 s. So anything a
        // person waits on goes smart-first, and balanced is for background writing only.
        switch job {
        case .quickCheck, .cleanup: return [fast, smart, balanced]
        case .voice, .coach, .agent, .scene, .plan: return [smart, fast, balanced]
        case .write: return [balanced, smart, fast]
        }
    }

    /// Own-key path (OpenRouter). Fixed open-weight models; the person still doesn't choose.
    static func ownKeyModelOrder(for job: TeachyAIJob, hasImages: Bool) -> [String] {
        if hasImages || job == .coach || job == .quickCheck || job == .voice {
            return ["qwen/qwen3-vl-30b-a3b-instruct", "google/gemini-2.5-flash"]
        }
        return ["deepseek/deepseek-v4-flash", "qwen/qwen3-vl-30b-a3b-instruct"]
    }

    static func routes(for job: TeachyAIJob, hasImages: Bool) throws -> [TeachyAIRoute] {
        guard !TeachyPublikSession.shared.isSwitchingAccount else { throw TeachyAINotReadyError() }
        let hasEnvironmentKey = !(ProcessInfo.processInfo.environment["PUBLIK_API_KEY"] ?? "").isEmpty
        guard hasEnvironmentKey || Publik.readCredential()?.choice != nil else { throw TeachyAINotReadyError() }
        let ownKey = TeachyAPIKeyStore.apiKey.flatMap { $0.isEmpty ? nil : (baseURL: openRouterBaseURL, apiKey: $0) }
        switch Publik.resolveProvider(userKey: ownKey) {
        case let .publik(baseURL, apiKey):
            var tiers = publikTierOrder(for: job)
            if hasImages {
                let visionTiers = tiers.filter { !TeachyTierVisionMemory.isKnownTextOnly($0) }
                if !visionTiers.isEmpty { tiers = visionTiers }
            }
            return tiers.map { route(baseURL: baseURL, apiKey: apiKey, model: $0, isPublik: true) }
        case let .own(baseURL, apiKey):
            return ownKeyModelOrder(for: job, hasImages: hasImages)
                .map { route(baseURL: baseURL, apiKey: apiKey, model: $0, isPublik: false) }
        case .needsOwnKey:
            throw TeachyAINotReadyError()
        }
    }

    private static func route(baseURL: String, apiKey: String, model: String, isPublik: Bool) -> TeachyAIRoute {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return TeachyAIRoute(
            url: URL(string: "\(trimmedBase)/chat/completions")!,
            baseURL: trimmedBase,
            apiKey: apiKey,
            model: model,
            isPublik: isPublik
        )
    }

    static var isReadyForAI: Bool {
        (try? routes(for: .coach, hasImages: false))?.isEmpty == false
    }

    static var isUsingPublik: Bool {
        (try? routes(for: .coach, hasImages: false))?.first?.isPublik ?? false
    }

    // MARK: - Requests

    /// How hard a publik tier should think before answering. Measured 14 Nov 2026 on the
    /// smart tier with a screenshot: default effort gave first words at about 4.3 s,
    /// "minimal" at about 1.4 s, with answers just as specific. Planning keeps the default.
    static func reasoningEffort(for job: TeachyAIJob) -> String? {
        switch job {
        case .voice, .coach, .quickCheck, .cleanup: return "minimal"
        case .agent, .scene, .write: return "low"
        case .plan: return nil
        }
    }

    static func makeRequest(for route: TeachyAIRoute, job: TeachyAIJob? = nil, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        try validateCurrentAccount(for: route)
        var request = URLRequest(url: route.url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        if !route.isPublik {
            request.setValue("https://teachy.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Teachy", forHTTPHeaderField: "X-Title")
        }
        var routedBody = body
        routedBody["model"] = route.model
        // Some publik tiers are reasoning models (publik-balanced spent ~470 tokens
        // thinking on a one-line screen question). Give them room so the answer isn't
        // cut off before it starts; billing is per token used, not per cap.
        if route.isPublik {
            let requestedMaxTokens = routedBody["max_tokens"] as? Int ?? 0
            routedBody["max_tokens"] = max(requestedMaxTokens, minimumPublikMaxTokens)
        }
        // OpenRouter-only extension; publik rejects unknown routing fields on some tiers.
        if route.isPublik {
            routedBody.removeValue(forKey: "reasoning")
            if routedBody["reasoning_effort"] == nil, let job, let effort = reasoningEffort(for: job) {
                routedBody["reasoning_effort"] = effort
            }
        }
        let bodyData = try JSONSerialization.data(withJSONObject: routedBody)
        if route.isPublik && bodyData.count > maximumRequestBodyBytes {
            throw NSError(
                domain: "TeachyAIRouter",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "That request is too big to send (\(bodyData.count / 1024) KB). Try again with one screen."]
            )
        }
        request.httpBody = bodyData
        return request
    }

    private static func validateCurrentAccount(for route: TeachyAIRoute) throws {
        let currentRoutes = try routes(for: .coach, hasImages: false)
        guard currentRoutes.contains(where: {
            $0.apiKey == route.apiKey && $0.baseURL == route.baseURL && $0.isPublik == route.isPublik
        }) else { throw CancellationError() }
    }

    /// Non-streaming call. Returns the response body of the first tier that answers.
    static func sendJSON(
        job: TeachyAIJob,
        hasImages: Bool,
        timeout: TimeInterval = 120,
        session: URLSession = .shared,
        body: [String: Any]
    ) async throws -> Data {
        var lastError: Error = TeachyAINotReadyError()
        for route in try routes(for: job, hasImages: hasImages) {
            try Task.checkCancellation()
            let request = try makeRequest(for: route, job: job, body: body, timeout: timeout)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code != .cancelled {
                lastError = error
                continue
            }
            try validateCurrentAccount(for: route)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch try classify(status: status, body: data, route: route, hasImages: hasImages) {
            case .ok:
                if answerWasCutOffBeforeAnyText(data) {
                    print("⚠️ TeachyAI: \(route.model) ran out of tokens before answering; trying the next tier")
                    lastError = NSError(domain: "TeachyAI", code: -2, userInfo: [NSLocalizedDescriptionKey: "The AI ran out of room before answering."])
                    continue
                }
                recordSuccess(route: route, job: job, response: response)
                return data
            case .tryNextTier(let error):
                lastError = error
            }
        }
        throw lastError
    }

    /// Streaming (SSE) call. Returns the byte stream of the first tier that answers 2xx.
    static func openStream(
        job: TeachyAIJob,
        hasImages: Bool,
        timeout: TimeInterval = 120,
        session: URLSession,
        body: [String: Any]
    ) async throws -> URLSession.AsyncBytes {
        var lastError: Error = TeachyAINotReadyError()
        for route in try routes(for: job, hasImages: hasImages) {
            try Task.checkCancellation()
            let request = try makeRequest(for: route, job: job, body: body, timeout: timeout)
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let error as URLError where error.code != .cancelled {
                lastError = error
                continue
            }
            try validateCurrentAccount(for: route)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(status) {
                recordSuccess(route: route, job: job, response: response)
                return bytes
            }
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 64_000 { break }
            }
            switch try classify(status: status, body: errorData, route: route, hasImages: hasImages) {
            case .ok:
                return bytes
            case .tryNextTier(let error):
                lastError = error
            }
        }
        throw lastError
    }

    /// A 200 whose message has no text because the model hit max_tokens while reasoning.
    private static func answerWasCutOffBeforeAnyText(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else { return false }
        if message["tool_calls"] != nil { return false }
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty && (choice["finish_reason"] as? String) == "length"
    }

    // MARK: - Error handling

    private enum Outcome {
        case ok
        case tryNextTier(Error)
    }

    private static func classify(status: Int, body: Data, route: TeachyAIRoute, hasImages: Bool) throws -> Outcome {
        if (200...299).contains(status) { return .ok }

        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let errorObject = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
        let errorType = errorObject?["type"] as? String ?? ""
        let message = errorObject?["message"] as? String ?? bodyText

        print("⚠️ TeachyAI: \(route.model) answered \(status) \(errorType) \(message.prefix(300))")

        if status == 402 && route.isPublik {
            let billing = Publik.topUpURLFrom402(body)
            let error = TeachyAIBillingError(message: billing.message, topUpURL: billing.url)
            Task { @MainActor in TeachyPublikSession.shared.reportBilling(error) }
            throw error
        }

        let lowercasedMessage = message.lowercased()
        let mentionsImages = ["image", "vision", "multimodal", "multi-modal", "image_url"].contains { lowercasedMessage.contains($0) }
        if hasImages && mentionsImages && (status == 400 || status == 422 || status == 502) {
            TeachyTierVisionMemory.markTextOnly(route.model)
        }

        let failure = NSError(
            domain: "TeachyAI",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: "AI error (\(status)): \(message.prefix(400))"]
        )

        if status == 401 && route.isPublik {
            // The install key was revoked; the gate provisions a new one on the next pass.
            Task { @MainActor in TeachyPublikSession.shared.restartGate() }
            throw failure
        }

        let retriable: Set<Int> = [400, 403, 404, 408, 409, 422, 425, 429, 500, 502, 503, 504, 529]
        if retriable.contains(status) {
            return .tryNextTier(failure)
        }
        throw failure
    }

    private static func recordSuccess(route: TeachyAIRoute, job: TeachyAIJob, response: URLResponse) {
        if let http = response as? HTTPURLResponse {
            let publikHeaders = http.allHeaderFields
                .compactMap { key, value -> String? in
                    guard let name = key as? String, name.lowercased().hasPrefix("x-publik-") else { return nil }
                    return "\(name.lowercased())=\(value)"
                }
                .sorted()
            if !publikHeaders.isEmpty {
                print("🧭 TeachyAI \(job.rawValue) → \(route.model): \(publikHeaders.joined(separator: " "))")
            }
        }
        TeachyHubBeacon.send(event: "ai_call", usingPublik: route.isPublik)
    }
}

// MARK: - Vision memory

/// Remembers, for a few days, which publik tiers said they can't read images.
/// A tier's backing model can change on publik's side, so this expires.
enum TeachyTierVisionMemory {
    private static let defaultsKey = "teachyPublikTextOnlyTiers"
    private static let lifetime: TimeInterval = 3 * 24 * 3600

    static func isKnownTextOnly(_ tier: String) -> Bool {
        guard let markedAt = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double])?[tier] else {
            return false
        }
        return Date().timeIntervalSince1970 - markedAt < lifetime
    }

    static func markTextOnly(_ tier: String) {
        var marks = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
        marks[tier] = Date().timeIntervalSince1970
        UserDefaults.standard.set(marks, forKey: defaultsKey)
        print("🧭 TeachyAI: \(tier) can't read images; screenshots go to another tier for now")
    }
}

// MARK: - Builds hub beacon

/// Tells the vedanttalksai builds hub that a person is using Teachy, so the hub
/// can split publik's one-listing numbers by build. Anonymous: build slug, event,
/// AI mode and a random id. No content, no account. Fire-and-forget.
enum TeachyHubBeacon {
    private static let endpoint = URL(string: "https://builds.vedantsoni.com/api/beacon")!
    private static let installIDKey = "teachyHubBeaconInstallID"

    private static var isOff: Bool {
        let environment = ProcessInfo.processInfo.environment
        let doNotTrack = (environment["DO_NOT_TRACK"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if !["", "0", "false"].contains(doNotTrack) { return true }
        return ["0", "false", "off"].contains((environment["STUDIO_BEACON"] ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static var installID: String {
        if let saved = UserDefaults.standard.string(forKey: installIDKey), UUID(uuidString: saved) != nil {
            return saved
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: installIDKey)
        return fresh
    }

    static func send(event: String, usingPublik: Bool) {
        guard !isOff else { return }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? Publik.appVersion
        let body: [String: Any] = [
            "v": 1,
            "build": "teachy",
            "event": event,
            "mode": usingPublik ? "publik" : NSNull(),
            "install": installID,
            "publik": usingPublik,
            "app_version": appVersion,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData
        Task.detached(priority: .background) {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
