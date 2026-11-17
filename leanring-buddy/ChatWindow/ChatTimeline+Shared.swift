//
//  ChatTimeline+Shared.swift
//  leanring-buddy
//
//  The app's one timeline: the open saved chat (`BrainStore.shared.sessions`)
//  plus `~/.teachy/brain/timeline.jsonl`. Kept apart from ChatTimeline.swift so
//  the timeline can be built and tested without the Brain.
//

import Foundation

extension ChatTimeline {
    static let shared = ChatTimeline(
        loadMessages: {
            BrainStore.shared.sessions.currentMessages().map {
                ChatMessage(isFromUser: $0.role == .user, text: $0.text, date: $0.date)
            }
        },
        // Rewritten on every message, chat switch and rename, so polling it catches all changes.
        conversationFileURL: BrainStore.shared.sessions.indexFileURL,
        store: ChatTimelineStore(fileURL: TeachyDataPaths.brainDirectoryURL.appendingPathComponent("timeline.jsonl")),
        changeNotification: ChatSessionStore.didChangeNotification,
        currentSessionID: { BrainStore.shared.sessions.currentSessionID },
        rowBelongsToOpenChat: { row in
            guard let open = BrainStore.shared.sessions.currentSession else { return row.sessionID == nil }
            if let rowSessionID = row.sessionID { return rowSessionID == open.id }
            // Rows from before saved chats: shown in the chat that was going on at the time.
            return row.date >= open.createdAt.addingTimeInterval(-60) && row.date <= open.updatedAt.addingTimeInterval(60 * 60)
        }
    )
}
