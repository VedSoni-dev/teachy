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

    /// Space between the section's title, its group of rows and what sits under the group.
    private static let sectionPartSpacing: CGFloat = 9
    /// Space above and below the content of one row of the group.
    private static let groupRowVerticalPadding: CGFloat = 11
    private static let statusMarkSideLength: CGFloat = 14
    /// The gap between a status mark and the text beside it.
    private static let statusMarkSpacing: CGFloat = 10
    /// The dividers between rows start where the names start, past the status mark.
    private static let statusMarkIndent: CGFloat = statusMarkSideLength + statusMarkSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionPartSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                TeachySectionTitle(title: "Connectors", detail: sectionDetail)

                if !center.connectors.isEmpty {
                    Text("Keys and sign-ins stay in your Keychain.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let storeProblem = center.storeProblem {
                Text(storeProblem)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The rows of the section and nothing else, in its one rounded container.
            VStack(alignment: .leading, spacing: 0) {
                if center.connectors.isEmpty {
                    ConnectorsEmptyState()
                }

                ForEach(Array(center.connectors.enumerated()), id: \.element.id) { connectorIndex, connector in
                    if connectorIndex > 0 {
                        TeachyRule()
                            .padding(.leading, Self.statusMarkIndent)
                    }
                    connectorRow(connector)
                }
            }
            .teachyGroup()

            ConnectorPopularStrip(
                entries: ConnectorCatalog.entries,
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
            .padding(.top, 4)

            switch openPanel {
            case .none:
                HStack(spacing: 6) {
                    compactButton("Add connector") {
                        resetForms()
                        openPanel = .add
                    }
                    compactButton("Paste config", kind: .quiet) {
                        resetForms()
                        openPanel = .paste
                    }
                }
            case .add:
                addForm
            case .paste:
                pasteForm
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { center.start() }
    }

    /// The fact beside the title: "2 of 3 connected".
    private var sectionDetail: String? {
        guard !center.connectors.isEmpty else { return nil }
        let connectedCount = center.connectors.filter { center.state(for: $0.id).isConnected }.count
        return "\(connectedCount) of \(center.connectors.count) connected"
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

                    Toggle("", isOn: Binding(
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
        .padding(.vertical, Self.groupRowVerticalPadding)
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
        VStack(alignment: .leading, spacing: 8) {
            wellField("Name, e.g. Linear", text: $draft.label)

            HStack(spacing: 6) {
                serverKindOption("Server URL", kind: .url)
                serverKindOption("Local command", kind: .command)
            }

            if serverKind == .url {
                wellField("https://mcp.example.com/mcp", text: $draft.serverURL, monospaced: true)
                SecureField("API key (optional)", text: $draft.apiKey, prompt: connectorFieldPrompt("API key (optional)"))
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.mono(12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .connectorFieldWell()
                    .onSubmit { submitDraft() }
                hint("No key? Leave it empty — if the server wants a sign-in, Teachy opens it in your browser.")
            } else {
                wellField("npx -y @example/mcp-server", text: $draft.commandLine, monospaced: true)
                hint("Needs a key? Put it in front, like API_KEY=… npx -y some-server. Teachy keeps it in your Keychain.")
            }

            wellField("Account label (optional), e.g. work", text: $draft.accountLabel)

            if let formError {
                errorText(formError)
            }

            HStack(spacing: 6) {
                compactButton("Add", kind: .primary) { submitDraft() }
                compactButton("Cancel", kind: .quiet) {
                    resetForms()
                    openPanel = .none
                }
            }
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
        .teachyButton(kind, size: .compact)
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

/// The "Popular" row: well-known servers with an Add button each. Plain values in, closures
/// out, so it renders without a `ConnectorCenter`.
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
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Popular")
                    .font(DS.Fonts.sans(11.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(entries) { entry in
                            tile(entry)
                        }
                    }
                    .padding(.vertical, 1)
                }

                if let keyEntry {
                    keyRow(keyEntry)
                        .padding(.top, 4)
                }

                if let error {
                    Text(error)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One server, drawn as an option: its name, one caption line, then the
    /// word that adds it (or the fact that it is added) and how it signs in.
    private func tile(_ entry: ConnectorCatalogEntry) -> some View {
        let isAdded = ConnectorCatalog.isAdded(entry, serverURLs: addedURLs)
        return VStack(alignment: .leading, spacing: 3) {
            Text(entry.name)
                .font(DS.Fonts.bodyEmphasized)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Text(entry.summary)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if isAdded {
                    TeachyStatusMark(kind: .done, sideLength: 13)
                    Text("Added")
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                } else if busyID == entry.id {
                    TeachyStatusMark(kind: .live, sideLength: 13)
                    Text("Adding…")
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                } else {
                    Button { onAdd(entry) } label: {
                        Text("Add")
                            // Room around the word, so the click target is not just two letters wide.
                            .padding(.vertical, 4)
                            .padding(.trailing, 12)
                    }
                    .teachyLinkButton(font: DS.Fonts.controlCompact)
                    .disabled(busyID != nil)
                }
                Spacer(minLength: 0)
                Text(authLabel(entry.auth))
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .frame(height: 22)
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: 220, alignment: .leading)
        .teachyOption(isSelected: false)
    }

    private func authLabel(_ auth: ConnectorCatalogEntry.Auth) -> String {
        switch auth {
        case .oauth: return "Sign in"
        case .apiKey: return "Key"
        case .none: return "Open"
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

private extension View {
    /// A one-line field is a well as tall as a regular button.
    func connectorFieldWell() -> some View {
        self
            .padding(.horizontal, 10)
            .frame(height: 28)
            .teachyWell()
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
