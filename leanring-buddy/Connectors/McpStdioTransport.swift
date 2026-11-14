//
//  McpStdioTransport.swift
//  leanring-buddy
//
//  Runs a local MCP server as a child process and talks newline-delimited JSON
//  over its stdin/stdout. stderr goes to a ring buffer for error messages.
//
//  A Mac app launched from Finder gets a bare PATH (/usr/bin:/bin:…), so `npx`,
//  `uvx`, `node` and `python` would not be found. `McpShellEnvironment` asks the
//  person's login shell for its PATH once and caches it.
//

import Foundation

// MARK: - Login-shell PATH

nonisolated enum McpShellEnvironment {
    static let startMarker = "__TEACHY_PATH_START__"
    static let endMarker = "__TEACHY_PATH_END__"

    /// Pulls the PATH out of whatever the shell printed (rc files can print banners around it).
    static func parsePATH(fromShellOutput output: String) -> String? {
        guard let startRange = output.range(of: startMarker, options: .backwards),
              let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex) else {
            return nil
        }
        let path = output[startRange.upperBound..<endRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Shell PATH first, then what the app inherited, then the usual install locations.
    static func mergedPATH(shellPATH: String?, inheritedPATH: String?, homeDirectory: String) -> String {
        let commonLocations = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(homeDirectory)/.local/bin", "\(homeDirectory)/.bun/bin", "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/.volta/bin", "\(homeDirectory)/.deno/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        var ordered: [String] = []
        let candidates = (shellPATH ?? "").split(separator: ":").map(String.init)
            + (inheritedPATH ?? "").split(separator: ":").map(String.init)
            + commonLocations
        for directory in candidates where !directory.isEmpty && seen.insert(directory).inserted {
            ordered.append(directory)
        }
        return ordered.joined(separator: ":")
    }

    /// Absolute path of `command`, searching `searchPATH` for bare names.
    static func resolveExecutable(_ command: String, searchPATH: String, workingDirectory: String? = nil) -> String? {
        let fileManager = FileManager.default
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            let absolute: String
            if expanded.hasPrefix("/") {
                absolute = expanded
            } else {
                let base = workingDirectory ?? fileManager.currentDirectoryPath
                absolute = (base as NSString).appendingPathComponent(expanded)
            }
            return isRunnableFile(absolute) ? absolute : nil
        }
        for directory in searchPATH.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(expanded)
            if isRunnableFile(candidate) { return candidate }
        }
        return nil
    }

    private static func isRunnableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static let cache = PATHCache()

    /// The PATH the person's login shell would give a command. Cached for the app's lifetime.
    static func loginShellPATH() async -> String {
        await cache.value()
    }

    private actor PATHCache {
        private var inFlight: Task<String, Never>?

        func value() async -> String {
            if let inFlight { return await inFlight.value }
            let task = Task<String, Never> {
                let environment = ProcessInfo.processInfo.environment
                let shellPATH = await McpShellEnvironment.askLoginShellForPATH(
                    shell: environment["SHELL"] ?? "/bin/zsh",
                    timeout: 5
                )
                return McpShellEnvironment.mergedPATH(
                    shellPATH: shellPATH,
                    inheritedPATH: environment["PATH"],
                    homeDirectory: NSHomeDirectory()
                )
            }
            inFlight = task
            return await task.value
        }
    }

    /// Runs `$SHELL -l -i -c 'print PATH'`. Output goes to a temp file rather than a pipe so a
    /// background job started by an rc file can never keep us waiting on an open pipe.
    static func askLoginShellForPATH(shell: String, timeout: TimeInterval) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let isFish = (shell as NSString).lastPathComponent == "fish"
        let printCommand = isFish
            ? "printf '%s%s%s' \(startMarker) (string join : $PATH) \(endMarker)"
            : "printf '%s%s%s' \(startMarker) \"$PATH\" \(endMarker)"

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teachy-shell-path-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", printCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        let finished: Bool = await withCheckedContinuation { continuation in
            let resumeOnce = McpOnceFlag()
            process.terminationHandler = { _ in
                if resumeOnce.claim() { continuation.resume(returning: true) }
            }
            do {
                try process.run()
            } catch {
                if resumeOnce.claim() { continuation.resume(returning: false) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumeOnce.claim() {
                    process.terminate()
                    continuation.resume(returning: false)
                }
            }
        }
        guard finished, let data = try? Data(contentsOf: outputURL) else { return nil }
        return parsePATH(fromShellOutput: String(decoding: data, as: UTF8.self))
    }
}

/// "Only the first caller wins" — guards a continuation that several callbacks race to resume.
nonisolated final class McpOnceFlag: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Transport

