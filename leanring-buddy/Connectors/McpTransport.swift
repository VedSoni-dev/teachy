//
//  McpTransport.swift
//  leanring-buddy
//
//  What an MCP transport has to do, the errors the connector code raises, and
//  how credentials reach the HTTP transport.
//

import Foundation

/// Carries whole JSON-RPC frames. `start` returns the stream of incoming frames;
/// the stream ending (or throwing) means the connection is gone.
nonisolated protocol McpTransport: Sendable {
    func start() async throws -> AsyncThrowingStream<Data, Error>
    func send(_ frame: Data) async throws
    /// Called once `initialize` succeeded, with the version both sides agreed on.
    func sessionDidInitialize(protocolVersion: String) async
    func close() async
    /// Recent diagnostic output (a local server's stderr), for error messages. Never secrets we hold.
    func diagnostics() async -> String
}

nonisolated enum McpError: Error, Sendable, Equatable, LocalizedError {
    /// HTTP 401/403. `hadCredentials` separates "you need to sign in" from "your token was rejected".
    case unauthorized(hadCredentials: Bool, wwwAuthenticate: String?)
    /// OAuth is configured but there is no usable token; the person has to sign in.
    case needsSignIn
    case sessionExpired
    case httpStatus(code: Int, body: String)
    case commandNotFound(String)
    case processExited(code: Int32, stderrTail: String)
    case launchFailed(String)
    case unsupportedProtocolVersion(String)
    case invalidResponse(String)
    case notConnected
    case invalidConfiguration(String)
    case oauth(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let hadCredentials, _):
            return hadCredentials ? "The server rejected the token." : "The server needs you to sign in."
        case .needsSignIn:
            return "Sign in to use this connector."
        case .sessionExpired:
            return "The server ended the session."
        case .httpStatus(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The server answered HTTP \(code)." : "The server answered HTTP \(code): \(detail)"
        case .commandNotFound(let command):
            return "Couldn't find \"\(command)\" on this Mac. Check it is installed and on your PATH."
        case .processExited(let code, let stderrTail):
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The local server quit (exit code \(code))." : "The local server quit (exit code \(code)): \(detail)"
        case .launchFailed(let message):
            return "Couldn't start the local server: \(message)"
        case .unsupportedProtocolVersion(let version):
            return "The server speaks MCP \(version), which Teachy doesn't support."
        case .invalidResponse(let message):
            return "The server sent something unexpected: \(message)"
        case .notConnected:
            return "This connector isn't connected."
        case .invalidConfiguration(let message):
            return message
        case .oauth(let message):
            return message
        }
    }
}

/// Supplies credentials for HTTP requests and reacts to a 401.
nonisolated protocol McpAuthProvider: Sendable {
    /// Headers to add to every request. Throwing `McpError.needsSignIn` is fine.
    func authorizationHeaders() async throws -> [String: String]
    /// Called on HTTP 401. Return true when credentials were renewed and the request is worth one retry.
    func handleUnauthorized(wwwAuthenticate: String?) async -> Bool
    func hasCredentials() async -> Bool
}

/// A fixed header from the Keychain: `Authorization: Bearer …` or an API-key header.
nonisolated struct McpStaticHeaderAuth: McpAuthProvider {
    let headers: [String: String]

    func authorizationHeaders() async throws -> [String: String] { headers }
    func handleUnauthorized(wwwAuthenticate: String?) async -> Bool { false }
    func hasCredentials() async -> Bool { !headers.isEmpty }
}

/// Keeps the last N bytes of a stream of text (a local server's stderr).
nonisolated final class McpRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage = Data()
    private let lock = NSLock()

    init(capacity: Int = 16_384) {
        self.capacity = max(1, capacity)
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
        if storage.count > capacity {
            storage = Data(storage.suffix(capacity))
        }
    }

    func text(lastLines: Int? = nil) -> String {
        lock.lock(); let snapshot = storage; lock.unlock()
        let text = String(decoding: snapshot, as: UTF8.self)
        guard let lastLines else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(lastLines).joined(separator: "\n")
    }
}
