//
//  BrowserLink.swift
//  leanring-buddy
//
//  The working part of the browser bridge with no UI and no main actor: it
//  owns the socket, knows which browsers are connected, sends a request to the
//  right one and returns its answer (or a timeout, or "the browser went away").
//  BrowserBridge wraps it for the app; the tests drive it directly against the
//  real helper binary (scripts/tests/run_chrome_tests.sh).
//

import Foundation

/// What settings shows, and what the tools check before they try.
nonisolated enum BrowserConnectionState: Equatable, Sendable {
    /// The helper or its browser manifests are not on this Mac yet.
    case notInstalled
    /// Installed, but no browser with the extension is talking to us.
    case waitingForChrome
    case connected(browserName: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

nonisolated final class BrowserLink: @unchecked Sendable {
    struct Peer: Equatable, Sendable {
        let id: String
        /// From the helper: the app that started it ("Google Chrome", "Arc", "Brave Browser").
        var browser: String
        var origin: String
        /// The extension itself has said hello (the helper connects a moment before it does).
        var extensionReady: Bool
        var order: Int
    }

    private let socketPath: String
    private let allowedExtensionIDs: [String]
    private let onChange: @Sendable () -> Void
    private let onEvent: @Sendable (_ peer: String, _ name: String, _ fields: BrowserPayload) -> Void

    private let lock = NSLock()
    private var server: BrowserSocketServer?
    private var peers: [String: Peer] = [:]
    private var order = 0
    let correlator = BrowserRequestCorrelator()

    init(
        socketPath: String,
        allowedExtensionIDs: [String] = BrowserHostManifest.allowedExtensionIDs,
        onChange: @escaping @Sendable () -> Void = {},
        onEvent: @escaping @Sendable (_ peer: String, _ name: String, _ fields: BrowserPayload) -> Void = { _, _, _ in }
    ) {
        self.socketPath = socketPath
        self.allowedExtensionIDs = allowedExtensionIDs
        self.onChange = onChange
        self.onEvent = onEvent
    }

    var isListening: Bool {
        lock.lock(); defer { lock.unlock() }
        return server != nil
    }

    func start() throws {
        lock.lock()
        if server != nil { lock.unlock(); return }
        lock.unlock()

        let created = BrowserSocketServer(
            path: socketPath,
            onOpen: { _ in },
            onMessage: { [weak self] peer, payload in self?.received(payload.object, from: peer) },
            onClose: { [weak self] peer in self?.closed(peer) }
        )
        try created.start()
        lock.lock()
        server = created
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let running = server
        server = nil
        peers.removeAll()
        lock.unlock()
        running?.stop()
        correlator.failAll()
        onChange()
    }

    // MARK: Who is connected

    /// Browsers whose extension is ready, most recently connected first.
    var readyPeers: [Peer] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.filter(\.extensionReady).sorted { $0.order > $1.order }
    }

    func peer(_ id: String) -> Peer? {
        lock.lock(); defer { lock.unlock() }
        return peers[id]
    }

    static func displayName(forBrowser raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "": return "Chrome"
        case "Google Chrome": return "Chrome"
        case "Google Chrome Beta": return "Chrome Beta"
        case "Google Chrome for Testing": return "Chrome for Testing"
        case "Microsoft Edge": return "Edge"
        case "Brave Browser": return "Brave"
        default: return name
        }
    }

    // MARK: Requests

    /// Sends one request and waits for its answer. `preferredPeer` keeps a job in the browser it started in.
    func request(
        method: String,
        params: [String: Any],
        preferredPeer: String? = nil,
        timeout: TimeInterval
    ) async throws -> (result: [String: Any], peer: String) {
        let (server, peer) = route(preferredPeer: preferredPeer)
        guard let running = server, let target = peer else { throw BrowserWireError.notConnected }

        // Checked here so the caller gets a clear answer instead of the helper's refusal.
        let probe = try BrowserFraming.encode(BrowserMessage.request(id: "t000000000", method: method, params: params))
        if probe.count - 4 > BrowserFraming.maxBytesToBrowser - 64 {
            throw BrowserWireError.messageTooLargeForBrowser(probe.count - 4)
        }

        let payload = BrowserPayload(params)
        let peerID = target.id
        let result = try await correlator.perform(method: method, owner: peerID, timeout: timeout) { id in
            let message = BrowserMessage.request(id: id, method: method, params: payload.object)
            if !running.send(message, to: peerID) { throw BrowserWireError.connectionLost }
        }
        return (result, peerID)
    }

    /// The socket and the browser a request should go to: the job's own browser, or the one that connected last.
    private func route(preferredPeer: String?) -> (BrowserSocketServer?, Peer?) {
        lock.lock(); defer { lock.unlock() }
        if let preferredPeer {
            return (server, peers[preferredPeer].flatMap { $0.extensionReady ? $0 : nil })
        }
        return (server, peers.values.filter(\.extensionReady).max { $0.order < $1.order })
    }

    // MARK: Incoming

    private func received(_ object: [String: Any], from peerID: String) {
        switch BrowserMessage.parse(object) {
        case .response(let id, let result):
            correlator.resolve(id: id, with: result)

        case .host(let event, let fields):
            if event == "hello" {
                let origin = fields["origin"] as? String ?? ""
                // Chrome already refuses to start the helper for any other extension; this is the second lock.
                let allowed = allowedExtensionIDs.contains { origin == "chrome-extension://\($0)/" }
                guard allowed else {
                    lock.lock()
                    let running = server
                    lock.unlock()
                    running?.disconnect(peerID)
                    return
                }
                lock.lock()
                order += 1
                peers[peerID] = Peer(id: peerID, browser: fields["browser"] as? String ?? "", origin: origin, extensionReady: false, order: order)
                lock.unlock()
            } else if event == "error", let id = BrowserMessage.idString(fields["id"]) {
                let code = fields["error"] as? String ?? "helper_error"
                let error: BrowserWireError = code == "message_too_large"
                    ? .messageTooLargeForBrowser(fields["bytes"] as? Int ?? 0)
                    : .remote(code: code, message: "The browser helper refused the message (\(code)).")
                correlator.resolve(id: id, with: .failure(error))
            }

        case .event(let name, let fields):
            if name == "hello" {
                lock.lock()
                let known = peers[peerID] != nil
                if known {
                    order += 1
                    peers[peerID]?.extensionReady = true
                    peers[peerID]?.order = order
                    if peers[peerID]?.browser.isEmpty == true { peers[peerID]?.browser = fields["browser"] as? String ?? "" }
                }
                lock.unlock()
                if known { onChange() }
            }
            onEvent(peerID, name, BrowserPayload(fields))

        case .unknown:
            break
        }
    }

    private func closed(_ peerID: String) {
        lock.lock()
        let had = peers.removeValue(forKey: peerID) != nil
        lock.unlock()
        correlator.failAll(owner: peerID)
        onEvent(peerID, "peer_closed", BrowserPayload([:]))
        if had { onChange() }
    }
}
