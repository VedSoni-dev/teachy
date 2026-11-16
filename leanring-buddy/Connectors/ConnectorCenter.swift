//
//  ConnectorCenter.swift
//  leanring-buddy
//
//  The one place the app talks to about MCP connectors: the saved list, each
//  connector's live state, and the tools they give the agent.
//
//  Nothing here calls an AI model. The only network traffic is to servers the
//  person added.
//

import Combine
import Foundation

/// A connector's tool, in the shape the agent's tool registry expects.
/// Named `mcp__<connectorid>__<toolname>`.
final class McpConnectorTool: BackgroundAgentTool {
    let name: String
    let description: String
    let jsonSchema: [String: Any]

    let connectorID: String
    /// "Linear · work" — for permission prompts.
    let connectorDisplayName: String
    /// The tool's name on the server.
    let remoteToolName: String
    /// How much this tool can change, per the server's annotations. `unknown` should be treated as `writes`.
    /// The server supplies these hints itself, so `readOnly` means "claims to be read-only".
    let mcpRisk: McpToolRisk
    /// True when the tool reaches outside the server's own data (the web, other people). Nil when unstated.
    let mcpOpenWorld: Bool?

    private let session: McpSession

    init(registeredName: String, descriptor: McpToolDescriptor, connector: McpConnectorConfig, session: McpSession) {
        self.name = registeredName
        self.connectorID = connector.id
        self.connectorDisplayName = connector.displayName
        self.remoteToolName = descriptor.name
        self.mcpRisk = descriptor.risk
        self.mcpOpenWorld = descriptor.openWorld
        self.session = session

        var summary = descriptor.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty { summary = descriptor.title ?? descriptor.name }
        if summary.count > 1_000 { summary = String(summary.prefix(1_000)) + "…" }
        self.description = "[\(connector.displayName)] \(summary)"
        self.jsonSchema = (descriptor.inputSchema.anyValue as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let result = try await session.callTool(name: remoteToolName, arguments: JSONValue(any: arguments))
        return McpContentFlattener.flatten(result)
    }
}

@MainActor
final class ConnectorCenter: ObservableObject {
    @Published private(set) var connectors: [McpConnectorConfig] = []
    @Published private(set) var states: [String: McpConnectorState] = [:]
    /// Set when mcp.json couldn't be read or written.
    @Published private(set) var storeProblem: String?
    /// Every connected connector's tools, ready for the agent's tool registry.
    private(set) var tools: [any BackgroundAgentTool] = []

    private final class Runtime {
        let session: McpSession
        let oauth: McpOAuthManager?
        init(session: McpSession, oauth: McpOAuthManager?) {
            self.session = session
            self.oauth = oauth
        }
    }

    private let store: McpConnectorStore
    private let secrets: any McpSecretStore
    private let openURL: @Sendable (URL) -> Void
    private let sessionOptions: McpSessionOptions
    private let pathProvider: (@Sendable () async -> String)?

    private var runtimes: [String: Runtime] = [:]
    private var toolsByConnector: [String: [McpConnectorTool]] = [:]
    private var hasStarted = false

    init(
        store: McpConnectorStore,
        secrets: any McpSecretStore,
        sessionOptions: McpSessionOptions = McpSessionOptions(),
        pathProvider: (@Sendable () async -> String)? = nil,
        openURL: @escaping @Sendable (URL) -> Void
    ) {
        self.store = store
        self.secrets = secrets
        self.sessionOptions = sessionOptions
        self.pathProvider = pathProvider
        self.openURL = openURL
    }

    // MARK: Starting

    /// Loads the saved list and connects the enabled connectors in the background.
    /// Safe to call often; only the first call does anything.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let loaded = store.load()
        connectors = loaded.connectors
        storeProblem = loaded.problem
        addBuiltInBrowserOnce()
        for connector in connectors where connector.enabled {
            states[connector.id] = .checking
            Task { await self.connect(id: connector.id) }
        }
    }

    // MARK: Built-in browser

    /// Marks that the built-in browser was added once, so removing it in settings sticks.
    static let builtInBrowserSeededKey = "teachyBuiltInBrowserConnectorSeeded.v1"
    static let builtInBrowserLabel = "Browser"
    /// Microsoft's open-source Playwright MCP (Apache-2.0): a real Chromium the agent drives by
    /// the page's accessibility tree. Its profile persists, so sign-ins made there are kept.
    /// Add `--extension` (with the Playwright MCP Bridge extension) to drive the person's own Chrome.
    static let builtInBrowserCommand = "npx -y @playwright/mcp@latest"

