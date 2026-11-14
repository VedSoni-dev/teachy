//
//  McpSession.swift
//  leanring-buddy
//
//  One live connection to one MCP server: the handshake, the tool list, tool
//  calls, and getting back up when a local server crashes.
//
//  Teachy is a tools-only client. It declares no client capabilities, so a
//  well-behaved server never asks it for sampling, roots or elicitation, and
//  resources/prompts are simply not requested.
//

import Foundation

nonisolated struct McpSessionOptions: Sendable {
    var clientName = "Teachy"
    var clientVersion = "1.0"
    var requestTimeout: TimeInterval = 30
    /// `initialize` gets longer: the first `npx -y some-server` has to download the package.
    var handshakeTimeout: TimeInterval = 90
    var toolCallTimeout: TimeInterval = 120
    /// Restarts after an unexpected disconnect before giving up.
    var maximumRestarts = 5
    var restartBackoffBase: TimeInterval = 1
    var restartBackoffCap: TimeInterval = 30
    /// A connection that lasted this long resets the restart counter.
    var stableAfter: TimeInterval = 60

    init() {}

    /// Newest first. We ask for the first and accept any of them back.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    func restartDelay(attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        return min(restartBackoffCap, restartBackoffBase * pow(2, exponent))
    }
}

nonisolated enum McpSessionEvent: Sendable {
    /// The server announced a new tool list (`notifications/tools/list_changed`).
    case toolsChanged([McpToolDescriptor])
    /// The connection dropped; a restart is scheduled.
    case restarting(attempt: Int, afterSeconds: TimeInterval, reason: String)
    case restarted([McpToolDescriptor])
    /// The connection dropped and won't be retried automatically.
    case stopped(reason: String, error: McpError?)
}

nonisolated struct McpServerInfo: Sendable, Equatable {
    var name: String
    var version: String
    var protocolVersion: String
    var instructions: String?
}

