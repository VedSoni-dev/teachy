//
//  SceneReplayLog.swift
//  leanring-buddy / Scene
//
//  When a command is drawn, and the record of it. The scheduler holds each command
//  until its spoken sentence starts (or staggers them when there is no speech);
//  the log remembers the moment each one was drawn so a scene replays the same way.
//
//  Pure (Foundation only).
//

import Foundation

// MARK: - Scheduling

struct SceneCueScheduler {
    enum Timing: Equatable {
        /// Commands wait for `sentenceStarted(n)` from the speech engine.
        case speech
        /// No speech: commands appear in order, a beat apart.
        case stagger
    }

    var timing: Timing
    /// Gap between two commands drawn back to back.
    var step: Double
    /// Extra pause when the cue number changes, in stagger timing.
    var cuePause: Double
    /// A command waiting longer than this for its sentence is drawn anyway.
    var maximumHold: Double

    private var queue: [(command: SceneCommand, enqueuedAt: Double)] = []
    private(set) var currentSentence = 0
    private var nextReleaseTime = 0.0
    private var lastReleasedCue: Int?
    private var releaseEverything = false

    init(timing: Timing, step: Double? = nil, cuePause: Double = 0.55, maximumHold: Double = 8) {
        self.timing = timing
        self.step = step ?? (timing == .speech ? 0.06 : 0.09)
        self.cuePause = cuePause
        self.maximumHold = maximumHold
    }

    var isEmpty: Bool { queue.isEmpty }
    var pendingCount: Int { queue.count }

    mutating func enqueue(_ command: SceneCommand, now: Double) {
        queue.append((command, now))
    }

    mutating func sentenceStarted(_ index: Int) {
        currentSentence = max(currentSentence, index)
    }

    /// Speech is over (or was never coming): let everything through, still in order.
    mutating func releaseAll() {
        releaseEverything = true
    }

    /// Commands to draw now, in script order.
    mutating func due(now: Double) -> [SceneCommand] {
        var released: [SceneCommand] = []
        while let head = queue.first {
            let cue = head.command.cue
            if timing == .speech, !releaseEverything, let cue, cue > currentSentence, now - head.enqueuedAt < maximumHold {
                break
            }
            var earliest = nextReleaseTime
            if timing == .stagger, let cue, let last = lastReleasedCue, cue != last, !released.isEmpty || nextReleaseTime > 0 {
                earliest += cuePause
            }
            if now < earliest { break }
            queue.removeFirst()
            released.append(head.command)
            if let cue { lastReleasedCue = cue }
            // `say` lines draw nothing, so they don't cost a beat.
            nextReleaseTime = max(now, earliest) + (head.command.verb == .say ? 0 : step)
        }
        return released
    }

    mutating func reset() {
        queue.removeAll()
        currentSentence = 0
        nextReleaseTime = 0
        lastReleasedCue = nil
        releaseEverything = false
    }
}

// MARK: - Replay log

struct SceneReplayLog: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Seconds since the scene began.
        var time: Double
        var command: SceneCommand
    }

    var title: String?
    private(set) var entries: [Entry] = []

    init(title: String? = nil) { self.title = title }

    var duration: Double { entries.last?.time ?? 0 }
    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ command: SceneCommand, at time: Double) {
        // Times never go backwards, so replay order always equals record order.
        entries.append(Entry(time: max(time, entries.last?.time ?? 0), command: command))
        if title == nil, command.verb == .scene3d || command.verb == .card { title = command.string("title") ?? command.freeText }
    }

    /// Entries with `after < time <= upTo`. Replaying with any tick size yields every entry exactly once.
    func entries(after: Double, upTo: Double) -> [Entry] {
        entries.filter { $0.time > after && $0.time <= upTo }
    }

    /// The scene as plain script, one command per line.
    var script: String {
        entries.map(\.command.scriptLine).joined(separator: "\n")
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> SceneReplayLog {
        try JSONDecoder().decode(SceneReplayLog.self, from: data)
    }
}
