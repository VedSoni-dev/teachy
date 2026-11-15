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

    /// Everything still waiting, in order, at once (the person interrupted: no more pacing).
    mutating func drainAll() -> [SceneCommand] {
        let waiting = queue.map(\.command)
        queue.removeAll()
        return waiting
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

    /// A few lines saying what the scene shows, for a follow-up request: its title, the kind
    /// of drawing, the objects and labelled parts by id, and what was said.
    var summary: String {
        var lines: [String] = []
        var kinds: [String] = []
        var objects: [String] = []
        var labels: [String] = []
        var said: [String] = []
        var cardLines: [String] = []
        for command in entries.map(\.command) {
            switch command.verb {
            case .say:
                if let text = command.freeText { said.append(text) }
            case .scene3d:
                if !kinds.contains("a 3D model") { kinds.append("a 3D model") }
            case .card:
                if !kinds.contains("a card") { kinds.append("a card") }
            case .label:
                if let on = command.string("on"), let text = command.freeText { labels.append("\(text) (\(on))") }
            case .text, .bullet, .formula:
                if let text = command.freeText, cardLines.count < 6 { cardLines.append(text) }
            case .chart:
                cardLines.append("chart: \(command.string("title") ?? "data") [\(command.string("labels") ?? "")] = \(command.string("data") ?? "")")
            default:
                if command.verb.isLibraryPart, command.hasExplicitID, objects.count < 10 {
                    objects.append("\(command.verb.rawValue) \(command.id)")
                }
                if command.verb.makes3DPart, let label = command.string("label") { labels.append("\(label) (\(command.id))") }
            }
        }
        if let title, !title.isEmpty { lines.append("Title: \(title)") }
        if !kinds.isEmpty { lines.append("Shown as: \(kinds.joined(separator: " and "))") }
        if !objects.isEmpty { lines.append("Objects: \(objects.joined(separator: ", "))") }
        if !labels.isEmpty { lines.append("Labelled parts: \(labels.prefix(12).joined(separator: ", "))") }
        if !cardLines.isEmpty { lines.append("On the card: \(cardLines.joined(separator: " | "))") }
        if !said.isEmpty { lines.append("You said: \(said.joined(separator: " "))") }
        let text = lines.joined(separator: "\n")
        return text.count > 1400 ? String(text.prefix(1400)) : text
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

// MARK: - Narration audio

/// The voice that went with a scene: stretches of mono 16-bit PCM, each with the moment
/// (seconds since the scene began) it started. Pure, so it can be tested and saved.
struct SceneNarrationAudio: Equatable {
    struct Segment: Equatable {
        var start: Double
        var samples: [Int16]
    }

    private(set) var sampleRate: Double = 0
    private(set) var segments: [Segment] = []

    /// A new chunk arriving more than this long after the audio so far would have finished playing starts a new stretch.
    static let gap = 0.25

    var isEmpty: Bool { segments.allSatisfy { $0.samples.isEmpty } }

    /// When the last stretch finishes playing.
    var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return segments.map { $0.start + Double($0.samples.count) / sampleRate }.max() ?? 0
    }

    mutating func append(_ pcm16: Data, sampleRate rate: Double, at time: Double) {
        guard rate > 0, pcm16.count >= 2 else { return }
        var samples = [Int16](repeating: 0, count: pcm16.count / 2)
        _ = samples.withUnsafeMutableBytes { pcm16.copyBytes(to: $0, count: (pcm16.count / 2) * 2) }
        if sampleRate == 0 { sampleRate = rate }
        if rate != sampleRate {
            // One rate per scene: resample by nearest sample (voices don't change rate mid-scene in practice).
            let ratio = rate / sampleRate
            let count = Int(Double(samples.count) / ratio)
            samples = (0..<count).map { samples[min(Int(Double($0) * ratio), samples.count - 1)] }
        }
        if let last = segments.indices.last {
            let end = segments[last].start + Double(segments[last].samples.count) / sampleRate
            // Voices send audio faster than it plays, so a chunk that arrives "early" continues the stretch.
            if time <= end + Self.gap {
                segments[last].samples += samples
                return
            }
        }
        segments.append(Segment(start: max(time, 0), samples: samples))
    }

    /// One continuous track from time zero, with silence between stretches. Later stretches never overlap earlier ones.
    func mixed() -> [Int16] {
        guard sampleRate > 0 else { return [] }
        var track: [Int16] = []
        for segment in segments {
            let startIndex = max(Int((segment.start * sampleRate).rounded()), track.count)
            if startIndex > track.count { track += [Int16](repeating: 0, count: startIndex - track.count) }
            track += segment.samples
        }
        return track
    }

    /// The whole track as little-endian PCM bytes, and back.
    func data() -> Data {
        mixed().withUnsafeBufferPointer { Data(buffer: $0) }
    }

    init() {}

    init(track pcm16: Data, sampleRate: Double) {
        append(pcm16, sampleRate: sampleRate, at: 0)
    }
}
