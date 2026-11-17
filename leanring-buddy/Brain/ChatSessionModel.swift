//
//  ChatSessionModel.swift
//  leanring-buddy
//
//  The pure rules behind Teachy's saved chats, with no file IO:
//    - what a chat (session) is and how the list of chats is stored;
//    - context management: which part of a long chat is sent whole, when the
//      older part should be folded into a summary, and how that summary,
//      the journal and the previous chat are put in front of the model;
//    - the journal, `JOURNAL.md`: a dated, day-by-day record of what Teachy
//      and the person did, so a fresh launch still knows about last Tuesday;
//    - searching every chat.
//
//  It works like a coding harness (Claude Code, Codex): every chat is kept in
//  full on disk, the model sees a summary of the old part plus the recent part
//  word for word, and nothing is ever silently thrown away.
//

import Foundation

// MARK: - A saved chat

nonisolated struct ChatSessionSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    /// True while the title is the first question cut short; a model-written title replaces it.
    var titleIsAutomatic: Bool
    var createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    /// The older part of the chat, folded into a few paragraphs by the model.
    /// Covers the first `summarizedMessageCount` messages.
    var compactSummary: String
    var summarizedMessageCount: Int
    /// How many messages the journal already covers.
    var journaledMessageCount: Int

    init(id: String, title: String, titleIsAutomatic: Bool = true, createdAt: Date, updatedAt: Date, messageCount: Int = 0, compactSummary: String = "", summarizedMessageCount: Int = 0, journaledMessageCount: Int = 0) {
        self.id = id
        self.title = title
        self.titleIsAutomatic = titleIsAutomatic
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.compactSummary = compactSummary
        self.summarizedMessageCount = summarizedMessageCount
        self.journaledMessageCount = journaledMessageCount
    }

    static let untitled = "New chat"
    static let automaticTitleLength = 60

    /// The first question, on one line and cut at a word, as a stand-in title.
    static func automaticTitle(fromFirstQuestion question: String) -> String {
        let oneLine = question.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !oneLine.isEmpty else { return untitled }
        guard oneLine.count > automaticTitleLength else { return oneLine }
        let cut = String(oneLine.prefix(automaticTitleLength))
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > automaticTitleLength / 2 {
            return String(cut[..<lastSpace]) + "…"
        }
        return cut + "…"
    }
}

/// `sessions/index.json`: every chat, plus which one is open.
nonisolated struct ChatSessionIndex: Codable, Equatable, Sendable {
    var currentSessionID: String?
    var sessions: [ChatSessionSummary]

    init(currentSessionID: String? = nil, sessions: [ChatSessionSummary] = []) {
        self.currentSessionID = currentSessionID
        self.sessions = sessions
    }

    /// Newest activity first, for the sidebar.
    var sessionsNewestFirst: [ChatSessionSummary] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func session(withID id: String) -> ChatSessionSummary? {
        sessions.first { $0.id == id }
    }

    mutating func update(_ id: String, _ change: (inout ChatSessionSummary) -> Void) {
        guard let position = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[position])
    }
}

// MARK: - Context management

