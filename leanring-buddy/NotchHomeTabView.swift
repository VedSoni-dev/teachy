//
//  NotchHomeTabView.swift
//  leanring-buddy
//
//  Home tab content for the notch panel: how to talk to Teachy, the publik
//  account, then settings as collapsed cards (voice, dictation, shortcuts,
//  cursor, memory, privacy, updates, advanced) and the feedback link.
//  The settings cards themselves live in Settings/SettingsSections.swift.
//

import SwiftUI

struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared
    @ObservedObject private var settings = TeachySettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pushToTalkInstructions

            PublikAccountSection()

            settingsHeader

            VStack(alignment: .leading, spacing: 8) {
                VoiceSettingsSection()

                MicrophoneSettingsSection()

                DictationSettingsSection()

                ShortcutsSettingsSection()

                cursorColorSection

                ConnectorsSection()

                // MOUNT: AgentJobsSection()

                PrivacySettingsSection()

                softwareUpdatesSection

                AdvancedSettingsSection()
            }

            BrainMemorySection()

            watchIntroAgainButton

            dmFeedbackButton
        }
    }

    private var settingsHeader: some View {
        Text("SETTINGS")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.leading, 4)
            .padding(.top, 2)
            .padding(.bottom, -6)
    }

    private var pushToTalkInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            PushToTalkShortcutPickerRow(
                shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
            )

            Text("Ask anything about your screen, or ask Teachy to do it for you.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("While you hold the keys, move the pointer to circle the thing you mean.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("Double-tap")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                KeyboardKeyLabel(text: "control")
                Text("to type a question instead.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var softwareUpdatesSection: some View {
        SettingsDisclosureCard(
            icon: "arrow.triangle.2.circlepath",
            title: "Updates",
            summary: "Teachy \(softwareUpdater.shortVersionString)"
        ) {
            Text("Teachy \(softwareUpdater.shortVersionString) (\(softwareUpdater.buildNumberString)). Updates are free and come from GitHub Releases.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                softwareUpdater.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Check for Updates…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!softwareUpdater.canCheckForUpdates)
            .opacity(softwareUpdater.canCheckForUpdates ? 1 : 0.45)
            .pointerCursor(isEnabled: softwareUpdater.canCheckForUpdates)
        }
    }

    private var watchIntroAgainButton: some View {
        Button {
            companionManager.replayOnboarding()
            notchManager.collapse()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 11))
                Text("Watch demo again")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var cursorColorSection: some View {
        SettingsDisclosureCard(
            icon: "cursorarrow",
            title: "Cursor",
            summary: companionManager.selectedCursorColor.rawValue.capitalized
        ) {
            Text("The colour of Teachy's pointer, and of the trail you draw while holding the talk keys.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(ClickyCursorColor.allCases) { cursorColor in
                    cursorColorOptionButton(cursorColor: cursorColor)
                }
            }
        }
    }

    private func cursorColorOptionButton(cursorColor: ClickyCursorColor) -> some View {
        let isSelected = companionManager.selectedCursorColor == cursorColor
        return Button(action: {
            companionManager.setSelectedCursorColor(cursorColor)
            // Same UserDefaults key; this keeps the settings object's copy current.
            settings.cursorColor = cursorColor
        }) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .overlay {
                    ZStack {
                        Triangle()
                            .fill(cursorColor.displayColor)
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-35))
                            .blur(radius: 12)
                            .opacity(isSelected ? 0.55 : 0.2)
                            .scaleEffect(1.8)

                        Triangle()
                            .fill(cursorColor.displayColor)
                            .frame(width: 14, height: 14)
                            .rotationEffect(.degrees(-35))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected ? cursorColor.displayColor : Color.white.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .shadow(
                    color: isSelected ? cursorColor.displayColor.opacity(0.35) : .clear,
                    radius: 8,
                    x: 0,
                    y: 2
                )
                .scaleEffect(isSelected ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var dmFeedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/VedSoni-dev/teachy/issues") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                Text("Give feedback")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// "Hold [key] + [key] to talk" with a Change button that records any two keys.
/// Recording runs through the global event tap, so it works even though the
/// notch panel never becomes the key window.
private struct PushToTalkShortcutPickerRow: View {
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    /// Bumped when the saved shortcut changes so the key capsules re-read it.
    @State private var shortcutRefreshCounter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if shortcutMonitor.isRecordingNewShortcut {
                    recordingInProgressLabel
                } else {
                    currentShortcutLabel
                }

                Spacer(minLength: 0)

                if shortcutMonitor.isRecordingNewShortcut {
                    shortcutRowButton(title: "Cancel") {
                        shortcutMonitor.cancelRecordingNewShortcut()
                    }
                } else {
                    if !PushToTalkShortcutKeys.isUsingDefaultShortcut {
                        shortcutRowButton(title: "Reset") {
                            PushToTalkShortcutKeys.resetToDefaultShortcut()
                        }
                    }
                    shortcutRowButton(title: "Change") {
                        shortcutMonitor.beginRecordingNewShortcut()
                    }
                }
            }
            .id(shortcutRefreshCounter)

            if shortcutMonitor.isRecordingNewShortcut {
                Text("Press any two keys, one after the other. Esc cancels.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.learnAccent)
            } else if !shortcutMonitor.isEventTapActive {
                Text("Needs Accessibility permission to listen for your shortcut.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
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
        HStack(spacing: 6) {
            Text("Hold")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            keyCapsules(labels: PushToTalkShortcutKeys.currentKeyCapsuleLabels)
            Text("to talk")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    private var recordingInProgressLabel: some View {
        let recordedKeyLabels = shortcutMonitor.keyCodesRecordedSoFar.map {
            PushToTalkShortcutKeys.displayName(forKeyCode: $0)
        }
        let placeholderCount = PushToTalkShortcutKeys.numberOfKeysInShortcut - recordedKeyLabels.count
        let labelsWithPlaceholders = recordedKeyLabels + Array(repeating: "…", count: max(0, placeholderCount))

        return HStack(spacing: 6) {
            Text("New keys")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            keyCapsules(labels: labelsWithPlaceholders)
        }
    }

    private func keyCapsules(labels: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { keyIndex, keyLabel in
                if keyIndex > 0 {
                    Text("+")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                KeyboardKeyLabel(text: keyLabel)
            }
        }
    }

    private func shortcutRowButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
