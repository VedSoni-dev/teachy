// The app's shared timeline reads the Brain. The renderer never uses it, but
// ChatWindowController refers to it, so it gets a stand-in here that touches
// nothing outside a temp directory.
import Foundation

extension ChatTimeline {
    static let shared = ChatTimeline(
        loadMessages: { [] },
        conversationFileURL: nil,
        store: ChatTimelineStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-docs2/unused-timeline.jsonl"))
    )
}

// The app's chat list reads the Brain's saved chats; the renderer shows a fixed list instead.
extension ChatSessionList {
    static let shared = ChatSessionList(actions: Actions(
        load: {
            let now = Date()
            let items = [
                ChatSessionListItem(id: "renderer-1", title: "Flights to Bergen", updatedAt: now, messageCount: 6),
                ChatSessionListItem(id: "renderer-2", title: "Fix the login test in teachy", updatedAt: now.addingTimeInterval(-3_600), messageCount: 14),
                ChatSessionListItem(id: "renderer-3", title: "Quarterly receipts", updatedAt: now.addingTimeInterval(-86_400), messageCount: 8),
                ChatSessionListItem(id: "renderer-4", title: "Board deck tidy-up", updatedAt: now.addingTimeInterval(-4 * 86_400), messageCount: 4),
            ]
            return (items, "renderer-1")
        },
        startNew: {},
        open: { _ in },
        rename: { _, _ in },
        delete: { _ in },
        search: { _ in [] }
    ))
}