    /// Gives every agent a working browser without Teachy's own extension. Added once; the
    /// person can switch it off or remove it like any other connector.
    private func addBuiltInBrowserOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.builtInBrowserSeededKey) else { return }
        defaults.set(true, forKey: Self.builtInBrowserSeededKey)
        if connectors.contains(where: { $0.displayName.lowercased().contains("playwright") || $0.id == "browser" }) { return }
        let draft = McpConnectorDraft(label: Self.builtInBrowserLabel, commandLine: Self.builtInBrowserCommand)
        guard let built = try? draft.build(existingIDs: Set(connectors.map(\.id))) else { return }
        connectors.append(built.config)
        try? persist()
    }

    /// For the agent: makes sure connectors are starting, gives ones still checking a moment
    /// to finish, and returns the tools available now.
    func toolsForAgent(waitingUpTo seconds: TimeInterval = 6) async -> [any BackgroundAgentTool] {
        start()
        await waitUntilSettled(timeout: seconds)
        return tools
    }

    /// Returns when no connector is "checking" any more, or after `timeout`.
    func waitUntilSettled(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, states.values.contains(.checking) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func state(for id: String) -> McpConnectorState {
        states[id] ?? .idle
    }

    /// A short note for the agent's system prompt. Empty when nothing is connected.
    func promptSection() -> String {
        let connected = connectors.filter { state(for: $0.id).isConnected && !(toolsByConnector[$0.id] ?? []).isEmpty }
        guard !connected.isEmpty else { return "" }
        var lines = ["Connected apps (MCP connectors). Prefer these tools over clicking through the app's UI:"]
        if connected.contains(where: { $0.id == "browser" }) {
            lines.append("- Browser: a real browser (Playwright). Use mcp__browser__browser_navigate to open a page, mcp__browser__browser_snapshot to read it (elements come with ref ids), then mcp__browser__browser_click / browser_type / browser_select_option with those refs. Use it for any website task that needs clicking, forms or signing in; web_fetch is enough for reading a public page. If a site needs the person to sign in, tell them to sign in in that browser window and wait.")
        }
        for connector in connected {
            let count = toolsByConnector[connector.id]?.count ?? 0
            lines.append("- \(connector.displayName): \(count) tool\(count == 1 ? "" : "s"), named mcp__\(connector.id)__…")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Changing the list

    /// Saves a new connector and starts connecting it. Returns its id; watch `states[id]`.
    @discardableResult
    func add(_ draft: McpConnectorDraft) throws -> String {
        start()
        let built = try draft.build(existingIDs: Set(connectors.map(\.id)))
        try insert([built])
        return built.config.id
    }

    /// Imports a pasted `{"mcpServers": …}` config. Secrets in it go to the Keychain. Returns the new ids.
    @discardableResult
    func importConfig(_ text: String) throws -> [String] {
        start()
        let imported = try McpConfigImporter.parse(text, existingIDs: Set(connectors.map(\.id)))
        try insert(imported)
        return imported.map(\.config.id)
    }

    private func insert(_ entries: [McpImportedConnector]) throws {
        for entry in entries {
            for (reference, value) in entry.secrets {
                try secrets.setSecret(value, for: reference)
            }
        }
        connectors.append(contentsOf: entries.map(\.config))
        do {
            try persist()
        } catch {
            // Don't leave half an entry behind: no saved connector, no stored secret.
            let failedIDs = Set(entries.map(\.config.id))
            connectors.removeAll { failedIDs.contains($0.id) }
            for entry in entries { for reference in entry.secrets.keys { secrets.removeSecret(for: reference) } }
            throw error
        }
        for entry in entries where entry.config.enabled {
            states[entry.config.id] = .checking
            let id = entry.config.id
            Task { await self.connect(id: id) }
        }
    }

    func remove(id: String) {
        guard let connector = connectors.first(where: { $0.id == id }) else { return }
        dropRuntime(id: id)
        for reference in connector.secretReferences { secrets.removeSecret(for: reference) }
        connectors.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        try? persist()
    }

    func setEnabled(id: String, _ enabled: Bool) {
        guard let index = connectors.firstIndex(where: { $0.id == id }), connectors[index].enabled != enabled else { return }
        connectors[index].enabled = enabled
        try? persist()
        if enabled {
            states[id] = .checking
            Task { await self.connect(id: id) }
        } else {
            dropRuntime(id: id)
            states[id] = .idle
        }
    }

    /// Replaces a connector's API key (the "Edit token" action) and reconnects.
    func updateToken(id: String, apiKey: String) async {
        guard let index = connectors.firstIndex(where: { $0.id == id }), connectors[index].isRemote else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        let reference: String
        if case .bearer(let existingReference, _, _) = connectors[index].auth {
            reference = existingReference
        } else {
            reference = "\(id).bearer"
            connectors[index].auth = .bearer(keychainRef: reference, header: "Authorization", scheme: "Bearer")
        }
        do {
            try secrets.setSecret(trimmedKey, for: reference)
            try persist()
        } catch {
            states[id] = .failed(McpConnectorState.message(for: error))
            return
        }
        dropRuntime(id: id)
        await connect(id: id)
    }

    // MARK: Connecting

    func reconnect(id: String) async {
        await connect(id: id)
    }

    /// Checks a connector really answers: connects if needed, otherwise pings.
    @discardableResult
    func test(id: String) async -> McpConnectorState {
        if state(for: id).isConnected, let runtime = runtimes[id] {
            states[id] = .checking
            do {
                try await runtime.session.ping()
                states[id] = .connected(toolCount: toolsByConnector[id]?.count ?? 0)
                return state(for: id)
            } catch {
                // fall through to a full reconnect
            }
        }
        await connect(id: id)
        return state(for: id)
    }

    /// Opens the browser to sign in to a remote server (OAuth), then connects.
    func signIn(id: String) async {
        guard let index = connectors.firstIndex(where: { $0.id == id }), connectors[index].isRemote else { return }
        if connectors[index].auth != .oauth {
            connectors[index].auth = .oauth
            try? persist()
            dropRuntime(id: id)
        }
        guard let oauth = runtime(for: connectors[index])?.oauth else { return }
        states[id] = .checking
        do {
            try await oauth.signIn()
        } catch {
            guard connectors.contains(where: { $0.id == id }) else { return }
            states[id] = error is McpError ? .failed(McpConnectorState.message(for: error)) : McpConnectorState.describing(error, auth: .oauth)
            return
        }
        await connect(id: id)
    }

    private func connect(id: String) async {
        guard let connector = connectors.first(where: { $0.id == id }), connector.enabled else { return }
        guard let runtime = runtime(for: connector) else { return }
        states[id] = .checking
        do {
            let descriptors = try await runtime.session.reconnect()
            guard runtimes[id] === runtime else { return } // removed or replaced while connecting
            publish(descriptors, for: connector, runtime: runtime)
        } catch {
            guard runtimes[id] === runtime else { return }
            setTools([], for: id)
            states[id] = McpConnectorState.describing(error, auth: connector.auth)
        }
    }

    private func runtime(for connector: McpConnectorConfig) -> Runtime? {
        if let existing = runtimes[connector.id] { return existing }

        var oauth: McpOAuthManager?
        if connector.auth == .oauth, case .http(let urlString, _, _) = connector.transport, let url = URL(string: urlString) {
            oauth = McpOAuthManager(
                serverURL: url,
                secretReference: connector.oauthSecretReference,
                secrets: secrets,
                openURL: openURL
            )
        }

        let connectorID = connector.id
        let secretStore = secrets
        let searchPathProvider = pathProvider
        let authProvider: (any McpAuthProvider)? = oauth
        let session = McpSession(
            options: sessionOptions,
            makeTransport: {
                try McpTransportBuilder.makeTransport(
                    for: connector, secrets: secretStore, oauth: authProvider, pathProvider: searchPathProvider
                )
            },
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event, connectorID: connectorID) }
            }
        )
        let runtime = Runtime(session: session, oauth: oauth)
        runtimes[connector.id] = runtime
        return runtime
    }

    private func dropRuntime(id: String) {
        setTools([], for: id)
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        Task { await runtime.session.close() }
    }

    private func handle(_ event: McpSessionEvent, connectorID: String) {
        guard let connector = connectors.first(where: { $0.id == connectorID }), let runtime = runtimes[connectorID] else { return }
        switch event {
        case .toolsChanged(let descriptors), .restarted(let descriptors):
            publish(descriptors, for: connector, runtime: runtime)
        case .restarting:
            states[connectorID] = .checking
        case .stopped(let reason, let error):
            setTools([], for: connectorID)
            states[connectorID] = error.map { McpConnectorState.describing($0, auth: connector.auth) } ?? .failed(reason)
        }
    }

    private func publish(_ descriptors: [McpToolDescriptor], for connector: McpConnectorConfig, runtime: Runtime) {
        let registeredNames = McpToolNaming.registeredNames(connectorID: connector.id, toolNames: descriptors.map(\.name))
        let adapters = zip(registeredNames, descriptors).map { registeredName, descriptor in
            McpConnectorTool(registeredName: registeredName, descriptor: descriptor, connector: connector, session: runtime.session)
        }
        setTools(adapters, for: connector.id)
        states[connector.id] = .connected(toolCount: adapters.count)
    }

    private func setTools(_ adapters: [McpConnectorTool], for id: String) {
        if adapters.isEmpty {
            toolsByConnector.removeValue(forKey: id)
        } else {
            toolsByConnector[id] = adapters
        }
        tools = connectors.flatMap { toolsByConnector[$0.id] ?? [] }
    }

    private func persist() throws {
        do {
            try store.save(connectors)
            storeProblem = nil
        } catch {
            storeProblem = "Couldn't save connectors: \(error.localizedDescription)"
            throw error
        }
    }

    /// Stops every local server and closes every connection.
    func shutdown() async {
        let active = runtimes.values.map(\.session)
        runtimes.removeAll()
        toolsByConnector.removeAll()
        tools = []
        for session in active { await session.close() }
        for connector in connectors { states[connector.id] = .idle }
    }
}
