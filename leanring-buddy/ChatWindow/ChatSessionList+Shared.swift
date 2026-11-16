//
//  ChatSessionList+Shared.swift
//  leanring-buddy
//
//  The app's one chat list, backed by the Brain's saved chats
//  (`BrainStore.shared.sessions`). Kept apart so the list and its sidebar can
//  be rendered without the Brain.
//

import Foundation

extension ChatSessionList {
    static let shared: ChatSessionList = {
        let store = BrainStore.shared.sessions
        let list = ChatSessionList(
            actions: Actions(
                load: {
                    let index = store.index()
                    let items = index.sessionsNewestFirst
                        // An empty chat shows only while it is the open one.
                        .filter { $0.messageCount > 0 || $0.id == index.currentSessionID }
                        .map { ChatSessionListItem(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, messageCount: $0.messageCount) }
                    return (items, index.currentSessionID)
                },
                startNew: {
                    store.startNewSession()
                    ChatMemoryKeeper.shared.scheduleMaintenance()
                },
                open: { sessionID in
                    store.switchToSession(sessionID)
                    ChatMemoryKeeper.shared.scheduleMaintenance()
                },
                rename: { sessionID, title in store.renameSession(sessionID, to: title) },
                delete: { sessionID in store.deleteSession(sessionID) },
                search: { query in
                    store.search(query, limit: 30).map {
                        ChatSessionSearchResult(sessionID: $0.sessionID, sessionTitle: $0.sessionTitle, snippet: $0.snippet, date: $0.date)
                    }
                }
            ),
            changeNotification: ChatSessionStore.didChangeNotification
        )
        list.onOpenChatChanged = { ChatTimeline.shared.openChatDidChange() }
        return list
    }()
}