actor McpSession {
    typealias TransportFactory = @Sendable () async throws -> any McpTransport
    typealias EventHandler = @Sendable (McpSessionEvent) -> Void

    private let makeTransport: TransportFactory
    private let options: McpSessionOptions
    private let onEvent: EventHandler

    private var transport: (any McpTransport)?
    private var peer: JSONRPCPeer?
    private var readerTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// Bumped on every (re)connect and on close, so late callbacks from an old connection are ignored.
    private var generation = 0
    private var isReady = false
    private var wasClosedOnPurpose = false
    private var restartAttempts = 0
    private var connectedAt: Date?
    private var serverSupportsTools = true

    private(set) var tools: [McpToolDescriptor] = []
    private(set) var serverInfo: McpServerInfo?

    init(
        options: McpSessionOptions = McpSessionOptions(),
        makeTransport: @escaping TransportFactory,
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.options = options
        self.makeTransport = makeTransport
        self.onEvent = onEvent
    }

    var isConnected: Bool { isReady }

    // MARK: Connect

    /// Starts the transport, does the MCP handshake and loads the tool list.
    @discardableResult
    func connect() async throws -> [McpToolDescriptor] {
        await tearDownConnection()
        wasClosedOnPurpose = false
        generation += 1
        let connectionGeneration = generation

        let newTransport = try await makeTransport()
        let stream: AsyncThrowingStream<Data, Error>
        do {
            stream = try await newTransport.start()
        } catch {
            await newTransport.close()
            throw error
        }

        let newPeer = JSONRPCPeer(sender: { [newTransport] frame in try await newTransport.send(frame) })
        await newPeer.setNotificationHandler { [weak self] method, _ in
            await self?.handleNotification(method: method, generation: connectionGeneration)
        }
        transport = newTransport
        peer = newPeer
        readerTask = Task { [weak self] in
            var streamError: Error?
            do {
                for try await frame in stream { await newPeer.receive(frame) }
            } catch {
                streamError = error
            }
            await newPeer.close(error: streamError ?? JSONRPCPeerError.closed(reason: "The server closed the connection."))
            await self?.connectionEnded(generation: connectionGeneration, error: streamError)
        }

        do {
            let loadedTools = try await handshake(peer: newPeer, transport: newTransport)
            guard generation == connectionGeneration else { throw CancellationError() }
            tools = loadedTools
            isReady = true
            connectedAt = Date()
            return loadedTools
        } catch {
            // A local server that died during startup explains itself on stderr; prefer that story.
            let betterError = await explain(error, transport: newTransport)
            if generation == connectionGeneration { await tearDownConnection() }
            throw betterError
        }
    }

    private func handshake(peer: JSONRPCPeer, transport: any McpTransport) async throws -> [McpToolDescriptor] {
        let requestedVersion = McpSessionOptions.supportedProtocolVersions[0]
        let initializeResult = try await peer.request(
            "initialize",
            params: .object([
                "protocolVersion": .string(requestedVersion),
                // Empty on purpose: no roots, no sampling, no elicitation.
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(options.clientName),
                    "version": .string(options.clientVersion),
                ]),
            ]),
            timeout: max(options.handshakeTimeout, options.requestTimeout)
        )

        guard let agreedVersion = initializeResult["protocolVersion"]?.stringValue else {
            throw McpError.invalidResponse("initialize had no protocolVersion")
        }
        guard McpSessionOptions.supportedProtocolVersions.contains(agreedVersion) else {
            throw McpError.unsupportedProtocolVersion(agreedVersion)
        }
        serverInfo = McpServerInfo(
            name: initializeResult["serverInfo"]?["name"]?.stringValue ?? "",
            version: initializeResult["serverInfo"]?["version"]?.stringValue ?? "",
            protocolVersion: agreedVersion,
            instructions: initializeResult["instructions"]?.stringValue
        )
        serverSupportsTools = initializeResult["capabilities"]?["tools"] != nil

        await transport.sessionDidInitialize(protocolVersion: agreedVersion)
        try await peer.notify("notifications/initialized")
        return try await fetchTools(peer: peer)
    }

    private func fetchTools(peer: JSONRPCPeer) async throws -> [McpToolDescriptor] {
        guard serverSupportsTools else { return [] }
        var collected: [McpToolDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        // The page cap and the repeated-cursor check stop a broken server from looping us forever.
        for _ in 0..<100 {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await peer.request(
                "tools/list",
                params: params.isEmpty ? nil : .object(params),
                timeout: options.requestTimeout
            )
            for toolJSON in page["tools"]?.arrayValue ?? [] {
                if let descriptor = McpToolDescriptor(json: toolJSON) { collected.append(descriptor) }
            }
            guard let nextCursor = page["nextCursor"]?.stringValue, !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else { break }
            cursor = nextCursor
        }
        return collected
    }

    // MARK: Using the connection

    /// Runs a tool and returns the raw `tools/call` result (`content`, `isError`, …).
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval? = nil) async throws -> JSONValue {
        if !isReady, let restartTask {
            await restartTask.value // a restart is under way; wait for its verdict
        }
        do {
            return try await sendToolCall(name: name, arguments: arguments, timeout: timeout)
        } catch McpError.sessionExpired {
            // A remote server forgot our session. Start a fresh one and try once more.
            try await connect()
            onEvent(.restarted(tools))
            return try await sendToolCall(name: name, arguments: arguments, timeout: timeout)
        }
    }

    private func sendToolCall(name: String, arguments: JSONValue, timeout: TimeInterval?) async throws -> JSONValue {
        guard isReady, let peer else { throw McpError.notConnected }
        var normalisedArguments = arguments
        if case .object = arguments {} else { normalisedArguments = .object([:]) }
        return try await peer.request(
            "tools/call",
            params: .object(["name": .string(name), "arguments": normalisedArguments]),
            timeout: timeout ?? options.toolCallTimeout
        )
    }

    func ping(timeout: TimeInterval = 10) async throws {
        guard isReady, let peer else { throw McpError.notConnected }
        _ = try await peer.request("ping", timeout: timeout)
    }

    @discardableResult
    func refreshTools() async throws -> [McpToolDescriptor] {
        guard isReady, let peer else { throw McpError.notConnected }
        let refreshed = try await fetchTools(peer: peer)
        tools = refreshed
        return refreshed
    }

    /// A person-requested reconnect: forget any pending restart and its backoff, then connect.
    @discardableResult
    func reconnect() async throws -> [McpToolDescriptor] {
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        return try await connect()
    }

    func close() async {
        wasClosedOnPurpose = true
        restartTask?.cancel()
        restartTask = nil
        await tearDownConnection()
    }

    func diagnostics() async -> String {
        await transport?.diagnostics() ?? ""
    }

    // MARK: Internals

    private func tearDownConnection() async {
        generation += 1
        isReady = false
        let oldTransport = transport
        let oldPeer = peer
        transport = nil
        peer = nil
        readerTask = nil
        await oldPeer?.close(error: JSONRPCPeerError.closed(reason: "The connector was disconnected."))
        await oldTransport?.close()
    }

    private func explain(_ error: Error, transport: any McpTransport) async -> Error {
        if error is McpError { return error }
        if error is JSONRPCErrorObject { return error }
        if case JSONRPCPeerError.timedOut = error {
            let stderrTail = await transport.diagnostics()
            if !stderrTail.isEmpty {
                return McpError.invalidResponse("no answer to the MCP handshake. The server said: \(stderrTail)")
            }
        }
        return error
    }

    private func handleNotification(method: String, generation notificationGeneration: Int) async {
        guard notificationGeneration == generation, method == "notifications/tools/list_changed" else { return }
        guard let refreshed = try? await refreshTools(), notificationGeneration == generation else { return }
        onEvent(.toolsChanged(refreshed))
    }

    /// The incoming stream ended. If nobody asked for that, bring the server back with backoff.
    private func connectionEnded(generation endedGeneration: Int, error: Error?) async {
        guard endedGeneration == generation, !wasClosedOnPurpose else { return }
        let wasReady = isReady
        let reason = (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription ?? "The server closed the connection."
        await tearDownConnection()
        // A connection that never became ready is `connect()`'s failure to report, not ours to retry.
        guard wasReady else { return }

        if let connectedAt, Date().timeIntervalSince(connectedAt) >= options.stableAfter {
            restartAttempts = 0
        }
        scheduleRestart(reason: reason, lastError: error as? McpError)
    }

    private func scheduleRestart(reason: String, lastError: McpError?) {
        guard !wasClosedOnPurpose else { return }
        restartAttempts += 1
        guard restartAttempts <= options.maximumRestarts else {
            onEvent(.stopped(reason: reason, error: lastError))
            return
        }
        let attempt = restartAttempts
        let delay = options.restartDelay(attempt: attempt)
        onEvent(.restarting(attempt: attempt, afterSeconds: delay, reason: reason))

        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performRestart()
        }
    }

    private func performRestart() async {
        guard !wasClosedOnPurpose else { return }
        do {
            let restartedTools = try await connect()
            restartTask = nil
            onEvent(.restarted(restartedTools))
        } catch {
            guard !wasClosedOnPurpose else { return }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Signing in or fixing a token is the person's job; retrying won't help.
            if let mcpError = error as? McpError {
                switch mcpError {
                case .unauthorized, .needsSignIn, .commandNotFound, .unsupportedProtocolVersion:
                    restartTask = nil
                    onEvent(.stopped(reason: reason, error: mcpError))
                    return
                default:
                    break
                }
            }
            scheduleRestart(reason: reason, lastError: error as? McpError)
        }
    }
}
