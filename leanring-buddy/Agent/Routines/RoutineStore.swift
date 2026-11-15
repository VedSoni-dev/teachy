//
//  RoutineStore.swift
//  leanring-buddy
//
//  The saved routines (~/.teachy/agents/routines.json) and the rules for what
//  happens after each run. Foundation only; the file is injected so tests use
//  a temp directory.
//

import Foundation

nonisolated struct Routine: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// The named agent that runs it; nil = a plain job.
    var agentSlug: String?
    /// What to do each time, as an instruction.
    var task: String
    var schedule: RoutineSchedule
    var enabled: Bool
    var createdAt: Date
    var lastRun: Date?
    /// The answer of the last run (or why it failed), including anything it was not allowed to do.
    var lastResult: String?
    /// "ok", "failed" or "needs you" (something was refused because nobody could say yes).
    var lastStatus: String?
    var consecutiveFailures: Int
    /// Results arrive silently; this is the unread dot.
    var hasUnreadResult: Bool
    /// Why Teachy paused it (three failures in a row). nil when the person paused it or it is running.
    var pausedReason: String?

    init(id: String = UUID().uuidString, agentSlug: String? = nil, task: String, schedule: RoutineSchedule, enabled: Bool = true, createdAt: Date) {
        self.id = id
        self.agentSlug = agentSlug
        self.task = task
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRun = nil
        self.lastResult = nil
        self.lastStatus = nil
        self.consecutiveFailures = 0
        self.hasUnreadResult = false
        self.pausedReason = nil
    }

    /// Schedules are counted from the last run, or from when the routine was made.
    var anchor: Date { lastRun ?? createdAt }

    func nextRun(calendar: Calendar) -> Date? {
        enabled ? schedule.nextFire(after: anchor, calendar: calendar) : nil
    }
}

nonisolated enum RoutineRunOutcome: Equatable, Sendable {
    case succeeded(result: String)
    /// It ran, but the gate refused something because nobody could say yes. Not a failure.
    case needsPerson(result: String)
    case failed(reason: String)
}

/// The list plus the rules. A value type, so every rule is tested without a disk.
nonisolated struct RoutineBook: Equatable, Sendable {
    static let failuresBeforePause = 3
    static let resultLimit = 4_000

    var routines: [Routine] = []

    init(routines: [Routine] = []) {
        self.routines = routines
    }

    /// The routines owed a run now. However many slots were missed, each appears once.
    func due(now: Date, calendar: Calendar, running: Set<String> = []) -> [Routine] {
        routines.filter { routine in
            routine.enabled && !running.contains(routine.id) && routine.schedule.isDue(anchor: routine.anchor, now: now, calendar: calendar)
        }
    }

    /// The earliest moment any enabled routine wants to run.
    func nextWake(calendar: Calendar) -> Date? {
        routines.compactMap { $0.nextRun(calendar: calendar) }.min()
    }

    /// Call when a run starts, before its result is known: the slot is used up whatever happens,
    /// so a crash or a quit mid-run cannot make it fire again and again.
    mutating func markStarted(id: String, now: Date) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].lastRun = now
    }

    /// Records how a run ended. Three failures in a row pause the routine.
    mutating func record(_ outcome: RoutineRunOutcome, id: String, now: Date) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        var routine = routines[index]
        routine.lastRun = now
        routine.hasUnreadResult = true
        switch outcome {
        case .succeeded(let result):
            routine.lastResult = Self.clip(result)
            routine.lastStatus = "ok"
            routine.consecutiveFailures = 0
        case .needsPerson(let result):
            routine.lastResult = Self.clip(result)
            routine.lastStatus = "needs you"
            routine.consecutiveFailures = 0
        case .failed(let reason):
            routine.lastResult = Self.clip(reason)
            routine.lastStatus = "failed"
            routine.consecutiveFailures += 1
            if routine.consecutiveFailures >= Self.failuresBeforePause {
                routine.enabled = false
                routine.pausedReason = "Paused after \(Self.failuresBeforePause) failed runs in a row."
            }
        }
        routines[index] = routine
    }

    /// Pause or resume by hand. Resuming clears the failure count and starts the schedule
    /// from now, so a long-paused routine does not fire the moment it is switched back on.
    mutating func setEnabled(_ enabled: Bool, id: String, now: Date) {
        guard let index = routines.firstIndex(where: { $0.id == id }), routines[index].enabled != enabled else { return }
        routines[index].enabled = enabled
        routines[index].pausedReason = nil
        if enabled {
            routines[index].consecutiveFailures = 0
            routines[index].lastRun = now
        }
    }

    mutating func markRead(id: String) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].hasUnreadResult = false
    }

    mutating func remove(id: String) {
        routines.removeAll { $0.id == id }
    }

    var unreadCount: Int { routines.filter(\.hasUnreadResult).count }

    private static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > resultLimit ? String(trimmed.prefix(resultLimit)) + "…" : trimmed
    }
}

nonisolated final class RoutineStore: @unchecked Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct File: Codable {
        var version = 1
        var routines: [Routine]
    }

    /// The saved routines. A missing file is an empty list; a file that cannot be read is
    /// reported, not overwritten.
    func load() -> (book: RoutineBook, problem: String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (RoutineBook(), nil) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(File.self, from: Data(contentsOf: fileURL))
            return (RoutineBook(routines: file.routines), nil)
        } catch {
            return (RoutineBook(), "Couldn't read routines.json, so no routines will run until it is fixed: \(error.localizedDescription)")
        }
    }

    func save(_ book: RoutineBook) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(routines: book.routines)).write(to: fileURL, options: .atomic)
    }
}
