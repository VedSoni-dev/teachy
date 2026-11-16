//
//  ConnectorsSection.swift
//  leanring-buddy
//
//  Home tab section for MCP connectors: one group of what's connected with a
//  switch for each, and a small form to add one (server URL or local command,
//  optional API key) or paste a config from another app. Self-contained — it
//  only talks to `ConnectorCenter.shared`. Mount it with `ConnectorsSection()`.
//

import AppKit
import SwiftUI

extension ConnectorCenter {
    /// The app's connectors: ~/.teachy/connectors/mcp.json, secrets in the Keychain,
    /// sign-in pages opened in the default browser.
    static let shared = ConnectorCenter(
        store: McpConnectorStore(fileURL: TeachyDataPaths.connectorsDirectoryURL.appendingPathComponent("mcp.json")),
        secrets: KeychainMcpSecretStore(),
        sessionOptions: {
            var options = McpSessionOptions()
            options.clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            return options
        }(),
        openURL: { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    )
}

struct ConnectorsSection: View {
    @ObservedObject private var center = ConnectorCenter.shared

    private enum Panel { case none, add, paste }
    private enum ServerKind { case url, command }

    @State private var openPanel: Panel = .none
    @State private var serverKind: ServerKind = .url
    @State private var draft = McpConnectorDraft()
    @State private var pastedConfig = ""
    @State private var formError: String?
    @State private var connectorPendingRemoval: String?
    @State private var connectorEditingToken: String?
    @State private var replacementToken = ""
    @State private var catalogBusyID: String?
    @State private var catalogKeyEntry: ConnectorCatalogEntry?
    @State private var catalogKey = ""
    @State private var catalogError: String?
    @State private var searchText = ""
    @State private var advancedExpanded = false
    @FocusState private var searchFocused: Bool

