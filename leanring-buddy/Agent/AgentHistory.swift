//
//  AgentHistory.swift
//  leanring-buddy
//
//  Every finished job is written to ~/.teachy/agents/history/<date>-<id>.json:
//  what was asked, the plan, each step (tool + a short result), the answer and
//  how it ended. The newest 200 are kept. Foundation only; the folder is
//  injected so tests use a temp directory.
//

import Foundation

nonisolated struct AgentJobRecord: Codable, Equatable, Identifiable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var tool: String
        /// A short version of what the tool returned.
        var result: String
        var seconds: Double
    }

    struct PlanStep: Codable, Equatable, Sendable {
        var text: String
        /// "pending", "current" or "done".
        var state: String
    }

    var id: String
    var title: String
    var request: String
    /// The named agent this ran as, if any.
    var agentSlug: String?
    var agentName: String?
    /// Set when a routine started it.
    var routineID: String?
    var projectID: String?
    var plan: [PlanStep]
    var steps: [Step]
    var answer: String
    /// "done", "failed", "stopped" or "running".
    var status: String
    /// Why it failed or stopped. Empty when done.
    var statusDetail: String
    /// Things the gate refused (unattended runs cannot ask).
    var refusals: [String]
    /// What the person added after the first request.
    var followUps: [String]
    var startedAt: Date
    var finishedAt: Date?

    static let stepResultLimit = 280

    static func shortResult(_ text: String) -> String {
        let squeezed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard squeezed.count > stepResultLimit else { return squeezed }
        return String(squeezed.prefix(stepResultLimit - 1)) + "…"
    }
}

nonisolated final class AgentHistoryStore: @unchecked Sendable {
    static let defaultCap = 200

    let directory: URL
    let cap: Int
    private let lock = NSLock()

    init(directory: URL, cap: Int = AgentHistoryStore.defaultCap) {
        self.directory = directory
        self.cap = max(1, cap)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// "2026-11-14-3F2A9C1B.json": the day it started, then the start of its id.
    static func fileName(for record: AgentJobRecord, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let safeID = record.id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(formatter.string(from: record.startedAt))-\(safeID.isEmpty ? "job" : safeID).json"
    }

    /// Writes (or rewrites, after a follow-up) one job, then drops the oldest past the cap.
    func save(_ record: AgentJobRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(for: record))
        try Self.makeEncoder().encode(record).write(to: url, options: .atomic)
        pruneLocked()
    }

    /// Newest first.
    func list(limit: Int? = nil) -> [AgentJobRecord] {
        lock.lock(); defer { lock.unlock() }
        let decoder = Self.makeDecoder()
        let records = jsonFilesLocked()
            .compactMap { try? decoder.decode(AgentJobRecord.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
        return limit.map { Array(records.prefix($0)) } ?? records
    }

    func record(id: String) -> AgentJobRecord? {
        list().first { $0.id == id }
    }

    func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        let decoder = Self.makeDecoder()
        for url in jsonFilesLocked() {
            if let record = try? decoder.decode(AgentJobRecord.self, from: Data(contentsOf: url)), record.id == id {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Which files go when there are more than `cap`: the oldest by start time. A file that
    /// cannot be read counts as oldest. Pure, so the rule is tested without a disk.
    static func namesToPrune(_ entries: [(name: String, startedAt: Date?)], cap: Int) -> [String] {
        guard entries.count > cap else { return [] }
        let oldestFirst = entries.sorted { lhs, rhs in
            let left = lhs.startedAt ?? .distantPast, right = rhs.startedAt ?? .distantPast
            return left == right ? lhs.name < rhs.name : left < right
        }
        return oldestFirst.prefix(entries.count - cap).map(\.name)
    }

    private func jsonFilesLocked() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "json" }
    }

    private func pruneLocked() {
        let files = jsonFilesLocked()
        guard files.count > cap else { return }
        let decoder = Self.makeDecoder()
        let entries = files.map { url -> (name: String, startedAt: Date?) in
            let record = try? decoder.decode(AgentJobRecord.self, from: Data(contentsOf: url))
            return (url.lastPathComponent, record?.startedAt)
        }
        for name in Self.namesToPrune(entries, cap: cap) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
