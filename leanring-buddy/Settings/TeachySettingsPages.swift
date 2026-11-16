import AppKit
import SwiftUI

struct TeachyAccountSettingsPage: View {
    @ObservedObject private var session = TeachyPublikSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageGroup(title: "AI payment") {
                SettingsPageLabel(title: paymentTitle, caption: "Teachy chooses the right model for each task.")
                if session.choice == "publik", let wallet = session.wallet {
                    if wallet.planKind != "plan" {
                        Text(String(format: "$%.2f", Double(wallet.balanceMicros) / 1_000_000))
                            .font(DS.Fonts.sans(28, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        Text("Available balance").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    }
                    if let url = URL(string: wallet.topUpURL) {
                        Button("Open publik wallet") { NSWorkspace.shared.open(url) }
                            .buttonStyle(SettingsGlossyButtonStyle(isSelected: true)).pointerCursor()
                    }
                }
                Button("Change how I pay for AI") { session.changePaymentChoice() }
                    .teachyButton(.secondary, size: .compact)
            }
            SettingsPageGroup(title: "Account") {
                HStack {
                    SettingsPageLabel(title: "Log out", caption: session.wallet?.handle.map { "Signed in as @\($0)" } ?? "Signed in to publik")
                    Spacer()
                    Button("Log out") { session.logOut() }.teachyButton(.secondary, size: .compact)
                        .disabled(!session.canLogOut)
                }
                if !session.canLogOut {
                    Text("Remove PUBLIK_API_KEY from the launch environment and restart Teachy to switch accounts.")
                        .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                }
                if let error = session.accountError {
                    Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.destructiveText)
                }
                TeachyRule()
                Button("Quit Teachy") { NSApp.terminate(nil) }
                    .teachyLinkButton(color: DS.Colors.destructiveText, font: DS.Fonts.body)
            }
        }
        .task { await session.refreshWallet() }
    }

    private var paymentTitle: String {
        guard session.choice == "publik" else { return "Your own OpenRouter key" }
        guard let wallet = session.wallet else { return "Your publik account" }
        return wallet.planKind == "plan" ? (wallet.planLabel ?? "Your publik plan") : "Pay as you go with publik"
    }
}

struct TeachyGeneralSettingsPage: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var settings = TeachySettings.shared
    @ObservedObject private var updater = TeachySoftwareUpdater.shared
    @State private var showsAbout = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageGroup(title: "Behavior") {
                SettingsToggleRow(title: "Quiet on calls", caption: "Show answers as captions while you are on a call.", isOn: $settings.quietOnCallsEnabled)
            }
            SettingsPageGroup(title: "Updates") {
                HStack(spacing: 12) {
                    SettingsPageLabel(title: "App updates", caption: "You're on version \(updater.shortVersionString) (\(updater.buildNumberString)).")
                    Spacer(minLength: 8)
                    Button("Check for updates") { updater.checkForUpdates() }
                        .buttonStyle(SettingsGlossyButtonStyle()).pointerCursor().disabled(!updater.canCheckForUpdates)
                }
                TeachyRule()
                actionRow("What's new", caption: "See the latest features in Teachy.") { TeachyAnnouncementController.shared.showLatest() }
                TeachyRule()
                actionRow("About Teachy", caption: "Version, updates, and what Teachy can do.") { showsAbout = true }
            }
            SettingsPageGroup(title: "Browser") { BrowserExtensionSection(startsExpanded: true) }
            SettingsPageGroup(title: "Privacy") { PrivacySettingsSection(startsExpanded: true) }
            SettingsPageGroup(title: "Support") {
                actionRow("Give feedback", caption: "Request a feature or report a bug.") {
                    if let url = URL(string: "https://github.com/VedSoni-dev/teachy/issues") { NSWorkspace.shared.open(url) }
                }
                TeachyRule()
                actionRow("Replay the welcome tour", caption: "Watch the Teachy introduction again.") { companionManager.replayOnboarding() }
            }
            SettingsPageGroup(title: "Advanced") { AdvancedSettingsSection(startsExpanded: true) }
        }
        .sheet(isPresented: $showsAbout) { TeachyAboutSettingsView() }
    }
    private func actionRow(_ title: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                SettingsPageLabel(title: title, caption: caption)
                Spacer()
                Image(systemName: "arrow.up.right").foregroundColor(DS.Colors.textTertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor()
    }
}

