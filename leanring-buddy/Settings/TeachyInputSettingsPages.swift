import SwiftUI

struct TeachyDictationSettingsPage: View {
    @ObservedObject private var settings = TeachySettings.shared
    private let dictionary: DictationDictionary
    @State private var words: [String]
    @State private var newWord = ""
    @State private var languageSearch = ""
    @State private var lastLanguage = "en"

    init(dictionary: DictationDictionary = .shared) {
        self.dictionary = dictionary
        _words = State(initialValue: dictionary.words)
    }
    private var languages: [TeachyDictationLanguage] {
        TeachyDictationLanguages.all.filter { $0.code != "auto" && (languageSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(languageSearch)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageGroup(title: "Dictionary") {
                HStack(spacing: 8) {
                    TextField("Add a word", text: $newWord).textFieldStyle(.plain).font(DS.Fonts.body)
                        .padding(9).teachyWell(cornerRadius: 8).onSubmit(addWord)
                    Button("Add", action: addWord).teachyButton(.primary, size: .compact)
                        .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !words.isEmpty {
                    SettingsFlowLayout(spacing: 6) {
                        ForEach(words, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word).font(DS.Fonts.sans(12, weight: .semibold))
                                Button {
                                    dictionary.remove(word)
                                    words = dictionary.words
                                } label: { Image(systemName: "xmark") }
                                    .teachyIconButton(sideLength: 17).accessibilityLabel("Remove \(word)")
                            }.padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 4)
                                .background(DS.Colors.fillSecondary, in: Capsule())
                        }
                    }
                }
            }
            Text("Names, jargon, and product words. Teachy leans toward these spellings.")
                .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary).padding(.top, -12)
            SettingsPageGroup(title: "Language") {
                SettingsToggleRow(title: "Auto-detect language", caption: "Teachy figures out the language as you speak.", isOn: Binding(get: { settings.dictationLanguage == "auto" }, set: { automatic in
                    if automatic { lastLanguage = settings.dictationLanguage; settings.dictationLanguage = "auto" }
                    else { settings.dictationLanguage = lastLanguage }
                }))
                TeachyRule()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(DS.Colors.textTertiary)
                    TextField("Search languages", text: $languageSearch).textFieldStyle(.plain).font(DS.Fonts.body)
                }.padding(9).teachyWell(cornerRadius: 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(languages) { language in
                        Button { settings.dictationLanguage = language.code; lastLanguage = language.code } label: {
                            HStack(spacing: 3) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(language.name).font(DS.Fonts.sans(11, weight: .medium))
                                    if let native = TeachyReplyLanguages.language(for: language.code)?.nativeName, native != language.name {
                                        Text(native).font(DS.Fonts.sans(10)).foregroundColor(DS.Colors.textTertiary)
                                    }
                                }.lineLimit(1)
                                Spacer(minLength: 0)
                                if settings.dictationLanguage == language.code {
                                    Image(systemName: "checkmark.circle.fill").font(DS.Fonts.sans(12)).foregroundColor(DS.Colors.pointer)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 35, alignment: .leading).padding(9)
                                .teachyOption(isSelected: settings.dictationLanguage == language.code)
                        }.buttonStyle(.plain).pointerCursor()
                            .accessibilityAddTraits(settings.dictationLanguage == language.code ? .isSelected : [])
                    }
                }
            }
            SettingsPageGroup(title: "Dictation behavior") {
                SettingsToggleRow(title: "Tidy up what I said", caption: "Fix punctuation and remove ums without adding words.", isOn: $settings.dictationCleanupEnabled)
                TeachyRule()
                DictationSpeedRows()
            }
            SettingsPageGroup(title: "Shortcut") { DictationShortcutPickerRow() }
        }
        .onAppear {
            words = dictionary.words
            if settings.dictationLanguage != "auto" { lastLanguage = settings.dictationLanguage }
        }
    }
    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        dictionary.add(word)
        words = dictionary.words
        newWord = ""
    }
}

struct TeachyShortcutsSettingsPage: View {
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    @State private var revision = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageGroup(title: "Talk to Teachy") {
                HStack(spacing: 8) {
                    SettingsPageLabel(title: "Push to talk", caption: "Hold to talk. Release to send.")
                    Spacer(minLength: 4)
                    keyCaps(shortcutMonitor.isRecordingNewShortcut ? shortcutMonitor.keyCodesRecordedSoFar.map { PushToTalkShortcutKeys.displayName(forKeyCode: $0) } : PushToTalkShortcutKeys.currentKeyCapsuleLabels)
                    Button(shortcutMonitor.isRecordingNewShortcut ? "Cancel" : "Change") {
                        if shortcutMonitor.isRecordingNewShortcut { shortcutMonitor.cancelRecordingNewShortcut() }
                        else { shortcutMonitor.beginRecordingNewShortcut() }
                    }.teachyButton(.secondary, size: .compact)
                }.id(revision)
                if shortcutMonitor.isRecordingNewShortcut {
                    Text("Press any two keys, one after the other. Escape cancels.").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                } else if !shortcutMonitor.isEventTapActive {
                    Text("Accessibility permission is needed to listen for your shortcut.").font(DS.Fonts.caption).foregroundColor(DS.Colors.warningText)
                }
                TeachyRule()
                HStack {
                    SettingsPageLabel(title: "Text mode", caption: "Press Control twice to type a question.")
                    Spacer()
                    keyCaps(["control", "control"])
                }
                TeachyRule()
                HStack {
                    SettingsPageLabel(title: "Always-on voice", caption: "Press Control three times to talk hands-free.")
                    Spacer()
                    keyCaps(["control", "control", "control"])
                }
            }
            SettingsPageGroup(title: "Dictation") {
                DictationShortcutPickerRow().id(revision)
            }
            Button("Reset talk and dictation shortcuts") {
                shortcutMonitor.cancelRecordingNewShortcut()
                DictationController.shared.cancelShortcutRecording()
                PushToTalkShortcutKeys.resetToDefaultShortcut()
                DictationShortcut.reset()
                revision += 1
            }.teachyButton(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: PushToTalkShortcutKeys.shortcutDidChangeNotification)) { _ in revision += 1 }
        .onDisappear { shortcutMonitor.cancelRecordingNewShortcut() }
    }
    private func keyCaps(_ labels: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, text in KeyboardKeyLabel(text: text) }
        }
    }
}
