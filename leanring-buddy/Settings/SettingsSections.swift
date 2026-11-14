//
//  SettingsSections.swift
//  leanring-buddy
//
//  The settings cards on the notch panel's Home tab: Voice, Dictation, Shortcuts,
//  Privacy and Advanced. Each is a card that starts collapsed with a one-line
//  summary, so Home stays short. They read and write `TeachySettings.shared`.
//

import AppKit
import SwiftUI

// MARK: - Building blocks

/// A glass card with a tappable header (icon, title, summary, chevron) that
/// shows or hides its content.
struct SettingsDisclosureCard<Content: View>: View {
    let icon: String
    let title: String
    let summary: String?
    @State private var isExpanded: Bool
    private let content: Content

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                        .frame(width: 16)

                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Spacer(minLength: 8)

                    if let summary, !isExpanded {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// A small dark-theme switch drawn in SwiftUI (the system one is light-on-light here).
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? DS.Colors.learnAccent : Color.white.opacity(0.14))
                    .frame(width: 32, height: 19)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 15, height: 15)
                            .padding(2)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
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
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }
}

private struct SettingsSubheading: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundColor(DS.Colors.textTertiary)
    }
}

private struct SettingsCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Hold [control] + [option]" drawn with key caps.
struct ShortcutKeysView: View {
    let shortcut: TeachyShortcut