struct TeachyVoiceSettingsPage: View {
    @ObservedObject private var settings = TeachySettings.shared
    @ObservedObject private var preview = VoicePreviewPlayer.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)
    private let firstNames = ["Puck", "Zephyr", "Aoede", "Fenrir", "Leda", "Sulafat", "Achird", "Sadachbia", "Kore", "Charon"]
    private var voices: [TeachyVoice] {
        firstNames.compactMap { name in TeachyVoiceCatalog.allVoices.first { $0.name == name } }
        + TeachyVoiceCatalog.allVoices.filter { !firstNames.contains($0.name) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageGroup(title: "Captions") {
                SettingsToggleRow(title: "Captions while Teachy talks", caption: "Show what Teachy says at the bottom of your screen.", isOn: $settings.captionsEnabled)
            }
            SettingsPageGroup(title: "Language") {
                HStack {
                    SettingsPageLabel(title: "Speak to me in", caption: "Automatic: the language you talk to it in.")
                    Spacer()
                    Menu {
                        Button("Automatic") { settings.replyLanguage = TeachyReplyLanguages.automaticCode }
                        ForEach(TeachyReplyLanguages.all) { language in
                            Button(language.pickerLabel) { settings.replyLanguage = language.code }
                        }
                    } label: { Text(TeachyReplyLanguages.language(for: settings.replyLanguage)?.nativeName ?? "Automatic") }
                        .menuStyle(.borderlessButton).fixedSize().pointerCursor()
                }
            }
            SettingsPageGroup(title: "Speech speed") {
                HStack(spacing: 8) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5], id: \.self) { speed in
                        Button(TeachySpeechSpeed.label(speed)) { settings.speechSpeed = speed }
                            .buttonStyle(SettingsGlossyButtonStyle(isSelected: settings.speechSpeed == speed))
                            .pointerCursor()
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 10) {
                SettingsPageHeading(title: "Voices")
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(voices) { voice in voiceTile(voice) }
                }
                if let error = preview.errorMessage {
                    Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.destructiveText)
                }
            }
            SettingsPageGroup(title: "Listening") {
                HStack {
                    SettingsPageLabel(title: "Fine-tune speech speed")
                    Text(TeachySpeechSpeed.label(settings.speechSpeed)).font(DS.Fonts.data).foregroundColor(DS.Colors.textSecondary)
                }
                TeachySlider(value: $settings.speechSpeed, in: TeachySpeechSpeed.range).accessibilityLabel("Speech speed")
                TeachyRule()
                SettingsToggleRow(title: "Quiet on calls", caption: "Show captions instead of speaking while you are on a call.", isOn: $settings.quietOnCallsEnabled)
                TeachyRule()
                HStack {
                    SettingsPageLabel(title: "Always-on switches off after", caption: "Press Control three times to talk hands-free.")
                    Spacer()
                    Menu("\(settings.alwaysOnAutoOffMinutes) min") {
                        ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                            Button("\(minutes) min") { settings.alwaysOnAutoOffMinutes = minutes }
                        }
                    }.menuStyle(.borderlessButton).fixedSize().pointerCursor()
                }
            }
        }.onDisappear { preview.stop() }
    }
    private func voiceTile(_ voice: TeachyVoice) -> some View {
        VStack(spacing: 6) {
            Button { settings.voiceName = voice.name } label: {
                VStack(spacing: 7) {
                    Image(systemName: symbol(for: voice.name)).font(DS.Fonts.sans(24)).foregroundColor(voiceColor(for: voice.name))
                    Text(voice.displayName).font(DS.Fonts.sans(12, weight: .semibold)).lineLimit(1)
                    Text(voice.character.components(separatedBy: ",").first ?? voice.character)
                        .font(DS.Fonts.sans(10)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }.frame(maxWidth: .infinity).padding(.top, 14)
            }.buttonStyle(.plain).pointerCursor()
            Button { preview.toggle(voice: voice.name, speed: settings.speechSpeed) } label: {
                if preview.isLoading(voice.name) { ProgressView().controlSize(.mini) }
                else { Image(systemName: preview.isPlaying(voice.name) ? "stop.fill" : "play.fill") }
            }.teachyIconButton(sideLength: 20).accessibilityLabel("Preview \(voice.displayName)")
        }
        .padding(.bottom, 6).frame(maxWidth: .infinity)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(settings.voiceName == voice.name ? DS.Colors.pointer : DS.Colors.hairline, lineWidth: settings.voiceName == voice.name ? 2 : 1))
        .accessibilityAddTraits(settings.voiceName == voice.name ? .isSelected : [])
    }
    private func symbol(for name: String) -> String {
        ["Puck": "face.smiling", "Zephyr": "sun.max.fill", "Aoede": "wind", "Fenrir": "bolt.fill", "Leda": "sparkle", "Sulafat": "flame.fill", "Achird": "hand.wave.fill", "Sadachbia": "party.popper.fill", "Kore": "diamond.fill", "Charon": "book.fill"][name] ?? "waveform"
    }
    private func voiceColor(for name: String) -> Color {
        switch name {
        case "Puck", "Zephyr": return DS.Colors.warning
        case "Fenrir", "Sulafat": return DS.Colors.destructiveText
        case "Achird": return DS.Colors.pointerColor(named: "green")
        default: return DS.Colors.pointer
        }
    }
}

