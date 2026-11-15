//
//  BrowserSocketServer.swift
//  leanring-buddy
//
//  The app's end of the line to the browser helper: a Unix domain socket in
//  ~/Library/Application Support/Teachy/browser.sock that only this macOS user
//  can open (folder 0700, socket 0600, and the peer's user id is checked).
//  Each browser that has the extension starts one helper, so there can be
//  several connections at once.
//
//  No AppKit and no main actor here: it runs on its own threads and reports
//  through the three callbacks. BrowserBridge owns one and hops to the main
//  actor. Tested by scripts/tests/run_chrome_tests.sh against the real helper.
//

import Darwin
import Foundation

nonisolated enum BrowserSocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    case alreadyInUse
    case system(String)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): return "The socket path is too long for macOS: \(path)"
        case .alreadyInUse: return "Another copy of Teachy is already talking to the browser."
        case .system(let what): return what
        }
    }
}

nonisolated final class BrowserSocketServer: @unchecked Sendable {
    typealias ConnectionID = String

    private final class Connection: @unchecked Sendable {
        let id: ConnectionID
        let fd: Int32
        let writeLock = NSLock()
        var open = true
        init(id: ConnectionID, fd: Int32) { self.id = id; self.fd = fd }
    }

    private let path: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connections: [ConnectionID: Connection] = [:]
    private var counter = 0
    private var stopped = false

    private let onOpen: @Sendable (ConnectionID) -> Void
    private let onMessage: @Sendable (ConnectionID, BrowserPayload) -> Void
    private let onClose: @Sendable (ConnectionID) -> Void

    init(
        path: String,
        onOpen: @escaping @Sendable (ConnectionID) -> Void,
        onMessage: @escaping @Sendable (ConnectionID, BrowserPayload) -> Void,
        onClose: @escaping @Sendable (ConnectionID) -> Void
    ) {
        self.path = path
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onClose = onClose
    }

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    // MARK: Start / stop

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        chmod(folder, 0o700)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = [UInt8](path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw BrowserSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Something already at the path: a live Teachy (leave it alone) or a leftover from a crash (replace it).
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                let alive = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, size) }
                } == 0
                close(probe)
                if alive { throw BrowserSocketError.alreadyInUse }
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserSocketError.system("socket: \(String(cString: strerror(errno)))") }
        // The folder is already 0700, so nobody else can reach the socket in the instant before chmod.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw BrowserSocketError.system("bind: \(why)")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw BrowserSocketError.system("listen: \(why)")
        }

        lock.lock()
        listenFD = fd
        stopped = false
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "teachy.browser.accept"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let open = Array(connections.values)
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
        for connection in open { shutdown(connection.fd, SHUT_RDWR) }
    }

    // MARK: Sending

    /// False when that connection is gone.
    @discardableResult
    func send(_ object: [String: Any], to id: ConnectionID) -> Bool {
        guard let data = try? BrowserFraming.encode(object) else { return false }
        lock.lock()
        let connection = connections[id]
        lock.unlock()
        guard let connection else { return false }

        connection.writeLock.lock()
        defer { connection.writeLock.unlock() }
        guard connection.open else { return false }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var done = 0
            while done < raw.count {
                let sent = write(connection.fd, raw.baseAddress! + done, raw.count - done)
                if sent < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += sent
            }
            return true
        }
        if !ok { shutdown(connection.fd, SHUT_RDWR) }
        return ok
    }

    func disconnect(_ id: ConnectionID) {
        lock.lock()
        let connection = connections[id]
        lock.unlock()
        if let connection { shutdown(connection.fd, SHUT_RDWR) }
    }

    // MARK: Threads

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return // stop() closed the socket
            }
            // Only this user's own helper.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                close(fd)
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            if stopped {
                lock.unlock()
                close(fd)
                return
            }
            counter += 1
            let connection = Connection(id: "c\(counter)", fd: fd)
            connections[connection.id] = connection
            lock.unlock()

            onOpen(connection.id)
            let thread = Thread { [weak self] in self?.readLoop(connection) }
            thread.name = "teachy.browser.read.\(connection.id)"
            thread.start()
        }
    }

    private func readLoop(_ connection: Connection) {
        var decoder = BrowserFrameDecoder()
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }

        reading: while true {
            let got = read(connection.fd, buffer, capacity)
            if got == 0 { break }
            if got < 0 {
                if errno == EINTR { continue }
                break
            }
            let frames: [BrowserFrame]
            do {
                frames = try decoder.push(Data(bytes: buffer, count: got))
            } catch {
                break reading // an impossible length: drop the connection, the helper reconnects
            }
            for frame in frames {
                if case .message(let object) = frame {
                    onMessage(connection.id, BrowserPayload(object))
                }
            }
        }

        connection.writeLock.lock()
        connection.open = false
        connection.writeLock.unlock()
        lock.lock()
        connections.removeValue(forKey: connection.id)
        lock.unlock()
        close(connection.fd)
        onClose(connection.id)
    }
}