/// Decides what of a chat goes to the model. Character counts stand in for
/// tokens (about four characters a token).
nonisolated enum ChatContextWindow {
    struct Budget: Equatable, Sendable {
        /// Recent messages sent word for word, at most this many characters.
        var recentCharacters = 14_000
        /// When the part of the chat not yet summarised grows past this, fold the older part.
        var compactionTriggerCharacters = 20_000
        /// After folding, this many newest messages stay word for word.
        var keepRecentMessages = 12
        /// Room for the journal in the prompt.
        var journalCharacters = 1_800
        /// Room for a chat summary in the prompt.
        var summaryCharacters = 3_000

        init() {}
    }

    /// A chat that sat this long gets a fresh chat on the next question, the way
    /// a coding harness starts a new session; the old one stays in history and in the journal.
    static let idleGapBeforeNewSession: TimeInterval = 6 * 60 * 60

    static func characterCount(_ messages: [BrainMessage]) -> Int {
        messages.reduce(0) { $0 + $1.text.count }
    }

    /// The messages to fold into the summary now, or nil when the chat still fits.
    /// Always leaves `keepRecentMessages` whole, and never starts a fold on an
    /// assistant reply (a question and its answer stay together).
    static func messagesToCompact(
        allMessages: [BrainMessage],
        summarizedMessageCount: Int,
        budget: Budget = Budget()
    ) -> Range<Int>? {
        let alreadySummarized = min(max(0, summarizedMessageCount), allMessages.count)
        let unsummarized = Array(allMessages[alreadySummarized...])
        guard unsummarized.count > budget.keepRecentMessages,
              characterCount(unsummarized) > budget.compactionTriggerCharacters else { return nil }
        var foldEnd = allMessages.count - budget.keepRecentMessages
        // Keep a question with its answer: if the first kept message is a reply, fold one fewer.
        while foldEnd > alreadySummarized, foldEnd < allMessages.count, allMessages[foldEnd].role == .assistant {
            foldEnd -= 1
        }
        guard foldEnd > alreadySummarized else { return nil }
        return alreadySummarized..<foldEnd
    }

    /// The recent messages sent word for word: everything after the summary,
    /// newest kept first until the budget is spent. Starts on a question.
    static func recentMessagesForModel(
        allMessages: [BrainMessage],
        summarizedMessageCount: Int,
        budget: Budget = Budget()
    ) -> [BrainMessage] {
        let alreadySummarized = min(max(0, summarizedMessageCount), allMessages.count)
        var kept: [BrainMessage] = []
        var spent = 0
        for message in allMessages[alreadySummarized...].reversed() {
            let cost = message.text.count
            if !kept.isEmpty, spent + cost > budget.recentCharacters { break }
            kept.insert(message, at: 0)
            spent += cost
        }
        while let first = kept.first, first.role == .assistant, kept.count > 1 { kept.removeFirst() }
        return kept
    }

    /// Question/answer pairs, the shape the voice turn sends as history.
    static func exchanges(from messages: [BrainMessage]) -> [(userText: String, assistantText: String)] {
        var pairs: [(userText: String, assistantText: String)] = []
        var waitingQuestion: String?
        for message in messages {
            switch message.role {
            case .user:
                waitingQuestion = waitingQuestion.map { $0 + "\n\n" + message.text } ?? message.text
            case .assistant:
                if let question = waitingQuestion {
                    pairs.append((userText: question, assistantText: message.text))
                    waitingQuestion = nil
                }
            }
        }
        return pairs
    }

    /// Phrases that mean "something we talked about before", for pulling matching
    /// old chats into the prompt.
    static let recallCues = [
        "yesterday", "last time", "last week", "earlier", "before", "remember", "we talked", "you said",
        "i told you", "the other day", "last night", "this morning", "continue", "pick up", "where we left",
        "again", "same as", "that project", "that bug", "that file"
    ]

    static func questionWantsRecall(_ question: String) -> Bool {
        let lowered = question.lowercased()
        return recallCues.contains { lowered.contains($0) }
    }

    /// The prompt section that carries the chat across its own length and across days.
    static func promptSection(
        sessionSummary: String,
        journal: String,
        previousSession: (title: String, updatedAt: Date, lastMessages: [BrainMessage])?,
        recalled: [ChatSearchHit],
        now: Date,
        budget: Budget = Budget()
    ) -> String {
        var parts: [String] = []
        let trimmedSummary = sessionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            parts.append("EARLIER IN THIS CHAT (summary of the part no longer shown word for word):\n" + clip(trimmedSummary, to: budget.summaryCharacters))
        }
        if let previousSession, !previousSession.lastMessages.isEmpty {
            let lines = previousSession.lastMessages.map { message in
                (message.role == .user ? "Them: " : "You: ") + clip(oneLine(message.text), to: 300)
            }
            parts.append("YOUR PREVIOUS CHAT (\"\(previousSession.title)\", \(relativeDay(previousSession.updatedAt, now: now))), how it ended:\n" + lines.joined(separator: "\n"))
        }
        if !recalled.isEmpty {
            let lines = recalled.map { hit in
                "- \(relativeDay(hit.date, now: now)), in \"\(hit.sessionTitle)\": " + (hit.isFromUser ? "they said " : "you said ") + "\"\(clip(oneLine(hit.snippet), to: 240))\""
            }
            parts.append("FROM OLDER CHATS (found because the question points back to them):\n" + lines.joined(separator: "\n"))
        }
        let trimmedJournal = journal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedJournal.isEmpty {
            parts.append("YOUR JOURNAL (what you and they did on recent days; today is \(ChatJournal.dayFormatter.string(from: now))):\n" + trimmedJournal)
        }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n\n")
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    static func relativeDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfThatDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfThatDay, to: startOfToday).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2...6: return "\(days) days ago"
        default: return "on " + ChatJournal.dayFormatter.string(from: date)
        }
    }

    /// Text sent to the model when folding part of a chat.
    static func compactionTranscript(_ messages: [BrainMessage]) -> String {
        messages.map { message in
            (message.role == .user ? "THEM: " : "TEACHY: ") + clip(message.text, to: 3_000)
        }.joined(separator: "\n\n")
    }

    static let compactionSystemPrompt = """
        You keep the running summary of a long conversation between a person and Teachy, their Mac assistant, so Teachy can keep going after the older messages are taken out of its view.
        You get the summary so far (may be empty) and the next part of the conversation. Write the new summary that replaces both.
        Keep: what they are working on and why; decisions made; facts, names, file paths, commands, URLs, numbers and code identifiers exactly as written; what was tried and whether it worked; open questions and what was promised next; how they like answers.
        Drop greetings, filler, and anything finished that will not matter again.
        Plain text, short paragraphs or "- " bullets, at most about 350 words. No preamble.
        """

    static let journalSystemPrompt = """
        You write Teachy's journal: a few dated lines that let Teachy remember, days later, what it did with this person.
        You get part of one conversation. Write 1 to 3 lines, each starting with "- ", each one plain sentence in past tense about what they worked on, what got done or decided, and anything left open (name projects, files, apps, people and places exactly).
        Skip small talk. If nothing worth remembering happened, answer exactly: NOTHING
        """

    static let titleSystemPrompt = """
        Give this conversation a short title, 2 to 6 words, like a chat title in a sidebar. Name the actual subject (a project, a bug, an app, a topic). No quotes, no trailing punctuation.
        """
}

