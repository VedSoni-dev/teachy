//
//  PastChatsTool.swift
//  leanring-buddy
//
//  Lets an agent job look back through the person's saved chats with Teachy
//  (`BrainStore.shared.sessions`), the way a coding harness can resume an old
//  session: "carry on with the bug from yesterday" finds what was said.
//  Read-only: it never changes a chat.
//

import Foundation

final class SearchPastChatsTool: BackgroundAgentTool {
    let name = "search_past_chats"
    let description = "Search the person's earlier chats with Teachy (every saved chat, across days) for what was said about something: a project, a bug, a file, a decision. Returns matching lines with the chat title and date, best first. Pass session_id instead to read the end of one chat."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Words to look for, e.g. \"login test teachy\""
            ],
            "session_id": [
                "type": "string",
                "description": "Read the last messages of this chat (from an earlier search result) instead of searching"
            ]
        ]
    ]

    static let maximumHits = 12
    static let messagesReadFromOneChat = 16

    func execute(arguments: [String: Any]) async throws -> String {
        let store = BrainStore.shared.sessions
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        if let sessionID = (arguments["session_id"] as? String)?.trimmingCharacters(in: .whitespaces), !sessionID.isEmpty {
            guard let session = store.index().session(withID: sessionID) else {
                return "No chat with id \(sessionID). Search first to get an id."
            }
            let lastMessages = store.messages(in: sessionID).suffix(Self.messagesReadFromOneChat)
            var lines = ["Chat \"\(session.title)\" (\(session.messageCount) messages, last \(formatter.string(from: session.updatedAt))):"]
            if !session.compactSummary.isEmpty { lines.append("Summary of the earlier part: " + session.compactSummary) }
            for message in lastMessages {
                lines.append((message.role == .user ? "THEM: " : "TEACHY: ") + ChatContextWindow.clip(message.text, to: 1_500))
            }
            return lines.joined(separator: "\n")
        }

        let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Give a query, or a session_id to read." }
        let hits = store.search(query, limit: Self.maximumHits)
        guard !hits.isEmpty else {
            let journal = store.recentJournal()
            return "No earlier chat mentions that." + (journal.isEmpty ? "" : " Recent journal:\n" + journal)
        }
        return hits.map { hit in
            "[\(formatter.string(from: hit.date))] \"\(hit.sessionTitle)\" (session_id \(hit.sessionID)) — " + (hit.isFromUser ? "they said: " : "Teachy said: ") + hit.snippet
        }.joined(separator: "\n")
    }

    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult {
        .textOnly(try await execute(arguments: arguments))
    }
}
