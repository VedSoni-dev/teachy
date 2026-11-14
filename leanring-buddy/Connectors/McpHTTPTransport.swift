//
//  McpHTTPTransport.swift
//  leanring-buddy
//
//  Remote MCP servers.
//
//  Streamable HTTP (current spec): every message is a POST to one endpoint. The
//  answer is either a JSON body or an SSE stream carrying the response (and any
//  notifications). The server may hand out an `Mcp-Session-Id` to send back, and
//  may offer a GET stream for messages it starts itself.
//
//  HTTP+SSE (the 2024-11-05 transport): if the first POST is refused with
//  400/404/405, open GET <url> as an SSE stream, wait for its `endpoint` event,
//  and POST messages there; answers arrive on the stream.
//

import Foundation

/// Refuses redirects that leave the server's origin, so an API-key header can
/// never be forwarded to a host the person didn't add.
nonisolated final class McpSameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func isSameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && port(first) == port(second)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.isSameOrigin(task.originalRequest?.url, request.url) ? request : nil)
    }
}

actor McpHTTPTransport: McpTransport {
    private enum Mode {
        case undetermined
        case streamable
        case legacySSE(postURL: URL)
    }

    private let url: URL
    private let staticHeaders: [String: String]
    private let staticHeadersCarryCredentials: Bool
    private let auth: (any McpAuthProvider)?
    private let urlSession: URLSession
    private let redirectGuard = McpSameOriginRedirectGuard()

    private var mode: Mode = .undetermined
    private var sessionID: String?
    private var protocolVersion: String?
    private var incoming: AsyncThrowingStream<Data, Error>.Continuation?
    private var streamTasks: [Task<Void, Never>] = []
    private var isClosed = false

    static let maximumBodyBytes = 20 * 1024 * 1024

    init(
        url: URL,
        staticHeaders: [String: String] = [:],
        staticHeadersCarryCredentials: Bool = false,
        auth: (any McpAuthProvider)? = nil,
        urlSession: URLSession? = nil
    ) {
        self.url = url
        self.staticHeaders = staticHeaders
        self.staticHeadersCarryCredentials = staticHeadersCarryCredentials
        self.auth = auth
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 300
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    /// Which transport the server turned out to speak ("streamable-http", "sse", or "unknown").
    var negotiatedTransportName: String {
        switch mode {
        case .undetermined: return "unknown"
        case .streamable: return "streamable-http"
        case .legacySSE: return "sse"
        }
    }

    // MARK: McpTransport

    func start() async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        incoming = continuation
        return stream
    }

    func send(_ frame: Data) async throws {
        guard !isClosed, incoming != nil else { throw McpError.notConnected }
        if case .legacySSE(let postURL) = mode {
            try await postLegacy(frame, to: postURL, allowAuthRetry: true)
        } else {
            try await postStreamable(frame, allowAuthRetry: true)
        }
    }

    func sessionDidInitialize(protocolVersion: String) async {
        self.protocolVersion = protocolVersion
        if case .streamable = mode { startServerStream() }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        incoming?.finish()
        incoming = nil
        for task in streamTasks { task.cancel() }
        streamTasks.removeAll()

        // Tell a streamable server the session is over. Best effort, never awaited.
        if case .streamable = mode, let sessionID {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            let headers = staticHeaders
            let authProvider = auth
            let session = urlSession
            Task.detached {
                var finalRequest = request
                for (name, value) in headers { finalRequest.setValue(value, forHTTPHeaderField: name) }
                if let authHeaders = try? await authProvider?.authorizationHeaders() {
                    for (name, value) in authHeaders { finalRequest.setValue(value, forHTTPHeaderField: name) }
                }
                _ = try? await session.data(for: finalRequest)
            }
        }
    }

    func diagnostics() async -> String { "" }

    // MARK: Requests

    private func makeRequest(method: String, url requestURL: URL, timeout: TimeInterval) async throws -> URLRequest {
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in staticHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let auth {
            for (name, value) in try await auth.authorizationHeaders() {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        return request
    }

    /// Returns true when the request should be retried with renewed credentials; throws when access is refused.
    private func shouldRetryAfterAuthFailure(_ response: HTTPURLResponse, allowAuthRetry: Bool) async throws -> Bool {
        let status = response.statusCode
        guard status == 401 || status == 403 else { return false }
        let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")
        if status == 401, allowAuthRetry, let auth, await auth.handleUnauthorized(wwwAuthenticate: challenge) {
            return true
        }
        var hadCredentials = staticHeadersCarryCredentials
        if let auth, await auth.hasCredentials() { hadCredentials = true }
        if status == 403 && !hadCredentials { return false } // a plain "forbidden", reported as an HTTP error
        throw McpError.unauthorized(hadCredentials: hadCredentials, wwwAuthenticate: challenge)
    }

    private func postStreamable(_ frame: Data, allowAuthRetry: Bool) async throws {
        var request = try await makeRequest(method: "POST", url: url, timeout: 300)
        request.httpBody = frame
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await urlSession.bytes(for: request, delegate: redirectGuard)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw McpError.invalidResponse("not an HTTP response")
        }
        let status = httpResponse.statusCode

        if try await shouldRetryAfterAuthFailure(httpResponse, allowAuthRetry: allowAuthRetry) {
            bytes.task.cancel()
            return try await postStreamable(frame, allowAuthRetry: false)
        }
        if status == 404, sessionID != nil {
            bytes.task.cancel()
            sessionID = nil
            throw McpError.sessionExpired
        }
        if case .undetermined = mode, [400, 404, 405].contains(status) {
            let originalBody = await Self.collectText(from: bytes, limit: 2_000)
            do {
                let postURL = try await openLegacyStream(allowAuthRetry: true)
                mode = .legacySSE(postURL: postURL)
            } catch let error as McpError {
                if case .unauthorized = error { throw error }
                throw McpError.httpStatus(code: status, body: originalBody)
            } catch {
                throw McpError.httpStatus(code: status, body: originalBody)
            }
            guard case .legacySSE(let postURL) = mode else { return }
            return try await postLegacy(frame, to: postURL, allowAuthRetry: true)
        }
        guard (200..<300).contains(status) else {
            throw McpError.httpStatus(code: status, body: await Self.collectText(from: bytes, limit: 2_000))
        }

        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSessionID.isEmpty {
            sessionID = newSessionID
        }
        mode = .streamable

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard let continuation = incoming else { bytes.task.cancel(); return }

        if contentType.contains("text/event-stream") {
            // The response (and anything the server sends before it) arrives as events; don't block the caller.
            let task = Task<Void, Never>.detached {
                do {
                    try await Self.readEvents(from: bytes) { event in
                        if event.event == "message", !event.data.isEmpty {
                            continuation.yield(Data(event.data.utf8))
                        }
                    }
                } catch {
                    // The stream broke mid-answer; the waiting request times out on its own.
                }
            }
            track(task)
            return
        }

        if status == 202 { bytes.task.cancel(); return }
        let body = try await Self.collectBody(from: bytes, expectedLength: httpResponse.expectedContentLength)
        if body.contains(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) {
            continuation.yield(body)
        }
    }

    private func postLegacy(_ frame: Data, to postURL: URL, allowAuthRetry: Bool) async throws {
        var request = try await makeRequest(method: "POST", url: postURL, timeout: 60)
        request.httpBody = frame
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await urlSession.data(for: request, delegate: redirectGuard)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw McpError.invalidResponse("not an HTTP response")
        }
        if try await shouldRetryAfterAuthFailure(httpResponse, allowAuthRetry: allowAuthRetry) {
            return try await postLegacy(frame, to: postURL, allowAuthRetry: false)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw McpError.httpStatus(code: httpResponse.statusCode, body: String(decoding: body.prefix(2_000), as: UTF8.self))
        }
        // Answers normally come on the stream, but a few servers reply inline.
        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("application/json"), let firstByte = body.first(where: { $0 > 0x20 }),
           firstByte == UInt8(ascii: "{") || firstByte == UInt8(ascii: "[") {
            incoming?.yield(body)
        }
    }

    // MARK: Legacy HTTP+SSE

    private func openLegacyStream(allowAuthRetry: Bool) async throws -> URL {
        var request = try await makeRequest(method: "GET", url: url, timeout: 60 * 60 * 24)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await urlSession.bytes(for: request, delegate: redirectGuard)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw McpError.invalidResponse("not an HTTP response")
        }
        if try await shouldRetryAfterAuthFailure(httpResponse, allowAuthRetry: allowAuthRetry) {
            bytes.task.cancel()
            return try await openLegacyStream(allowAuthRetry: false)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw McpError.httpStatus(
                code: httpResponse.statusCode,
                body: await Self.collectText(from: bytes, limit: 2_000)
            )
        }
        guard let continuation = incoming else { throw McpError.notConnected }
        let baseURL = url

        return try await withCheckedThrowingContinuation { (endpointContinuation: CheckedContinuation<URL, Error>) in
            let endpointAnnounced = McpOnceFlag()
            let task = Task.detached {
                do {
                    try await Self.readEvents(from: bytes) { event in
                        if event.event == "endpoint" {
                            guard endpointAnnounced.claim() else { return }
                            let announced = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                            // The endpoint must stay on the server the person added.
                            if let postURL = URL(string: announced, relativeTo: baseURL)?.absoluteURL,
                               McpSameOriginRedirectGuard.isSameOrigin(postURL, baseURL) {
                                endpointContinuation.resume(returning: postURL)
                            } else {
                                endpointContinuation.resume(throwing: McpError.invalidResponse("the server announced an endpoint on another host"))
                            }
                        } else if event.event == "message", !event.data.isEmpty {
                            continuation.yield(Data(event.data.utf8))
                        }
                    }
                    if endpointAnnounced.claim() {
                        endpointContinuation.resume(throwing: McpError.invalidResponse("the stream ended before the server announced its endpoint"))
                    } else {
                        continuation.finish(throwing: JSONRPCPeerError.closed(reason: "The server closed the connection."))
                    }
                } catch {
                    if endpointAnnounced.claim() {
                        endpointContinuation.resume(throwing: error)
                    } else {
                        continuation.finish(throwing: JSONRPCPeerError.closed(reason: "The connection to the server dropped."))
                    }
                }
            }
            track(task)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if endpointAnnounced.claim() {
                    task.cancel()
                    endpointContinuation.resume(throwing: McpError.invalidResponse("the server never announced its endpoint"))
                }
            }
        }
    }

    // MARK: Optional server-initiated stream (streamable HTTP)

    /// Lets the server push `notifications/tools/list_changed` and the like. Servers that
    /// don't offer it answer 405, which is fine — we just stop.
    private func startServerStream() {
        guard let continuation = incoming else { return }
        let task = Task.detached { [weak self] in
            var consecutiveFailures = 0
            var lastEventID: String?
            while !Task.isCancelled, consecutiveFailures < 3 {
                guard let self else { return }
                guard var request = try? await self.makeRequest(method: "GET", url: self.url, timeout: 60 * 60 * 24) else { return }
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }

                var retryDelayMilliseconds = 2_000
                do {
                    let (bytes, response) = try await self.urlSession.bytes(for: request, delegate: self.redirectGuard)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode),
                          (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream") else {
                        bytes.task.cancel()
                        return // not offered
                    }
                    try await Self.readEvents(from: bytes) { event in
                        if let id = event.id { lastEventID = id }
                        if let retry = event.retryMilliseconds { retryDelayMilliseconds = min(max(retry, 250), 60_000) }
                        if event.event == "message", !event.data.isEmpty {
                            continuation.yield(Data(event.data.utf8))
                        }
                    }
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                }
                try? await Task.sleep(nanoseconds: UInt64(retryDelayMilliseconds) * 1_000_000)
            }
        }
        track(task)
    }

    private func track(_ task: Task<Void, Never>) {
        if isClosed { task.cancel(); return }
        streamTasks.append(task)
    }

    // MARK: Byte helpers

    /// Reads an SSE response to its end, calling `onEvent` for each event.
    /// (`AsyncBytes.lines` can't be used: it swallows the blank lines that end an event.)
    nonisolated static func readEvents(
        from bytes: URLSession.AsyncBytes,
        onEvent: (SSEEvent) -> Void
    ) async throws {
        var parser = SSEParser()
        var chunk = Data()
        for try await byte in bytes {
            chunk.append(byte)
            if byte == 0x0A || byte == 0x0D {
                for event in parser.feed(chunk) { onEvent(event) }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            for event in parser.feed(chunk) { onEvent(event) }
        }
    }

    nonisolated static func collectBody(from bytes: URLSession.AsyncBytes, expectedLength: Int64) async throws -> Data {
        var body = Data()
        if expectedLength > 0 { body.reserveCapacity(Int(min(expectedLength, Int64(maximumBodyBytes)))) }
        for try await byte in bytes {
            body.append(byte)
            if body.count > maximumBodyBytes {
                bytes.task.cancel()
                throw McpError.invalidResponse("the response was larger than 20 MB")
            }
        }
        return body
    }

    nonisolated static func collectText(from bytes: URLSession.AsyncBytes, limit: Int) async -> String {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { bytes.task.cancel(); break }
            }
        } catch {}
        return String(decoding: body, as: UTF8.self)
    }
}
