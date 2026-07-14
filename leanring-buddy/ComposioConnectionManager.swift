//
//  ComposioConnectionManager.swift
//  Detects Composio-supported frontmost apps and prompts the user to sync.
//

import AppKit
import Combine
import Foundation

struct ComposioSyncPromptState: Equatable {
    let toolkitSlug: String
    let displayName: String
    let frontmostAppName: String
}

@MainActor
final class ComposioConnectionManager: ObservableObject {
    @Published private(set) var isComposioConfigured = false
    @Published private(set) var connectedToolkitSlugs: Set<String> = []
    @Published private(set) var availableToolkits: [ComposioToolkitOption] = []
    @Published private(set) var isLoadingAvailableToolkits = false
    @Published var manualToolkitSearchQuery = ""
    @Published private(set) var activeSyncPrompt: ComposioSyncPromptState?
    @Published private(set) var isConnectingToolkit = false
    @Published private(set) var connectingToolkitSlug: String?
    @Published private(set) var lastConnectionError: String?

    var displayedManualToolkits: [ComposioToolkitOption] {
        ComposioToolkitCatalog.mergedDisplayedToolkits(
            searchResults: availableToolkits,
            searchQuery: manualToolkitSearchQuery
        )
    }

    private weak var companionManager: CompanionManager?
    private var frontmostAppMonitorTimer: Timer?
    private var toolkitSearchDebounceTask: Task<Void, Never>?
    private var lastPromptedToolkitSlug: String?
    private var lastAttentionFeedbackToolkitSlug: String?

    private static let clickyComposioUserIDKey = "clickyComposioUserID"
    private static let dismissedToolkitSlugUserDefaultsPrefix = "composioSyncDismissedToolkit."

    var composioUserID: String {
        if let existingUserID = UserDefaults.standard.string(forKey: Self.clickyComposioUserIDKey),
           !existingUserID.isEmpty {
            return existingUserID
        }

        let generatedUserID = UUID().uuidString
        UserDefaults.standard.set(generatedUserID, forKey: Self.clickyComposioUserIDKey)
        return generatedUserID
    }