// MARK: - Search across chats

nonisolated struct ChatSearchHit: Equatable, Sendable {
    var sessionID: String
    var sessionTitle: String
    var isFromUser: Bool
    var snippet: String
    var date: Date
    var score: Int
}

nonisolated enum ChatSearch {
    static let ignoredWords: Set<String> = [
        "the", "and", "for", "you", "that", "this", "with", "what", "was", "were", "are", "did", "can", "how",
        "about", "from", "have", "has", "had", "but", "not", "yesterday", "last", "time", "remember", "earlier",
        "before", "again", "told", "said", "talked", "week", "day", "night", "morning", "continue", "where",
        "left", "off", "pick", "same", "our", "your", "my", "me", "it", "is", "of", "to", "in", "on", "we", "a", "an"
    ]

    static func meaningfulWords(in query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "._-/")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "._-/")) }
            .filter { $0.count >= 3 && !ignoredWords.contains($0) }
    }

    /// Scores one message: the number of query words it contains (a whole-phrase match counts extra).
    static func score(_ text: String, words: [String], phrase: String) -> Int {
        let lowered = text.lowercased()
        var total = words.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
        if phrase.count >= 4, lowered.contains(phrase) { total += 3 }
        return total
    }

    /// A short window of the message around the first matching word.
    static func snippet(of text: String, around words: [String], radius: Int = 110) -> String {
        let flat = ChatContextWindow.oneLine(text)
        let lowered = flat.lowercased()
        guard let firstMatch = words.compactMap({ lowered.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return ChatContextWindow.clip(flat, to: radius * 2)
        }
        let matchOffset = lowered.distance(from: lowered.startIndex, to: firstMatch.lowerBound)
        let startOffset = max(0, matchOffset - radius)
        let endOffset = min(flat.count, matchOffset + radius)
        let start = flat.index(flat.startIndex, offsetBy: startOffset)
        let end = flat.index(flat.startIndex, offsetBy: endOffset)
        return (startOffset > 0 ? "…" : "") + String(flat[start..<end]) + (endOffset < flat.count ? "…" : "")
    }
}

