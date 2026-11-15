//
//  BrowserWire.swift
//  leanring-buddy
//
//  The bytes between Teachy and its browser extension, and the bookkeeping that
//  pairs each request with its answer. Pure: Foundation only, no AppKit, no
//  sockets. Tested by scripts/tests/run_chrome_tests.sh.
//
//  Wire format (the same on both sides of the native-messaging helper): a
//  32-bit little-endian length, then that many bytes of UTF-8 JSON, one JSON
//  object per frame.
//
//      app -> extension   {"type":"request","id":"7","method":"click","params":{…}}
//      extension -> app   {"type":"response","id":"7","ok":true,"result":{…}}
//                         {"type":"response","id":"7","ok":false,"error":{"code":"…","message":"…"}}
//                         {"type":"event","event":"hello" | "user_stopped" | "tab_closed", …}
//      helper -> app      {"type":"host","event":"hello" | "error", …}
//

import Foundation

nonisolated enum BrowserWireError: Error, LocalizedError, Equatable {
    /// A length prefix beyond any real message: the stream cannot be trusted any more.
    case frameTooLarge(Int)
    /// Chrome refuses more than 1 MB from a native host, so a bigger request can never arrive.
    case messageTooLargeForBrowser(Int)
    case notConnected
    case timedOut(method: String, seconds: Double)
    case connectionLost
    case cancelled
    /// The extension answered with ok:false.
    case remote(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let bytes):
            return "The browser helper sent a broken message (\(bytes) bytes)."
        case .messageTooLargeForBrowser(let bytes):
            return "That is too much to send to the browser in one go (\(bytes / 1024) KB; the limit is 1 MB). Send less text at a time."
        case .notConnected:
            return "Teachy's browser extension is not connected."
        case .timedOut(let method, let seconds):
            return "The browser did not answer \(method) within \(Int(seconds)) seconds."
        case .connectionLost:
            return "The browser went away before it answered."
        case .cancelled:
            return "Stopped."
        case .remote(_, let message):
            return message
        }
    }

    var code: String {
        switch self {
        case .frameTooLarge: return "frame_too_large"
        case .messageTooLargeForBrowser: return "message_too_large"
        case .notConnected: return "not_connected"
        case .timedOut: return "timeout"
        case .connectionLost: return "connection_lost"
        case .cancelled: return "cancelled"
        case .remote(let code, _): return code
        }
    }
}

/// A JSON object crossing a concurrency boundary. The dictionaries here are built once and only read.
nonisolated struct BrowserPayload: @unchecked Sendable {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }
}

// MARK: - Framing

nonisolated enum BrowserFraming {
    /// Chrome's limit for one message from a native host to the browser.
    static let maxBytesToBrowser = 1024 * 1024
    /// Screenshots come back as base64 inside JSON, so replies can be several MB. Past this, it is not a message.
    static let maxFrameBytes = 64 * 1024 * 1024

    static func encode(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return frame(body)
    }

    static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).littleEndian
        var data = Data(capacity: body.count + 4)
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

nonisolated enum BrowserFrame {
    case message([String: Any])
    /// A whole frame arrived but it was not a JSON object. The stream itself is still in step.
    case malformed
}

/// Feed it bytes as they arrive from the socket; it hands back whole messages.
nonisolated struct BrowserFrameDecoder {
    private var buffer = Data()
    private let maxFrameBytes: Int

    init(maxFrameBytes: Int = BrowserFraming.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    var bufferedByteCount: Int { buffer.count }

    /// Throws `frameTooLarge` when a length prefix is absurd; the connection should be dropped then.
    mutating func push(_ chunk: Data) throws -> [BrowserFrame] {
        buffer.append(chunk)
        var frames: [BrowserFrame] = []
        var offset = 0
        let count = buffer.count
        while count - offset >= 4 {
            let length = buffer.withUnsafeBytes { raw -> Int in
                Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            if length > maxFrameBytes {
                buffer.removeAll()
                throw BrowserWireError.frameTooLarge(length)
            }
            guard count - offset - 4 >= length else { break }
            let start = buffer.startIndex + offset + 4
            let body = buffer.subdata(in: start..<(start + length))
            offset += 4 + length
            if !body.isEmpty, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                frames.append(.message(object))
            } else {
                frames.append(.malformed)
            }
        }
        if offset > 0 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset)) }
        return frames
    }
}

