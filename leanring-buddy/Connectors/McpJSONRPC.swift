//
//  McpJSONRPC.swift
//  leanring-buddy
//
//  JSON-RPC 2.0 for the MCP client: message framing, and a peer that matches
//  responses to requests by id, times requests out, and cancels them.
//  Transport-free on purpose — bytes go out through a closure and come in
//  through `receive`, so all of it is unit tested without a process or socket.
//

import Foundation

nonisolated enum JSONRPCID: Hashable, Sendable {
    case int(Int)
    case string(String)

    init?(json: JSONValue?) {
        switch json {
        case .int(let value): self = .int(value)
        case .double(let value) where value == value.rounded(): self = .int(Int(value))
        case .string(let value): self = .string(value)
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .int(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }
}

nonisolated struct JSONRPCErrorObject: Error, Sendable, Equatable, LocalizedError {
    var code: Int
    var message: String
    var data: JSONValue?

    static let methodNotFound = -32601
    static let invalidRequest = -32600
    static let parseError = -32700

    var errorDescription: String? { "\(message) (code \(code))" }
}

nonisolated enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID?, error: JSONRPCErrorObject)

    /// One frame may hold a single message or a batch (array).
    /// Entries that aren't valid JSON-RPC are skipped rather than failing the frame.
    static func parse(_ data: Data) throws -> [JSONRPCMessage] {
        let json = try JSONValue.parse(data)
        if case .array(let entries) = json {
            return entries.compactMap { JSONRPCMessage(json: $0) }
        }
        guard let message = JSONRPCMessage(json: json) else {
            throw JSONRPCErrorObject(code: JSONRPCErrorObject.invalidRequest, message: "Not a JSON-RPC 2.0 message", data: nil)
        }
        return [message]
    }

    init?(json: JSONValue) {
        guard case .object(let members) = json, members["jsonrpc"]?.stringValue == "2.0" else { return nil }
        let id = JSONRPCID(json: members["id"])
        if let method = members["method"]?.stringValue {
            let params = members["params"]
            if let id {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }
        if let errorJSON = members["error"], case .object = errorJSON {
            let errorObject = JSONRPCErrorObject(
                code: errorJSON["code"]?.intValue ?? 0,
                message: errorJSON["message"]?.stringValue ?? "Unknown error",
                data: errorJSON["data"]
            )
            self = .error(id: id, error: errorObject)
            return
        }
        if let id, let result = members["result"] {
            self = .response(id: id, result: result)
            return
        }
        return nil
    }

    var json: JSONValue {
        var members: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch self {
        case .request(let id, let method, let params):
            members["id"] = id.json
            members["method"] = .string(method)
            if let params { members["params"] = params }
        case .notification(let method, let params):
            members["method"] = .string(method)
            if let params { members["params"] = params }
        case .response(let id, let result):
            members["id"] = id.json
            members["result"] = result
        case .error(let id, let error):
            members["id"] = id?.json ?? .null
            var errorMembers: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
            if let data = error.data { errorMembers["data"] = data }
            members["error"] = .object(errorMembers)
        }
        return .object(members)
    }

    /// Single line, no trailing newline.
    func encoded() throws -> Data {
        try json.serialized()
    }
}

nonisolated enum JSONRPCPeerError: Error, Sendable, Equatable, LocalizedError {
    case timedOut(method: String, seconds: Double)
    case closed(reason: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let method, let seconds):
            return "The server didn't answer \(method) within \(Int(seconds.rounded(.up)))s."
        case .closed(let reason):
            return reason
        }
    }
}