// MARK: - Journal

/// `JOURNAL.md`: one `## yyyy-MM-dd` section per day, newest last, "- " lines in each.
/// The person can read and edit it like the other Brain files.
nonisolated enum ChatJournal {
    static let header = """
        # Journal

        What Teachy and you did, day by day. Teachy adds to this after each chat; edit or delete anything.

        """

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return formatter
    }()

    static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    struct Day: Equatable, Sendable {
        /// "2026-11-16"
        var key: String
        /// The heading after "## ", e.g. "2026-11-16 (Monday)".
        var heading: String
        var lines: [String]
    }

    static func parse(_ markdown: String) -> (preamble: String, days: [Day]) {
        var preambleLines: [String] = []
        var days: [Day] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                days.append(Day(key: String(heading.prefix(10)), heading: heading, lines: []))
            } else if !days.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { days[days.count - 1].lines.append(trimmed) }
            } else {
                preambleLines.append(line)
            }
        }
        let preamble = preambleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (preamble, days)
    }

    static func render(preamble: String, days: [Day]) -> String {
        var text = (preamble.isEmpty ? header.trimmingCharacters(in: .whitespacesAndNewlines) : preamble) + "\n"
        for day in days where !day.lines.isEmpty {
            text += "\n## \(day.heading)\n" + day.lines.joined(separator: "\n") + "\n"
        }
        return text
    }

    /// The journal with these lines added under the day of `date` (in date order,
    /// duplicates skipped). Keeps the last `maximumDays` days.
    static func appending(lines newLines: [String], on date: Date, to markdown: String, maximumDays: Int = 400) -> String {
        let cleaned = newLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? $0 : "- " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")) }
        var uniqueLines: [String] = []
        for line in cleaned where !uniqueLines.contains(line) { uniqueLines.append(line) }
        guard !uniqueLines.isEmpty else { return markdown }
        var (preamble, days) = parse(markdown)
        let key = dayKeyFormatter.string(from: date)
        if let position = days.firstIndex(where: { $0.key == key }) {
            for line in uniqueLines where !days[position].lines.contains(line) { days[position].lines.append(line) }
        } else {
            days.append(Day(key: key, heading: dayFormatter.string(from: date), lines: uniqueLines))
            days.sort { $0.key < $1.key }
        }
        return render(preamble: preamble, days: Array(days.suffix(maximumDays)))
    }

    /// The newest days that fit the budget, oldest first, for the prompt.
    static func recent(_ markdown: String, now: Date, maximumDays: Int = 14, budgetCharacters: Int = 1_800) -> String {
        let days = parse(markdown).days.filter { !$0.lines.isEmpty }
        var chosen: [String] = []
        var spent = 0
        for day in days.suffix(maximumDays).reversed() {
            let block = "\(day.heading):\n" + day.lines.joined(separator: "\n")
            if spent + block.count > budgetCharacters {
                // Fit what we can of the newest day rather than nothing at all.
                if chosen.isEmpty { chosen.append(ChatContextWindow.clip(block, to: budgetCharacters)) }
                break
            }
            chosen.insert(block, at: 0)
            spent += block.count + 1
        }
        return chosen.joined(separator: "\n")
    }

    /// The model's journal answer as "- " lines; empty when it said NOTHING.
    static func lines(fromModelAnswer answer: String) -> [String] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.uppercased() != "NOTHING" else { return [] }
        return trimmed.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased() != "NOTHING" }
            .map { line in
                let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
                return "- " + body
            }
            .prefix(3)
            .map { $0 }
    }
}