nonisolated final class McpStdioTransport: McpTransport, @unchecked Sendable {
    private let command: String
    private let arguments: [String]
    private let extraEnvironment: [String: String]
    private let workingDirectory: String?
    private let pathProvider: @Sendable () async -> String
    /// Values that must never appear in an error message (the secrets we injected).
    private let redactions: [String]

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var unfinishedOutput = Data()
    private var isClosing = false
    private var didFinish = false
    private var sawOutputEnd = false
    private var exitCode: Int32?
    private let stderrBuffer = McpRingBuffer(capacity: 16_384)
    private let writeQueue = DispatchQueue(label: "app.teachy.mcp.stdio.write")

    init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        redactions: [String] = [],
        pathProvider: @escaping @Sendable () async -> String = { await McpShellEnvironment.loginShellPATH() }
    ) {
        self.command = command
        self.arguments = arguments
        self.extraEnvironment = environment
        self.workingDirectory = workingDirectory
        self.redactions = redactions.filter { $0.count >= 4 }
        self.pathProvider = pathProvider
    }

    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    func start() async throws -> AsyncThrowingStream<Data, Error> {
        let searchPATH = await pathProvider()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPATH
        for (name, value) in extraEnvironment { environment[name] = value }

        let expandedWorkingDirectory = workingDirectory.map { ($0 as NSString).expandingTildeInPath }
        guard let executablePath = McpShellEnvironment.resolveExecutable(
            command,
            searchPATH: environment["PATH"] ?? searchPATH,
            workingDirectory: expandedWorkingDirectory
        ) else {
            throw McpError.commandNotFound(command)
        }

        // Writing to a server that already quit would otherwise kill the whole app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executablePath)
        child.arguments = arguments
        child.environment = environment
        if let expandedWorkingDirectory {
            child.currentDirectoryURL = URL(fileURLWithPath: expandedWorkingDirectory, isDirectory: true)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        let (stream, streamContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        locked {
            continuation = streamContinuation
            process = child
            stdinHandle = stdinPipe.fileHandleForWriting
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.outputEnded()
            } else {
                self?.consumeOutput(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.stderrBuffer.append(data)
            }
        }
        child.terminationHandler = { [weak self] finishedProcess in
            self?.processExited(code: finishedProcess.terminationStatus)
        }

        do {
            try child.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            locked {
                didFinish = true
                process = nil
                stdinHandle = nil
                continuation = nil
            }
            streamContinuation.finish()
            throw McpError.launchFailed(error.localizedDescription)
        }
        return stream
    }

    func send(_ frame: Data) async throws {
        let (handle, finished) = locked { (stdinHandle, didFinish) }
        guard let handle, !finished else { throw McpError.notConnected }

        var line = frame
        line.append(0x0A)
        // A dedicated serial queue: keeps frames in order, and a server that stopped
        // reading (full pipe) blocks this queue instead of a Swift concurrency thread.
        try await withCheckedThrowingContinuation { (writeContinuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try handle.write(contentsOf: line)
                    writeContinuation.resume()
                } catch {
                    writeContinuation.resume(throwing: McpError.notConnected)
                }
            }
        }
    }

    func sessionDidInitialize(protocolVersion: String) async {}

    /// Clean shutdown, as the spec describes for stdio: close stdin, give the server a moment
    /// to leave by itself, then SIGTERM, then SIGKILL.
    func close() async {
        let (child, handle): (Process?, FileHandle?) = locked {
            isClosing = true
            let current = (process, stdinHandle)
            stdinHandle = nil
            return current
        }

        try? handle?.close()
        guard let child else { return }

        await withCheckedContinuation { (closeContinuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                Self.wait(for: child, seconds: 1.5)
                if child.isRunning {
                    child.terminate()
                    Self.wait(for: child, seconds: 2)
                }
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                    Self.wait(for: child, seconds: 1)
                }
                closeContinuation.resume()
            }
        }
        finishIfNeeded(force: true)
    }

    func diagnostics() async -> String {
        redacted(stderrBuffer.text(lastLines: 12))
    }

    // MARK: Internals

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private static func wait(for child: Process, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while child.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func redacted(_ text: String) -> String {
        var result = text
        for secret in redactions {
            result = result.replacingOccurrences(of: secret, with: "[hidden]")
        }
        return result
    }

    private func consumeOutput(_ data: Data) {
        lock.lock()
        unfinishedOutput.append(data)
        var lines: [Data] = []
        while let newlineIndex = unfinishedOutput.firstIndex(of: 0x0A) {
            lines.append(Data(unfinishedOutput[unfinishedOutput.startIndex..<newlineIndex]))
            unfinishedOutput = Data(unfinishedOutput[unfinishedOutput.index(after: newlineIndex)...])
        }
        let streamContinuation = continuation
        lock.unlock()

        for line in lines { deliver(line, to: streamContinuation) }
    }

    private func deliver(_ rawLine: Data, to streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?) {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard let firstByte = line.first(where: { $0 != 0x20 && $0 != 0x09 }) else { return }
        // Anything that isn't JSON on stdout is a server misbehaving (a banner, a log line).
        // Keep it for diagnostics instead of feeding it to the JSON-RPC layer.
        guard firstByte == UInt8(ascii: "{") || firstByte == UInt8(ascii: "[") else {
            stderrBuffer.append(line + Data([0x0A]))
            return
        }
        streamContinuation?.yield(line)
    }

    private func outputEnded() {
        lock.lock()
        sawOutputEnd = true
        let leftover = unfinishedOutput
        unfinishedOutput.removeAll()
        let streamContinuation = continuation
        let exited = exitCode != nil
        lock.unlock()

        if !leftover.isEmpty { deliver(leftover, to: streamContinuation) }
        if exited {
            finishIfNeeded(force: true)
        } else {
            // stdout closed but the process is still alive; give it a moment to report its exit code.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finishIfNeeded(force: true)
            }
        }
    }

    private func processExited(code: Int32) {
        lock.lock()
        exitCode = code
        let outputDone = sawOutputEnd
        lock.unlock()

        if outputDone {
            finishIfNeeded(force: true)
        } else {
            // Let the last bytes of stdout arrive; a grandchild holding the pipe open must not hang us.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finishIfNeeded(force: true)
            }
        }
    }

    private func finishIfNeeded(force: Bool) {
        lock.lock()
        guard !didFinish, force else { lock.unlock(); return }
        didFinish = true
        let streamContinuation = continuation
        continuation = nil
        let closing = isClosing
        let code = exitCode ?? -1
        stdinHandle = nil
        lock.unlock()

        if closing {
            streamContinuation?.finish()
        } else {
            streamContinuation?.finish(throwing: McpError.processExited(
                code: code,
                stderrTail: redacted(stderrBuffer.text(lastLines: 6))
            ))
        }
    }
}
