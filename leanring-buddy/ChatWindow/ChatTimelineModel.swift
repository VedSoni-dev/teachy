//
//  ChatTimelineModel.swift
//  leanring-buddy
//
//  The data behind the chat window's thread, with no UI:
//    - the extra rows other parts of the app post (a drawing, an agent job, a note)
//      and their file, `~/.teachy/brain/timeline.jsonl`;
//    - merging those rows with the saved conversation into one thread;
//    - grouping the thread by day, and filtering it by a search;
//    - splitting a reply into paragraphs and code blocks;
//    - what Return does in the composer.
//

import Foundation

// MARK: - Rows posted by other parts of the app

nonisolated enum ChatJobStatus: String, Codable, Sendable {
    case running
    case waitingForYou
    case done
    case failed
    case stopped

    var label: String {
        switch self {
        case .running: return "Working"
        case .waitingForYou: return "Needs you"
        case .done: return "Done"
        case .failed: return "Didn't finish"
        case .stopped: return "Stopped"
        }
    }
}

/// What another part of the app can add to the thread.
nonisolated enum ChatTimelineEvent: Sendable {
    /// A drawing Teachy made. Posting the same `id` again updates the row.
    case drawing(title: String, thumbnailURL: URL?, id: String)
    /// An agent job. Post it again with the same `id` as its status changes.
    case job(title: String, status: ChatJobStatus, answer: String?, id: String)
    /// A short line in the thread ("Attached budget.pdf").
    case note(String)
}

nonisolated struct ChatTimelineRow: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case drawing
        case job
        case note
    }

    var id: String
    var kind: Kind
    var title: String
    var date: Date
    var status: ChatJobStatus?
    var answer: String?
    /// File path of a drawing's preview picture.
    var thumbnailPath: String?
    /// The saved chat that was open when this was posted. nil for rows from before chats existed.
    var sessionID: String?
}

