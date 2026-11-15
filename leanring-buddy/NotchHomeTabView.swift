//
//  NotchHomeTabView.swift
//  leanring-buddy
//
//  Home tab content for the notch panel, top to bottom: how to talk to Teachy,
//  the other ways in (chat, always-on, typing, files), agents and their jobs,
//  connectors, drawings, memory, then settings as a grouped list of rows that
//  open in place, and the feedback links.
//  The settings rows themselves live in Settings/SettingsSections.swift.
//

import SwiftUI

struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared
    @ObservedObject private var settings = TeachySettings.shared

    /// Space between the sections of the page.
    private let sectionSpacing: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            howToTalkSection

            quickActionsSection

            AgentsSection()

            ConnectorsSection()

            DrawingsSection()

            BrainMemorySection()

            settingsSection

            footerLinks
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - How to talk

    /// The one line the panel is about, then the three things you can do with it.
    private var howToTalkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PushToTalkShortcutPickerRow(
                shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
            )

            HStack(alignment: .top, spacing: 0) {
                howToTalkColumn(
                    symbolName: "text.bubble",
                    title: "Ask",
                    explanation: "Anything on your screen. Teachy answers out loud, and points or draws right on it."
                )
                howToTalkColumnDivider
                howToTalkColumn(
                    symbolName: "lasso",
                    title: "Circle",
                    explanation: "While you hold the keys, move the pointer around the thing you mean."
                )
                howToTalkColumnDivider
                howToTalkColumn(
                    symbolName: "wand.and.stars",
                    title: "Hand it off",
                    explanation: "Say \u{201C}do it for me\u{201D} and it takes the job. It asks before anything risky."
                )
            }
            .padding(.vertical, 13)
            .teachyGroup(horizontalPadding: 0)
        }
    }

    private func howToTalkColumn(symbolName: String, title: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(DS.Fonts.sans(12, weight: .medium))
                    .foregroundColor(DS.Colors.pointer)
                Text(title)
                    .font(DS.Fonts.itemTitle)
                    .foregroundColor(DS.Colors.textPrimary)
            }
            Text(explanation)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var howToTalkColumnDivider: some View {
        Rectangle()
            .fill(DS.Colors.hairline)
            .frame(width: 1)
            .padding(.vertical, 2)
    }

    // MARK: - Quick actions

    /// The other ways in: the chat window, always-on listening, typing, dropping a file.
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    ChatWindowController.shared.show()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(DS.Fonts.sans(10.5, weight: .medium))
                        Text("Open chat")
                        Text("⌃⌘A")
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .fixedSize()
                }
                .teachyButton(.secondary, size: .compact)

                AlwaysOnPillView(showsNotice: false)
                    .fixedSize()

                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                Text("Double-tap")
                KeyboardKeyLabel(text: "control")
                Text("to type a question. Drop a file on the notch to attach it.")
            }
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .lineLimit(1)

            AlwaysOnNoticeLine()

            AttachmentChipsView(compact: true)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            TeachySectionTitle(title: "Settings")

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

/// "Hold [key] [key] and ask." — the headline of the panel — with a Change button
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
                    Button("Change keys") {
                        shortcutMonitor.beginRecordingNewShortcut()
                    }
                    .teachyButton(.quiet, size: .compact)
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
            headlineText("and ask.")
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
            .font(DS.Fonts.display)
            .foregroundColor(DS.Colors.textPrimary)
    }

    private func keyCaps(labels: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, keyLabel in
                KeyboardKeyLabel(text: keyLabel, isProminent: true)
            }
        }
    }
}
