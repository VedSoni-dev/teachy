//
//  ChatSessionStore.swift
//  leanring-buddy
//
//  Teachy's saved chats on disk, like a coding harness's session files:
//
//      ~/.teachy/brain/sessions/index.json        every chat: title, dates, summary state, which is open
//      ~/.teachy/brain/sessions/<id>.jsonl        the whole chat, one message per line, never trimmed
//      ~/.teachy/brain/JOURNAL.md                 what happened, day by day (see ChatJournal)
//
//  The rules live in ChatSessionModel.swift; this file only reads and writes.
//  Every call re-reads the files under one lock, so it is safe from any thread
//  and picks up hand edits. Never logs message text.
//

import Foundation

nonisolated final class ChatSessionStore: @unchecked Sendable {
    /// Posted on the main queue after chats change (a message, a new chat, a switch, a rename).
    static let didChangeNotification = Notification.Name("TeachyChatSessionsDidChange")

    let directoryURL: URL
    let journalFileURL: URL
    /// The Brain's older single conversation, imported once as the first chat.
    private let legacyConversationFileURL: URL?
    private let lock = NSLock()
    private let now: () -> Date

    init(directoryURL: URL, journalFileURL: URL, legacyConversationFileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.directoryURL = directoryURL
        self.journalFileURL = journalFileURL
        self.legacyConversationFileURL = legacyConversationFileURL
        self.now = now
    }

    var indexFileURL: URL { directoryURL.appendingPathComponent("index.json") }

    func transcriptFileURL(for sessionID: String) -> URL {
        directoryURL.appendingPathComponent(Self.safeFileName(sessionID) + ".jsonl")
    }

    // MARK: - Reading

    func index() -> ChatSessionIndex {
        lock.lock()
        defer { lock.unlock() }
        migrateLegacyConversationIfNeeded()
        return loadIndex()
    }

    var currentSessionID: String? { index().currentSessionID }

    var currentSession: ChatSessionSummary? {
        let loaded = index()
        return loaded.currentSessionID.flatMap { loaded.session(withID: $0) }
    }

    func messages(in sessionID: String) -> [BrainMessage] {
        lock.lock()
        defer { lock.unlock() }
        return loadTranscript(sessionID)
    }

    func currentMessages() -> [BrainMessage] {
        guard let sessionID = currentSessionID else { return [] }
        return messages(in: sessionID)
    }

    /// The chat before the open one, when it was active recently (for bridging a fresh chat).
    func previousSession(within interval: TimeInterval = 36 * 60 * 60) -> (summary: ChatSessionSummary, lastMessages: [BrainMessage])? {
        let loaded = index()
        let candidates = loaded.sessionsNewestFirst.filter { $0.id != loaded.currentSessionID && $0.messageCount > 0 }
        guard let previous = candidates.first, now().timeIntervalSince(previous.updatedAt) <= interval else { return nil }
        return (previous, Array(messages(in: previous.id).suffix(4)))
    }

    // MARK: - Changing

    /// Starts an empty chat and opens it. An open chat that is still empty is reused.
    @discardableResult
    func startNewSession() -> ChatSessionSummary {
        let created = mutateIndex { index -> ChatSessionSummary in
            if let currentID = index.currentSessionID, let current = index.session(withID: currentID), current.messageCount == 0 {
                return current
            }
            return Self.addEmptySession(to: &index, at: now())
        }
        return created
    }

    /// Opens an existing chat. Returns false when there is no such chat.
    @discardableResult
    func switchToSession(_ sessionID: String) -> Bool {
        mutateIndex { index -> Bool in
            guard index.session(withID: sessionID) != nil else { return false }
            // An empty chat left behind is not worth keeping in the list.
            if let currentID = index.currentSessionID, currentID != sessionID,
               let current = index.session(withID: currentID), current.messageCount == 0 {
                index.sessions.removeAll { $0.id == currentID }
            }
            index.currentSessionID = sessionID
            return true
        }
    }

    func renameSession(_ sessionID: String, to title: String, isAutomatic: Bool = false) {
        let cleaned = ChatContextWindow.oneLine(title).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”."))
        guard !cleaned.isEmpty else { return }
        mutateIndex { index in
            index.update(sessionID) { session in
                // A title the person typed is never replaced by a model-written one.
                if isAutomatic && !session.titleIsAutomatic { return }
                session.title = ChatContextWindow.clip(cleaned, to: 80)
                session.titleIsAutomatic = isAutomatic
            }
        }
    }

    func deleteSession(_ sessionID: String) {
        mutateIndex { index in
            index.sessions.removeAll { $0.id == sessionID }
            if index.currentSessionID == sessionID {
                index.currentSessionID = index.sessionsNewestFirst.first?.id
            }
        }
        lock.lock()
        try? FileManager.default.removeItem(at: transcriptFileURL(for: sessionID))
        lock.unlock()
    }

    /// Adds a message to the open chat. Starts a chat when none is open, and a fresh
    /// one when the open chat has sat idle past `ChatContextWindow.idleGapBeforeNewSession`.
    /// Returns the id of the chat it went into.
    @discardableResult
    func append(_ message: BrainMessage) -> String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var stored = message
        stored.text = text

        lock.lock()
        defer { lock.unlock() }
        migrateLegacyConversationIfNeeded()
        var index = loadIndex()
        var sessionID = index.currentSessionID.flatMap { index.session(withID: $0)?.id }
        if let openID = sessionID, let open = index.session(withID: openID), open.messageCount > 0,
           message.role == .user, stored.date.timeIntervalSince(open.updatedAt) > ChatContextWindow.idleGapBeforeNewSession {
            sessionID = nil
        }
        if sessionID == nil {
            sessionID = Self.addEmptySession(to: &index, at: stored.date).id
        }
        guard let targetID = sessionID else { return nil }

        guard appendLine(stored, to: transcriptFileURL(for: targetID)) else { return nil }
        index.update(targetID) { session in
            session.messageCount += 1
            session.updatedAt = stored.date
            if session.titleIsAutomatic, session.title == ChatSessionSummary.untitled, stored.role == .user {
                session.title = ChatSessionSummary.automaticTitle(fromFirstQuestion: stored.text)
            }
        }
        index.currentSessionID = targetID
        saveIndex(index)
        postDidChange()
        return targetID
    }

    /// Stores the model-written summary of the first `throughMessageCount` messages.
    func saveCompactSummary(_ summary: String, for sessionID: String, throughMessageCount: Int) {
        mutateIndex { index in
            index.update(sessionID) { session in
                guard throughMessageCount > session.summarizedMessageCount else { return }
                session.compactSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                session.summarizedMessageCount = min(throughMessageCount, session.messageCount)
            }
        }
    }

    // MARK: - Journal

    func journalText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: journalFileURL, encoding: .utf8)) ?? ""
    }

    func recentJournal(budgetCharacters: Int = ChatContextWindow.Budget().journalCharacters) -> String {
        ChatJournal.recent(journalText(), now: now(), budgetCharacters: budgetCharacters)
    }

    /// Adds lines under the day they happened and marks the chat as journaled up to `throughMessageCount`.
    func addJournalLines(_ lines: [String], on date: Date, for sessionID: String, throughMessageCount: Int) {
        lock.lock()
        let existing = (try? String(contentsOf: journalFileURL, encoding: .utf8)) ?? ""
        let updated = ChatJournal.appending(lines: lines, on: date, to: existing)
        if updated != existing { write(Data(updated.utf8), to: journalFileURL) }
        lock.unlock()
        mutateIndex { index in
            index.update(sessionID) { session in
                session.journaledMessageCount = max(session.journaledMessageCount, min(throughMessageCount, session.messageCount))
            }
        }
    }

    /// Chats with messages the journal does not cover yet, that are finished enough to write up:
    /// not the open chat, or the open chat after `quietInterval` without a message.
    func sessionsNeedingJournal(quietInterval: TimeInterval = 20 * 60) -> [ChatSessionSummary] {
        let loaded = index()
        let currentTime = now()
        return loaded.sessions.filter { session in
            guard session.messageCount > session.journaledMessageCount else { return false }
            if session.id != loaded.currentSessionID { return true }
            return currentTime.timeIntervalSince(session.updatedAt) >= quietInterval
        }
    }

    // MARK: - Search

    /// Finds messages across every chat that match the words of the query, best first.
    func search(_ query: String, limit: Int = 20, excludingSessionID: String? = nil) -> [ChatSearchHit] {
        let words = ChatSearch.meaningfulWords(in: query)
        let phrase = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || phrase.count >= 3 else { return [] }
        let searchWords = words.isEmpty ? [phrase] : words
        let loaded = index()
        var hits: [ChatSearchHit] = []
        for session in loaded.sessions where session.id != excludingSessionID {
            let titleScore = ChatSearch.score(session.title, words: searchWords, phrase: phrase)
            for message in messages(in: session.id) {
                let score = ChatSearch.score(message.text, words: searchWords, phrase: phrase)
                guard score > 0 else { continue }
                hits.append(ChatSearchHit(
                    sessionID: session.id,
                    sessionTitle: session.title,
                    isFromUser: message.role == .user,
                    snippet: ChatSearch.snippet(of: message.text, around: searchWords),
                    date: message.date,
                    score: score + titleScore
                ))
            }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
        return Array(hits.prefix(limit))
    }

    // MARK: - Forgetting

    /// Drops messages that mention the phrase from every chat ("forget X").
    func removeMessages(mentioning phrase: String) {
        lock.lock()
        defer { lock.unlock() }
        var index = loadIndex()
        var changed = false
        for session in index.sessions {
            let existing = loadTranscript(session.id)
            let kept = BrainConversationLog.removingMessages(mentioning: phrase, from: existing)
            guard kept.count != existing.count else { continue }
            write(Data(BrainConversationLog.encode(kept).utf8), to: transcriptFileURL(for: session.id))
            index.update(session.id) { summary in
                summary.messageCount = kept.count
                // The summary may hold the forgotten thing: rebuild it from what is left.
                summary.compactSummary = ""
                summary.summarizedMessageCount = 0
                summary.journaledMessageCount = min(summary.journaledMessageCount, kept.count)
            }
            changed = true
        }
        if changed {
            saveIndex(index)
            postDidChange()
        }
    }

    /// Deletes every chat and the journal.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.removeItem(at: journalFileURL)
        postDidChange()
    }

    // MARK: - File IO (callers hold the lock)

    private static func addEmptySession(to index: inout ChatSessionIndex, at date: Date) -> ChatSessionSummary {
        let session = ChatSessionSummary(id: newSessionID(at: date), title: ChatSessionSummary.untitled, createdAt: date, updatedAt: date)
        index.sessions.append(session)
        index.currentSessionID = session.id
        return session
    }

    static func newSessionID(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + UUID().uuidString.prefix(6).lowercased()
    }

    private static func safeFileName(_ sessionID: String) -> String {
        String(sessionID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    }

    @discardableResult
    private func mutateIndex<Result>(_ change: (inout ChatSessionIndex) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        migrateLegacyConversationIfNeeded()
        var index = loadIndex()
        let before = index
        let result = change(&index)
        if index != before {
            saveIndex(index)
            postDidChange()
        }
        return result
    }

    private func loadIndex() -> ChatSessionIndex {
        guard let data = try? Data(contentsOf: indexFileURL) else { return ChatSessionIndex() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ChatSessionIndex.self, from: data)) ?? ChatSessionIndex()
    }

    private func saveIndex(_ index: ChatSessionIndex) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(index) else { return }
        write(data, to: indexFileURL)
    }

    private func loadTranscript(_ sessionID: String) -> [BrainMessage] {
        guard let text = try? String(contentsOf: transcriptFileURL(for: sessionID), encoding: .utf8) else { return [] }
        return BrainConversationLog.decode(text)
    }

    private func appendLine(_ message: BrainMessage, to url: URL) -> Bool {
        let line = BrainConversationLog.encode([message])
        guard !line.isEmpty else { return false }
        ensureDirectory()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                return true
            } catch {
                print("ChatSessionStore: could not append to \(url.lastPathComponent)")
                return false
            }
        }
        return write(Data(line.utf8), to: url)
    }

    @discardableResult
    private func write(_ data: Data, to url: URL) -> Bool {
        ensureDirectory()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            print("ChatSessionStore: could not write \(url.lastPathComponent)")
            return false
        }
    }

    private func ensureDirectory() {
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        // Chats are personal: readable by this user only.
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The first time chats are used, the Brain's older rolling conversation becomes
    /// the first saved chat, so nothing said before this version is lost.
    private func migrateLegacyConversationIfNeeded() {
        guard !FileManager.default.fileExists(atPath: indexFileURL.path) else { return }
        var index = ChatSessionIndex()
        if let legacyConversationFileURL,
           let text = try? String(contentsOf: legacyConversationFileURL, encoding: .utf8) {
            let legacyMessages = BrainConversationLog.decode(text)
            if let first = legacyMessages.first, let last = legacyMessages.last {
                var session = ChatSessionSummary(
                    id: Self.newSessionID(at: first.date),
                    title: ChatSessionSummary.automaticTitle(fromFirstQuestion: legacyMessages.first { $0.role == .user }?.text ?? ""),
                    createdAt: first.date,
                    updatedAt: last.date
                )
                session.messageCount = legacyMessages.count
                write(Data(BrainConversationLog.encode(legacyMessages).utf8), to: transcriptFileURL(for: session.id))
                index.sessions.append(session)
                index.currentSessionID = session.id
            }
        }
        saveIndex(index)
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ChatSessionStore.didChangeNotification, object: nil)
        }
    }
}
