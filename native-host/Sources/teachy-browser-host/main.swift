//
//  teachy-browser-host
//
//  The helper Chrome starts for the Teachy extension (native messaging). It is
//  a pipe and nothing else:
//
//      Chrome  <- stdin/stdout, 4-byte length + JSON ->  this  <- Unix socket, same framing ->  Teachy.app
//
//  It reads no page content itself, keeps nothing, and talks to nobody but the
//  browser that started it and the Teachy app of the same macOS user.
//
//  - If Teachy is not running it says so ({"type":"host","event":"app_not_running"})
//    and keeps trying to reach it, so the extension works the moment Teachy opens.
//  - Chrome refuses messages over 1 MB from a host, so anything bigger coming
//    from the app is refused here with an error back to the app.
//  - It exits when Chrome closes its end.
//
//  Socket: ~/Library/Application Support/Teachy/browser.sock
//  (TEACHY_BROWSER_SOCKET overrides it; used by the tests.)
//

import Darwin
import Foundation

// MARK: - Limits

/// Chrome's own limit for one message from a host to the browser.
let maxBytesToBrowser = 1024 * 1024
/// Anything bigger than this from either side is treated as a broken stream.
let maxFrameBytes = 64 * 1024 * 1024
let protocolVersion = 1

// MARK: - Low-level I/O

func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: count)
    var done = 0
    while done < count {
        let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + done, count - done) }
        if got == 0 { return nil }
        if got < 0 {
            if errno == EINTR { continue }
            return nil
        }
        done += got
    }
    return buffer
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var done = 0
    while done < bytes.count {
        let sent = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + done, bytes.count - done) }
        if sent < 0 {
            if errno == EINTR { continue }
            return false
        }
        done += sent
    }
    return true
}

enum FrameRead {
    case frame([UInt8])
    case endOfStream
    case tooLarge(Int)
}

/// One native-messaging frame: a 32-bit length in native byte order, then that many bytes of JSON.
func readFrame(_ fd: Int32) -> FrameRead {
    guard let header = readExactly(fd, 4) else { return .endOfStream }
    let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    if length > maxFrameBytes { return .tooLarge(length) }
    if length == 0 { return .frame([]) }
    guard let body = readExactly(fd, length) else { return .endOfStream }
    return .frame(body)
}

func framed(_ body: [UInt8]) -> [UInt8] {
    var length = UInt32(body.count)
    var out = [UInt8]()
    out.reserveCapacity(body.count + 4)
    withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
    out.append(contentsOf: body)
    return out
}

func jsonBytes(_ object: [String: Any]) -> [UInt8] {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return [UInt8](data)
}

/// The message as a dictionary, or nil when it is not a JSON object.
func parseObject(_ body: [UInt8]) -> [String: Any]? {
    guard !body.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
}

// MARK: - Who started us

func parentBrowserName() -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    guard length > 0 else { return "" }
    let path = String(cString: buffer)
    for component in path.split(separator: "/") where component.hasSuffix(".app") {
        return String(component.dropLast(4))
    }
    return (path as NSString).lastPathComponent
}

func socketPath() -> String {
    if let override = ProcessInfo.processInfo.environment["TEACHY_BROWSER_SOCKET"], !override.isEmpty {
        return override
    }
    return NSHomeDirectory() + "/Library/Application Support/Teachy/browser.sock"
}

// MARK: - The relay

final class Relay: @unchecked Sendable {
    private let stdoutLock = NSLock()
    private let socketLock = NSLock()
    private var socketFD: Int32 = -1
    private let path: String
    private let origin: String
    private let browser: String

    init(path: String, origin: String, browser: String) {
        self.path = path
        self.origin = origin
        self.browser = browser
    }

    // To Chrome.
    func sendToBrowser(_ body: [UInt8]) {
        stdoutLock.lock()
        let ok = writeAll(STDOUT_FILENO, framed(body))
        stdoutLock.unlock()
        if !ok { exit(0) } // Chrome went away.
    }

    func sendToBrowser(_ object: [String: Any]) { sendToBrowser(jsonBytes(object)) }

