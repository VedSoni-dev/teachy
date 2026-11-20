//
//  MemoryLearning.swift
//  leanring-buddy
//
//  The rules for learning from chats: after a turn (and, a few at a time, for
//  older chats), the new messages go to a model together with what is already
//  remembered, and it answers with memory actions: new facts, updates (same
//  "Subject:" replaces the old bullet) and removals for things no longer true.
//  That is the add / update / delete loop memory layers like mem0 and
//  supermemory run, kept in the person's own Markdown files.
//
//  Pure: `Core/ChatMemoryKeeper.swift` makes the model call and applies the actions.
//  Progress per chat lives in `~/.teachy/brain/learned.json`.
//

import Foundation

/// How far each chat has been learned from: `sessionID → message count`.
nonisolated struct MemoryLearningProgress: Codable, Equatable, Sendable {
    var learnedMessageCountBySession: [String: Int] = [:]

    init(learnedMessageCountBySession: [String: Int] = [:]) {
        self.learnedMessageCountBySession = learnedMessageCountBySession
    }

    func learnedCount(for sessionID: String) -> Int { learnedMessageCountBySession[sessionID] ?? 0 }
}

nonisolated enum MemoryLearning {
    /// One model call reads at most this many new messages; longer backlogs take several passes.
    static let maximumMessagesPerPass = 30
    /// Older chats learned per maintenance pass, so a big history is caught up gradually.
    static let backfillSessionsPerPass = 2

    /// The chats with messages not yet learned from: the open chat first, then newest first.
    static func sessionsToLearn(index: ChatSessionIndex, progress: MemoryLearningProgress) -> [ChatSessionSummary] {
        let pending = index.sessionsNewestFirst.filter { $0.messageCount > progress.learnedCount(for: $0.id) }
        let open = pending.filter { $0.id == index.currentSessionID }
        let others = pending.filter { $0.id != index.currentSessionID }
        return open + Array(others.prefix(backfillSessionsPerPass))
    }

    /// The slice of a chat to learn from next, with two earlier messages for context.
    static func nextSlice(of messages: [BrainMessage], learnedCount: Int) -> (context: [BrainMessage], new: [BrainMessage], learnedThrough: Int)? {
        let start = min(max(0, learnedCount), messages.count)
        guard start < messages.count else { return nil }
        let end = min(messages.count, start + maximumMessagesPerPass)
        let context = Array(messages[max(0, start - 2)..<start])
        return (context, Array(messages[start..<end]), end)
    }

    static let systemPrompt = """
        You keep the long-term memory of Teachy, a Mac assistant, about one person. Read the new part of a conversation and decide what to remember, update or forget, so next week Teachy never has to ask again.

        Remember (one short plain fact per action):
        - likes and favourites: songs, artists, videos, shows, games, food, brands, places. If they asked for "the one I like" and the conversation shows which one, remember it ("Favourite Carti song: <title>").
        - how they want things done: which browser or app to use for what, whether Teachy may take over the mouse, how they like a job finished ("YouTube: play in my Chrome"). Corrections like "no, use my browser" are the most important thing to keep.
        - how they like answers (length, tone, language) when they say so or complain.
        - who they are: name, job, school, people they mention by name and who they are, where they live, routines.
        - what they are working on, tools and apps they use, names and spellings Teachy got wrong.
        Do not remember: one-off requests, small talk, what was on screen, things Teachy said that they did not confirm, guesses, passwords, keys, card or account numbers.

        Update instead of duplicating. CURRENT MEMORY is below. If a new fact changes one already there, start the note with the same "Subject: " so it replaces the old bullet. If something there is now wrong or they ask to forget it, emit a forget action with a few words of it.

        Answer with ONLY a JSON array of actions and nothing else, [] when nothing is worth keeping.
        """

    static func userPrompt(currentMemory: String, sessionTitle: String, context: [BrainMessage], new: [BrainMessage]) -> String {
        var parts: [String] = []
        parts.append("CURRENT MEMORY:\n" + (currentMemory.isEmpty ? "(empty)" : currentMemory))
        parts.append(BrainAction.schemaDescription)
        if !context.isEmpty {
            parts.append("EARLIER IN THE CHAT (already learned, for context only):\n" + ChatContextWindow.compactionTranscript(context))
        }
        parts.append("NEW PART OF THE CHAT \"\(sessionTitle)\":\n" + ChatContextWindow.compactionTranscript(new))
        return parts.joined(separator: "\n\n")
    }

    /// Kinds the learner may write. The short-lived logs (recent, screen) stay with the voice turn.
    static let learnableKinds: Set<BrainKind> = [.aboutMe, .answerStyle, .howToDoThings, .likes, .tools, .skills, .mistakes, .words, .project]

    /// The actions in a model answer: the first JSON array in it, code fences and chatter ignored.
    static func actions(fromModelAnswer answer: String) -> [BrainAction] {
        guard let open = answer.firstIndex(of: "["), let close = answer.lastIndex(of: "]"), open < close else { return [] }
        let json = String(answer[open...close])
        return BrainAction.decodeList(fromJSON: json).filter { action in
            switch action {
            case .remember(let kind, let note):
                return learnableKinds.contains(kind) && !looksSecret(note)
            case .forget(let phrase):
                return BrainText.normalized(phrase).count >= 4
            }
        }
    }

    /// A last guard against storing credentials the model should have skipped.
    static func looksSecret(_ note: String) -> Bool {
        let lowered = note.lowercased()
        if ["password", "passcode", "api key", "secret key", "private key", "card number", "cvv", "ssn", "pin code"].contains(where: { lowered.contains($0) }) {
            return true
        }
        // Long unbroken letter/digit runs look like keys or tokens.
        return note.split(whereSeparator: { $0.isWhitespace }).contains { $0.count >= 28 && $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) }
    }

    /// One short line for the chat thread about what was learned.
    static func timelineNote(for actions: [BrainAction]) -> String? {
        let remembered = actions.compactMap { action -> String? in
            if case .remember(_, let note) = action { return note }
            return nil
        }
        guard !remembered.isEmpty else { return nil }
        let shown = remembered.prefix(2).map { ChatContextWindow.clip(BrainText.singleLineNote($0), to: 70) }
        let extra = remembered.count > 2 ? " and \(remembered.count - 2) more" : ""
        return "Remembered: " + shown.joined(separator: "; ") + extra
    }
}
