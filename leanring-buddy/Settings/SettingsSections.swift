//
//  SettingsSections.swift
//  leanring-buddy
//
//  The settings rows on the notch panel's Home tab: Voice, Dictation, Shortcuts,
//  Privacy and Advanced. Each is a row of a grouped list that starts closed with
//  a one-line summary, so Home stays short. They read and write `TeachySettings.shared`.
//

import AppKit
import SwiftUI

// MARK: - Building blocks

private struct SettingsStandaloneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Category pages show the existing controls without a second disclosure layer.
    var settingsStandalone: Bool {
        get { self[SettingsStandaloneKey.self] }
        set { self[SettingsStandaloneKey.self] = newValue }
    }
}


/// One row of a grouped settings list: a tinted symbol, the title, a one-line
/// summary and a chevron. Clicking it opens the row in place; the content sits
/// under the title. Rows go inside a `.teachyGroup()` container, and each row
/// draws the inset divider below itself, the way System Settings does.
/// (The name is from when this was a card.)
struct SettingsDisclosureCard<Content: View>: View {
    let icon: String
    let title: String
    let summary: String?
    @State private var isExpanded: Bool
    @State private var isHeaderHovered = false
    @Environment(\.settingsStandalone) private var isStandalone
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled
    private let content: Content

    /// The opened content and the divider line up with the title, past the symbol.
    private let contentLeadingInset: CGFloat = 30

    init(
        icon: String,
        title: String,
        summary: String? = nil,
        startsExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.summary = summary
        self._isExpanded = State(initialValue: startsExpanded)
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if isStandalone {
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            disclosureBody
        }
    }

    private var disclosureBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon)
                        .font(DS.Fonts.sans(13, weight: .medium))
                        .foregroundColor(DS.Colors.pointer)
                        .frame(width: 20)

                    Text(title)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)

                    Spacer(minLength: 12)

                    if let summary, !isExpanded {
                        Text(summary)
                            .font(DS.Fonts.sans(12).monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Image(systemName: "chevron.right")
                        .font(DS.Fonts.sans(10, weight: .semibold))
                        .foregroundColor(isHeaderHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                withAnimation(DS.Motion.hover) { isHeaderHovered = hovering }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(.leading, contentLeadingInset)
                .padding(.top, 2)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            TeachyRule()
                .padding(.leading, contentLeadingInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label on the left and Teachy's switch on the right; the whole row toggles.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            DS.Haptics.stateChanged()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                configuration.label
                Spacer(minLength: 8)
                TeachySwitch(isOn: configuration.isOn)
                    .padding(.top, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// A title, a line of plain-words explanation, and a switch.
struct SettingsToggleRow: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                if let caption {
                    Text(caption)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .toggleStyle(SettingsSwitchStyle())
    }
}

struct SettingsDivider: View {
    var body: some View {
        TeachyRule()
    }
}

/// A quiet heading inside an opened row. Sentence case, never capitals.
private struct SettingsSubheading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.Fonts.sans(12, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
    }
}

private struct SettingsCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Hold [control] [option]" drawn with key caps.
struct ShortcutKeysView: View {
    let shortcut: TeachyShortcut

    var body: some View {
        HStack(spacing: 4) {
            Text(shortcut.gestureWord)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.trailing, 2)
            ForEach(Array(shortcut.keyLabels.enumerated()), id: \.offset) { _, label in
                KeyboardKeyLabel(text: label)
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let shortcut: TeachyShortcut

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 8)
            ShortcutKeysView(shortcut: shortcut)
        }
    }
}

/// Lays children out left to right and wraps to a new row when the width runs out.
struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arranged.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

// MARK: - Pieces the sections below share

/// The label of a control inside an opened row, with its one-line explanation
/// under it. The same left side as `SettingsToggleRow`, for rows that end in
/// something other than a switch (a menu, a field) or in nothing at all.
private struct SettingsLabelWithCaption: View {
    let title: String
    let caption: Text

    init(title: String, caption: String) {
        self.title = title
        self.caption = Text(caption)
    }

    /// For a caption that sets part of itself in mono (a file path).
    init(title: String, styledCaption: Text) {
        self.title = title
        self.caption = styledCaption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
            caption
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }
}

/// A menu that shows the value it holds ("Español", "5 min"), drawn the way an
/// unselected option is.
private struct SettingsValueMenu<MenuItems: View>: View {
    let valueText: String
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        Menu {
            menuItems()
        } label: {
            Text(valueText)
                .font(DS.Fonts.controlCompact)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(DS.Colors.textPrimary)
        }
        .menuStyle(.borderlessButton)
        // The system's own chevron: a borderless menu draws a symbol placed in
        // its label before the text, not after it.
        .menuIndicator(.visible)
        .fixedSize()
        // On the menu itself: a borderless menu ignores backgrounds inside its label.
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .teachyOption(isSelected: false)
        .pointerCursor()
    }
}

private extension View {
    /// The well a settings text field sits in.
    func settingsFieldWell() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .teachyWell(cornerRadius: DS.CornerRadius.control, isEdged: true)
    }
}

