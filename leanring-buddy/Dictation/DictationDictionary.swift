//
//  DictationDictionary.swift
//  leanring-buddy
//
//  The person's dictation words (names, jargon) and the local transcript backup.
//  Plain files under ~/.teachy/dictation that the person can read and edit:
//    dictionary.json  a JSON list of words or phrases
//    history.jsonl    one JSON object per finished dictation
//  Foundation only.
//

import Foundation

nonisolated enum DictationPaths {
    /// ~/.teachy/dictation (same home-relative convention as TeachyDataPaths).
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teachy/dictation", isDirectory: true)
    }

    static var dictionaryURL: URL { directoryURL.appendingPathComponent("dictionary.json") }
    static var historyURL: URL { directoryURL.appendingPathComponent("history.jsonl") }
    static var dictionaryDisplayPath: String { "~/.teachy/dictation/dictionary.json" }
}

nonisolated final class DictationDictionary: @unchecked Sendable {
    static let shared = DictationDictionary(fileURL: DictationPaths.dictionaryURL)

    static let maximumWords = 500
    /// Transcription prompts are short; the newest words win.
    static let maximumPromptCharacters = 800

    private let fileURL: URL
    private let lock = NSLock()
    private var storedWords: [String] = []
    private var loadedModificationDate: Date?

    init(fileURL: URL) {
        self.fileURL = fileURL
        lock.lock()
        reloadIfChangedLocked()
        lock.unlock()
    }

    /// Oldest first. Re-reads the file if the person edited it by hand.
    var words: [String] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedLocked()
        return storedWords
    }

    /// Returns true if the word was added (false if empty or already there).
    @discardableResult
    func add(_ word: String) -> Bool {
        let cleaned = Self.normalize(word)
        guard !cleaned.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedLocked()
        if let existing = storedWords.firstIndex(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            // Same word with new capitals replaces the old spelling.
            guard storedWords[existing] != cleaned else { return false }
            storedWords.remove(at: existing)
        }
        storedWords.append(cleaned)
        if storedWords.count > Self.maximumWords {
            storedWords.removeFirst(storedWords.count - Self.maximumWords)
        }
        saveLocked()
        return true
    }

    @discardableResult
    func remove(_ word: String) -> Bool {
        let cleaned = Self.normalize(word)
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedLocked()
        let before = storedWords.count
        storedWords.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
        guard storedWords.count != before else { return false }
        saveLocked()
        return true
    }

    /// The words as a transcription prompt, newest first, or nil when empty.
    var transcriptionPrompt: String? {
        Self.prompt(from: words)
    }

    static func prompt(from words: [String]) -> String? {
        var chosen: [String] = []
        var length = 0
        for word in words.reversed() {
            let added = word.count + 2
            if length + added > maximumPromptCharacters { break }
            chosen.append(word)
            length += added
        }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }

    static func normalize(_ word: String) -> String {
        let collapsed = word.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(80))
    }

    private func reloadIfChangedLocked() {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard modificationDate != loadedModificationDate || modificationDate == nil else { return }
        loadedModificationDate = modificationDate
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            if modificationDate == nil { storedWords = [] }
            return
        }
        var seen = Set<String>()
        storedWords = list.compactMap { $0 as? String }
            .map(Self.normalize)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func saveLocked() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: storedWords, options: [.prettyPrinted])
            try data.write(to: fileURL, options: .atomic)
            loadedModificationDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        } catch {
            print("⚠️ Dictation: couldn't save the dictionary: \(error.localizedDescription)")
        }
    }
}

/// Appends every finished dictation to history.jsonl so nothing said is lost.
nonisolated final class DictationHistoryLog: @unchecked Sendable {
    static let shared = DictationHistoryLog(fileURL: DictationPaths.historyURL)

    struct Entry {
        var date = Date()
        var appBundleIdentifier: String?
        var raw: String
        var cleaned: String
        /// "publik" or "apple".
        var transcriber: String
        /// "accessibility", "paste", "clipboard" or "none".
        var insertion: String
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func line(for entry: Entry) -> Data? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "timestamp": formatter.string(from: entry.date),
            "app": entry.appBundleIdentifier ?? "",
            "raw": entry.raw,
            "cleaned": entry.cleaned,
            "transcriber": entry.transcriber,
            "insertion": entry.insertion,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    @discardableResult
    func append(_ entry: Entry) -> Bool {
        guard let line = Self.line(for: entry) else { return false }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
                return true
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return true
        } catch {
            print("⚠️ Dictation: couldn't save the transcript backup: \(error.localizedDescription)")
            return false
        }
    }
}
