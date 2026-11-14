//
//  ConnectorsSection.swift
//  leanring-buddy
//
//  Home tab card for MCP connectors: what's connected, a switch for each, and a
//  small form to add one (server URL or local command, optional API key) or
//  paste a config from another app. Self-contained — it only talks to
//  `ConnectorCenter.shared`. Mount it with `ConnectorsSection()`.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connectors")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(summaryLine)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let storeProblem = center.storeProblem {
                Text(storeProblem)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(center.connectors) { connector in
                connectorRow(connector)
            }

            switch openPanel {
            case .none:
                HStack(spacing: 8) {
                    capsuleButton("Add connector") {
                        resetForms()
                        openPanel = .add
                    }
                    quietButton("Paste config") {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .task { center.start() }
    }

    private var summaryLine: String {
        if center.connectors.isEmpty {
            return "Give Teachy tools from your other apps. Add an MCP server by its URL, or a command that runs one on this Mac."
        }
        let connectedCount = center.connectors.filter { center.state(for: $0.id).isConnected }.count
        return "\(connectedCount) of \(center.connectors.count) connected. Keys and sign-ins stay in your Keychain."
    }

    // MARK: Rows

    private func connectorRow(_ connector: McpConnectorConfig) -> some View {
        let state = center.state(for: connector.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(dotColor(for: state, enabled: connector.enabled))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(connector.enabled ? state.summary : "Off")
                        .font(.system(size: 10))
                        .foregroundColor(statusColor(for: state, enabled: connector.enabled))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if state == .checking && connector.enabled {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }

                Toggle("", isOn: Binding(
                    get: { connector.enabled },
                    set: { center.setEnabled(id: connector.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if connectorPendingRemoval == connector.id {
                HStack(spacing: 8) {
                    Text("Remove \(connector.label)?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    capsuleButton("Remove", fill: DS.Colors.destructive, textColor: DS.Colors.textOnAccent) {
                        center.remove(id: connector.id)
                        connectorPendingRemoval = nil
                    }
                    quietButton("Cancel") { connectorPendingRemoval = nil }
                }
                .padding(.leading, 15)
            } else if connectorEditingToken == connector.id {
                HStack(spacing: 8) {
                    SecureField("New API key", text: $replacementToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(6)
                        .glassCard(cornerRadius: 8)
                        .onSubmit { saveReplacementToken(for: connector.id) }
                    capsuleButton("Save") { saveReplacementToken(for: connector.id) }
                    quietButton("Cancel") {
                        connectorEditingToken = nil
                        replacementToken = ""
                    }
                }
                .padding(.leading, 15)
            } else {
                HStack(spacing: 12) {
                    if connector.enabled {
                        if state == .needsSignIn {
                            quietButton("Sign in", color: DS.Colors.accentText) {
                                Task { await center.signIn(id: connector.id) }
                            }
                        }
                        if state == .tokenRejected || (state == .needsSignIn && connector.isRemote) {
                            quietButton(state == .tokenRejected ? "Edit token" : "Use an API key", color: DS.Colors.accentText) {
                                replacementToken = ""
                                connectorEditingToken = connector.id
                            }
                        }
                        quietButton("Reconnect") {
                            Task { await center.reconnect(id: connector.id) }
                        }
                    }
                    quietButton("Remove") { connectorPendingRemoval = connector.id }
                }
                .padding(.leading, 15)
            }
        }
        .padding(.vertical, 2)
    }

    private func saveReplacementToken(for id: String) {
        let token = replacementToken
        replacementToken = ""
        connectorEditingToken = nil
        Task { await center.updateToken(id: id, apiKey: token) }
    }

    private func dotColor(for state: McpConnectorState, enabled: Bool) -> Color {
        guard enabled else { return DS.Colors.textTertiary }
        switch state {
        case .connected: return DS.Colors.success
        case .checking, .needsSignIn: return DS.Colors.warning
        case .tokenRejected, .failed: return DS.Colors.destructive
        case .idle: return DS.Colors.textTertiary
        }
    }

    private func statusColor(for state: McpConnectorState, enabled: Bool) -> Color {
        guard enabled else { return DS.Colors.textTertiary }
        switch state {
        case .tokenRejected, .failed: return DS.Colors.destructiveText
        case .needsSignIn: return DS.Colors.warningText
        default: return DS.Colors.textTertiary
        }
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Name, e.g. Linear", text: $draft.label)

            HStack(spacing: 6) {
                kindButton("Server URL", kind: .url)
                kindButton("Local command", kind: .command)
            }

            if serverKind == .url {
                field("https://mcp.example.com/mcp", text: $draft.serverURL, monospaced: true)
                SecureField("API key (optional)", text: $draft.apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(8)
                    .glassCard(cornerRadius: 8)
                    .onSubmit { submitDraft() }
                hint("No key? Leave it empty — if the server wants a sign-in, Teachy opens it in your browser.")
            } else {
                field("npx -y @example/mcp-server", text: $draft.commandLine, monospaced: true)
                hint("Needs a key? Put it in front, like API_KEY=… npx -y some-server. Teachy keeps it in your Keychain.")
            }

            field("Account label (optional), e.g. work", text: $draft.accountLabel)

            if let formError {
                Text(formError)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                capsuleButton("Add") { submitDraft() }
                quietButton("Cancel") {
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: 96)
                .padding(6)
                .glassCard(cornerRadius: 8)

            if let formError {
                Text(formError)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                capsuleButton("Import") {
                    do {
                        try center.importConfig(pastedConfig)
                        resetForms()
                        openPanel = .none
                    } catch {
                        formError = McpConnectorState.message(for: error)
                    }
                }
                quietButton("Cancel") {
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

    private func field(_ placeholder: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundColor(DS.Colors.textPrimary)
            .autocorrectionDisabled()
            .padding(8)
            .glassCard(cornerRadius: 8)
            .onSubmit { submitDraft() }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func kindButton(_ title: String, kind: ServerKind) -> some View {
        Button {
            serverKind = kind
            formError = nil
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(serverKind == kind ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(serverKind == kind ? 0.14 : 0.04)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func capsuleButton(
        _ title: String,
        fill: Color = Color.white.opacity(0.1),
        textColor: Color = DS.Colors.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func quietButton(_ title: String, color: Color = DS.Colors.textTertiary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
