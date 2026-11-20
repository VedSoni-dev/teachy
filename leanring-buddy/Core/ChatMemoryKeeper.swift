//
//  ChatMemoryKeeper.swift
//  leanring-buddy
//
//  Keeps the saved chats small enough to send and remembered across days,
//  the way a coding harness compacts its context:
//
//    - compaction: when the open chat grows past the budget, the older part is
//      folded into a running summary (ChatContextWindow.messagesToCompact);
//      the full chat stays on disk;
//    - titles: a short model-written title after the first exchange;
//    - journal: once a chat goes quiet, 1–3 dated lines go into JOURNAL.md, so a
//      fresh launch next week still knows what happened;
//    - learning: new messages become facts in PROFILE.md / VOLATILE.md (likes,
//      how they want things done, people, corrections), updating or removing older
//      facts instead of piling up (`MemoryLearning`). Old chats are caught up a
//      couple per pass.
//
//  Runs after each voice turn and at launch, in the background, one pass at a
//  time. Failures are quiet: the next pass tries again.
//

import Foundation

@MainActor
final class ChatMemoryKeeper {
    static let shared = ChatMemoryKeeper()

    private var isRunning = false
    private var runAgainWhenDone = false
    private var quietTimer: Timer?

    private var store: ChatSessionStore { BrainStore.shared.sessions }

    /// Starts the launch pass and a periodic check, so chats left open get journaled.
    func start() {
        scheduleMaintenance()
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleMaintenance() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    /// Call after a turn is saved, a chat is switched, or a new chat is started.
    func scheduleMaintenance() {
        guard !isRunning else {
            runAgainWhenDone = true
            return
        }
        isRunning = true
        Task { [weak self] in
            await self?.runMaintenancePass()
            guard let self else { return }
            self.isRunning = false
            if self.runAgainWhenDone {
                self.runAgainWhenDone = false
                self.scheduleMaintenance()
            }
        }
    }

    private func runMaintenancePass() async {
        // Not signed in yet: the router throws and the pass is retried later.
        await learnFromNewMessages()
        if let current = store.currentSession {
            await compactIfNeeded(current)
            await writeTitleIfNeeded(current)
        }
        for session in store.sessionsNeedingJournal().prefix(4) {
            await writeJournal(for: session)
        }
    }

    // MARK: - The three jobs

    private func compactIfNeeded(_ session: ChatSessionSummary) async {
        let allMessages = store.messages(in: session.id)
        guard let range = ChatContextWindow.messagesToCompact(allMessages: allMessages, summarizedMessageCount: session.summarizedMessageCount) else { return }
        let previousSummary = session.compactSummary.isEmpty ? "(none yet)" : session.compactSummary
        let prompt = "SUMMARY SO FAR:\n\(previousSummary)\n\nNEXT PART OF THE CONVERSATION:\n" + ChatContextWindow.compactionTranscript(Array(allMessages[range]))
        guard let summary = await ask(system: ChatContextWindow.compactionSystemPrompt, user: prompt, job: .write, maxTokens: 900),
              !summary.isEmpty else { return }
        store.saveCompactSummary(summary, for: session.id, throughMessageCount: range.upperBound)
        print("🧠 Chat compacted: \(range.count) older messages folded into the summary")
    }

    private func writeTitleIfNeeded(_ session: ChatSessionSummary) async {
        guard session.titleIsAutomatic, session.messageCount >= 2 else { return }
        let opening = store.messages(in: session.id).prefix(4)
        guard let title = await ask(system: ChatContextWindow.titleSystemPrompt, user: ChatContextWindow.compactionTranscript(Array(opening)), job: .cleanup, maxTokens: 40),
              !title.isEmpty, title.count <= 80 else { return }
        store.renameSession(session.id, to: title, isAutomatic: false)
    }

    private func writeJournal(for session: ChatSessionSummary) async {
        let allMessages = store.messages(in: session.id)
        let startIndex = min(session.journaledMessageCount, allMessages.count)
        let newMessages = Array(allMessages[startIndex...])
        guard let lastNew = newMessages.last else { return }
        let transcript = "Chat: \(session.title)\n\n" + ChatContextWindow.compactionTranscript(newMessages.suffix(30).map { $0 })
        guard let answer = await ask(system: ChatContextWindow.journalSystemPrompt, user: transcript, job: .cleanup, maxTokens: 300) else { return }
        // Marked as journaled even when nothing was worth writing, so it is not asked again.
        store.addJournalLines(ChatJournal.lines(fromModelAnswer: answer), on: lastNew.date, for: session.id, throughMessageCount: allMessages.count)
    }

    // MARK: - Learning

    private var learningProgressFileURL: URL {
        BrainStore.shared.directoryURL.appendingPathComponent("learned.json")
    }

    private func loadLearningProgress() -> MemoryLearningProgress {
        guard let data = try? Data(contentsOf: learningProgressFileURL),
              let progress = try? JSONDecoder().decode(MemoryLearningProgress.self, from: data) else { return MemoryLearningProgress() }
        return progress
    }

    private func saveLearningProgress(_ progress: MemoryLearningProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? FileManager.default.createDirectory(at: BrainStore.shared.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: learningProgressFileURL, options: .atomic)
    }

    /// Turns new chat messages into remembered facts. The open chat is learned right after
    /// each turn; older chats a couple per pass until the whole history is covered.
    private func learnFromNewMessages() async {
        var progress = loadLearningProgress()
        let index = store.index()
        for session in MemoryLearning.sessionsToLearn(index: index, progress: progress) {
            let allMessages = store.messages(in: session.id)
            guard let slice = MemoryLearning.nextSlice(of: allMessages, learnedCount: progress.learnedCount(for: session.id)) else {
                progress.learnedMessageCountBySession[session.id] = allMessages.count
                continue
            }
            let prompt = MemoryLearning.userPrompt(
                currentMemory: BrainStore.shared.promptContext(budgetCharacters: 8_000),
                sessionTitle: session.title,
                context: slice.context,
                new: slice.new
            )
            guard let answer = await ask(system: MemoryLearning.systemPrompt, user: prompt, job: .write, maxTokens: 700) else { return }
            let actions = MemoryLearning.actions(fromModelAnswer: answer)
            if !actions.isEmpty {
                BrainStore.shared.apply(actions: actions)
                // Shown in the chat it came from, so the person sees what stuck (and can fix it).
                if session.id == index.currentSessionID, let note = MemoryLearning.timelineNote(for: actions) {
                    ChatTimeline.shared.post(.note(note))
                }
                print("🧠 Learned \(actions.count) memory change(s) from a chat")
            }
            progress.learnedMessageCountBySession[session.id] = slice.learnedThrough
            saveLearningProgress(progress)
        }
        // Chats deleted since: drop their progress.
        let liveIDs = Set(store.index().sessions.map(\.id))
        let before = progress.learnedMessageCountBySession.count
        progress.learnedMessageCountBySession = progress.learnedMessageCountBySession.filter { liveIDs.contains($0.key) }
        if progress.learnedMessageCountBySession.count != before { saveLearningProgress(progress) }
    }

    // MARK: - Model call

    private func ask(system: String, user: String, job: TeachyAIJob, maxTokens: Int) async -> String? {
        let body: [String: Any] = [
            "max_tokens": maxTokens,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        do {
            let data = try await TeachyAIRouter.sendJSON(job: job, hasImages: false, timeout: 60, body: body)
            return Self.assistantText(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("🧠 Chat memory pass skipped: \(error.localizedDescription)")
            return nil
        }
    }

    private static func assistantText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        if let blocks = message["content"] as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined() }
        return nil
    }
}

// MARK: - What the voice turn sends

extension ChatSessionStore {
    /// The open chat, unless it has sat idle so long that the next question starts a new one
    /// (see `ChatContextWindow.idleGapBeforeNewSession`).
    func openSessionStillActive(now: Date = Date()) -> ChatSessionSummary? {
        guard let session = currentSession else { return nil }
        if session.messageCount > 0, now.timeIntervalSince(session.updatedAt) > ChatContextWindow.idleGapBeforeNewSession { return nil }
        return session
    }

