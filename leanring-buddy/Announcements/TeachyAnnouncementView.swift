import SwiftUI

struct TeachyAnnouncementView: View {
    let announcement: TeachyAnnouncement
    let dismiss: () -> Void
    var contentSizeChanged: (CGSize) -> Void = { _ in }
    @ObservedObject private var settings = TeachySettings.shared
    @State private var keyCodes = DictationShortcut.current()
    @State private var isRecording = false
    @State private var shortcutProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 58)
                .padding(.bottom, 18)

            Text(announcement.title)
                .font(DS.Fonts.announcementTitle)
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Text(announcement.message)
                .font(DS.Fonts.announcementBody)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            if announcement.showsDictationControls {
                VStack(spacing: 8) {
                    shortcutRow
                    languageRow
                }
                .padding(.horizontal, 50)
                .padding(.top, 22)
            }

            Button("Got it", action: finish)
                .teachyButton(.primary, size: .large, isFullWidth: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isRecording)
                .padding(.horizontal, 60)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: AnnouncementContentSize.self, value: geometry.size)
            }
        }
        .onPreferenceChange(AnnouncementContentSize.self, perform: contentSizeChanged)
        .background {
            TeachyGlassSurface(
                shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                dimming: TeachyGlass.tileDimming,
                solidFill: DS.Colors.surface2
            )
        }
        .overlay(alignment: .topTrailing) {
            Button(action: finish) { Image(systemName: "xmark") }
                .teachyIconButton(sideLength: 28, isFilled: true)
                .accessibilityLabel("Close announcement")
                .help("Close announcement")
                .padding(10)
        }
        .preferredColorScheme(.dark)
        .onExitCommand {
            if isRecording { DictationController.shared.cancelShortcutRecording() }
            else { finish() }
        }
        .onAppear { keyCodes = DictationShortcut.current() }
        .onReceive(NotificationCenter.default.publisher(for: DictationShortcut.didChangeNotification)) { _ in
            keyCodes = DictationShortcut.current()
        }
        .onDisappear { cancelRecording() }
    }

    private var hero: some View {
        TeachyPointerShape()
            .fill(DS.Colors.pointer)
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: announcement.symbol)
                    .font(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.pointer)
                    .frame(width: 26, height: 26)
                    .background(DS.Colors.textPrimary, in: Circle())
                    .offset(x: 8, y: 4)
            }
            .accessibilityHidden(true)
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRecording {
                HStack {
                    Text("Hold your new keys…").font(DS.Fonts.bodyEmphasized)
                    Spacer(minLength: 0)
                    changeShortcutButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        shortcutLabel
                        Spacer(minLength: 0)
                        shortcutKeys
                        changeShortcutButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            shortcutLabel
                            Spacer(minLength: 0)
                            changeShortcutButton
                        }
                        shortcutKeys
                    }
                }
            }
            if let shortcutProblem {
                Text(shortcutProblem)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .padding(14)
        .teachyGroup()
    }

    private var shortcutLabel: some View {
        Label("Shortcut", systemImage: "keyboard")
            .font(DS.Fonts.bodyEmphasized)
            .fixedSize()
    }

    private var shortcutKeys: some View {
        HStack(spacing: 3) {
            ForEach(Array(keyCodes.enumerated()), id: \.offset) { _, keyCode in
                KeyboardKeyLabel(text: PushToTalkShortcutKeys.displayName(forKeyCode: keyCode))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation shortcut: \(keyCodes.map { PushToTalkShortcutKeys.displayName(forKeyCode: $0) }.joined(separator: " + "))")
    }

    private var changeShortcutButton: some View {
        Button(isRecording ? "Cancel" : "Change") {
            if isRecording { DictationController.shared.cancelShortcutRecording() }
            else { recordShortcut() }
        }
        .teachyButton(.secondary)
        .fixedSize()
        .accessibilityLabel(isRecording ? "Cancel shortcut recording" : "Change dictation shortcut")
    }

    private var languageRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(DS.Colors.textSecondary)
            Text("Language").font(DS.Fonts.bodyEmphasized)
            Spacer(minLength: 0)
            Menu {
                Picker("Dictation language", selection: $settings.dictationLanguage) {
                    ForEach(TeachyDictationLanguages.all) { language in
                        Text(language.name).tag(language.code)
                    }
                    if !TeachyDictationLanguages.all.contains(where: { $0.code == settings.dictationLanguage }) {
                        Text(TeachyDictationLanguages.name(for: settings.dictationLanguage)).tag(settings.dictationLanguage)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.up.chevron.down")
                    Text(TeachyDictationLanguages.name(for: settings.dictationLanguage))
                }
                .font(DS.Fonts.bodyEmphasized)
                .foregroundStyle(DS.Colors.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("Dictation language")
            .accessibilityValue(TeachyDictationLanguages.name(for: settings.dictationLanguage))
            .disabled(isRecording)
        }
        .frame(minHeight: 26)
        .padding(14)
        .teachyGroup()
    }

    private func recordShortcut() {
        shortcutProblem = nil
        isRecording = true
        DictationController.shared.recordShortcut { result in
            isRecording = false
            switch result {
            case .saved(let codes): keyCodes = codes
            case .cancelled: break
            case .rejected(let message): shortcutProblem = message
            }
        }
    }

    private func cancelRecording() {
        if isRecording { DictationController.shared.cancelShortcutRecording() }
    }

    private func finish() {
        cancelRecording()
        dismiss()
    }
}

private struct AnnouncementContentSize: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
