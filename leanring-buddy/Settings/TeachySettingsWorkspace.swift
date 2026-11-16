import AppKit
import SwiftUI

/// Full settings workspace. The containing notch or window owns its dimensions.
struct TeachySettingsWorkspace: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var selection: TeachySettingsPage
    @ObservedObject private var updater = TeachySoftwareUpdater.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        categoryButton(.account)
                        categoryButton(.general)
                        sidebarHeading("TEACHY")
                        ForEach([TeachySettingsPage.voice, .microphone, .dictation, .shortcuts, .cursor]) { categoryButton($0) }
                        sidebarHeading("WORK")
                        ForEach([TeachySettingsPage.integrations, .agents, .routines, .drawings, .memory]) { categoryButton($0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                Text("Teachy \(updater.shortVersionString) (\(updater.buildNumberString))")
                    .font(DS.Fonts.sans(10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(20)
            }
            .frame(width: 200)
            Rectangle().fill(DS.Colors.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selection.rawValue).font(DS.Fonts.workspaceTitle)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(selection.subtitle).font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    page
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 17)
                .padding(.bottom, 28)
            }
            .id(selection)
        }
        .background(DS.Colors.workspaceBackground)
        .environment(\.settingsStandalone, true)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .account: TeachyAccountSettingsPage()
        case .general: TeachyGeneralSettingsPage(companionManager: companionManager)
        case .voice: TeachyVoiceSettingsPage()
        case .microphone: MicrophoneSettingsSection(startsExpanded: true)
        case .dictation: TeachyDictationSettingsPage()
        case .shortcuts: TeachyShortcutsSettingsPage(shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor)
        case .cursor: TeachyCursorSettingsPage(companionManager: companionManager)
        case .integrations:
            SettingsPageGroup(title: "Browser") { BrowserExtensionSection(startsExpanded: true) }
            ConnectorsSection()
        case .agents: AgentsSection(showsRoutines: false)
        case .routines: RoutinesSection()
        case .drawings: DrawingsSection(startsExpanded: true)
        case .memory: BrainMemorySection()
        }
    }

    private func sidebarHeading(_ text: String) -> some View {
        Text(text).font(DS.Fonts.sans(10, weight: .semibold)).tracking(1.6)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.leading, 10).padding(.top, 15).padding(.bottom, 8)
    }

    private func categoryButton(_ category: TeachySettingsPage) -> some View {
        SettingsSidebarButton(category: category, isSelected: selection == category) { selection = category }
    }
}


private struct SettingsSidebarButton: View {
    let category: TeachySettingsPage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.icon).frame(width: 18)
                Text(category.rawValue).font(DS.Fonts.sans(13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 10).frame(height: 39)
            .background(isSelected ? DS.Colors.surface3 : (isHovered ? DS.Colors.fillQuaternary : .clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

