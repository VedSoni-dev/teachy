//
//  SuggestionCenter.swift
//  leanring-buddy
//
//  Once a day (after 8 am, when Teachy is idle) asks the model for up to three
//  things it could take off the person's plate, from what Teachy knows about
//  them: memory, recent chats, the journal, connected apps and what is open.
//  The ideas appear from the notch (`SuggestionPanelPresenter`). Do it starts an
//  ordinary agent job with the approved plan; Adjust starts it with the person's
//  change; Nah remembers the idea so it is not offered again.
//
//  State lives in ~/.teachy/suggestions/state.json (today's ideas, the day they
//  were offered, dismissed headlines). Nothing here sends anything anywhere
//  except the one model call through `TeachyAIRouter`.
//

import AppKit
import Combine
import Foundation

@MainActor
final class SuggestionCenter: ObservableObject {
    static let shared = SuggestionCenter()

    private struct SavedState: Codable {
        var lastOfferedDay: String?
        var todaysSuggestions: [TeachySuggestion] = []
        var dismissedHeadlines: [String] = []
    }

    /// Today's ideas that have not been answered yet.
    @Published private(set) var pendingSuggestions: [TeachySuggestion] = []
    @Published private(set) var isGenerating = false

    private weak var backgroundAgentManager: BackgroundAgentManager?
    private var isTeachyBusy: () -> Bool = { false }
    private var checkTimer: Timer?
    private var offerNowObserver: NSObjectProtocol?
    static let offerNowNotification = Notification.Name("teachy.suggestions.offerNow")
    private var state = SavedState()

    private static let checkIntervalSeconds: TimeInterval = 10 * 60
    private static let firstCheckDelaySeconds: TimeInterval = 90

    private var stateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teachy/suggestions", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    // MARK: Start

    /// Called once at launch. `isTeachyBusy` says whether a voice turn or a job is under way.
    func start(backgroundAgentManager: BackgroundAgentManager, isTeachyBusy: @escaping () -> Bool) {
        self.backgroundAgentManager = backgroundAgentManager
        self.isTeachyBusy = isTeachyBusy
        loadState()
        pendingSuggestions = state.lastOfferedDay == TeachySuggestionRules.dayKey(for: Date()) ? state.todaysSuggestions : []

        // Settings → "Suggest things now".
        if offerNowObserver == nil {
            offerNowObserver = NotificationCenter.default.addObserver(forName: Self.offerNowNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.offerNow() }
            }
        }

        checkTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelaySeconds) { [weak self] in
            Task { await self?.offerIfDue() }
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.offerIfDue() }
        }
    }

    // MARK: Offering

    /// The daily check: asks for ideas once a day and shows them if there are any.
    func offerIfDue(now: Date = Date()) async {
        let busy = isTeachyBusy() || ConsentPrompter.shared.isShowing || DriveTakeoverMonitor.shared.isDriving
        guard TeachySuggestionRules.shouldOffer(
            now: now,
            lastOfferedDay: state.lastOfferedDay,
            isEnabled: TeachySettingsStorage.suggestionsEnabled(),
            isBusy: busy
        ) else { return }
        await generateAndShow(now: now, markOffered: true)
    }

    /// Settings → "Suggest things now": asks right away, whatever the day.
    func offerNow() async {
        if !pendingSuggestions.isEmpty {
            SuggestionPanelPresenter.shared.show(pendingSuggestions, startExpanded: true)
            return
        }
        await generateAndShow(now: Date(), markOffered: true)
    }

    private func generateAndShow(now: Date, markOffered: Bool) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        let context = Self.gatherContext(now: now)
        let dismissed = Set(state.dismissedHeadlines)
        // The model call runs off the main actor's critical path; failures just mean no ideas today.
        guard let answer = await Self.askModel(context: context) else { return }
        let suggestions = TeachySuggestionRules.parse(modelAnswer: answer, dismissedHeadlines: dismissed)

        if markOffered {
            state.lastOfferedDay = TeachySuggestionRules.dayKey(for: now)
        }
        state.todaysSuggestions = suggestions
        pendingSuggestions = suggestions
        saveState()

        guard !suggestions.isEmpty else { return }
        SuggestionPanelPresenter.shared.show(suggestions, startExpanded: false)
    }

    // MARK: Answers

    func accept(_ suggestion: TeachySuggestion) {
        removeFromPending(suggestion)
        backgroundAgentManager?.runTask(transcript: TeachySuggestionRules.jobInstruction(for: suggestion))
    }

    func accept(_ suggestion: TeachySuggestion, withChange change: String) {
        removeFromPending(suggestion)
        backgroundAgentManager?.runTask(transcript: TeachySuggestionRules.adjustedJobInstruction(for: suggestion, change: change))
    }

    func dismiss(_ suggestion: TeachySuggestion) {
        removeFromPending(suggestion)
        state.dismissedHeadlines = TeachySuggestionRules.remembering(dismissal: suggestion.headline, in: state.dismissedHeadlines)
        saveState()
    }

    private func removeFromPending(_ suggestion: TeachySuggestion) {
        pendingSuggestions.removeAll { $0.id == suggestion.id }
        state.todaysSuggestions = pendingSuggestions
        saveState()
    }

    // MARK: Context and the model call

    /// What the model knows when it picks ideas. Plain text, assembled from Teachy's own stores.
    private static func gatherContext(now: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        var sections = ["Now: \(dateFormatter.string(from: now))."]

        let memory = BrainStore.shared.promptContext(budgetCharacters: 2400)
        if !memory.isEmpty { sections.append("What you know about them:\n\(memory)") }

        let journal = BrainStore.shared.sessions.recentJournal(budgetCharacters: 1800)
        if !journal.isEmpty { sections.append("Recent journal:\n\(journal)") }

        let recentChats = BrainStore.shared.sessions.index().sessions
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)
            .map { chat -> String in
                let summary = chat.compactSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- \(chat.title)" + (summary.isEmpty ? "" : ": " + String(summary.prefix(220)))
            }
        if !recentChats.isEmpty { sections.append("Recent chats with Teachy:\n" + recentChats.joined(separator: "\n")) }

        let connectedServices = ConnectorCenter.shared.connectors.filter(\.enabled).map(\.label)
        if !connectedServices.isEmpty { sections.append("Connected services: " + connectedServices.joined(separator: ", ") + ".") }

        let openApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter { $0 != "Teachy" && $0 != "Finder" }
        if !openApps.isEmpty { sections.append("Apps open right now: " + openApps.prefix(15).joined(separator: ", ") + ".") }

        return sections.joined(separator: "\n\n")
    }

    private static func askModel(context: String) async -> String? {
        let body: [String: Any] = [
            "max_tokens": 1400,
            "stream": false,
            "messages": [
                ["role": "system", "content": TeachySuggestionRules.systemPrompt],
                ["role": "user", "content": context],
            ],
        ]
        do {
            let data = try await TeachyAIRouter.sendJSON(job: .plan, hasImages: false, timeout: 90, body: body)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any]
            else { return nil }
            if let text = message["content"] as? String { return text }
            if let blocks = message["content"] as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined() }
            return nil
        } catch {
            print("💡 Suggestions skipped: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Saved state

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let decoded = try? JSONDecoder().decode(SavedState.self, from: data)
        else { return }
        state = decoded
    }

    private func saveState() {
        do {
            try FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateFileURL, options: .atomic)
        } catch {
            print("💡 Couldn't save suggestions: \(error.localizedDescription)")
        }
    }
}
