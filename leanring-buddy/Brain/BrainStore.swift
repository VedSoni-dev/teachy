//
//  BrainStore.swift
//  leanring-buddy
//
//  Teachy's memory on disk: two plain Markdown files the person can open and
//  edit (`PROFILE.md`, `VOLATILE.md`) plus a rolling conversation window, all
//  under `~/.teachy/brain/`.
//
//  The files are the source of truth. Nothing is cached: every call re-reads
//  the file, so hand edits made in any editor are picked up on the next call,
//  and every change is a read-modify-atomic-write under one lock.
//
//  All methods are synchronous and safe to call from any thread. The files are
//  a few kilobytes, so the IO is cheap enough for the main thread.
//
//  Privacy: this file never logs memory contents — only file names on failure.
//

import Foundation

nonisolated final class BrainStore: @unchecked Sendable {
    /// The app's memory. First use creates `~/.teachy/brain/` lazily on write and
    /// runs the one-time import from the older stores (see `BrainMigration`).
    static let shared: BrainStore = {
        let store = BrainStore(directoryURL: TeachyDataPaths.brainDirectoryURL)
        BrainMigration.runIfNeeded(into: store)
        return store
    }()

    /// Posted on the main queue after memory changes through this store.
    static let didChangeNotification = Notification.Name("TeachyBrainStoreDidChange")

    let directoryURL: URL
    private let lock = NSLock()
    /// Every chat in full, its summaries and the day-by-day journal (`sessions/`, `JOURNAL.md`).
    /// `conversation.jsonl` stays as the short rolling window across all chats.
    let sessions: ChatSessionStore

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.sessions = ChatSessionStore(
            directoryURL: directoryURL.appendingPathComponent("sessions", isDirectory: true),
            journalFileURL: directoryURL.appendingPathComponent("JOURNAL.md"),
            legacyConversationFileURL: directoryURL.appendingPathComponent("conversation.jsonl")
        )
    }

    var profileFileURL: URL { fileURL(for: .profile) }
    var volatileFileURL: URL { fileURL(for: .volatile) }
    var conversationFileURL: URL { directoryURL.appendingPathComponent("conversation.jsonl") }

    func fileURL(for file: BrainFile) -> URL {
        directoryURL.appendingPathComponent(file.fileName)
    }

    // MARK: - Remember and forget

    /// Remembers one note in the section for `kind`. Near-identical notes are
    /// not added twice (a repeated mistake gets a "(xN)" count instead), and
    /// "Subject: value" replaces the older bullet about the same subject.
    @discardableResult
    func remember(_ note: String, kind: BrainKind, date: Date = Date()) -> BrainRememberOutcome {
        updateMemory { $0.remember(note, kind: kind, date: date) } ?? .rejected
    }

    /// Removes every bullet that mentions the phrase (from both files, and the
    /// matching messages from the saved conversation). Returns the removed bullets.
    @discardableResult
    func forget(matching phrase: String) -> [String] {
        let removedTexts = updateMemory { $0.forget(matching: phrase) } ?? []
        forgetConversationMessages(mentioning: phrase)
        sessions.removeMessages(mentioning: phrase)
        return removedTexts
    }

    /// Resets both files to their empty templates and deletes the saved conversation.
    @discardableResult
    func forgetEverything() -> Bool {
        sessions.removeAll()
        lock.lock()
        defer { lock.unlock() }
        var didSucceed = true
        for file in BrainFile.allCases {
            didSucceed = write(file.template, to: fileURL(for: file)) && didSucceed
        }
        if FileManager.default.fileExists(atPath: conversationFileURL.path) {
            didSucceed = ((try? FileManager.default.removeItem(at: conversationFileURL)) != nil) && didSucceed
        }
        postDidChange()
        return didSucceed
    }

    // MARK: - For the turn engine

    /// The memory text to inject into every model call. Empty when nothing is
    /// remembered. See `BrainMemory.promptContext` for the budget rules.
    func promptContext(budgetCharacters: Int = 2400) -> String {
        lock.lock()
        defer { lock.unlock() }
        return loadMemory()?.memory.promptContext(budgetCharacters: budgetCharacters) ?? ""
    }

    /// Short static text describing the memory actions, for the system prompt.
    var actionSchemaDescription: String { BrainAction.schemaDescription }
    static var actionSchemaDescription: String { BrainAction.schemaDescription }

    /// Applies the memory actions the model emitted, in order, in one write.
    @discardableResult
    func apply(actions: [BrainAction]) -> BrainApplyResult {
        guard !actions.isEmpty else { return BrainApplyResult() }
        var forgottenPhrases: [String] = []
        let result = updateMemory { memory -> BrainApplyResult in
            var result = BrainApplyResult()
            for action in actions {
                switch action {
                case .remember(let kind, let note):
                    result.rememberOutcomes.append(memory.remember(note, kind: kind))
                case .forget(let phrase):
                    result.forgotten.append(contentsOf: memory.forget(matching: phrase))
                    forgottenPhrases.append(phrase)
                }
            }
            return result
        }
        for phrase in forgottenPhrases {
            forgetConversationMessages(mentioning: phrase)
        }
        return result ?? BrainApplyResult(
            rememberOutcomes: actions.compactMap { action -> BrainRememberOutcome? in
                if case .remember = action { return .rejected }
                return nil
            }
        )
    }

    /// Remembers several notes in one write. Returns false when memory could not be read or written.
    @discardableResult
    func rememberAll(_ entries: [(note: String, kind: BrainKind, date: Date)]) -> Bool {
        updateMemory { memory in
            for entry in entries {
                memory.remember(entry.note, kind: entry.kind, date: entry.date)
            }
            return true
        } ?? false
    }

    /// Every remembered bullet in both files with its section title, for recall.
    func rememberedItems() -> [(section: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        guard let memory = loadMemory()?.memory else { return [] }
        var items: [(section: String, text: String)] = []
        for file in BrainFile.allCases {
            let document = memory[file]
            for sectionIndex in document.sections.indices {
                let title = document.sections[sectionIndex].title
                for item in document.items(inSectionAt: sectionIndex) where item.isBullet {
                    items.append((title, item.text))
                }
            }
        }
        return items
    }

    // MARK: - For the UI

    /// How many things are remembered across both files.
    var rememberedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadMemory()?.memory.itemCount ?? 0
    }

    /// Creates the folder and any missing memory file (from its template) so
    /// there is always something to open in an editor.
    @discardableResult
    func ensureFilesExist() -> Bool {
        updateMemory { _ in true } ?? false
    }

    // MARK: - Conversation window

    /// The last messages of the conversation, oldest first, persisted across launches.
    var recentConversation: [BrainMessage] { recentMessages() }

    func recentMessages(limit: Int = BrainConversationLog.windowSize) -> [BrainMessage] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadConversation().suffix(max(0, limit)))
    }

    func appendMessage(role: BrainMessage.Role, text: String, date: Date = Date()) {
        appendMessage(BrainMessage(role: role, text: text, date: date))
    }

    func appendMessage(_ message: BrainMessage) {
        // The full chat (kept whole, with history and summaries) and the short rolling window.
        sessions.append(message)
        lock.lock()
        defer { lock.unlock() }
        let existingMessages = loadConversation()
        let trimmedMessages = BrainConversationLog.appending(message, to: existingMessages)
        guard trimmedMessages != existingMessages else { return }
        write(BrainConversationLog.encode(trimmedMessages), to: conversationFileURL)
    }

    private func forgetConversationMessages(mentioning phrase: String) {
        lock.lock()
        defer { lock.unlock() }
        let existingMessages = loadConversation()
        let keptMessages = BrainConversationLog.removingMessages(mentioning: phrase, from: existingMessages)
        guard keptMessages.count != existingMessages.count else { return }
        write(BrainConversationLog.encode(keptMessages), to: conversationFileURL)
    }

    private func loadConversation() -> [BrainMessage] {
        guard let jsonLines = try? String(contentsOf: conversationFileURL, encoding: .utf8) else { return [] }
        return BrainConversationLog.decode(jsonLines)
    }

    // MARK: - File IO

    nonisolated private struct LoadedMemory {
        var memory: BrainMemory
        /// The text each file had on disk; nil for a file that does not exist yet.
        var textOnDisk: [BrainFile: String]
    }

    /// Reads both files. A missing file reads as its empty template. Returns nil
    /// when a file exists but cannot be read as text — in that case nothing is
    /// written either, so a file we do not understand is never overwritten.
    private func loadMemory() -> LoadedMemory? {
        var memory = BrainMemory()
        var textOnDisk: [BrainFile: String] = [:]
        for file in BrainFile.allCases {
            let url = fileURL(for: file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                print("BrainStore: could not read \(file.fileName); leaving it untouched")
                return nil
            }
            textOnDisk[file] = text
            memory[file] = BrainDocument(markdown: text)
        }
        return LoadedMemory(memory: memory, textOnDisk: textOnDisk)
    }

    /// Read → change → write back only the files whose text changed (or that did not exist).
    private func updateMemory<Result>(_ change: (inout BrainMemory) -> Result) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard var loaded = loadMemory() else { return nil }
        let result = change(&loaded.memory)

        var didWriteAnything = false
        for file in BrainFile.allCases {
            let newText = loaded.memory[file].markdown
            guard newText != loaded.textOnDisk[file] else { continue }
            guard write(newText, to: fileURL(for: file)) else { return nil }
            didWriteAnything = true
        }
        if didWriteAnything { postDidChange() }
        return result
    }

    @discardableResult
    private func write(_ text: String, to url: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                // Memory is personal: readable by this user only.
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try Data(text.utf8).write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            print("BrainStore: could not write \(url.lastPathComponent)")
            return false
        }
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: BrainStore.didChangeNotification, object: nil)
        }
    }
}