    // To the app. False when the app is not connected.
    @discardableResult
    func sendToApp(_ body: [UInt8]) -> Bool {
        socketLock.lock()
        defer { socketLock.unlock() }
        guard socketFD >= 0 else { return false }
        if writeAll(socketFD, framed(body)) { return true }
        shutdown(socketFD, SHUT_RDWR)
        return false
    }

    @discardableResult
    func sendToApp(_ object: [String: Any]) -> Bool { sendToApp(jsonBytes(object)) }

    private func setSocket(_ fd: Int32) {
        socketLock.lock()
        socketFD = fd
        socketLock.unlock()
    }

    /// Connects to the app's socket. Only a socket owned by this user, with this user on the other end.
    private func connectToApp() -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { return -1 }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = [UInt8](path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard result == 0 else { close(fd); return -1 }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { close(fd); return -1 }
        return fd
    }

    /// Runs for the life of the process: connect, relay app -> Chrome, reconnect when the app goes.
    func runAppSide() {
        var toldBrowserAppIsMissing = false
        var attempts = 0
        while true {
            let fd = connectToApp()
            if fd < 0 {
                if !toldBrowserAppIsMissing {
                    sendToBrowser(["type": "host", "event": "app_not_running"])
                    toldBrowserAppIsMissing = true
                }
                attempts += 1
                // Quick at first (the app may be starting), then relaxed.
                usleep(attempts < 40 ? 250_000 : 3_000_000)
                continue
            }

            attempts = 0
            toldBrowserAppIsMissing = false
            setSocket(fd)
            sendToApp([
                "type": "host", "event": "hello", "version": protocolVersion,
                "origin": origin, "browser": browser, "pid": Int(getpid())
            ])
            sendToBrowser(["type": "host", "event": "app_connected"])

            relay: while true {
                switch readFrame(fd) {
                case .endOfStream:
                    break relay
                case .tooLarge(let length):
                    sendToApp(["type": "host", "event": "error", "error": "frame_too_large", "bytes": length])
                    break relay
                case .frame(let body):
                    guard let object = parseObject(body) else {
                        sendToApp(["type": "host", "event": "error", "error": "malformed_frame"])
                        continue
                    }
                    if body.count > maxBytesToBrowser {
                        var reply: [String: Any] = [
                            "type": "host", "event": "error", "error": "message_too_large",
                            "bytes": body.count, "limit": maxBytesToBrowser
                        ]
                        if let id = object["id"] { reply["id"] = id }
                        sendToApp(reply)
                        continue
                    }
                    sendToBrowser(body)
                }
            }

            setSocket(-1)
            close(fd)
            sendToBrowser(["type": "host", "event": "app_not_running"])
            toldBrowserAppIsMissing = true
            usleep(250_000)
        }
    }

    /// Runs on the main thread: Chrome -> app, until Chrome closes the pipe.
    func runBrowserSide() -> Int32 {
        while true {
            switch readFrame(STDIN_FILENO) {
            case .endOfStream:
                return 0
            case .tooLarge(let length):
                // The stream cannot be trusted past this point.
                sendToApp(["type": "host", "event": "error", "error": "frame_too_large", "bytes": length])
                sendToBrowser(["type": "host", "event": "error", "error": "frame_too_large"])
                return 2
            case .frame(let body):
                guard let object = parseObject(body) else {
                    sendToBrowser(["type": "host", "event": "error", "error": "malformed_frame"])
                    sendToApp(["type": "host", "event": "error", "error": "malformed_frame"])
                    continue
                }
                if !sendToApp(body) {
                    var reply: [String: Any] = ["type": "host", "event": "app_not_running"]
                    if let id = object["id"] { reply["id"] = id }
                    sendToBrowser(reply)
                }
            }
        }
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("teachy-browser-host \(protocolVersion)")
    exit(0)
}

// Chrome passes the calling extension's origin as the first argument.
let origin = arguments.dropFirst().first(where: { $0.hasPrefix("chrome-extension://") }) ?? ""
let relay = Relay(path: socketPath(), origin: origin, browser: parentBrowserName())

let appThread = Thread { relay.runAppSide() }
appThread.stackSize = 1 << 20
appThread.start()

exit(relay.runBrowserSide())