/// Matches responses to requests. Feed it every incoming frame via `receive`.
actor JSONRPCPeer {
    typealias Sender = @Sendable (Data) async throws -> Void
    typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue?) async -> Void

    private let sender: Sender
    private var notificationHandler: NotificationHandler?
    private var nextRequestNumber = 0
    private var pendingContinuations: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeoutTasks: [JSONRPCID: Task<Void, Never>] = [:]
    /// Ids cancelled before their continuation was registered.
    private var cancelledBeforeRegistration: Set<JSONRPCID> = []
    private var closedError: Error?
    /// Frames that weren't JSON-RPC (a server printing a banner to stdout, say).
    private(set) var unparseableFrameCount = 0

    init(sender: @escaping Sender) {
        self.sender = sender
    }

    func setNotificationHandler(_ handler: NotificationHandler?) {
        notificationHandler = handler
    }

    var pendingRequestCount: Int { pendingContinuations.count }

    // MARK: Outgoing

    /// Sends a request and waits for its response. Throws `JSONRPCErrorObject` when the
    /// server answers with an error, `JSONRPCPeerError.timedOut` on timeout, and
    /// `CancellationError` when the calling task is cancelled (the server is told).
    func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        if let closedError { throw closedError }
        nextRequestNumber += 1
        let id = JSONRPCID.int(nextRequestNumber)
        let frame = try JSONRPCMessage.request(id: id, method: method, params: params).encoded()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if Task.isCancelled || cancelledBeforeRegistration.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingContinuations[id] = continuation
                timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.expire(id: id, method: method, timeout: timeout)
                }
                Task { [weak self, sender] in
                    do {
                        try await sender(frame)
                    } catch {
                        await self?.finish(id: id, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancel(id: id, method: method) }
        }
    }

    func notify(_ method: String, params: JSONValue? = nil) async throws {
        if let closedError { throw closedError }
        try await sender(try JSONRPCMessage.notification(method: method, params: params).encoded())
    }

    // MARK: Incoming

    func receive(_ frame: Data) async {
        guard let messages = try? JSONRPCMessage.parse(frame) else {
            unparseableFrameCount += 1
            return
        }
        for message in messages {
            switch message {
            case .response(let id, let result):
                finish(id: id, with: .success(result))
            case .error(let id, let error):
                if let id { finish(id: id, with: .failure(error)) }
            case .notification(let method, let params):
                // Never awaited here: a handler that sends a request (reloading the tool list)
                // needs this receive loop free to deliver the answer.
                if let notificationHandler {
                    Task { await notificationHandler(method, params) }
                }
            case .request(let id, let method, _):
                await answerServerRequest(id: id, method: method)
            }
        }
    }

    /// Fails everything in flight. Later requests throw the same error.
    func close(error: Error = JSONRPCPeerError.closed(reason: "The connection closed.")) {
        guard closedError == nil else { return }
        closedError = error
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: Internals

    /// Teachy offers the server nothing (no sampling, roots or elicitation), so the only
    /// server→client request it honours is `ping`. Everything else is declined cleanly.
    private func answerServerRequest(id: JSONRPCID, method: String) async {
        let reply: JSONRPCMessage
        if method == "ping" {
            reply = .response(id: id, result: .object([:]))
        } else {
            reply = .error(id: id, error: JSONRPCErrorObject(
                code: JSONRPCErrorObject.methodNotFound,
                message: "Teachy does not support \(method)",
                data: nil
            ))
        }
        if let frame = try? reply.encoded() {
            try? await sender(frame)
        }
    }

    private func finish(id: JSONRPCID, with result: Result<JSONValue, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        // An unknown id is a late answer to something already timed out or cancelled.
        guard let continuation = pendingContinuations.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func expire(id: JSONRPCID, method: String, timeout: TimeInterval) async {
        guard pendingContinuations[id] != nil else { return }
        finish(id: id, with: .failure(JSONRPCPeerError.timedOut(method: method, seconds: timeout)))
        await tellServerRequestWasAbandoned(id: id, method: method, reason: "timed out")
    }

    private func cancel(id: JSONRPCID, method: String) async {
        guard pendingContinuations[id] != nil else {
            // Not registered yet (or already answered). Remember it only while it could still register.
            if case .int(let number) = id, number >= nextRequestNumber { cancelledBeforeRegistration.insert(id) }
            return
        }
        finish(id: id, with: .failure(CancellationError()))
        await tellServerRequestWasAbandoned(id: id, method: method, reason: "cancelled")
    }

    private func tellServerRequestWasAbandoned(id: JSONRPCID, method: String, reason: String) async {
        // The spec forbids cancelling `initialize`.
        guard method != "initialize", closedError == nil else { return }
        let notification = JSONRPCMessage.notification(
            method: "notifications/cancelled",
            params: .object(["requestId": id.json, "reason": .string(reason)])
        )
        if let frame = try? notification.encoded() {
            try? await sender(frame)
        }
    }
}