    /// The open chat's recent exchanges, word for word, within the budget (after the summary).
    func historyForVoiceTurn(maximumExchanges: Int = 12) -> [(userTranscript: String, assistantResponse: String)] {
        guard let session = openSessionStillActive() else { return [] }
        let recent = ChatContextWindow.recentMessagesForModel(allMessages: messages(in: session.id), summarizedMessageCount: session.summarizedMessageCount)
        return ChatContextWindow.exchanges(from: recent).suffix(maximumExchanges).map {
            (userTranscript: $0.userText, assistantResponse: $0.assistantText)
        }
    }

    /// The prompt section that carries memory across a long chat and across days:
    /// the open chat's summary, how the previous chat ended (when this one is new),
    /// older chats the question points back to, and the journal.
    func contextPromptSection(forQuestion question: String) -> String {
        let session = openSessionStillActive()
        var previous: (title: String, updatedAt: Date, lastMessages: [BrainMessage])?
        if session == nil, let idle = currentSession, idle.messageCount > 0 {
            // The open chat sat idle long enough that this question starts a new one:
            // bridge from how the idle chat ended.
            previous = (idle.title, idle.updatedAt, Array(messages(in: idle.id).suffix(4)))
        } else if (session?.messageCount ?? 0) < 4, let found = previousSession() {
            previous = (found.summary.title, found.summary.updatedAt, found.lastMessages)
        }
        var recalled: [ChatSearchHit] = []
        if ChatContextWindow.questionWantsRecall(question) {
            recalled = Array(search(question, limit: 4, excludingSessionID: session?.id))
        }
        return ChatContextWindow.promptSection(
            sessionSummary: session?.compactSummary ?? "",
            journal: recentJournal(),
            previousSession: previous,
            recalled: recalled,
            now: Date()
        )
    }
}
