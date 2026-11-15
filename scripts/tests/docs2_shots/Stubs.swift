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