    private static let statusMarkSideLength: CGFloat = 16
    private static let statusMarkSpacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    searchField
                    addCustomButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    addCustomButton
                }
            }

            if let storeProblem = center.storeProblem {
                errorText(storeProblem)
            }

            switch openPanel {
            case .none:
                EmptyView()
            case .add:
                formSection("New connector") { addForm }
            case .paste:
                EmptyView()
            }

            if !center.connectors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    connectorSectionLabel("Your integrations", detail: sectionDetail)
                    VStack(alignment: .leading, spacing: 0) {
                        if filteredConnectors.isEmpty {
                            Text("No added integrations match your search.")
                                .font(DS.Fonts.body)
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(14)
                        }
                        ForEach(Array(filteredConnectors.enumerated()), id: \.element.id) { index, connector in
                            if index > 0 { TeachyRule().padding(.leading, 42) }
                            connectorRow(connector)
                        }
                    }
                    .connectorCard()
                }
            }

            ConnectorPopularStrip(
                entries: filteredCatalog,
                addedURLs: center.remoteServerURLs,
                busyID: catalogBusyID,
                keyEntry: catalogKeyEntry,
                key: $catalogKey,
                error: catalogError,
                onAdd: { addFromCatalog($0) },
                onSubmitKey: { entry in addFromCatalog(entry, apiKey: catalogKey) },
                onCancelKey: {
                    catalogKeyEntry = nil
                    catalogKey = ""
                    catalogError = nil
                }
            )

            VStack(alignment: .leading, spacing: 8) {
                hint("Custom connectors can use a hosted MCP URL or a command on this Mac. Keys and sign-ins stay in your Keychain.")
                if openPanel == .paste {
                    formSection("Import connectors") { pasteForm }
                } else {
                    linkButton("Import a connector config") {
                        resetForms()
                        openPanel = .paste
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { center.start() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Search integrations", text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityLabel("Search integrations")
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .teachyIconButton()
                .accessibilityLabel("Clear search")
            }
        }
        .connectorFieldWell(isFocused: searchFocused)
        .frame(minWidth: 150)
    }

    private var addCustomButton: some View {
        compactButton("Add custom connector") {
            resetForms()
            openPanel = .add
        }
        .fixedSize()
    }

    private var filteredCatalog: [ConnectorCatalogEntry] {
        ConnectorCatalog.entries.filter { matchesSearch($0.name + " " + $0.summary) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredConnectors: [McpConnectorConfig] {
        center.connectors.filter { matchesSearch($0.displayName) }
    }

    private func matchesSearch(_ value: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }

    private var sectionDetail: String {
        let connectedCount = center.connectors.filter { center.state(for: $0.id).isConnected }.count
        return "\(connectedCount) of \(center.connectors.count) connected"
    }

    private func formSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            connectorSectionLabel(title)
            content().padding(14).connectorCard()
        }
    }

    // MARK: Popular (one-click add)

    private func addFromCatalog(_ entry: ConnectorCatalogEntry, apiKey: String? = nil) {
        catalogError = nil
        if entry.auth == .apiKey, apiKey == nil {
            // Ask for the key first; nothing is saved or contacted yet.
            catalogKey = ""
            catalogKeyEntry = entry
            return
        }
        guard catalogBusyID == nil else { return }
        catalogBusyID = entry.id
        Task {
            do {
                // Same path as the Add form: saved, checked, then the browser sign-in if it asks.
                try await center.addFromCatalog(entry, apiKey: apiKey ?? "")
                catalogKeyEntry = nil
                catalogKey = ""
            } catch {
                catalogError = McpConnectorState.message(for: error)
            }
            catalogBusyID = nil
        }
    }

    // MARK: Rows

    private func connectorRow(_ connector: McpConnectorConfig) -> some View {
        let state = center.state(for: connector.id)
        return HStack(alignment: .top, spacing: Self.statusMarkSpacing) {
            TeachyStatusMark(kind: statusKind(for: state, enabled: connector.enabled), sideLength: Self.statusMarkSideLength)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connector.displayName)
                            .font(DS.Fonts.itemTitle)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        stateLine(for: state, enabled: connector.enabled)
                    }

                    Spacer(minLength: 8)

                    Toggle("Enable \(connector.displayName)", isOn: Binding(
                        get: { connector.enabled },
                        set: { center.setEnabled(id: connector.id, $0) }
                    ))
                    .toggleStyle(ConnectorSwitchToggleStyle())
                    .labelsHidden()
                }

                if connectorPendingRemoval == connector.id {
                    HStack(spacing: 6) {
                        Text("Remove \(connector.label)?")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer(minLength: 8)
                        compactButton("Remove", kind: .danger) {
                            center.remove(id: connector.id)
                            connectorPendingRemoval = nil
                        }
                        compactButton("Cancel", kind: .quiet) { connectorPendingRemoval = nil }
                    }
                } else if connectorEditingToken == connector.id {
                    HStack(spacing: 6) {
                        SecureField("New API key", text: $replacementToken, prompt: connectorFieldPrompt("New API key"))
                            .textFieldStyle(.plain)
                            .font(DS.Fonts.mono(12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .connectorFieldWell()
                            .onSubmit { saveReplacementToken(for: connector.id) }
                        compactButton("Save") { saveReplacementToken(for: connector.id) }
                        compactButton("Cancel", kind: .quiet) {
                            connectorEditingToken = nil
                            replacementToken = ""
                        }
                    }
                } else {
                    HStack(spacing: 14) {
                        if connector.enabled {
                            if state == .needsSignIn {
                                compactButton("Sign in") {
                                    Task { await center.signIn(id: connector.id) }
                                }
                            }
                            if state == .tokenRejected {
                                compactButton("Edit token") {
                                    replacementToken = ""
                                    connectorEditingToken = connector.id
                                }
                            } else if state == .needsSignIn && connector.isRemote {
                                linkButton("Use an API key") {
                                    replacementToken = ""
                                    connectorEditingToken = connector.id
                                }
                            }
                            linkButton("Reconnect") {
                                Task { await center.reconnect(id: connector.id) }
                            }
                        }
                        linkButton("Remove", color: DS.Colors.destructiveText) { connectorPendingRemoval = connector.id }
                    }
                }
            }
        }
        .padding(14)
    }

    /// The state in words. A short fact ("Connected · 12 tools") is set as
    /// data; a failure is the server's own sentence, so it is set as an error.
    @ViewBuilder
    private func stateLine(for state: McpConnectorState, enabled: Bool) -> some View {
        if enabled, case .failed(let failureMessage) = state {
            Text(failureMessage)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.destructiveText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(enabled ? state.summary : "Off")
                .font(DS.Fonts.data)
                .foregroundColor(statusColor(for: state, enabled: enabled))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveReplacementToken(for id: String) {
        let token = replacementToken
        replacementToken = ""
        connectorEditingToken = nil
        Task { await center.updateToken(id: id, apiKey: token) }
    }

    /// The mark says the state: done when connected, live while Teachy is
    /// checking, needs-you when it wants a sign-in, failed when it was refused
    /// or broke, stopped when switched off.
    private func statusKind(for state: McpConnectorState, enabled: Bool) -> TeachyStatusKind {
        guard enabled else { return .stopped }
        switch state {
        case .connected: return .done
        case .checking: return .live
        case .needsSignIn: return .needsYou
        case .tokenRejected, .failed: return .failed
        case .idle: return .waiting
        }
    }

    private func statusColor(for state: McpConnectorState, enabled: Bool) -> Color {
        guard enabled else { return DS.Colors.textTertiary }
        switch state {
        case .tokenRejected, .failed: return DS.Colors.destructiveText
        case .needsSignIn: return DS.Colors.warningText
        default: return DS.Colors.textSecondary
        }
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeledField("Name") {
                wellField("e.g. Linear", text: $draft.label)
            }

            if serverKind == .url {
                labeledField("Server URL") {
                    wellField("https://mcp.example.com/mcp", text: $draft.serverURL, monospaced: true)
                }
                labeledField("Authentication") {
                    SecureField("API key (optional)", text: $draft.apiKey, prompt: connectorFieldPrompt("API key (optional)"))
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.mono(12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .connectorFieldWell()
                        .onSubmit { submitDraft() }
                    hint("Leave the key empty to sign in through your browser when the server requests it. Open servers need no key.")
                }
            } else {
                labeledField("Command") {
                    wellField("npx -y @example/mcp-server", text: $draft.commandLine, monospaced: true)
                    hint("Needs a key? Put it in front, like API_KEY=… npx -y some-server. Teachy keeps it in your Keychain.")
                }
            }

            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    labeledField("Type") {
                        HStack(spacing: 6) {
                            serverKindOption("Remote URL", kind: .url)
                            serverKindOption("Command on this Mac", kind: .command)
                        }
                    }
                    labeledField("Account label") {
                        wellField("Optional, e.g. work", text: $draft.accountLabel)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Advanced")
                    .font(DS.Fonts.bodyEmphasized)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .pointerCursor()

            if let formError { errorText(formError) }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                compactButton("Cancel", kind: .quiet) {
                    resetForms()
                    openPanel = .none
                }
                compactButton("Add connector", kind: .primary) { submitDraft() }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DS.Fonts.bodyEmphasized).foregroundColor(DS.Colors.textPrimary)
            content()
        }
    }

    private func submitDraft() {
        var submitted = draft
        if serverKind == .url {
            submitted.commandLine = ""
        } else {
            submitted.serverURL = ""
            submitted.apiKey = ""
        }
        do {
            // The new row shows "Checking…" and then Connected, Token rejected, or the error.
            try center.add(submitted)
            resetForms()
            openPanel = .none
        } catch {
            formError = McpConnectorState.message(for: error)
        }
    }

    // MARK: Paste form

    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            hint("Paste a config from another app — the block that starts with \"mcpServers\". Any keys in it move to your Keychain.")

            TextEditor(text: $pastedConfig)
                .font(DS.Fonts.mono(12))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: 96)
                .padding(6)
                .teachyWell()

            if let formError {
                errorText(formError)
            }

            HStack(spacing: 6) {
                compactButton("Import", kind: .primary) {
                    do {
                        try center.importConfig(pastedConfig)
                        resetForms()
                        openPanel = .none
                    } catch {
                        formError = McpConnectorState.message(for: error)
                    }
                }
                compactButton("Cancel", kind: .quiet) {
                    resetForms()
                    openPanel = .none
                }
            }
        }
    }

    private func resetForms() {
        draft = McpConnectorDraft()
        pastedConfig = ""
        formError = nil
        serverKind = .url
        advancedExpanded = false
    }

    // MARK: Pieces

    private func wellField(_ placeholder: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text, prompt: connectorFieldPrompt(placeholder))
            .textFieldStyle(.plain)
            .font(monospaced ? DS.Fonts.mono(12) : DS.Fonts.body)
            .foregroundColor(DS.Colors.textPrimary)
            .autocorrectionDisabled()
            .connectorFieldWell()
            .onSubmit { submitDraft() }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.destructiveText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One of the two kinds of server.
    private func serverKindOption(_ title: String, kind: ServerKind) -> some View {
        Button {
            serverKind = kind
            formError = nil
        } label: {
            Text(title)
                .font(DS.Fonts.controlCompact)
                .foregroundColor(serverKind == kind ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .teachyOption(isSelected: serverKind == kind)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func compactButton(
        _ title: String,
        kind: TeachyButtonKind = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .teachyButton(kind)
    }

    /// A word in a row that does something. With no colour it takes the tint.
    private func linkButton(_ title: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .teachyLinkButton(color: color)
    }
}

/// Nothing connected yet: one line and one caption line. It is the only row of
/// the group until a connector is added.
struct ConnectorsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No connectors yet.")
                .font(DS.Fonts.itemTitle)
                .foregroundColor(DS.Colors.textPrimary)
            Text("Give Teachy tools from your other apps. Add an MCP server by its URL, or a command that runs one on this Mac.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 11)
    }
}

/// The catalog is a full-height grouped list; the settings page owns scrolling.
/// Plain values and closures keep its previews independent of `ConnectorCenter`.
struct ConnectorPopularStrip: View {
    let entries: [ConnectorCatalogEntry]
    let addedURLs: [String]
    var busyID: String?
    /// Set while a key-based entry is waiting for its key.
    var keyEntry: ConnectorCatalogEntry?
    @Binding var key: String
    var error: String?
    var onAdd: (ConnectorCatalogEntry) -> Void = { _ in }
    var onSubmitKey: (ConnectorCatalogEntry) -> Void = { _ in }
    var onCancelKey: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectorSectionLabel("All integrations", detail: "\(entries.count)")
            if let error {
                Text(error)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text("No integrations match your search.")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { TeachyRule().padding(.leading, 52) }
                    ConnectorCatalogRow(entry: entry, isAdded: ConnectorCatalog.isAdded(entry, serverURLs: addedURLs), isBusy: busyID == entry.id, addDisabled: busyID != nil) {
                        onAdd(entry)
                    }
                    if keyEntry?.id == entry.id {
                        keyRow(entry).padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }
                // Keep a pending key form reachable if the user changes the search.
                if let keyEntry, !entries.contains(where: { $0.id == keyEntry.id }) {
                    keyRow(keyEntry).padding(14)
                }
            }
            .connectorCard()
        }
    }

    private func keyRow(_ entry: ConnectorCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(entry.name) needs a key: \((entry.keyHint ?? "paste it here").prefix(1).lowercased() + (entry.keyHint ?? "paste it here").dropFirst()). It stays in your Keychain.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("Key for \(entry.name)", text: $key, prompt: connectorFieldPrompt("Key for \(entry.name)"))
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.mono(12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .connectorFieldWell()
                    .onSubmit { onSubmitKey(entry) }
                Button { onSubmitKey(entry) } label: {
                    Text("Add")
                }
                .teachyButton(.primary, size: .compact)
                .disabled(busyID != nil || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(action: onCancelKey) {
                    Text("Cancel")
                }
                .teachyButton(.quiet, size: .compact)
            }
        }
    }
}

