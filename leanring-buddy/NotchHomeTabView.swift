//
//  NotchHomeTabView.swift
//  leanring-buddy
//
//  Compact Home launcher and the selected Agents, Drawings or Settings page.
//  Navigation lives in the compact notch header.
//

import SwiftUI

struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared
    @ObservedObject private var settings = TeachySettings.shared
    @ObservedObject private var history = SceneHistory.shared
    @ObservedObject private var connections = ConnectorCenter.shared

    var body: some View {
        Group {
            switch notchManager.selectedTab {
            case .home:
                homeOverview
            case .agents:
                AgentsSection()
            case .drawings:
                DrawingsSection(startsExpanded: true)
            case .connections:
                ConnectorsSection()
            case .settings:
                VStack(alignment: .leading, spacing: 20) {
                    settingsSection
                    ConnectorsSection()
                    BrainMemorySection()
                    footerLinks
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var homeOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent drawings")
                        .font(DS.Fonts.itemTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Button("View all") { notchManager.selectedTab = .drawings }
                        .teachyLinkButton()
                }
                if history.entries.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "scribble.variable")
                            .foregroundColor(DS.Colors.pointer)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Make something clear.").font(DS.Fonts.bodyEmphasized)
                            Text("Ask Teachy to draw or explain what’s on your screen.")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 66)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(history.entries.prefix(3))) { entry in
                            Button {
                                history.replay(entry.id)
                                notchManager.collapse()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ZStack {
                                        DS.Colors.fillTertiary
                                        if let image = history.thumbnail(for: entry.id) {
                                            Image(nsImage: image).resizable().scaledToFit()
                                        } else {
                                            Image(systemName: "scribble.variable")
                                                .foregroundColor(DS.Colors.textSecondary)
                                        }
                                    }
                                    .frame(height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(entry.title)
                                        .font(DS.Fonts.caption)
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .accessibilityLabel("Replay \(entry.title)")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Connections")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: 8) {
                    Button { notchManager.selectedTab = .connections } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text(connectionSummary).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "plus")
                        }
                    }
                    .teachyButton(.secondary, size: .compact, isFullWidth: true)
                    .accessibilityLabel("Manage connections, \(connectionSummary)")
                    Button {
                        ChatWindowController.shared.show()
                        notchManager.collapse()
                    } label: {
                        Label("Open chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .teachyButton(.primary, size: .compact)
                    .fixedSize()
                    .accessibilityLabel("Open Teachy chat")
                }
            }
            PushToTalkShortcutPickerRow(shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor)
            AlwaysOnNoticeLine()
            AttachmentChipsView(compact: true)
        }
        .onAppear { history.reload() }
    }

    private var connectionSummary: String {
        if connections.connectors.isEmpty { return "Add a connection" }
        let active = connections.states.values.filter { $0.isConnected }.count
        return active > 0 ? "\(active) connected" : "\(connections.connectors.count) configured"
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            TeachySectionTitle(title: "Settings")
            AlwaysOnPillView(showsNotice: true)

            VStack(alignment: .leading, spacing: 0) {
                PublikAccountSection()

                VoiceSettingsSection()

                MicrophoneSettingsSection()

                DictationSettingsSection()

                ShortcutsSettingsSection()

                pointerColorSection

                BrowserExtensionSection()

                PrivacySettingsSection()

                softwareUpdatesSection

                AdvancedSettingsSection()
            }
            .teachyGroup()
        }
    }

    private var softwareUpdatesSection: some View {
        SettingsDisclosureCard(
            icon: "arrow.triangle.2.circlepath",
            title: "Updates",
            summary: "Version \(softwareUpdater.shortVersionString)"
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Teachy \(softwareUpdater.shortVersionString) (\(softwareUpdater.buildNumberString))")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Updates are free and come from GitHub Releases.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Check for updates…") {
                    softwareUpdater.checkForUpdates()
                }
                .teachyButton(.secondary, size: .compact)
                .disabled(!softwareUpdater.canCheckForUpdates)
            }
        }
    }

    // MARK: - Pointer colour

    private var pointerColorSection: some View {
        SettingsDisclosureCard(
            icon: "cursorarrow",
            title: "Pointer",
            summary: companionManager.selectedCursorColor.rawValue.capitalized
        ) {
            Text("The colour of Teachy's pointer and of the trail you draw while holding the talk keys. It is also Teachy's accent colour.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(ClickyCursorColor.allCases) { cursorColor in
                    PointerColorOptionButton(
                        cursorColor: cursorColor,
                        isSelected: companionManager.selectedCursorColor == cursorColor
                    ) {
                        companionManager.setSelectedCursorColor(cursorColor)
                        // Same UserDefaults key; this keeps the settings object's copy current.
                        settings.cursorColor = cursorColor
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Footer

    private var footerLinks: some View {
        HStack(spacing: 18) {
            Button("Watch the demo again") {
                companionManager.replayOnboarding()
                notchManager.collapse()
            }
            .teachyLinkButton()

            Button("Give feedback") {
                if let url = URL(string: "https://github.com/VedSoni-dev/teachy/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
            .teachyLinkButton()

            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }
}

/// One pointer colour, drawn the way System Settings draws an accent colour:
/// a filled swatch, with a ring round the one that is chosen.
private struct PointerColorOptionButton: View {
    let cursorColor: ClickyCursorColor
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    private let swatchDiameter: CGFloat = 24
    /// The ring sits this far outside the swatch.
    private let ringGap: CGFloat = 3

    var body: some View {
        Button {
            onSelect()
            DS.Haptics.stateChanged()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(cursorColor.displayColor, lineWidth: 2)
                    .frame(width: swatchDiameter + 2 * (ringGap + 2), height: swatchDiameter + 2 * (ringGap + 2))
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.82)

                Circle()
                    .fill(cursorColor.displayColor)
                    .frame(width: swatchDiameter, height: swatchDiameter)
                    .overlay {
                        // The pointer itself, so the swatch says what the colour is for.
                        TeachyPointerShape()
                            .fill(DS.Colors.colorOnPointerColor(named: cursorColor.rawValue))
                            .frame(width: 9, height: 9)
                    }
                    .brightness(isHovered && !isSelected ? 0.08 : 0)
            }
            .frame(width: swatchDiameter + 2 * (ringGap + 2), height: swatchDiameter + 2 * (ringGap + 2))
            .contentShape(Circle())
            .animation(isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard, value: isSelected)
            .animation(DS.Motion.hover, value: isHovered)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovered = hovering }
        .accessibilityLabel("\(cursorColor.rawValue.capitalized) pointer")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Why always-on switched itself off, or which microphone took over. Shown under
/// the quick actions only when there is something to say.
private struct AlwaysOnNoticeLine: View {
    @ObservedObject private var voiceModeController = VoiceModeController.shared

    var body: some View {
        if let notice = voiceModeController.notice {
            Text(notice)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Compact "Hold [key] [key] to talk" hint, with a Change button
/// that records any two keys. Recording runs through the global event tap, so it
/// works even though the notch panel never becomes the key window.
private struct PushToTalkShortcutPickerRow: View {
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    /// Bumped when the saved shortcut changes so the key caps re-read it.
    @State private var shortcutRefreshCounter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if shortcutMonitor.isRecordingNewShortcut {
                    recordingInProgressLabel
                } else {
                    currentShortcutLabel
                }

                Spacer(minLength: 8)

                if shortcutMonitor.isRecordingNewShortcut {
                    Button("Cancel") {
                        shortcutMonitor.cancelRecordingNewShortcut()
                    }
                    .teachyButton(.quiet, size: .compact)
                } else {
                    if !PushToTalkShortcutKeys.isUsingDefaultShortcut {
                        Button("Reset") {
                            PushToTalkShortcutKeys.resetToDefaultShortcut()
                        }
                        .teachyButton(.quiet, size: .compact)
                    }
                    Button("Change") {
                        shortcutMonitor.beginRecordingNewShortcut()
                    }
                    .teachyButton(.quiet, size: .compact)
                    .accessibilityLabel("Change talk shortcut")
                }
            }
            .id(shortcutRefreshCounter)

            if shortcutMonitor.isRecordingNewShortcut {
                Text("Press any two keys, one after the other. Esc cancels.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            } else if !shortcutMonitor.isEventTapActive {
                Text("Needs Accessibility permission to listen for your shortcut.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PushToTalkShortcutKeys.shortcutDidChangeNotification)) { _ in
            shortcutRefreshCounter += 1
        }
        .onDisappear {
            // Don't leave the tap silently capturing keys after the panel closes.
            shortcutMonitor.cancelRecordingNewShortcut()
        }
    }

    private var currentShortcutLabel: some View {
        HStack(alignment: .center, spacing: 8) {
            headlineText("Hold")
            keyCaps(labels: PushToTalkShortcutKeys.currentKeyCapsuleLabels)
            headlineText("to talk")
        }
    }

    private var recordingInProgressLabel: some View {
        let recordedKeyLabels = shortcutMonitor.keyCodesRecordedSoFar.map {
            PushToTalkShortcutKeys.displayName(forKeyCode: $0)
        }
        let placeholderCount = PushToTalkShortcutKeys.numberOfKeysInShortcut - recordedKeyLabels.count
        let labelsWithPlaceholders = recordedKeyLabels + Array(repeating: "…", count: max(0, placeholderCount))

        return HStack(alignment: .center, spacing: 8) {
            headlineText("New keys")
            keyCaps(labels: labelsWithPlaceholders)
        }
    }

    private func headlineText(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.bodyEmphasized)
            .foregroundColor(DS.Colors.textPrimary)
    }

    private func keyCaps(labels: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, keyLabel in
                KeyboardKeyLabel(text: keyLabel)
            }
        }
    }
}