/// Reads and writes `timeline.jsonl`: one JSON row per line, newest last.
nonisolated final class ChatTimelineStore: @unchecked Sendable {
    static let maximumRows = 300

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func rows() -> [ChatTimelineRow] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Adds the event, or updates the row that has the same id (keeping its place and time).
    @discardableResult
    func post(_ event: ChatTimelineEvent, date: Date = Date(), sessionID: String? = nil) -> ChatTimelineRow {
        lock.lock()
        defer { lock.unlock() }
        var rows = load()
        var row: ChatTimelineRow
        switch event {
        case .drawing(let title, let thumbnailURL, let id):
            row = ChatTimelineRow(id: "drawing-" + id, kind: .drawing, title: title, date: date, thumbnailPath: thumbnailURL?.path)
        case .job(let title, let status, let answer, let id):
            row = ChatTimelineRow(id: "job-" + id, kind: .job, title: title, date: date, status: status, answer: answer)
        case .note(let text):
            row = ChatTimelineRow(id: "note-" + UUID().uuidString, kind: .note, title: text, date: date)
        }
        row.sessionID = sessionID
        if let position = rows.firstIndex(where: { $0.id == row.id }) {
            row.date = rows[position].date
            // A job keeps the chat it started in, even if another chat is open when it finishes.
            row.sessionID = rows[position].sessionID ?? sessionID
            if row.thumbnailPath == nil { row.thumbnailPath = rows[position].thumbnailPath }
            if row.answer == nil { row.answer = rows[position].answer }
            rows[position] = row
        } else {
            rows.append(row)
        }
        save(Array(rows.suffix(Self.maximumRows)))
        return row
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func load() -> [ChatTimelineRow] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Self.decode(text)
    }

    private func save(_ rows: [ChatTimelineRow]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encode(rows).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func encode(_ rows: [ChatTimelineRow]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = rows.compactMap { row -> String? in
            guard let data = try? encoder.encode(row) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Lines that can't be read (a hand edit, a torn write) are skipped.
    static func decode(_ text: String) -> [ChatTimelineRow] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(ChatTimelineRow.self, from: data)
        }
    }
}

// MARK: - The thread

/// One thing shown in the thread.
nonisolated struct ChatThreadItem: Identifiable, Equatable, Sendable {
    nonisolated enum Content: Equatable, Sendable {
        case userMessage(String)
        case assistantMessage(String)
        /// A reply that is still arriving.
        case streamingReply(String)
        case row(ChatTimelineRow)
    }

    var id: String
    var date: Date
    var content: Content

    /// The text a search looks through, and what Copy puts on the clipboard.
    var plainText: String {
        switch content {
        case .userMessage(let text), .assistantMessage(let text), .streamingReply(let text):
            return text
        case .row(let row):
            return [row.title, row.answer].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

nonisolated struct ChatDay: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var items: [ChatThreadItem]
}

/// A message as the thread needs it. `BrainMessage` maps straight onto this.
nonisolated struct ChatMessage: Equatable, Sendable {
    var isFromUser: Bool
    var text: String
    var date: Date
}

nonisolated enum ChatThread {

    /// The saved conversation and the posted rows as one list, oldest first.
    /// `pendingQuestion` is a question just asked that is not saved yet;
    /// `streamingReply` is the answer arriving for it.
    static func merge(
        messages: [ChatMessage],
        rows: [ChatTimelineRow],
        pendingQuestion: (text: String, date: Date)? = nil,
        streamingReply: (text: String, date: Date)? = nil
    ) -> [ChatThreadItem] {
        var items: [ChatThreadItem] = []
        var seenIdentifiers: [String: Int] = [:]
        for message in messages {
            let base = "\(message.isFromUser ? "u" : "a")-\(Int(message.date.timeIntervalSince1970 * 1000))"
            let repeatCount = seenIdentifiers[base, default: 0]
            seenIdentifiers[base] = repeatCount + 1
            let displayText = message.isFromUser ? message.text : ChatReplyText.withoutActionTags(message.text)
            guard !displayText.isEmpty else { continue }
            items.append(ChatThreadItem(
                id: repeatCount == 0 ? base : "\(base)-\(repeatCount)",
                date: message.date,
                content: message.isFromUser ? .userMessage(displayText) : .assistantMessage(displayText)
            ))
        }
        for row in rows {
            items.append(ChatThreadItem(id: row.id, date: row.date, content: .row(row)))
        }
        // Stable: things with the same time keep the order they were given in.
        items = items.enumerated().sorted { first, second in
            first.element.date != second.element.date ? first.element.date < second.element.date : first.offset < second.offset
        }.map(\.element)

        if let pendingQuestion {
            let alreadySaved = messages.suffix(4).contains { $0.isFromUser && $0.text == pendingQuestion.text && $0.date >= pendingQuestion.date.addingTimeInterval(-2) }
            if !alreadySaved {
                items.append(ChatThreadItem(id: "pending-question", date: pendingQuestion.date, content: .userMessage(pendingQuestion.text)))
            }
        }
        if let streamingReply {
            let text = ChatReplyText.withoutActionTags(streamingReply.text)
            if !text.isEmpty {
                items.append(ChatThreadItem(id: "streaming-reply", date: streamingReply.date, content: .streamingReply(text)))
            }
        }
        return items
    }

    /// The thread split into days, oldest day first, labelled "Today", "Yesterday",
    /// a weekday within the last week, or the date.
    static func days(
        _ items: [ChatThreadItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [ChatDay] {
        var days: [ChatDay] = []
        for item in items {
            let dayStart = calendar.startOfDay(for: item.date)
            let identifier = "day-\(Int(dayStart.timeIntervalSince1970))"
            if days.last?.id == identifier {
                days[days.count - 1].items.append(item)
            } else {
                days.append(ChatDay(id: identifier, label: dayLabel(for: dayStart, now: now, calendar: calendar, locale: locale), items: [item]))
            }
        }
        return days
    }

    static func dayLabel(for dayStart: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: dayStart, to: today).day ?? 0
        if daysAgo == 0 { return "Today" }
        if daysAgo == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if daysAgo > 1 && daysAgo < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: dayStart) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        }
        return formatter.string(from: dayStart)
    }

    /// Items whose text contains every word of the search, in any order, ignoring case and accents.
    static func filter(_ items: [ChatThreadItem], matching query: String) -> [ChatThreadItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = fold(item.plainText)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - Reply text

nonisolated enum ChatReplyText {
    nonisolated enum Block: Equatable, Sendable {
        case paragraph(String)
        case code(language: String?, text: String)
    }

    private static let actionTagNames = "POINT|DO|GUIDE|CLIPBOARD|REMEMBER|FORGET|SHOW|JOB|READ|STEP|DRAW|NOTE"

    /// Removes the bracket tags the voice model adds for the app ([POINT:…], [SHOW: …]),
    /// including one that has only half arrived at the end of a streaming reply.
    static func withoutActionTags(_ text: String) -> String {
        // The space before a tag goes with it, so no double space is left behind
        // (and spaces elsewhere, such as code indentation, are never touched).
        var cleaned = text.replacingOccurrences(
            of: " ?\\[(?:\(actionTagNames))(?::[^\\]]*)?\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: " ?\\[(?:\(actionTagNames))(?::[^\\]]*)?$", with: "", options: .regularExpression)
        // A reply cut right after "[" or "[PO": nothing to show yet.
        cleaned = cleaned.replacingOccurrences(of: "\\[[A-Z]{0,9}$", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a reply at its ``` fences. A fence that never closes (still streaming) is a code block to the end.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideCode = false

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphLines = []
        }
        func flushCode() {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
            codeLines = []
            codeLanguage = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideCode {
                    flushCode()
                    insideCode = false
                } else {
                    flushParagraph()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    insideCode = true
                }
                continue
            }
            if insideCode { codeLines.append(line) } else { paragraphLines.append(line) }
        }
        if insideCode { flushCode() } else { flushParagraph() }
        return blocks
    }
}

// MARK: - Composer keys

nonisolated enum ChatComposerKeyRule {
    nonisolated enum ReturnAction: Equatable, Sendable {
        case send
        case insertNewline
        /// Let the text system handle it (an input method is mid-word).
        case passThrough
    }

    /// Return sends. Shift+Return or Option+Return adds a line. While an input
    /// method is composing (Japanese, Chinese…), Return belongs to it.
    static func action(shift: Bool, option: Bool, isComposingText: Bool) -> ReturnAction {
        if isComposingText { return .passThrough }
        if shift || option { return .insertNewline }
        return .send
    }
}