// MARK: - Pieces shared by the section and the Popular strip

/// The placeholder inside a field: the faintest text colour.
private func connectorFieldPrompt(_ placeholder: String) -> Text {
    Text(placeholder).foregroundColor(DS.Colors.textQuaternary)
}

private func connectorSectionLabel(_ title: String, detail: String? = nil) -> some View {
    HStack {
        Text(title.uppercased())
            .tracking(1.1)
        Spacer()
        if let detail { Text(detail) }
    }
    .font(DS.Fonts.sans(11, weight: .semibold))
    .foregroundColor(DS.Colors.textTertiary)
    .padding(.horizontal, 3)
}

private extension View {
    func connectorFieldWell(isFocused: Bool? = nil) -> some View {
        modifier(ConnectorFieldWell(externalFocus: isFocused))
    }

    func connectorCard() -> some View {
        background(DS.Colors.workspaceCard, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.Colors.workspaceBorder, lineWidth: 1))
    }
}

private struct ConnectorFieldWell: ViewModifier {
    var externalFocus: Bool?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(DS.Colors.fillTertiary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke((externalFocus ?? isFocused) ? DS.Colors.pointer : .clear, lineWidth: 1.5))
    }
}

private struct ConnectorCatalogRow: View {
    let entry: ConnectorCatalogEntry
    let isAdded: Bool
    let isBusy: Bool
    let addDisabled: Bool
    var onAdd: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(DS.Fonts.sans(22, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 26, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(DS.Fonts.itemTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(entry.summary)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isAdded {
                Label("Added", systemImage: "checkmark")
                    .font(DS.Fonts.controlCompact)
                    .foregroundColor(DS.Colors.textSecondary)
            } else if isBusy {
                Text("Adding…")
                    .font(DS.Fonts.controlCompact)
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                Button("Add", action: onAdd)
                    .teachyButton(.primary)
                    .disabled(addDisabled)
                    .accessibilityLabel("Add \(entry.name)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(minHeight: 64)
        .background(isHovered ? DS.Colors.fillQuaternary : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var symbol: String {
        switch entry.id {
        case "linear": return "line.3.horizontal.decrease.circle"
        case "notion", "granola": return "doc.text"
        case "github", "deepwiki": return "chevron.left.forwardslash.chevron.right"
        case "atlassian": return "square.stack.3d.up"
        case "asana", "monday": return "checklist"
        case "airtable": return "tablecells"
        case "sentry": return "waveform.path.ecg"
        case "vercel": return "triangle.fill"
        case "supabase": return "bolt.fill"
        case "neon": return "externaldrive"
        case "cloudflare", "cloudflare-docs": return "cloud"
        case "posthog": return "chart.bar"
        case "stripe", "paypal", "square": return "creditcard"
        case "intercom": return "bubble.left.and.bubble.right"
        case "canva": return "paintpalette"
        case "webflow": return "globe"
        case "huggingface": return "face.smiling"
        case "context7", "microsoft-learn": return "books.vertical"
        case "exa": return "magnifyingglass"
        case "aws-knowledge": return "shippingbox"
        default: return "puzzlepiece.extension"
        }
    }
}

/// Teachy's switch on its own, for a row whose title already says what it
/// switches. Assistive tech still gets an ordinary toggle.
private struct ConnectorSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            DS.Haptics.stateChanged()
        } label: {
            TeachySwitch(isOn: configuration.isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityRepresentation {
            // Named style, so the stand-in is a system switch and not this style again.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