// MARK: - Messages

nonisolated enum BrowserMessage {
    static func request(id: String, method: String, params: [String: Any]) -> [String: Any] {
        ["type": "request", "id": id, "method": method, "params": params]
    }

    enum Incoming {
        case response(id: String, result: Result<[String: Any], BrowserWireError>)
        case event(name: String, fields: [String: Any])
        /// From the helper itself: "hello" (who started it) or "error" (optionally about one request id).
        case host(event: String, fields: [String: Any])
        case unknown
    }

    static func parse(_ object: [String: Any]) -> Incoming {
        switch object["type"] as? String {
        case "response":
            guard let id = idString(object["id"]) else { return .unknown }
            if object["ok"] as? Bool == true {
                return .response(id: id, result: .success(object["result"] as? [String: Any] ?? [:]))
            }
            let error = object["error"] as? [String: Any] ?? [:]
            let code = error["code"] as? String ?? "failed"
            let message = error["message"] as? String ?? code
            return .response(id: id, result: .failure(.remote(code: code, message: message)))
        case "event":
            guard let name = object["event"] as? String else { return .unknown }
            return .event(name: name, fields: object)
        case "host":
            guard let name = object["event"] as? String else { return .unknown }
            return .host(event: name, fields: object)
        default:
            return .unknown
        }
    }

    static func idString(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

// MARK: - Request / response pairing

/// Hands out request ids and holds each caller until its answer, a timeout, a lost
/// connection or a cancellation, whichever comes first. Thread-safe.
nonisolated final class BrowserRequestCorrelator: @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<BrowserPayload, Error>
        let method: String
        let owner: String
        var timer: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var counter = 0

    init() {}

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func nextID() -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "t\(counter)"
    }

    /// Registers a request, calls `send` with its id (send the bytes there), and waits.
    /// `owner` names the connection the request went to, so losing that connection fails only its requests.
    func perform(
        method: String,
        owner: String = "",
        timeout: TimeInterval,
        send: @escaping @Sendable (String) throws -> Void
    ) async throws -> [String: Any] {
        let id = nextID()
        let payload: BrowserPayload = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserPayload, Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(id: id, with: .failure(BrowserWireError.timedOut(method: method, seconds: timeout)))
                }
                lock.lock()
                pending[id] = Pending(continuation: continuation, method: method, owner: owner, timer: timer)
                lock.unlock()

                // Cancelled before we got here: the cancellation handler found nothing to cancel.
                if Task.isCancelled {
                    finish(id: id, with: .failure(BrowserWireError.cancelled))
                    return
                }
                do {
                    try send(id)
                } catch {
                    finish(id: id, with: .failure(error))
                }
            }
        } onCancel: {
            self.finish(id: id, with: .failure(BrowserWireError.cancelled))
        }
        return payload.object
    }

    /// The answer for `id` arrived. False when nobody is waiting for it (late, duplicate or unknown).
    @discardableResult
    func resolve(id: String, with result: Result<[String: Any], BrowserWireError>) -> Bool {
        switch result {
        case .success(let object): return finish(id: id, with: .success(BrowserPayload(object)))
        case .failure(let error): return finish(id: id, with: .failure(error))
        }
    }

    /// The connection `owner` closed (nil: every connection): everything waiting on it fails now.
    func failAll(owner: String? = nil, with error: BrowserWireError = .connectionLost) {
        lock.lock()
        let ids = pending.filter { owner == nil || $0.value.owner == owner }.map(\.key)
        lock.unlock()
        for id in ids { finish(id: id, with: .failure(error)) }
    }

    @discardableResult
    private func finish(id: String, with result: Result<BrowserPayload, Error>) -> Bool {
        lock.lock()
        guard let entry = pending.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        entry.timer?.cancel()
        entry.continuation.resume(with: result)
        return true
    }
}