    func startMonitoring(companionManager: CompanionManager) {
        self.companionManager = companionManager
        frontmostAppMonitorTimer?.invalidate()

        frontmostAppMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.evaluateFrontmostApplicationForSyncPrompt()
            }
        }

        Task {
            await refreshComposioConfigurationAndConnections()
            await evaluateFrontmostApplicationForSyncPrompt()
        }
    }

    func stopMonitoring() {
        frontmostAppMonitorTimer?.invalidate()
        frontmostAppMonitorTimer = nil
    }

    func refreshComposioConfigurationAndConnections() async {
        let healthURL = URL(string: "\(ClickyWorkerConfiguration.workerBaseURL)/health")!
        do {
            let (data, response) = try await URLSession.shared.data(from: healthURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let healthObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                isComposioConfigured = false
                connectedToolkitSlugs = []
                return
            }

            isComposioConfigured = healthObject["composio"] as? Bool ?? false
            guard isComposioConfigured else {
                connectedToolkitSlugs = []
                return
            }

            await refreshConnectedToolkitSlugs()
            await refreshAvailableToolkits()
        } catch {
            isComposioConfigured = false
            connectedToolkitSlugs = []
        }
    }

    func refreshConnectedToolkitSlugs() async {
        guard isComposioConfigured else { return }

        var components = URLComponents(string: ClickyWorkerConfiguration.composioConnectionsEndpointURL)!
        components.queryItems = [URLQueryItem(name: "user_id", value: composioUserID)]

        guard let requestURL = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: requestURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connectedSlugs = responseObject["connected_toolkit_slugs"] as? [String] else {
                return
            }

            connectedToolkitSlugs = Set(connectedSlugs)

            if let activePrompt = activeSyncPrompt,
               connectedToolkitSlugs.contains(activePrompt.toolkitSlug) {
                clearActiveSyncPrompt()
            }
        } catch {
            print("⚠️ Composio connections refresh failed: \(error)")
        }
    }

    func scheduleToolkitSearchRefresh() {
        toolkitSearchDebounceTask?.cancel()
        toolkitSearchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await refreshAvailableToolkits()
        }
    }

    func refreshAvailableToolkits(searchQuery: String? = nil) async {
        guard isComposioConfigured else {
            availableToolkits = []
            return
        }

        let queryToUse = searchQuery ?? manualToolkitSearchQuery
        isLoadingAvailableToolkits = true
        defer { isLoadingAvailableToolkits = false }

        var components = URLComponents(string: ClickyWorkerConfiguration.composioToolkitsEndpointURL)!
        var queryItems = [URLQueryItem(name: "limit", value: "30")]
        let trimmedQuery = queryToUse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: trimmedQuery))
        }
        components.queryItems = queryItems

        guard let requestURL = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: requestURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            availableToolkits = ComposioToolkitOption.parseList(from: responseObject)
        } catch {
            print("⚠️ Composio toolkit catalog refresh failed: \(error)")
        }
    }

    func connectToolkit(slug toolkitSlug: String, displayName: String) async {
        isConnectingToolkit = true
        connectingToolkitSlug = toolkitSlug
        lastConnectionError = nil
        defer {
            isConnectingToolkit = false
            connectingToolkitSlug = nil
        }

        do {
            let redirectURL = try await requestComposioConnectRedirectURL(toolkitSlug: toolkitSlug)
            NSWorkspace.shared.open(redirectURL)

            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshConnectedToolkitSlugs()
                if connectedToolkitSlugs.contains(toolkitSlug) {
                    if activeSyncPrompt?.toolkitSlug == toolkitSlug {
                        clearActiveSyncPrompt()
                        companionManager?.backgroundAgentSideDockManager.hideComposioSyncPrompt()
                    }
                    return
                }
            }

            lastConnectionError = "Finish signing in to \(displayName) in your browser, then tap Refresh."
        } catch {
            lastConnectionError = error.localizedDescription
        }
    }

    func connectActiveToolkit() async {
        guard let activePrompt = activeSyncPrompt else { return }
        await connectToolkit(slug: activePrompt.toolkitSlug, displayName: activePrompt.displayName)
    }

    func dismissActiveSyncPrompt(forHours dismissHours: Double = 6) {
        guard let activePrompt = activeSyncPrompt else { return }
        let dismissUntilDate = Date().addingTimeInterval(dismissHours * 3600)
        UserDefaults.standard.set(
            dismissUntilDate.timeIntervalSince1970,
            forKey: Self.dismissedToolkitUserDefaultsKey(toolkitSlug: activePrompt.toolkitSlug)
        )
        clearActiveSyncPrompt()
        companionManager?.backgroundAgentSideDockManager.hideComposioSyncPrompt()
    }

    private func evaluateFrontmostApplicationForSyncPrompt() async {
        guard let companionManager else { return }
        guard isComposioConfigured else {
            clearActiveSyncPrompt()
            return
        }

        if companionManager.isBackgroundAgentActivelyRunning {
            return
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            if activeSyncPrompt != nil {
                clearActiveSyncPrompt()
                companionManager.backgroundAgentSideDockManager.hideComposioSyncPrompt()
            }
            return
        }

        let frontmostAppName = frontmostApplication.localizedName ?? "this app"
        guard let toolkitMatch = ComposioFrontmostAppMapping.match(
            bundleIdentifier: frontmostApplication.bundleIdentifier,
            localizedAppName: frontmostAppName
        ) else {
            if activeSyncPrompt != nil {
                clearActiveSyncPrompt()
                companionManager.backgroundAgentSideDockManager.hideComposioSyncPrompt()
            }
            return
        }

        if connectedToolkitSlugs.contains(toolkitMatch.toolkitSlug) {
            if activeSyncPrompt != nil {
                clearActiveSyncPrompt()
                companionManager.backgroundAgentSideDockManager.hideComposioSyncPrompt()
            }
            return
        }

        if isToolkitDismissed(toolkitSlug: toolkitMatch.toolkitSlug) {
            return
        }

        let newPrompt = ComposioSyncPromptState(
            toolkitSlug: toolkitMatch.toolkitSlug,
            displayName: toolkitMatch.displayName,
            frontmostAppName: frontmostAppName
        )

        let isNewToolkitPrompt = lastPromptedToolkitSlug != toolkitMatch.toolkitSlug
        activeSyncPrompt = newPrompt
        lastPromptedToolkitSlug = toolkitMatch.toolkitSlug

        let shouldPlayAttentionFeedback = isNewToolkitPrompt
            && lastAttentionFeedbackToolkitSlug != toolkitMatch.toolkitSlug

        companionManager.backgroundAgentSideDockManager.showComposioSyncPrompt(
            companionManager: companionManager,
            syncPrompt: newPrompt,
            playAttentionFeedback: shouldPlayAttentionFeedback
        )

        if shouldPlayAttentionFeedback {
            lastAttentionFeedbackToolkitSlug = toolkitMatch.toolkitSlug
        }
    }

    private func requestComposioConnectRedirectURL(toolkitSlug: String) async throws -> URL {
        var request = URLRequest(url: URL(string: ClickyWorkerConfiguration.composioConnectEndpointURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "user_id": composioUserID,
            "toolkit_slug": toolkitSlug,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let redirectURLString = responseObject["redirect_url"] as? String,
              let redirectURL = URL(string: redirectURLString) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Failed to start Composio connect flow"
            throw NSError(domain: "ComposioConnectionManager", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        return redirectURL
    }

    private func clearActiveSyncPrompt() {
        activeSyncPrompt = nil
        lastConnectionError = nil
    }

    private func isToolkitDismissed(toolkitSlug: String) -> Bool {
        let dismissedUntilTimestamp = UserDefaults.standard.double(
            forKey: Self.dismissedToolkitUserDefaultsKey(toolkitSlug: toolkitSlug)
        )
        guard dismissedUntilTimestamp > 0 else { return false }
        return Date().timeIntervalSince1970 < dismissedUntilTimestamp
    }

    private static func dismissedToolkitUserDefaultsKey(toolkitSlug: String) -> String {
        "\(dismissedToolkitSlugUserDefaultsPrefix)\(toolkitSlug)"
    }
}
