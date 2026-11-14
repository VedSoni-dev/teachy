//
//  StreamIdleGuard.swift
//  leanring-buddy
//
//  Server-sent-event lines from a model stream, with a watchdog. Some publik tiers
//  send the whole answer and then never close the connection (seen 14 Nov 2026 on
//  publik-fast: text complete at 1.3 s, socket still open at 45 s). Without a guard
//  the app sits in "thinking" forever. The stream ends quietly when:
//    - nothing at all arrives for `firstByteTimeout` seconds, or
//    - content has started and nothing arrives for `idleTimeout` seconds.
//

import Foundation

enum StreamIdleGuard {
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private var contentStarted = false

        func touch(isContent: Bool) {
            lock.lock(); lastActivity = Date(); if isContent { contentStarted = true }; lock.unlock()
        }
        func secondsIdle() -> (idle: TimeInterval, contentStarted: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (Date().timeIntervalSince(lastActivity), contentStarted)
        }
    }

    /// True for an SSE data line whose delta has non-empty answer text. Reasoning deltas and
    /// keep-alives don't count: a reasoning tier may pause mid-thought for longer than the
    /// idle limit, and must not be cut off before it starts answering.
    static let lineCarriesAnswerText: @Sendable (String) -> Bool = { line in
        line.hasPrefix("data:") && line.contains("\"content\":\"") && !line.contains("\"content\":\"\"")
    }

    /// `isContentLine` says whether a line carries real answer text (as opposed to a
    /// keep-alive comment), which switches the watchdog to the short idle limit.
    static func lines(
        from bytes: URLSession.AsyncBytes,
        firstByteTimeout: TimeInterval = 60,
        idleTimeout: TimeInterval = 4,
        isContentLine: @escaping @Sendable (String) -> Bool = StreamIdleGuard.lineCarriesAnswerText
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let activity = Activity()
            let reader = Task {
                do {
                    for try await line in bytes.lines {
                        activity.touch(isContent: isContentLine(line))
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let state = activity.secondsIdle()
                    let limit = state.contentStarted ? idleTimeout : firstByteTimeout
                    if state.idle > limit {
                        print("⏱️ TeachyAI: stream idle for \(Int(state.idle)) s; closing it")
                        reader.cancel()
                        continuation.finish()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                watchdog.cancel()
            }
        }
    }
}