    var body: some View {
        HStack(spacing: 5) {
            Text(shortcut.gestureWord)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            ForEach(Array(shortcut.keyLabels.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Text("+")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
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
                .font(.system(size: 12, weight: .medium))
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

// MARK: - Voice

struct VoiceSettingsSection: View {
    @ObservedObject private var settings = TeachySettings.shared
    @ObservedObject private var preview: VoicePreviewPlayer
    private let startsExpanded: Bool

    init(startsExpanded: Bool = false, preview: VoicePreviewPlayer? = nil) {
        self.startsExpanded = startsExpanded
        self.preview = preview ?? .shared
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        SettingsDisclosureCard(
            icon: "waveform",
            title: "Voice",
            summary: "\(settings.selectedVoice.displayName) · \(TeachySpeechSpeed.label(settings.speechSpeed))"
                + (settings.captionsEnabled ? " · captions on" : ""),
            startsExpanded: startsExpanded
        ) {
            SettingsCaption(text: "Pick the voice Teachy answers in. Press play to hear one first.")

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(TeachyVoiceCatalog.voices) { voice in
                    voiceChip(voice)
                }
            }

            if let errorMessage = preview.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text(TeachySpeechSpeed.label(settings.speechSpeed))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(DS.Colors.textSecondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    // No `step:` here (it draws a row of tick marks). The setting
                    // snaps to 0.05 itself.
                    Slider(value: $settings.speechSpeed, in: TeachySpeechSpeed.range)
                    .controlSize(.small)
                    .tint(DS.Colors.learnAccent)
                    Image(systemName: "hare.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Captions while Teachy talks",
                caption: "Shows the words at the bottom of your screen as they are spoken. Typed questions always get captions.",
                isOn: $settings.captionsEnabled
            )
        }
        .onDisappear { preview.stop() }
    }

    private func voiceChip(_ voice: TeachyVoice) -> some View {
        let isSelected = settings.voiceName == voice.name
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(voice.character)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                preview.toggle(voice: voice.name, speed: settings.speechSpeed)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(preview.isPlaying(voice.name) ? 0.18 : 0.09))
                        .frame(width: 24, height: 24)
                    if preview.isLoading(voice.name) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: preview.isPlaying(voice.name) ? "stop.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Hear \(voice.displayName)")
            .accessibilityLabel("Preview \(voice.displayName)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? DS.Colors.learnAccent.opacity(0.22) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? DS.Colors.learnAccent : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { settings.voiceName = voice.name }
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
        SettingsDisclosureCard(icon: "mic.fill", title: "Dictation", summary: summary, startsExpanded: startsExpanded) {
            dictionaryBlock

            SettingsDivider()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    SettingsCaption(text: "Auto-detect works for most people. Pick one if it guesses wrong.")
                }
                Spacer(minLength: 8)
                languageMenu
            }

            SettingsToggleRow(
                title: "Tidy up what I said",
                caption: "Fixes punctuation and drops the ums. Never adds words you didn't say.",
                isOn: $settings.dictationCleanupEnabled
            )

            SettingsDivider()

            DictationShortcutPickerRow()
        }
        .onAppear { words = dictionary.words }
    }

    private var dictionaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSubheading(text: "Dictionary")
            SettingsCaption(text: "Names and words to spell your way. Teachy also adds a word when you correct it right after dictating.")

            if words.isEmpty {
                Text("No words yet.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                SettingsFlowLayout(spacing: 6) {
                    ForEach(visibleWords, id: \.self) { word in
                        wordChip(word)
                    }
                }
                if words.count > collapsedWordLimit {
                    Button {
                        isShowingEveryWord.toggle()
                    } label: {
                        Text(isShowingEveryWord ? "Show fewer" : "Show all \(words.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            HStack(spacing: 6) {
                TextField(
                    "",
                    text: $newWord,
                    prompt: Text("Add a word or name").foregroundColor(DS.Colors.textTertiary)
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.75)
                    )
                    .onSubmit(addWord)

                Button(action: addWord) {
                    Text("Add")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DS.Colors.learnAccent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedNewWord.isEmpty)
                .opacity(trimmedNewWord.isEmpty ? 0.45 : 1)
                .pointerCursor(isEnabled: !trimmedNewWord.isEmpty)
            }

            Text("Saved on this Mac in \(DictationPaths.dictionaryDisplayPath)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.8))
        }
    }

    private func wordChip(_ word: String) -> some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Button {
                dictionary.remove(word)
                words = dictionary.words
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove \(word)")
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }

    private var languageMenu: some View {
        Menu {
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
        } label: {
            HStack(spacing: 5) {
                Text(TeachyDictationLanguages.name(for: settings.dictationLanguage))
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(DS.Colors.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // On the menu itself: a borderless menu ignores backgrounds inside its label.
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .pointerCursor()
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
    static var dictationKeyNames: String {
        DictationShortcut.current().map { PushToTalkShortcutKeys.displayName(forKeyCode: $0) }.joined(separator: " + ")
    }

    func liveShortcutLine(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 8)
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(DS.Colors.textSecondary)
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
            liveShortcutLine("Ask by voice", "Hold " + PushToTalkShortcutKeys.currentKeyCapsuleLabels.joined(separator: " + "))
            liveShortcutLine("Type a question", "Double-tap control")
            liveShortcutLine("Dictate", "Hold " + Self.dictationKeyNames)
            liveShortcutLine("Hands-free dictation", "Double-tap " + Self.dictationKeyNames + " (again to stop)")
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
            fact(
                icon: "camera.viewfinder",
                title: "Your screen",
                text: "A screenshot is taken when you ask something (the talk key or the text box), and while Teachy is helping with steps you started: a walkthrough or a task. It goes to publik to answer that moment. Teachy never watches when you haven't asked."
            )
            fact(
                icon: "waveform",
                title: "Your voice",
                text: "What you say goes to publik to be turned into text, and Teachy's answers go to publik to be spoken. If publik can't be reached, your Mac's own dictation and voice are used."
            )
            fact(
                icon: "internaldrive",
                title: "Stays on this Mac",
                text: "Memory, your dictation dictionary and your dictation history are plain files in ~/.teachy. Read, edit or delete them any time."
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "Let agents use my browser sign-ins",
                caption: "Off: Teachy never reads cookies from Safari, Chrome or other browsers. On: agent tools can open sites as you, using the sign-ins already in your browser.",
                isOn: $settings.allowBrowserCookieTools
            )
        }
    }

    private func fact(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.learnAccent)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                SettingsCaption(text: text)
            }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Your own ElevenLabs key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                SettingsCaption(text: "Optional. Used for walkthrough steps and short notices only, and billed by ElevenLabs. Spoken answers use the voice you picked above.")
            }

            if isConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.learnAccent)
                    Text("Key saved")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button {
                        TeachyElevenLabsKeyStore.apiKey = nil
                        apiKeyInput = ""
                        errorMessage = nil
                        isConfigured = false
                    } label: {
                        Text("Remove")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.destructiveText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            } else {
                HStack(spacing: 6) {
                    SecureField(
                        "",
                        text: $apiKeyInput,
                        prompt: Text("ElevenLabs API key").foregroundColor(DS.Colors.textTertiary)
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.75)
                        )
                        .onSubmit(validateAndSave)

                    Button(action: validateAndSave) {
                        Group {
                            if isValidating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Save").font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(width: 44)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DS.Colors.learnAccent)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedKey.isEmpty || isValidating)
                    .opacity(trimmedKey.isEmpty || isValidating ? 0.45 : 1)
                    .pointerCursor(isEnabled: !trimmedKey.isEmpty && !isValidating)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
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
