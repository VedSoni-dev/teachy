//
//  ChatTimeline+Shared.swift
//  leanring-buddy
//
//  The app's one timeline: the Brain's saved conversation plus
//  `~/.teachy/brain/timeline.jsonl`. Kept apart from ChatTimeline.swift so the
//  timeline can be built and tested without the Brain.
//

import Foundation

extension ChatTimeline {
    static let shared = ChatTimeline(
        loadMessages: {
            BrainStore.shared.recentMessages().map {
                ChatMessage(isFromUser: $0.role == .user, text: $0.text, date: $0.date)
            }
        },
        conversationFileURL: BrainStore.shared.conversationFileURL,
        store: ChatTimelineStore(fileURL: TeachyDataPaths.brainDirectoryURL.appendingPathComponent("timeline.jsonl")),
        changeNotification: BrainStore.didChangeNotification
    )
}
