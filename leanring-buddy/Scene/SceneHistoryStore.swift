//
//  SceneHistoryStore.swift
//  leanring-buddy / Scene
//
//  The files behind the drawing history (see SceneHistory.swift for the layout).
//  Plain Foundation, so the tests can run it against a temp folder.
//

import Foundation

struct SceneHistoryEntry: Identifiable, Codable, Equatable {
    /// The folder name: "<yyyy-MM-dd>-<id>".
    var id: String
    var title: String
    var question: String
    var date: Date
    /// Seconds the drawing took to build.
    var duration: Double
    /// "3D model", "card" or "screen marks".
    var kind: String
    var narrationSampleRate: Double?

    var hasNarration: Bool { (narrationSampleRate ?? 0) > 0 }
}

struct SceneHistoryStore {
    let root: URL
    /// Older drawings beyond this many are removed when a new one is saved.
    var limit = 200

    init(root: URL) { self.root = root }

    /// ~/.teachy/drawings, unless TEACHY_DRAWINGS_DIR names another folder (tests use a temp one).
    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["TEACHY_DRAWINGS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teachy/drawings", isDirectory: true)
    }

    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func thumbnailURL(for id: String) -> URL { folder(for: id).appendingPathComponent("thumb.png") }
    func videoURL(for id: String) -> URL { folder(for: id).appendingPathComponent("video.mp4") }

    /// "2026-11-14-3fa9c2d1". The date is the local calendar day.
    static func makeID(date: Date, random: UInt32 = .random(in: .min ... .max), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date))-\(String(format: "%08x", random))"
    }

    /// Ids are folder names this store made itself; anything else (a path, "..") is refused.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^\d{4}-\d{2}-\d{2}-[0-9a-f]{8}$"#, options: .regularExpression) != nil
    }

    static func kind(of log: SceneReplayLog) -> String {
        let verbs = log.entries.map(\.command.verb)
        if verbs.contains(.scene3d) || verbs.contains(where: { $0.makes3DPart }) { return "3D model" }
        if verbs.contains(.card) || verbs.contains(where: { $0.family == .card }) { return "card" }
        return "screen marks"
    }

    /// Writes a drawing. Returns nil when there is nothing worth keeping or the folder cannot be written.
    @discardableResult
    func save(log: SceneReplayLog, question: String, thumbnailPNG: Data?, narration: SceneNarrationAudio = SceneNarrationAudio(),
              date: Date = Date()) -> SceneHistoryEntry? {
        guard log.entries.contains(where: { $0.command.verb != .say }) else { return nil }
        let id = Self.makeID(date: date)
        let folder = folder(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let title = (log.title?.isEmpty == false ? log.title : nil) ?? Self.titleFromQuestion(question)
            let entry = SceneHistoryEntry(id: id, title: title, question: question, date: date, duration: log.duration, kind: Self.kind(of: log),
                                          narrationSampleRate: narration.isEmpty ? nil : narration.sampleRate)
            try log.encoded().write(to: folder.appendingPathComponent("scene.json"), options: .atomic)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entry).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
            if let thumbnailPNG { try thumbnailPNG.write(to: thumbnailURL(for: id), options: .atomic) }
            if !narration.isEmpty { try narration.data().write(to: folder.appendingPathComponent("narration.pcm"), options: .atomic) }
            prune()
            return entry
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    static func titleFromQuestion(_ question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Drawing" }
        let short = trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
        return short.prefix(1).uppercased() + short.dropFirst()
    }

    /// Newest first.
    func entries() -> [SceneHistoryEntry] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder -> SceneHistoryEntry? in
            guard Self.isValidID(folder.lastPathComponent), let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  var entry = try? decoder.decode(SceneHistoryEntry.self, from: data) else { return nil }
            entry.id = folder.lastPathComponent
            return entry
        }
        .sorted { $0.date > $1.date || ($0.date == $1.date && $0.id > $1.id) }
    }

    func log(for id: String) -> SceneReplayLog? {
        guard Self.isValidID(id), let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("scene.json")) else { return nil }
        return try? SceneReplayLog.decoded(from: data)
    }

    func narration(for entry: SceneHistoryEntry) -> SceneNarrationAudio {
        guard Self.isValidID(entry.id), let rate = entry.narrationSampleRate, rate > 0,
              let data = try? Data(contentsOf: folder(for: entry.id).appendingPathComponent("narration.pcm")) else { return SceneNarrationAudio() }
        return SceneNarrationAudio(track: data, sampleRate: rate)
    }

    func delete(_ id: String) {
        guard Self.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    private func prune() {
        let all = entries()
        guard all.count > limit else { return }
        for entry in all.dropFirst(limit) { delete(entry.id) }
    }
}