struct TeachyCursorSettingsPage: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var settings = TeachySettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsPageHeading(title: "Color")
                HStack(spacing: 12) {
                    ForEach(ClickyCursorColor.allCases) { color in
                        Button {
                            companionManager.setSelectedCursorColor(color)
                            settings.cursorColor = color
                        } label: {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(DS.Colors.workspaceCard)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    TeachyPointerShape().fill(color.displayColor).frame(width: 26, height: 30)
                                        .shadow(color: color.displayColor, radius: 14)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if companionManager.selectedCursorColor == color {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Colors.pointer).padding(10)
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(companionManager.selectedCursorColor == color ? DS.Colors.pointer : DS.Colors.workspaceBorder, lineWidth: companionManager.selectedCursorColor == color ? 2 : 1))
                        }.buttonStyle(.plain).pointerCursor().accessibilityLabel("\(color.rawValue) cursor")
                            .accessibilityAddTraits(companionManager.selectedCursorColor == color ? .isSelected : [])
                    }
                }
            }
            SettingsPageGroup(title: "Visibility") {
                SettingsToggleRow(title: "Hide floating cursor", caption: "Hide the cursor until your next interaction.", isOn: Binding(get: { !companionManager.isClickyCursorEnabled }, set: { companionManager.setClickyCursorEnabled(!$0) }))
            }
        }
    }
}

/// A compact About surface, backed by the installed app's version and updater.
struct TeachyAboutSettingsView: View {
    @ObservedObject private var updater = TeachySoftwareUpdater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
            }
            Text("Teachy").font(DS.Fonts.sans(22, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
            Text("Version \(updater.shortVersionString) (\(updater.buildNumberString))")
                .font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
            Text("Ask about your screen, dictate into any app, and work with agents, routines, and connected tools.")
                .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Check for updates") { updater.checkForUpdates() }
                    .buttonStyle(SettingsGlossyButtonStyle()).pointerCursor()
                    .disabled(!updater.canCheckForUpdates)
                Button("Done") { dismiss() }
                    .buttonStyle(SettingsGlossyButtonStyle(isSelected: true)).pointerCursor()
                    .keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }
        .padding(28).frame(width: 340)
        .background(DS.Colors.workspaceBackground)
        .environment(\.colorScheme, .dark)
    }
}

/// Local treatment for the reference's pale, highlighted capsule controls.
private struct SettingsGlossyButtonStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.controlCompact)
            .foregroundColor(DS.Colors.notchBlack)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background {
                Capsule().fill(LinearGradient(
                    colors: [DS.Colors.textPrimary, isSelected ? DS.Colors.pointer.opacity(0.65) : DS.Colors.textPrimary.opacity(0.58)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .overlay(Capsule().strokeBorder(isSelected ? DS.Colors.pointer : DS.Colors.hairlineStrong, lineWidth: 1))
            .shadow(color: DS.Colors.notchBlack.opacity(0.18), radius: 2, y: 1)
            .brightness(isHovered ? 0.05 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { isHovered = $0 }
    }
}
