//
//  McpOAuth.swift
//  leanring-buddy
//
//  "Sign in through your browser" for remote MCP servers (OAuth 2.1, as the MCP
//  authorization spec lays it out):
//
//    1. Find the authorization server: the 401's `WWW-Authenticate` points at
//       protected-resource metadata (RFC 9728), which names the issuer; the
//       issuer's metadata (RFC 8414 / OpenID) names its endpoints.
//    2. Register Teachy as a public client when the server offers dynamic
//       registration (RFC 7591).
//    3. Authorization-code flow with PKCE (S256) in the default browser. The
//       redirect lands on a listener bound to 127.0.0.1 on a random port.
//    4. Tokens (and the client registration) are stored in the Keychain as one
//       JSON blob. Access tokens are refreshed before they expire and on a 401.
//
//  Not supported: servers that offer neither dynamic registration nor accept an
//  unregistered client (they need a client id typed in by hand), and Client ID
//  Metadata Documents.
//

import CryptoKit
import Foundation

// MARK: - Stored state

nonisolated struct McpOAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
}

nonisolated struct McpOAuthClientRegistration: Codable, Sendable, Equatable {
    var issuer: String
    var clientID: String
    var clientSecret: String?
    var redirectPort: Int
    var authorizationEndpoint: String
    var tokenEndpoint: String
}

nonisolated struct McpOAuthStoredState: Codable, Sendable, Equatable {
    var registration: McpOAuthClientRegistration?
    var tokens: McpOAuthTokens?
}

// MARK: - Pure helpers

nonisolated enum McpPKCE {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomURLSafeString(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

nonisolated struct McpOAuthServerMetadata: Sendable, Equatable {
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var scope: String?
}

nonisolated enum McpOAuthDiscovery {
    /// `Bearer realm="x", resource_metadata="https://…", scope="a b"` → `[realm: x, resource_metadata: …, scope: a b]`
    static func parseChallenge(_ header: String?) -> [String: String] {
        guard let header else { return [:] }
        var parameters: [String: String] = [:]
        guard let pattern = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))"#) else { return [:] }
        let fullRange = NSRange(header.startIndex..., in: header)
        for match in pattern.matches(in: header, range: fullRange) {
            guard let nameRange = Range(match.range(at: 1), in: header) else { continue }
            let valueRange = Range(match.range(at: 2), in: header) ?? Range(match.range(at: 3), in: header)
            guard let valueRange else { continue }
            parameters[header[nameRange].lowercased()] = header[valueRange].replacingOccurrences(of: "\\\"", with: "\"")
        }
        return parameters
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(scheme)://\(hostPart):\($0)" } ?? "\(scheme)://\(hostPart)"
    }

    private static func trimmedPath(of url: URL) -> String {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Where a server's protected-resource metadata may live: path-specific first, then the root.
    static func protectedResourceMetadataURLs(for serverURL: URL) -> [URL] {
        guard let origin = origin(of: serverURL) else { return [] }
        let path = trimmedPath(of: serverURL)
        var candidates: [String] = []
        if !path.isEmpty { candidates.append("\(origin)/.well-known/oauth-protected-resource\(path)") }
        candidates.append("\(origin)/.well-known/oauth-protected-resource")
        return candidates.compactMap(URL.init(string:))
    }

    /// Where an issuer's metadata may live (RFC 8414 with path insertion, then OpenID Connect discovery).
    static func authorizationServerMetadataURLs(forIssuer issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        let path = trimmedPath(of: issuer)
        var candidates: [String] = []
        if path.isEmpty {
            candidates = [
                "\(origin)/.well-known/oauth-authorization-server",
                "\(origin)/.well-known/openid-configuration",
            ]
        } else {
            candidates = [
                "\(origin)/.well-known/oauth-authorization-server\(path)",
                "\(origin)/.well-known/openid-configuration\(path)",
                "\(origin)\(path)/.well-known/openid-configuration",
            ]
        }
        return candidates.compactMap(URL.init(string:))
    }

    /// The `resource` value sent with authorization and token requests (RFC 8707).
    static func canonicalResource(for serverURL: URL) -> String {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return serverURL.absoluteString }
        components.fragment = nil
        components.query = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var text = components.string ?? serverURL.absoluteString
        if components.path == "/" { text.removeLast() }
        return text
    }

    /// OAuth endpoints must be https, except on this machine.
    static func isAcceptableEndpoint(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (scheme == "http" && McpConnectorConfig.isLoopbackHost(url.host))
    }

    static func formEncode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedName)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func tokens(fromTokenResponse json: JSONValue, previous: McpOAuthTokens?, now: Date = Date()) -> McpOAuthTokens? {
        guard let accessToken = json["access_token"]?.stringValue, !accessToken.isEmpty else { return nil }
        var expiresAt: Date?
        if let seconds = json["expires_in"]?.intValue ?? json["expires_in"]?.stringValue.flatMap(Int.init), seconds > 0 {
            expiresAt = now.addingTimeInterval(TimeInterval(seconds))
        }
        return McpOAuthTokens(
            accessToken: accessToken,
            // Servers that don't rotate refresh tokens omit it on refresh; keep the one we have.
            refreshToken: json["refresh_token"]?.stringValue ?? previous?.refreshToken,
            expiresAt: expiresAt,
            scope: json["scope"]?.stringValue ?? previous?.scope
        )
    }
}

