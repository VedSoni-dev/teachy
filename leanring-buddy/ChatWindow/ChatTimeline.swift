//
//  ChatTimeline.swift
//  leanring-buddy
//
//  What the chat window shows, kept up to date: the saved conversation, the
//  rows other parts of the app post (drawings, agent jobs, notes), the question
//  just asked, and the reply while it is still arriving.
//
//  The conversation is owned by the Brain (`conversation.jsonl`). This class only
//  reads it: it checks the file's modification date about twice a second while
//  the window is open, and reloads when it changes or when the Brain says so.
//
//  Other modules:
//      ChatTimeline.shared.post(.drawing(title: "How a turbofan works", thumbnailURL: url, id: sceneID))
//      ChatTimeline.shared.post(.job(title: "Inbox Hunter", status: .running, answer: nil, id: jobID))
//      ChatTimeline.shared.post(.note("Attached report.pdf"))
//      ChatTimeline.shared.userAsked(transcript)                    // when a turn starts
//      ChatTimeline.shared.streamingReply(text: soFar, isFinal: false)   // from onTextChunk
//

import Combine
import Foundation

@MainActor
final class ChatTimeline: ObservableObject {
    /// The thread, oldest first.
    @Published private(set) var items: [ChatThreadItem] = []
    /// True between a question being asked and its reply starting to arrive.
    @Published private(set) var isWaitingForReply = false

    /// Called when the person clicks a drawing row (the raw id that was posted).
    var onOpenDrawing: ((String) -> Void)?
    /// Called when the person clicks a job row (the raw id that was posted).
    var onOpenJob: ((String) -> Void)?

    private let loadMessages: () -> [ChatMessage]
    private let conversationFileURL: URL?
    private let store: ChatTimelineStore
    private let changeNotification: Notification.Name?
    /// The open saved chat, stamped on posted rows. nil when chats are not used (tests).
    private let currentSessionID: () -> String?
    /// Whether a posted row belongs in the thread being shown.
    private let rowBelongsToOpenChat: (ChatTimelineRow) -> Bool

    private var messages: [ChatMessage] = []
    private var rows: [ChatTimelineRow] = []
    private var pendingQuestion: (text: String, date: Date)?
    private var streaming: (text: String, date: Date, isFinal: Bool)?

    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private var lastConversationModification: Date?
    private var lastTimelineModification: Date?
    private var clearStreamingTask: Task<Void, Never>?
    private var watchers = 0

    /// - Parameters:
    ///   - loadMessages: the saved conversation, oldest first.
    ///   - conversationFileURL: the file whose modification date signals a change.
    ///   - store: where posted rows are kept.
    ///   - changeNotification: a notification that also means "reload".
    init(
        loadMessages: @escaping () -> [ChatMessage],
        conversationFileURL: URL?,
        store: ChatTimelineStore,
        changeNotification: Notification.Name? = nil,
        currentSessionID: @escaping () -> String? = { nil },
        rowBelongsToOpenChat: @escaping (ChatTimelineRow) -> Bool = { _ in true }
    ) {
        self.loadMessages = loadMessages
        self.conversationFileURL = conversationFileURL
        self.store = store
        self.changeNotification = changeNotification
        self.currentSessionID = currentSessionID
        self.rowBelongsToOpenChat = rowBelongsToOpenChat
        reload()
    }

    /// The open chat changed (new chat, or another one picked): drop the live turn and reload.
    func openChatDidChange() {
        clearStreamingTask?.cancel()
        streaming = nil
        pendingQuestion = nil
        isWaitingForReply = false
        reload()
    }

    // MARK: - For other modules

    /// Adds a drawing, a job or a note to the thread and saves it. Posting a
    /// drawing or job again with the same id updates its row.
    func post(_ event: ChatTimelineEvent) {
        store.post(event, sessionID: currentSessionID())
        rows = store.rows().filter(rowBelongsToOpenChat)
        lastTimelineModification = store.modificationDate
        rebuild()
    }

    /// The person just asked this (typed or spoken). Shown at once, before the
    /// Brain has saved it.
    func userAsked(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pendingQuestion?.text == trimmed, let asked = pendingQuestion?.date, Date().timeIntervalSince(asked) < 3 { return }
        clearStreamingTask?.cancel()
        streaming = nil
        pendingQuestion = (trimmed, Date())
        isWaitingForReply = true
        rebuild()
        // A turn that fails never saves the question; don't leave "thinking" up forever.
        scheduleClear(after: 90)
    }

    /// The reply so far (the whole text each time, not just the new part).
    /// Call with `isFinal: true` when it is complete.
    func streamingReply(text: String, isFinal: Bool) {
        let startDate = streaming?.date ?? Date()
        streaming = (text, startDate, isFinal)
        if !ChatReplyText.withoutActionTags(text).isEmpty { isWaitingForReply = false }
        rebuild()
        // The finished reply stays until the Brain saves it and a reload replaces it.
        scheduleClear(after: isFinal ? 20 : 90)
    }

    // MARK: - Keeping up to date

    /// Call when a window showing the timeline opens; `stopWatching()` when it closes.
    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        reload()
        if let changeNotification {
            observer = NotificationCenter.default.addObserver(forName: changeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfFilesChanged() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func reloadIfFilesChanged() {
        let conversationModification = conversationFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        let timelineModification = store.modificationDate
        guard conversationModification != lastConversationModification || timelineModification != lastTimelineModification else { return }
        reload()
    }

    func reload() {
        lastConversationModification = conversationFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        lastTimelineModification = store.modificationDate
        let loaded = loadMessages()
        let conversationChanged = loaded != messages
        messages = loaded
        rows = store.rows().filter(rowBelongsToOpenChat)

        if conversationChanged {
            // The turn has been saved: the saved messages replace the live ones.
            if let pendingQuestion, loaded.suffix(4).contains(where: { $0.isFromUser && $0.text == pendingQuestion.text }) {
                self.pendingQuestion = nil
            }
            if let streaming, loaded.last.map({ !$0.isFromUser && $0.date >= streaming.date }) == true {
                self.streaming = nil
                clearStreamingTask?.cancel()
            }
            if pendingQuestion == nil { isWaitingForReply = false }
        }
        rebuild()
    }

    private func scheduleClear(after seconds: TimeInterval) {
        clearStreamingTask?.cancel()
        clearStreamingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.streaming = nil
            self.pendingQuestion = nil
            self.isWaitingForReply = false
            self.reload()
        }
    }

    private func rebuild() {
        let merged = ChatThread.merge(
            messages: messages,
            rows: rows,
            pendingQuestion: pendingQuestion,
            streamingReply: streaming.map { ($0.text, $0.date) }
        )
        if merged != items { items = merged }
    }
}