// MARK: - Voice

struct VoiceSettingsSection: View {
    @ObservedObject private var settings = TeachySettings.shared
    @ObservedObject private var preview: VoicePreviewPlayer
    private let startsExpanded: Bool

    init(startsExpanded: Bool = false, preview: VoicePreviewPlayer? = nil, showsMoreVoices: Bool = false) {
        self.startsExpanded = startsExpanded
        self.preview = preview ?? .shared
        self._showsMoreVoices = State(initialValue: showsMoreVoices)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    @State private var showsMoreVoices: Bool

    /// The first eight, plus the chosen voice if it is one of the others, until "More voices" is opened.
    private var visibleVoices: [TeachyVoice] {
        if showsMoreVoices { return TeachyVoiceCatalog.allVoices }
        let chosen = TeachyVoiceCatalog.moreVoices.filter { $0.name == settings.voiceName }
        return TeachyVoiceCatalog.voices + chosen
    }

    private var summary: String {
        var parts = [settings.selectedVoice.displayName, TeachySpeechSpeed.label(settings.speechSpeed)]
        if let language = TeachyReplyLanguages.language(for: settings.replyLanguage) { parts.append(language.nativeName) }
        if settings.captionsEnabled { parts.append("captions on") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SettingsDisclosureCard(
            icon: "waveform",
            title: "Voice",
            summary: summary,
            startsExpanded: startsExpanded
        ) {
            SettingsCaption(text: "Pick the voice Teachy answers in. Press play to hear one first.")

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(visibleVoices) { voice in
                    voiceChip(voice)
                }
            }

            Button(showsMoreVoices ? "Fewer voices" : "More voices (\(TeachyVoiceCatalog.moreVoices.count))") {
                withAnimation(DS.Motion.standard) { showsMoreVoices.toggle() }
            }
            .teachyLinkButton()

            if let errorMessage = preview.errorMessage {
                Text(errorMessage)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Speed")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text(TeachySpeechSpeed.label(settings.speechSpeed))
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "tortoise")
                        .font(DS.Fonts.sans(11))
                        .foregroundColor(DS.Colors.textTertiary)
                    // The setting snaps to 0.05 itself.
                    TeachySlider(value: $settings.speechSpeed, in: TeachySpeechSpeed.range)
                    Image(systemName: "hare")
                        .font(DS.Fonts.sans(11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            SettingsDivider()

            HStack(alignment: .top, spacing: 8) {
                SettingsLabelWithCaption(
                    title: "Answer in",
                    caption: settings.replyLanguage == TeachyReplyLanguages.automaticCode
                        ? "Teachy answers in whatever language you speak to it."
                        : "Teachy always answers in this language, and listens for it."
                )
                Spacer(minLength: 8)
                SettingsValueMenu(
                    valueText: TeachyReplyLanguages.language(for: settings.replyLanguage)?.nativeName ?? "Same as you speak"
                ) {
                    Button("Same as you speak") { settings.replyLanguage = TeachyReplyLanguages.automaticCode }
                    Divider()
                    ForEach(TeachyReplyLanguages.all) { language in
                        Button(language.pickerLabel) { settings.replyLanguage = language.code }
                    }
                }
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Captions while Teachy talks",
                caption: "Shows the words at the bottom of your screen as they are spoken. Typed questions always get captions.",
                isOn: $settings.captionsEnabled
            )

            SettingsToggleRow(
                title: "Quiet on calls",
                caption: "On a call, answers show as captions and are copied instead of spoken, unless you hold the talk key. With your Mac muted, they are always shown and copied.",
                isOn: $settings.quietOnCallsEnabled
            )

            SettingsDivider()

            HStack(alignment: .top, spacing: 8) {
                SettingsLabelWithCaption(
                    title: "Always-on switches off after",
                    caption: "Press Control three times to talk without holding a key. It also switches off when your Mac locks or sleeps."
                )
                Spacer(minLength: 8)
                SettingsValueMenu(valueText: "\(settings.alwaysOnAutoOffMinutes) min") {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                        Button("\(minutes) quiet minute\(minutes == 1 ? "" : "s")") { settings.alwaysOnAutoOffMinutes = minutes }
                    }
                }
            }
        }
        .onDisappear { preview.stop() }
    }

    private func voiceChip(_ voice: TeachyVoice) -> some View {
        let isSelected = settings.voiceName == voice.name
        let isPlayingPreview = preview.isPlaying(voice.name)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.displayName)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(voice.character)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                preview.toggle(voice: voice.name, speed: settings.speechSpeed)
            } label: {
                if preview.isLoading(voice.name) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                } else {
                    // A preview that is playing is live, so its symbol takes the tint.
                    Image(systemName: isPlayingPreview ? "stop.fill" : "play.fill")
                        .foregroundColor(isPlayingPreview ? DS.Colors.pointer : nil)
                }
            }
            .teachyIconButton()
            .help("Hear \(voice.displayName)")
            .accessibilityLabel("Preview \(voice.displayName)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .teachyOption(isSelected: isSelected)
        .onTapGesture { settings.voiceName = voice.name }
        .pointerCursor()
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Dictation

struct DictationSettingsSection: View {
    @ObservedObject private var settings = TeachySettings.shared
    private let dictionary: DictationDictionary
    private let startsExpanded: Bool

    @State private var words: [String] = []
    @State private var newWord: String = ""
    @State private var isShowingEveryWord = false

    /// Words shown before "Show all".
    private let collapsedWordLimit = 24

    init(startsExpanded: Bool = false, dictionary: DictationDictionary = .shared) {
        self.startsExpanded = startsExpanded
        self.dictionary = dictionary
        self._words = State(initialValue: dictionary.words)
    }

    private var summary: String {
        let count = words.count == 1 ? "1 word" : "\(words.count) words"
        return "\(count) · \(TeachyDictationLanguages.name(for: settings.dictationLanguage))"
    }

    /// Newest first.
    private var visibleWords: [String] {
        let newestFirst = Array(words.reversed())
        return isShowingEveryWord ? newestFirst : Array(newestFirst.prefix(collapsedWordLimit))
    }

    var body: some View {
        SettingsDisclosureCard(icon: "character.cursor.ibeam", title: "Dictation", summary: summary, startsExpanded: startsExpanded) {
            dictionaryBlock

            SettingsDivider()

            HStack(alignment: .top, spacing: 8) {
                SettingsLabelWithCaption(
                    title: "Language",
                    caption: "Auto-detect works for most people. Pick one if it guesses wrong."
                )
                Spacer(minLength: 8)
                languageMenu
            }

            SettingsToggleRow(
                title: "Tidy up what I said",
                caption: "Fixes punctuation and drops the ums. Never adds words you didn't say.",
                isOn: $settings.dictationCleanupEnabled
            )

            DictationSpeedRows()

            SettingsDivider()

            DictationShortcutPickerRow()
        }
        .onAppear { words = dictionary.words }
    }

    private var dictionaryBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                SettingsSubheading(text: "Dictionary")
                SettingsCaption(text: "Names and words to spell your way. Teachy also adds a word when you correct it right after dictating.")
            }

            if words.isEmpty {
                SettingsCaption(text: "No words yet.")
            } else {
                SettingsFlowLayout(spacing: 6) {
                    ForEach(visibleWords, id: \.self) { word in
                        wordChip(word)
                    }
                }
                if words.count > collapsedWordLimit {
                    Button(isShowingEveryWord ? "Show fewer" : "Show all \(words.count)") {
                        isShowingEveryWord.toggle()
                    }
                    .teachyLinkButton()
                }
            }

            HStack(spacing: 6) {
                TextField(
                    "",
                    text: $newWord,
                    prompt: Text("Add a word or name").foregroundColor(DS.Colors.textQuaternary)
                )
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .settingsFieldWell()
                    .onSubmit(addWord)

                Button("Add", action: addWord)
                    .teachyButton(.secondary)
                    .disabled(trimmedNewWord.isEmpty)
            }

            // The path is a real path, so it alone is mono.
            (Text("Saved on this Mac in ") + Text(DictationPaths.dictionaryDisplayPath).font(DS.Fonts.mono(11)))
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    /// One word of the dictionary: a small grey token with a cross that removes it.
    private func wordChip(_ word: String) -> some View {
        HStack(spacing: 1) {
            Text(word)
                .font(DS.Fonts.sans(12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Button {
                dictionary.remove(word)
                words = dictionary.words
            } label: {
                Image(systemName: "xmark")
            }
            .teachyIconButton(sideLength: 18)
            .help("Remove \(word)")
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .teachyWell(cornerRadius: DS.CornerRadius.small)
    }

    private var languageMenu: some View {
        SettingsValueMenu(valueText: TeachyDictationLanguages.name(for: settings.dictationLanguage)) {
            ForEach(TeachyDictationLanguages.all) { language in
                Button {
                    settings.dictationLanguage = language.code
                } label: {
                    if settings.dictationLanguage == language.code {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        }
    }

    private var trimmedNewWord: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addWord() {
        guard !trimmedNewWord.isEmpty else { return }
        dictionary.add(trimmedNewWord)
        newWord = ""
        words = dictionary.words
    }
}

// MARK: - Shortcuts

extension ShortcutsSettingsSection {
    /// The dictation keys as they are set right now, one label per key.
    static var dictationKeyLabels: [String] {
        DictationShortcut.current().map { PushToTalkShortcutKeys.displayName(forKeyCode: $0) }
    }
}

/// One shortcut as it is set right now: what it does on the left, the gesture
/// and its key caps on the right. Drawn like `ShortcutRow`, but from key labels,
/// because the talk and dictation keys can be any keys, not only modifiers.
private struct LiveShortcutRow: View {
    let title: String
    /// "Hold" or "Double-tap".
    let gestureWord: String
    let keyLabels: [String]
    /// A few words after the keys ("again to stop").
    var noteAfterKeys: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(gestureWord)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.trailing, 2)
                ForEach(Array(keyLabels.enumerated()), id: \.offset) { _, keyLabel in
                    KeyboardKeyLabel(text: keyLabel)
                }
                if let noteAfterKeys {
                    Text(noteAfterKeys)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

struct ShortcutsSettingsSection: View {
    @ObservedObject private var settings = TeachySettings.shared
    private let startsExpanded: Bool

    init(startsExpanded: Bool = false) {
        self.startsExpanded = startsExpanded
    }

    var body: some View {
        SettingsDisclosureCard(
            icon: "keyboard",
            title: "Shortcuts",
            summary: "\(settings.shortcuts.rows.count) shortcuts",
            startsExpanded: startsExpanded
        ) {
            // Live values: the talk and dictation keys can both be changed.
            LiveShortcutRow(title: "Ask by voice", gestureWord: "Hold", keyLabels: PushToTalkShortcutKeys.currentKeyCapsuleLabels)
            LiveShortcutRow(title: "Type a question", gestureWord: "Double-tap", keyLabels: ["control"])
            LiveShortcutRow(title: "Dictate", gestureWord: "Hold", keyLabels: Self.dictationKeyLabels)
            LiveShortcutRow(title: "Hands-free dictation", gestureWord: "Double-tap", keyLabels: Self.dictationKeyLabels, noteAfterKeys: "again to stop")
            SettingsCaption(text: "These work in any app. Change the talk keys at the top of this tab, and the dictation keys under Dictation.")
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsSection: View {
    @ObservedObject private var settings = TeachySettings.shared
    private let startsExpanded: Bool

    init(startsExpanded: Bool = false) {
        self.startsExpanded = startsExpanded
    }

    var body: some View {
        SettingsDisclosureCard(
            icon: "lock.fill",
            title: "Privacy",
            summary: "What leaves this Mac",
            startsExpanded: startsExpanded
        ) {
            SettingsLabelWithCaption(
                title: "Your screen",
                caption: "A screenshot is taken only when you ask (talk key or text box) and during a walkthrough or task you started. It goes to publik to answer that moment. Teachy never watches unasked."
            )
            SettingsLabelWithCaption(
                title: "Your voice",
                caption: "What you say goes to publik to become text, and Teachy's answers go to publik to be spoken. If publik can't be reached, your Mac's own dictation and voice are used."
            )
            SettingsLabelWithCaption(
                title: "Stays on this Mac",
                styledCaption: Text("Memory, your dictation dictionary and your dictation history are plain files in ")
                    + Text("~/.teachy").font(DS.Fonts.mono(11))
                    + Text(". Read, edit or delete them any time.")
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "Auto permissions",
                caption: "On: agents click, type, browse and change things without stopping to ask. They still ask every time before deleting, sending, paying, posting or touching passwords. Off: they ask before every change.",
                isOn: $settings.agentAutoPermissions
            )

            SettingsToggleRow(
                title: "Let agents use my browser sign-ins",
                caption: "Off: Teachy never reads cookies from Safari, Chrome or other browsers. On: agent tools can open sites as you, using the sign-ins already in your browser.",
                isOn: $settings.allowBrowserCookieTools
            )
        }
    }
}

// MARK: - Advanced (own ElevenLabs key)

/// The optional ElevenLabs key. `LocalSpeechSynthesizer.speakText` still tries it
/// first for whole messages (walkthrough steps, notices), so it stays, tucked away here.
/// Streamed answers always use the publik voice from the Voice card.
struct AdvancedSettingsSection: View {
    private let startsExpanded: Bool

    @State private var apiKeyInput: String = ""
    @State private var isValidating: Bool = false
    @State private var errorMessage: String?
    @State private var isConfigured: Bool = TeachyElevenLabsKeyStore.isConfigured

    init(startsExpanded: Bool = false) {
        self.startsExpanded = startsExpanded
    }

    var body: some View {
        SettingsDisclosureCard(
            icon: "slider.horizontal.3",
            title: "Advanced",
            summary: isConfigured ? "ElevenLabs key set" : nil,
            startsExpanded: startsExpanded
        ) {
            SettingsLabelWithCaption(
                title: "Your own ElevenLabs key",
                caption: "Optional. Used for walkthrough steps and short notices only, and billed by ElevenLabs. Spoken answers use the voice you picked above."
            )

            if isConfigured {
                HStack(spacing: 8) {
                    TeachyStatusMark(kind: .done)
                    Text("Key saved")
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button("Remove") {
                        TeachyElevenLabsKeyStore.apiKey = nil
                        apiKeyInput = ""
                        errorMessage = nil
                        isConfigured = false
                    }
                    .teachyButton(.danger, size: .compact)
                }
            } else {
                HStack(spacing: 6) {
                    SecureField(
                        "",
                        text: $apiKeyInput,
                        prompt: Text("ElevenLabs API key").font(DS.Fonts.body).foregroundColor(DS.Colors.textQuaternary)
                    )
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.mono(12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .settingsFieldWell()
                        .onSubmit(validateAndSave)

                    Button(action: validateAndSave) {
                        Group {
                            if isValidating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Save")
                            }
                        }
                        // The spinner is narrower than the word: hold the button's width.
                        .frame(minWidth: 30)
                    }
                    .teachyButton(.secondary)
                    .disabled(trimmedKey.isEmpty || isValidating)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var trimmedKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateAndSave() {
        let key = trimmedKey
        guard !key.isEmpty, !isValidating else { return }

        isValidating = true
        errorMessage = nil

        Task {
            // Validate against the endpoint Teachy actually uses (text-to-speech). Keys
            // can be scoped to "Text to Speech only", which is all Teachy needs but
            // fails on /v1/voices or /v1/user, so those would reject a good key.
            let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(TeachyElevenLabsKeyStore.voiceID)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": "Hi",
                "model_id": "eleven_turbo_v2_5",
            ])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    TeachyElevenLabsKeyStore.apiKey = key
                    isConfigured = true
                } else {
                    errorMessage = Self.errorMessage(from: data)
                }
            } catch {
                errorMessage = "Couldn't reach ElevenLabs. Check your connection."
            }
            isValidating = false
        }
    }

    /// ElevenLabs tells an invalid key apart from a valid key that lacks a
    /// permission. Say which, so people fix the right thing.
    private static func errorMessage(from responseData: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let detail = json["detail"] as? [String: Any],
            let status = detail["status"] as? String
        else {
            return "That key doesn't seem valid. Check it and try again."
        }
        if status == "missing_permissions" {
            return "That key is missing the Text to Speech permission. Turn it on in ElevenLabs, under API Keys."
        }
        return "That key doesn't seem valid. Check it and try again."
    }
}


/// Dictation speed switches (keys documented in Dictation/DictationSpeedPolicy.swift).
struct DictationSpeedRows: View {
    @AppStorage("teachyDictationLiveInsertionEnabled") private var typesAsYouSpeak = true
    @AppStorage("teachyDictationSpeedMode") private var speedMode = "speed"

    var body: some View {
        SettingsToggleRow(
            title: "Type while I'm speaking",
            caption: "Words appear in the field as you say them, then get corrected when you let go. Turn off if an app handles it badly.",
            isOn: $typesAsYouSpeak
        )
        SettingsToggleRow(
            title: "Speed first",
            caption: "Finish with the on-device text right away and fix it up after. Off waits for the most accurate transcript before typing.",
            isOn: Binding(get: { speedMode != "accuracy" }, set: { speedMode = $0 ? "speed" : "accuracy" })
        )
    }
}

struct SettingsPageGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { SettingsPageHeading(title: title) }
            VStack(alignment: .leading, spacing: 13, content: content)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        }
    }
}

struct SettingsPageHeading: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(DS.Fonts.sans(10, weight: .semibold)).tracking(1.4)
            .foregroundColor(DS.Colors.textTertiary).padding(.leading, 3)
    }
}

struct SettingsPageLabel: View {
    let title: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.Fonts.bodyEmphasized).foregroundColor(DS.Colors.textPrimary)
            if let caption {
                Text(caption).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