// MARK: - Loopback redirect listener

/// A one-shot HTTP listener on 127.0.0.1 that receives the browser's redirect.
nonisolated final class McpLoopbackRedirectListener: @unchecked Sendable {
    let port: Int
    private let socketDescriptor: Int32
    private let lock = NSLock()
    private var isCancelled = false

    static let callbackPath = "/callback"
    var redirectURI: String { "http://127.0.0.1:\(port)\(Self.callbackPath)" }

    /// Binds `preferredPort` when it is free (a registered redirect URI has to match exactly),
    /// otherwise any free port.
    init(preferredPort: Int? = nil) throws {
        var boundSocket: Int32 = -1
        for candidatePort in [preferredPort, 0].compactMap({ $0 }) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(candidatePort).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")) // loopback only, never the network
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0, listen(descriptor, 8) == 0 {
                boundSocket = descriptor
                break
            }
            Darwin.close(descriptor)
        }
        guard boundSocket >= 0 else { throw McpError.oauth("Couldn't open a local port for sign-in.") }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(boundSocket, $0, &length) }
        }
        guard nameResult == 0 else {
            Darwin.close(boundSocket)
            throw McpError.oauth("Couldn't open a local port for sign-in.")
        }
        socketDescriptor = boundSocket
        port = Int(in_port_t(bigEndian: boundAddress.sin_port))
    }

    deinit {
        Darwin.close(socketDescriptor)
    }

    func cancel() {
        lock.lock(); isCancelled = true; lock.unlock()
    }

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled
    }

    /// Waits for the browser to hit `/callback` and returns its query parameters.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.acceptUntilCallback(deadline: Date().addingTimeInterval(timeout)) })
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func acceptUntilCallback(deadline: Date) throws -> [String: String] {
        while true {
            if cancelled { throw CancellationError() }
            if Date() >= deadline { throw McpError.oauth("Sign-in timed out. Try again.") }

            var pollDescriptor = pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 200) > 0 else { continue }
            let client = accept(socketDescriptor, nil, nil)
            guard client >= 0 else { continue }
            defer { Darwin.close(client) }

            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

            var requestBytes = [UInt8]()
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            while requestBytes.count < 16_384 {
                let count = recv(client, &readBuffer, readBuffer.count, 0)
                if count <= 0 { break }
                requestBytes.append(contentsOf: readBuffer[0..<count])
                if requestBytes.count >= 4, String(decoding: requestBytes, as: UTF8.self).contains("\r\n\r\n") { break }
            }

            let requestLine = String(decoding: requestBytes, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let pieces = requestLine.split(separator: " ")
            guard pieces.count >= 2, pieces[0] == "GET",
                  let components = URLComponents(string: "http://127.0.0.1\(pieces[1])"),
                  components.path == Self.callbackPath else {
                Self.respond(to: client, status: "404 Not Found", body: "Not found")
                continue
            }

            var parameters: [String: String] = [:]
            for item in components.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
            let succeeded = parameters["code"] != nil && parameters["error"] == nil
            Self.respond(
                to: client,
                status: "200 OK",
                body: Self.page(
                    title: succeeded ? "You're signed in" : "Sign-in didn't finish",
                    message: succeeded ? "You can close this tab and go back to Teachy." : "Go back to Teachy and try again."
                )
            )
            return parameters
        }
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Teachy</title>
        <style>body{font:16px -apple-system,sans-serif;background:#12151A;color:#F5F5F7;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}div{text-align:center}p{color:#A1A1A6}</style>
        </head><body><div><h2>\(title)</h2><p>\(message)</p></div></body></html>
        """
    }

    private static func respond(to client: Int32, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let response = Data(head.utf8) + bodyData
        response.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}

// MARK: - Manager

actor McpOAuthManager: McpAuthProvider {
    typealias URLOpener = @Sendable (URL) -> Void

    private let serverURL: URL
    private let secretReference: String
    private let secrets: any McpSecretStore
    private let urlSession: URLSession
    private let clientName: String
    private let openURL: URLOpener
    private let signInTimeout: TimeInterval

    private var lastChallenge: String?
    private var refreshInFlight: Task<Bool, Never>?

    init(
        serverURL: URL,
        secretReference: String,
        secrets: any McpSecretStore,
        urlSession: URLSession? = nil,
        clientName: String = "Teachy",
        signInTimeout: TimeInterval = 300,
        openURL: @escaping URLOpener
    ) {
        self.serverURL = serverURL
        self.secretReference = secretReference
        self.secrets = secrets
        self.clientName = clientName
        self.signInTimeout = signInTimeout
        self.openURL = openURL
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    // MARK: Stored state

    private func loadState() -> McpOAuthStoredState {
        guard let text = secrets.secret(for: secretReference),
              let state = try? JSONDecoder().decode(McpOAuthStoredState.self, from: Data(text.utf8)) else {
            return McpOAuthStoredState()
        }
        return state
    }

    private func saveState(_ state: McpOAuthStoredState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? secrets.setSecret(String(decoding: data, as: UTF8.self), for: secretReference)
    }

    // MARK: McpAuthProvider

    func authorizationHeaders() async throws -> [String: String] {
        var state = loadState()
        guard let tokens = state.tokens else { throw McpError.needsSignIn }
        // Renew a minute early rather than let a tool call hit a 401.
        if let expiresAt = tokens.expiresAt, expiresAt.timeIntervalSinceNow < 60, tokens.refreshToken != nil {
            _ = await refresh()
            state = loadState()
        }
        guard let accessToken = state.tokens?.accessToken else { throw McpError.needsSignIn }
        return ["Authorization": "Bearer \(accessToken)"]
    }

    func handleUnauthorized(wwwAuthenticate: String?) async -> Bool {
        if let wwwAuthenticate { lastChallenge = wwwAuthenticate }
        return await refresh()
    }

    func hasCredentials() async -> Bool {
        loadState().tokens != nil
    }

    func signOut() {
        secrets.removeSecret(for: secretReference)
    }

    // MARK: Refresh

    /// Concurrent callers share one refresh request.
    func refresh() async -> Bool {
        if let refreshInFlight { return await refreshInFlight.value }
        let task = Task<Bool, Never> { await self.performRefresh() }
        refreshInFlight = task
        let succeeded = await task.value
        refreshInFlight = nil
        return succeeded
    }

    private func performRefresh() async -> Bool {
        var state = loadState()
        guard let tokens = state.tokens, let refreshToken = tokens.refreshToken,
              let registration = state.registration, let tokenEndpoint = URL(string: registration.tokenEndpoint) else {
            return false
        }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", registration.clientID),
            ("resource", McpOAuthDiscovery.canonicalResource(for: serverURL)),
        ]
        if let clientSecret = registration.clientSecret { fields.append(("client_secret", clientSecret)) }

        guard let (json, status) = try? await postForm(to: tokenEndpoint, fields: fields) else {
            return false // offline or similar: keep the tokens, the next attempt may work
        }
        if (200..<300).contains(status), let renewed = McpOAuthDiscovery.tokens(fromTokenResponse: json, previous: tokens) {
            state.tokens = renewed
            saveState(state)
            return true
        }
        if status == 400 || status == 401 {
            // The refresh token is spent or revoked; the person has to sign in again.
            state.tokens = nil
            saveState(state)
        }
        return false
    }

    // MARK: Sign-in

    /// The whole browser sign-in. Returns once tokens are stored, or throws with a sentence for the person.
    func signIn() async throws {
        if lastChallenge == nil { lastChallenge = await probeForChallenge() }
        let challenge = McpOAuthDiscovery.parseChallenge(lastChallenge)
        let metadata = try await discoverMetadata(challenge: challenge)

        var state = loadState()
        let previousPort = state.registration?.issuer == metadata.issuer ? state.registration?.redirectPort : nil
        let listener = try McpLoopbackRedirectListener(preferredPort: previousPort)

        let registration: McpOAuthClientRegistration
        if let saved = state.registration, saved.issuer == metadata.issuer, saved.redirectPort == listener.port {
            registration = McpOAuthClientRegistration(
                issuer: saved.issuer, clientID: saved.clientID, clientSecret: saved.clientSecret, redirectPort: saved.redirectPort,
                authorizationEndpoint: metadata.authorizationEndpoint.absoluteString, tokenEndpoint: metadata.tokenEndpoint.absoluteString
            )
        } else {
            registration = try await registerClient(metadata: metadata, redirectURI: listener.redirectURI, port: listener.port)
        }
        state.registration = registration
        saveState(state)

        let verifier = McpPKCE.randomURLSafeString(byteCount: 48)
        let expectedState = McpPKCE.randomURLSafeString(byteCount: 24)
        let resource = McpOAuthDiscovery.canonicalResource(for: serverURL)

        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw McpError.oauth("The server's sign-in address isn't valid.")
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID),
            URLQueryItem(name: "redirect_uri", value: listener.redirectURI),
            URLQueryItem(name: "code_challenge", value: McpPKCE.challenge(forVerifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "resource", value: resource),
        ])
        if let scope = metadata.scope, !scope.isEmpty { queryItems.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = queryItems
        guard let authorizationURL = components.url else { throw McpError.oauth("The server's sign-in address isn't valid.") }

        openURL(authorizationURL)
        let callback = try await listener.waitForCallback(timeout: signInTimeout)

        if let errorCode = callback["error"] {
            let detail = callback["error_description"] ?? errorCode
            throw McpError.oauth(errorCode == "access_denied" ? "Sign-in was cancelled." : "Sign-in failed: \(detail)")
        }
        // A mismatched state means this redirect didn't come from the sign-in we started.
        guard callback["state"] == expectedState, let code = callback["code"], !code.isEmpty else {
            throw McpError.oauth("Sign-in failed: the browser came back with an unexpected answer.")
        }

        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", listener.redirectURI),
            ("client_id", registration.clientID),
            ("code_verifier", verifier),
            ("resource", resource),
        ]
        if let clientSecret = registration.clientSecret { fields.append(("client_secret", clientSecret)) }
        let (tokenJSON, status) = try await postForm(to: metadata.tokenEndpoint, fields: fields)
        guard (200..<300).contains(status), let tokens = McpOAuthDiscovery.tokens(fromTokenResponse: tokenJSON, previous: nil) else {
            let detail = tokenJSON["error_description"]?.stringValue ?? tokenJSON["error"]?.stringValue ?? "HTTP \(status)"
            throw McpError.oauth("Sign-in failed while fetching the token: \(detail)")
        }
        state.tokens = tokens
        saveState(state)
    }

    // MARK: Discovery

    /// An unauthenticated request, only to read the server's `WWW-Authenticate` header.
    private func probeForChallenge() async -> String? {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await urlSession.bytes(for: request) else { return nil }
        bytes.task.cancel()
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
    }

    private func fetchJSON(_ url: URL) async -> JSONValue? {
        guard McpOAuthDiscovery.isAcceptableEndpoint(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(McpSessionOptions.supportedProtocolVersions[0], forHTTPHeaderField: "MCP-Protocol-Version")
        guard let (data, response) = try? await urlSession.data(for: request),
              let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode),
              let json = try? JSONValue.parse(data), case .object = json else { return nil }
        return json
    }

    private func discoverMetadata(challenge: [String: String]) async throws -> McpOAuthServerMetadata {
        // 1. Protected-resource metadata → which authorization server protects this MCP server.
        var resourceMetadataURLs: [URL] = []
        if let advertised = challenge["resource_metadata"], let url = URL(string: advertised) { resourceMetadataURLs.append(url) }
        resourceMetadataURLs.append(contentsOf: McpOAuthDiscovery.protectedResourceMetadataURLs(for: serverURL))

        var issuerURL: URL?
        var scope = challenge["scope"]
        for candidate in resourceMetadataURLs {
            guard let json = await fetchJSON(candidate) else { continue }
            if let firstServer = json["authorization_servers"]?.arrayValue?.first?.stringValue, let url = URL(string: firstServer) {
                issuerURL = url
            }
            if scope == nil, let supported = json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue), !supported.isEmpty {
                scope = supported.joined(separator: " ")
            }
            break
        }

        // Older servers are their own authorization server.
        let fallbackIssuer = URL(string: McpOAuthDiscovery.canonicalResource(for: serverURL))
            .flatMap { URL(string: "/", relativeTo: $0)?.absoluteURL } ?? serverURL
        let issuer = issuerURL ?? fallbackIssuer

        // 2. Authorization-server metadata → the endpoints.
        for candidate in McpOAuthDiscovery.authorizationServerMetadataURLs(forIssuer: issuer) {
            guard let json = await fetchJSON(candidate),
                  let authorizationEndpoint = json["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                  let tokenEndpoint = json["token_endpoint"]?.stringValue.flatMap(URL.init(string:)) else { continue }
            if let methods = json["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue), !methods.contains("S256") {
                throw McpError.oauth("This server's sign-in doesn't support PKCE, so Teachy won't use it.")
            }
            let registrationEndpoint = json["registration_endpoint"]?.stringValue.flatMap(URL.init(string:))
            guard McpOAuthDiscovery.isAcceptableEndpoint(authorizationEndpoint), McpOAuthDiscovery.isAcceptableEndpoint(tokenEndpoint),
                  registrationEndpoint.map(McpOAuthDiscovery.isAcceptableEndpoint) ?? true else {
                throw McpError.oauth("This server's sign-in isn't served over https, so Teachy won't use it.")
            }
            return McpOAuthServerMetadata(
                issuer: json["issuer"]?.stringValue ?? issuer.absoluteString,
                authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: registrationEndpoint,
                scope: scope
            )
        }

        // 3. No metadata anywhere: the 2025-03-26 spec's default endpoints on the server's own origin.
        guard McpOAuthDiscovery.isAcceptableEndpoint(issuer),
              let authorizationEndpoint = URL(string: "/authorize", relativeTo: issuer)?.absoluteURL,
              let tokenEndpoint = URL(string: "/token", relativeTo: issuer)?.absoluteURL else {
            throw McpError.oauth("Couldn't find how to sign in to this server.")
        }
        return McpOAuthServerMetadata(
            issuer: issuer.absoluteString,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: URL(string: "/register", relativeTo: issuer)?.absoluteURL,
            scope: scope
        )
    }

    private func registerClient(metadata: McpOAuthServerMetadata, redirectURI: String, port: Int) async throws -> McpOAuthClientRegistration {
        guard let registrationEndpoint = metadata.registrationEndpoint else {
            throw McpError.oauth("This server needs an app registered with it by hand, which Teachy can't do yet. Use an API key if it offers one.")
        }
        var request = URLRequest(url: registrationEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONValue.object([
            "client_name": .string(clientName),
            "redirect_uris": .array([.string(redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ]).serialized()

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode),
              let json = try? JSONValue.parse(data), let clientID = json["client_id"]?.stringValue, !clientID.isEmpty else {
            throw McpError.oauth("The server wouldn't register Teachy for sign-in.")
        }
        return McpOAuthClientRegistration(
            issuer: metadata.issuer,
            clientID: clientID,
            clientSecret: json["client_secret"]?.stringValue,
            redirectPort: port,
            authorizationEndpoint: metadata.authorizationEndpoint.absoluteString,
            tokenEndpoint: metadata.tokenEndpoint.absoluteString
        )
    }

    private func postForm(to url: URL, fields: [(String, String)]) async throws -> (JSONValue, Int) {
        guard McpOAuthDiscovery.isAcceptableEndpoint(url) else { throw McpError.oauth("The server's token address isn't https.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = McpOAuthDiscovery.formEncode(fields)
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ((try? JSONValue.parse(data)) ?? .object([:]), status)
    }
}
