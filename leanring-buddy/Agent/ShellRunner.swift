//
//  ShellRunner.swift
//  leanring-buddy
//
//  Runs one shell command for the agent's bash tool. Foundation + POSIX only.
//
//  What it fixes over the old BashTool:
//  - stdout and stderr are drained WHILE the command runs, so a command that
//    prints more than a pipe buffer (~64 KB) no longer hangs until the timeout
//  - captured output is capped; the rest is read and thrown away
//  - the command runs in its own process group, and on timeout the whole
//    group is killed, not just the shell
//  - stdin is /dev/null, so a command that waits for typing fails fast
//

import Foundation

struct ShellRunResult: Equatable {
    var standardOutput: String
    var standardError: String
    var exitCode: Int32
    var timedOut: Bool
    var wasCancelled: Bool
    var outputWasTruncated: Bool

    /// The text handed back to the model.
    var report: String {
        var text = ""
        if !standardOutput.isEmpty { text += "stdout:\n\(standardOutput)\n" }
        if !standardError.isEmpty { text += "stderr:\n\(standardError)\n" }
        if outputWasTruncated { text += "[output was longer than Teachy keeps; the rest was dropped]\n" }
        if timedOut { text += "[timed out and was stopped]\n" }
        if wasCancelled { text += "[stopped]\n" }
        text += "exit code: \(exitCode)"
        return text
    }
}

enum ShellRunner {
    static let defaultOutputCap = 200_000

    private final class Collector {
        private let lock = NSLock()
        private var data = Data()
        private(set) var truncated = false
        let cap: Int
        init(cap: Int) { self.cap = cap }

        func append(_ bytes: UnsafeRawBufferPointer) {
            lock.lock(); defer { lock.unlock() }
            let room = cap - data.count
            if room <= 0 { truncated = true; return }
            if bytes.count > room {
                data.append(contentsOf: bytes.prefix(room))
                truncated = true
            } else {
                data.append(contentsOf: bytes)
            }
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }

        var wasTruncated: Bool {
            lock.lock(); defer { lock.unlock() }
            return truncated
        }
    }

    private final class StopFlag {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// Blocks the calling thread. Call it off the main thread.
    static func run(
        command: String,
        timeoutSeconds: TimeInterval,
        outputCap: Int = defaultOutputCap,
        workingDirectory: String? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ShellRunResult {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw posixError("Could not open a pipe") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw posixError("Could not open a pipe")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (so the whole tree can be killed) and no inherited descriptors.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argumentStrings = ["/bin/zsh", "-c", command]
        var argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, "/bin/zsh", &fileActions, &attributes, argv, environ)
        close(outPipe[1])
        close(errPipe[1])
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw NSError(domain: "ShellRunner", code: Int(spawnStatus), userInfo: [NSLocalizedDescriptionKey: "Could not start the shell: \(String(cString: strerror(spawnStatus)))"])
        }

        let stopReading = StopFlag()
        let readers = DispatchGroup()
        let outCollector = Collector(cap: outputCap)
        let errCollector = Collector(cap: outputCap)

        func drain(_ descriptor: Int32, into collector: Collector) {
            readers.enter()
            Thread.detachNewThread {
                defer { close(descriptor); readers.leave() }
                let bufferSize = 16 * 1024
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
                defer { buffer.deallocate() }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                while true {
                    descriptorState.revents = 0
                    let ready = poll(&descriptorState, 1, 100)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    if stopReading.isStopped { return }
                    if ready == 0 { continue }
                    let count = read(descriptor, buffer, bufferSize)
                    if count > 0 {
                        collector.append(UnsafeRawBufferPointer(start: buffer, count: count))
                    } else if count == 0 {
                        return // end of stream
                    } else if errno != EINTR && errno != EAGAIN {
                        return
                    }
                }
            }
        }
        drain(outPipe[0], into: outCollector)
        drain(errPipe[0], into: errCollector)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var status: Int32 = 0
        var timedOut = false
        var cancelled = false
        var exited = false

        while !exited {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { exited = true; break }
            if waited < 0 && errno != EINTR { exited = true; status = 0; break }
            if isCancelled() { cancelled = true; break }
            if Date() > deadline { timedOut = true; break }
            usleep(20_000)
        }

        if !exited {
            // Whole group: the shell and everything it started.
            kill(-pid, SIGTERM)
            let graceDeadline = Date().addingTimeInterval(1.0)
            while Date() < graceDeadline {
                if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }
                usleep(20_000)
            }
            kill(-pid, SIGKILL)
            if !exited {
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }

        // Normally the readers see end-of-stream right away. If something the command
        // left running still holds the pipe, stop waiting after a moment.
        if readers.wait(timeout: .now() + 0.5) == .timedOut {
            stopReading.stop()
            _ = readers.wait(timeout: .now() + 1.0)
        }

        let exitCode: Int32
        if timedOut { exitCode = 124 } else if cancelled { exitCode = 130 } else if status & 0x7f == 0 { exitCode = (status >> 8) & 0xff } else { exitCode = 128 + (status & 0x7f) }

        return ShellRunResult(
            standardOutput: outCollector.text,
            standardError: errCollector.text,
            exitCode: exitCode,
            timedOut: timedOut,
            wasCancelled: cancelled,
            outputWasTruncated: outCollector.wasTruncated || errCollector.wasTruncated
        )
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: "ShellRunner", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"])
    }
}
