//
//  TeachySettings.swift
//  leanring-buddy
//
//  Every user-facing preference in one place, saved in UserDefaults.
//  `TeachySettings.shared` is the observable object the settings screens bind to.
//  `TeachySettingsStorage` reads the same values without the object, for code
//  that runs off the main actor or just needs one value (speech, dictation, tools).
//  Foundation + Combine only, so the unit tests compile this file on its own.
//

import Combine
import Foundation

// MARK: - Keys

nonisolated enum TeachySettingsKey {
    /// Also read by `LocalSpeechSynthesizer.publikVoiceName`.
    static let voiceName = "teachyPublikVoiceName"
    static let speechSpeed = "teachySpeechSpeed"
    static let captionsEnabled = "teachyCaptionsEnabled"
    /// Also read and written by `CompanionManager.selectedCursorColor`.
    static let cursorColor = "selectedCursorColor"
    static let dictationLanguage = "teachyDictationLanguage"
    static let dictationCleanupEnabled = "teachyDictationCleanupEnabled"
    static let soundsEnabled = "teachySoundsEnabled"
    static let allowBrowserCookieTools = "teachyAllowBrowserCookieTools"
    /// On (the default): agents make ordinary changes without asking; risky ones still ask.
    static let agentAutoPermissions = "teachyAgentAutoPermissions"
    /// On (the default): once a day Teachy offers a few things it could do, from the notch.
    static let suggestionsEnabled = "teachySuggestionsEnabled"
    static let shortcuts = "teachyShortcuts"
    /// "auto" (answer in the language they spoke) or a `TeachyReplyLanguages` code.
    static let replyLanguage = "teachyReplyLanguage"
    static let alwaysOnAutoOffMinutes = "teachyAlwaysOnAutoOffMinutes"
    static let quietOnCallsEnabled = "teachyQuietOnCallsEnabled"
    /// Tap the screen near the camera to start and stop talking (MacBooks with light + motion sensors).
    static let screenTapEnabled = "teachyScreenTapEnabled"
    /// A `ScreenTapSensitivity` raw value.
    static let screenTapSensitivity = "teachyScreenTapSensitivity"
    /// Webcam eye tracking: where the person looks while asking becomes part of the question.
    static let eyeTrackingEnabled = "teachyEyeTrackingEnabled"
    /// A `TeachyWebControlPreference` raw value: how jobs work on websites.
    static let webControlPreference = "teachyWebControlPreference"
    /// A `TeachyPointerControlPreference` raw value: whether jobs may move the real mouse.
    static let pointerControlPreference = "teachyPointerControlPreference"
}

// MARK: - How Teachy acts

/// Where agent jobs do web work.
nonisolated enum TeachyWebControlPreference: String, CaseIterable, Identifiable, Sendable {
    /// Teachy picks per task: their Chrome for signed-in sites and things to watch or hear,
    /// its own background browser for research and forms, the mouse only as a last resort.
    case automatic
    /// Always their own Chrome (through the Teachy extension, else tabs and AppleScript).
    case myChrome
    /// Always Teachy's own browser, out of sight: their screen and mouse stay free.
    case backgroundBrowser
    /// Their browser, driven with the real mouse and keyboard so they can watch.
    case myScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Let Teachy choose"
        case .myChrome: return "My Chrome"
        case .backgroundBrowser: return "Teachy's own browser"
        case .myScreen: return "My screen"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Your Chrome for your accounts and anything to watch or hear, Teachy's browser for research, your mouse only when nothing else works."
        case .myChrome: return "Uses your tabs and sign-ins without moving your mouse. Best with the Teachy Chrome extension."
        case .backgroundBrowser: return "Works out of sight in a separate browser. Your screen and mouse stay yours; you are not signed in there."
        case .myScreen: return "Clicks and types in your browser with your mouse and keyboard, so you can watch every step."
        }
    }
}

/// Whether agent jobs may take the real pointer and keyboard (the `computer` tool).
nonisolated enum TeachyPointerControlPreference: String, CaseIterable, Identifiable, Sendable {
    case allowed
    case askFirst
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allowed: return "Allowed"
        case .askFirst: return "Ask first"
        case .never: return "Never"
        }
    }

    var detail: String {
        switch self {
        case .allowed: return "Teachy may take your mouse when a job needs it. Move the mouse or press Escape to take it back."
        case .askFirst: return "Teachy asks once per job before it takes your mouse and keyboard."
        case .never: return "Jobs never move your mouse. Some steps in apps without accessibility support may not be possible."
        }
    }
}

// MARK: - Voices

nonisolated struct TeachyVoice: Equatable, Identifiable, Sendable {
    let name: String
    /// A few words on how it sounds, shown under the name.
    let character: String
    var id: String { name }
    var displayName: String { name.prefix(1).uppercased() + name.dropFirst() }
}

nonisolated enum TeachyVoiceCatalog {
    static let defaultVoiceName = "Puck"

    /// The voices of publik's realtime voice socket (Gemini Live), which is what Teachy
    /// speaks with. The slower fallback endpoint has its own fixed voice.
    /// The eight the picker shows first.
    static let voices: [TeachyVoice] = [
        TeachyVoice(name: "Puck", character: "Upbeat, friendly"),
        TeachyVoice(name: "Aoede", character: "Breezy, warm"),
        TeachyVoice(name: "Kore", character: "Firm, clear"),
        TeachyVoice(name: "Leda", character: "Young, bright"),
        TeachyVoice(name: "Zephyr", character: "Light, quick"),
        TeachyVoice(name: "Charon", character: "Deep, informative"),
        TeachyVoice(name: "Fenrir", character: "Lively, excitable"),
        TeachyVoice(name: "Orus", character: "Steady, calm"),
    ]

    /// 22 more, shown under "More voices". Added on 14 Nov 2026 after the socket accepted
    /// each name in a `session.update` (it rejects unknown names with an error). Their
    /// one-word characters are Google's published descriptions of the Gemini voices, not
    /// something heard and judged here.
    static let moreVoices: [TeachyVoice] = [
        TeachyVoice(name: "Sulafat", character: "Warm"),
        TeachyVoice(name: "Achird", character: "Friendly"),
        TeachyVoice(name: "Vindemiatrix", character: "Gentle"),
        TeachyVoice(name: "Achernar", character: "Soft"),
        TeachyVoice(name: "Callirrhoe", character: "Easy-going"),
        TeachyVoice(name: "Umbriel", character: "Easy-going"),
        TeachyVoice(name: "Zubenelgenubi", character: "Casual"),
        TeachyVoice(name: "Algieba", character: "Smooth"),
        TeachyVoice(name: "Despina", character: "Smooth"),
        TeachyVoice(name: "Autonoe", character: "Bright"),
        TeachyVoice(name: "Laomedeia", character: "Upbeat"),
        TeachyVoice(name: "Sadachbia", character: "Lively"),
        TeachyVoice(name: "Iapetus", character: "Clear"),
        TeachyVoice(name: "Erinome", character: "Clear"),
        TeachyVoice(name: "Schedar", character: "Even"),
        TeachyVoice(name: "Alnilam", character: "Firm"),
        TeachyVoice(name: "Pulcherrima", character: "Forward"),
        TeachyVoice(name: "Rasalgethi", character: "Informative"),
        TeachyVoice(name: "Sadaltager", character: "Knowledgeable"),
        TeachyVoice(name: "Gacrux", character: "Mature"),
        TeachyVoice(name: "Enceladus", character: "Breathy"),
        TeachyVoice(name: "Algenib", character: "Gravelly"),
    ]

    static let allVoices: [TeachyVoice] = voices + moreVoices

    static func isKnown(_ name: String) -> Bool {
        allVoices.contains { $0.name == name }
    }

    /// The stored name if publik has that voice, else the default.
    static func resolved(_ name: String?) -> String {
        guard let name, let match = allVoices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return defaultVoiceName
        }
        return match.name
    }

    /// What the preview button says.
    static let previewSentence = "Hi, I'm Teachy. This is how I sound."
}

// MARK: - Speech speed

nonisolated enum TeachySpeechSpeed {
    static let range: ClosedRange<Double> = 0.5...1.5
    static let step = 0.05
    static let defaultValue = 1.0

    /// Clamped to the range and snapped to the slider's step, so 0.999999 is 1.0.
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return ((clamped / step).rounded() * step * 100).rounded() / 100
    }

    /// "1.0×", "0.85×".
    static func label(_ value: Double) -> String {
        let hundredths = Int((normalized(value) * 100).rounded())
        return hundredths % 10 == 0
            ? String(format: "%.1f×", Double(hundredths) / 100)
            : String(format: "%.2f×", Double(hundredths) / 100)
    }
}

// MARK: - Dictation language

nonisolated struct TeachyDictationLanguage: Equatable, Identifiable, Sendable {
    let code: String
    let name: String
    var id: String { code }
}

nonisolated enum TeachyDictationLanguages {
    static let automaticCode = "auto"

    /// The common ones. Any other ISO 639 code saved by hand still works.
    static let all: [TeachyDictationLanguage] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("hi", "Hindi"), ("gu", "Gujarati"), ("bn", "Bengali"), ("ta", "Tamil"),
        ("ur", "Urdu"), ("ar", "Arabic"), ("he", "Hebrew"), ("tr", "Turkish"),
        ("ru", "Russian"), ("uk", "Ukrainian"), ("pl", "Polish"), ("sv", "Swedish"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("vi", "Vietnamese"),
        ("id", "Indonesian"), ("th", "Thai"),
    ].map { TeachyDictationLanguage(code: $0.0, name: $0.1) }

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code.uppercased()
    }

    /// Lowercased two- or three-letter code, or "auto" for anything else.
    static func normalized(_ code: String?) -> String {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              code != automaticCode,
              (2...3).contains(code.count), code.allSatisfy({ $0.isLetter && $0.isASCII })
        else { return automaticCode }
        return code
    }
}

// MARK: - Reply language

/// A language Teachy can answer in.
nonisolated struct TeachyReplyLanguage: Equatable, Identifiable, Sendable {
    /// ISO 639 code, also what transcription takes ("es", "zh").
    let code: String
    let englishName: String
    /// The language's name in the language itself, as shown in the picker.
    let nativeName: String
    /// The locale the Mac's on-device speech recogniser is asked for.
    let localeIdentifier: String
    var id: String { code }
    /// "Español (Spanish)", or just "English".
    var pickerLabel: String { nativeName == englishName ? englishName : "\(nativeName) (\(englishName))" }
}

nonisolated enum TeachyReplyLanguages {
    static let automaticCode = "auto"

    static let all: [TeachyReplyLanguage] = [
        ("en", "English", "English", "en-US"), ("es", "Spanish", "Español", "es-ES"),
        ("fr", "French", "Français", "fr-FR"), ("de", "German", "Deutsch", "de-DE"),
        ("it", "Italian", "Italiano", "it-IT"), ("pt", "Portuguese", "Português", "pt-BR"),
        ("nl", "Dutch", "Nederlands", "nl-NL"), ("sv", "Swedish", "Svenska", "sv-SE"),
        ("da", "Danish", "Dansk", "da-DK"), ("nb", "Norwegian", "Norsk", "nb-NO"),
        ("fi", "Finnish", "Suomi", "fi-FI"), ("pl", "Polish", "Polski", "pl-PL"),
        ("cs", "Czech", "Čeština", "cs-CZ"), ("sk", "Slovak", "Slovenčina", "sk-SK"),
        ("hu", "Hungarian", "Magyar", "hu-HU"), ("ro", "Romanian", "Română", "ro-RO"),
        ("bg", "Bulgarian", "Български", "bg-BG"), ("hr", "Croatian", "Hrvatski", "hr-HR"),
        ("sr", "Serbian", "Српски", "sr-RS"), ("el", "Greek", "Ελληνικά", "el-GR"),
        ("uk", "Ukrainian", "Українська", "uk-UA"), ("ru", "Russian", "Русский", "ru-RU"),
        ("tr", "Turkish", "Türkçe", "tr-TR"), ("ar", "Arabic", "العربية", "ar-SA"),
        ("he", "Hebrew", "עברית", "he-IL"), ("fa", "Persian", "فارسی", "fa-IR"),
        ("hi", "Hindi", "हिन्दी", "hi-IN"), ("gu", "Gujarati", "ગુજરાતી", "gu-IN"),
        ("mr", "Marathi", "मराठी", "mr-IN"), ("bn", "Bengali", "বাংলা", "bn-IN"),
        ("pa", "Punjabi", "ਪੰਜਾਬੀ", "pa-IN"), ("ta", "Tamil", "தமிழ்", "ta-IN"),
        ("te", "Telugu", "తెలుగు", "te-IN"), ("kn", "Kannada", "ಕನ್ನಡ", "kn-IN"),
        ("ml", "Malayalam", "മലയാളം", "ml-IN"), ("ur", "Urdu", "اردو", "ur-PK"),
        ("zh", "Chinese", "中文", "zh-CN"), ("ja", "Japanese", "日本語", "ja-JP"),
        ("ko", "Korean", "한국어", "ko-KR"), ("vi", "Vietnamese", "Tiếng Việt", "vi-VN"),
        ("th", "Thai", "ไทย", "th-TH"), ("id", "Indonesian", "Bahasa Indonesia", "id-ID"),
        ("ms", "Malay", "Bahasa Melayu", "ms-MY"), ("fil", "Filipino", "Filipino", "fil-PH"),
        ("sw", "Swahili", "Kiswahili", "sw-KE"), ("ca", "Catalan", "Català", "ca-ES"),
    ].map { TeachyReplyLanguage(code: $0.0, englishName: $0.1, nativeName: $0.2, localeIdentifier: $0.3) }

    /// Nil for "auto" and for anything not in the list.
    static func language(for code: String?) -> TeachyReplyLanguage? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        return all.first { $0.code == code }
    }

    /// A known code, or "auto".
    static func normalized(_ code: String?) -> String {
        language(for: code)?.code ?? automaticCode
    }

    /// What the picker and the card summary show for a saved setting.
    static func label(for code: String) -> String {
        language(for: code)?.pickerLabel ?? "Same as you speak"
    }

    /// The sentence added to the voice prompt so the model writes its reply in the right language.
    static func promptSentence(for code: String) -> String {
        guard let language = language(for: code) else {
            return "LANGUAGE: Reply in the language they just spoke to you in. If they switch language, switch with them. Keep the bracket tags ([POINT:], [SHOW:], [DO:] and the rest) exactly as written, in English."
        }
        return "LANGUAGE: Always reply in \(language.englishName) (\(language.nativeName)), whatever language they speak to you in. Keep the bracket tags ([POINT:], [SHOW:], [DO:] and the rest) exactly as written, in English."
    }

    /// The locale to ask the Mac's speech recogniser for, or nil to use the Mac's own language.
    /// A fixed reply language wins; otherwise the dictation language, if one is set.
    static func recognizerLocaleIdentifier(replyLanguage: String, dictationLanguage: String?) -> String? {
        if let fixed = language(for: replyLanguage) { return fixed.localeIdentifier }
        return language(for: dictationLanguage)?.localeIdentifier
    }

    /// The language code to send with a transcription request, or nil to let it detect.
    static func transcriptionLanguageCode(replyLanguage: String, dictationLanguage: String?) -> String? {
        if let fixed = language(for: replyLanguage) { return fixed.code == "fil" ? "tl" : fixed.code }
        return dictationLanguage
    }
}

// MARK: - Shortcuts

/// A modifier-only shortcut: a set of modifier keys that is either held or double-tapped.
nonisolated struct TeachyShortcut: Codable, Equatable, Sendable {
    enum Modifier: String, Codable, CaseIterable, Sendable {
        // Declared in the order they are shown.
        case function, control, option, shift, command

        var keyLabel: String {
            switch self {
            case .function: return "fn"
            case .control: return "control"
            case .option: return "option"
            case .shift: return "shift"
            case .command: return "command"
            }
        }
    }

    var modifiers: Set<Modifier>
    /// True: tap the keys twice. False: hold them.
    var isDoubleTap: Bool

    init(_ modifiers: Set<Modifier>, doubleTap: Bool = false) {
        self.modifiers = modifiers
        self.isDoubleTap = doubleTap
    }

    /// In display order (fn, control, option, shift, command).
    var orderedModifiers: [Modifier] {
        Modifier.allCases.filter { modifiers.contains($0) }
    }

    var keyLabels: [String] { orderedModifiers.map(\.keyLabel) }

    /// "Hold" or "Double-tap".
    var gestureWord: String { isDoubleTap ? "Double-tap" : "Hold" }

    /// "Hold control + option" or "Double-tap control".
    var displayText: String {
        gestureWord + " " + keyLabels.joined(separator: " + ")
    }

    var isValid: Bool { !modifiers.isEmpty }
}

nonisolated struct TeachyShortcutSet: Codable, Equatable, Sendable {
    var pushToTalk = TeachyShortcut([.control, .option])
    var textBox = TeachyShortcut([.control], doubleTap: true)
    var dictation = TeachyShortcut([.function, .control])
    var handsFreeDictation = TeachyShortcut([.function, .control], doubleTap: true)

    static let standard = TeachyShortcutSet()

    init() {}

    /// A missing or broken entry falls back to its default instead of failing the whole set.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys, _ fallback: TeachyShortcut) -> TeachyShortcut {
            guard let shortcut = try? container.decode(TeachyShortcut.self, forKey: key), shortcut.isValid else {
                return fallback
            }
            return shortcut
        }
        let standard = TeachyShortcutSet()
        pushToTalk = read(.pushToTalk, standard.pushToTalk)
        textBox = read(.textBox, standard.textBox)
        dictation = read(.dictation, standard.dictation)
        handsFreeDictation = read(.handsFreeDictation, standard.handsFreeDictation)
    }

    struct Row: Identifiable, Equatable, Sendable {
        let title: String
        let shortcut: TeachyShortcut
        var id: String { title }
    }

    var rows: [Row] {
        [
            Row(title: "Talk, and circle things", shortcut: pushToTalk),
            Row(title: "Text box", shortcut: textBox),
            Row(title: "Dictate", shortcut: dictation),
            Row(title: "Hands-free dictation", shortcut: handsFreeDictation),
        ]
    }
}

// MARK: - Plain storage (any thread)

/// Reads and writes the saved values directly. Every reader applies the same
/// defaults and clean-up as `TeachySettings`, so the two can never disagree.
nonisolated enum TeachySettingsStorage {
    static func voiceName(_ defaults: UserDefaults = .standard) -> String {
        TeachyVoiceCatalog.resolved(defaults.string(forKey: TeachySettingsKey.voiceName))
    }

    static func speechSpeed(_ defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: TeachySettingsKey.speechSpeed) != nil else { return TeachySpeechSpeed.defaultValue }
        return TeachySpeechSpeed.normalized(defaults.double(forKey: TeachySettingsKey.speechSpeed))
    }

    static func captionsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.captionsEnabled, default: false, defaults)
    }

    static func cursorColorName(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: TeachySettingsKey.cursorColor) ?? "blue"
    }

    static func dictationLanguage(_ defaults: UserDefaults = .standard) -> String {
        TeachyDictationLanguages.normalized(defaults.string(forKey: TeachySettingsKey.dictationLanguage))
    }

    /// The code to send to transcription, or nil to let it detect the language.
    static func dictationLanguageCode(_ defaults: UserDefaults = .standard) -> String? {
        let language = dictationLanguage(defaults)
        return language == TeachyDictationLanguages.automaticCode ? nil : language
    }

    static func dictationCleanupEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.dictationCleanupEnabled, default: true, defaults)
    }

    static func soundsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.soundsEnabled, default: true, defaults)
    }

    static func allowBrowserCookieTools(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.allowBrowserCookieTools, default: false, defaults)
    }

    static func agentAutoPermissions(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.agentAutoPermissions, default: true, defaults)
    }

    static func suggestionsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.suggestionsEnabled, default: true, defaults)
    }

    static func webControlPreference(_ defaults: UserDefaults = .standard) -> TeachyWebControlPreference {
        defaults.string(forKey: TeachySettingsKey.webControlPreference).flatMap(TeachyWebControlPreference.init(rawValue:)) ?? .automatic
    }

    /// Ask first by default: taking someone's mouse without warning is the thing they hate most.
    static func pointerControlPreference(_ defaults: UserDefaults = .standard) -> TeachyPointerControlPreference {
        defaults.string(forKey: TeachySettingsKey.pointerControlPreference).flatMap(TeachyPointerControlPreference.init(rawValue:)) ?? .askFirst
    }

    static func replyLanguage(_ defaults: UserDefaults = .standard) -> String {
        TeachyReplyLanguages.normalized(defaults.string(forKey: TeachySettingsKey.replyLanguage))
    }

    /// The sentence to add to the voice prompt so the reply is written in the right language.
    static func replyLanguagePromptSentence(_ defaults: UserDefaults = .standard) -> String {
        TeachyReplyLanguages.promptSentence(for: replyLanguage(defaults))
    }

    /// The locale to give the Mac's speech recogniser for push-to-talk, or nil to use the Mac's own language.
    static func speechRecognizerLocale(_ defaults: UserDefaults = .standard) -> Locale? {
        TeachyReplyLanguages.recognizerLocaleIdentifier(
            replyLanguage: replyLanguage(defaults), dictationLanguage: dictationLanguageCode(defaults)
        ).map(Locale.init(identifier:))
    }

    /// Always-on switches itself off after this many minutes with nobody speaking.
    static func alwaysOnAutoOffMinutes(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: TeachySettingsKey.alwaysOnAutoOffMinutes) != nil else { return 5 }
        return min(max(defaults.integer(forKey: TeachySettingsKey.alwaysOnAutoOffMinutes), 1), 60)
    }

    /// On a call, answers become captions instead of sound (unless the talk key was held).
    static func quietOnCallsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.quietOnCallsEnabled, default: true, defaults)
    }

    static func shortcuts(_ defaults: UserDefaults = .standard) -> TeachyShortcutSet {
        guard let data = defaults.data(forKey: TeachySettingsKey.shortcuts),
              let decoded = try? JSONDecoder().decode(TeachyShortcutSet.self, from: data)
        else { return .standard }
        return decoded
    }

    static func saveShortcuts(_ shortcuts: TeachyShortcutSet, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        defaults.set(data, forKey: TeachySettingsKey.shortcuts)
    }

    static func screenTapEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.screenTapEnabled, default: false, defaults)
    }

    static func screenTapSensitivity(_ defaults: UserDefaults = .standard) -> ScreenTapSensitivity {
        defaults.string(forKey: TeachySettingsKey.screenTapSensitivity).flatMap(ScreenTapSensitivity.init(rawValue:)) ?? .standard
    }

    /// Off by default: it keeps the camera on while enabled.
    static func eyeTrackingEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(TeachySettingsKey.eyeTrackingEnabled, default: false, defaults)
    }

    private static func bool(_ key: String, default fallback: Bool, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}

// MARK: - Observable store

@MainActor
final class TeachySettings: ObservableObject {
    static let shared = TeachySettings()

    private let defaults: UserDefaults

    @Published var voiceName: String {
        didSet {
            let resolved = TeachyVoiceCatalog.resolved(voiceName)
            if resolved != voiceName { voiceName = resolved; return }
            defaults.set(voiceName, forKey: TeachySettingsKey.voiceName)
        }
    }

    /// 0.5 (slow) to 1.5 (fast).
    @Published var speechSpeed: Double {
        didSet {
            let normalized = TeachySpeechSpeed.normalized(speechSpeed)
            if normalized != speechSpeed { speechSpeed = normalized; return }
            defaults.set(speechSpeed, forKey: TeachySettingsKey.speechSpeed)
        }
    }

    @Published var captionsEnabled: Bool {
        didSet { defaults.set(captionsEnabled, forKey: TeachySettingsKey.captionsEnabled) }
    }

    /// The raw name ("red", "blue", "yellow", "green"). `cursorColor` in
    /// TeachySettings+CursorColor.swift gives the typed value.
    @Published var cursorColorName: String {
        didSet { defaults.set(cursorColorName, forKey: TeachySettingsKey.cursorColor) }
    }

    /// "auto" or a language code such as "en".
    @Published var dictationLanguage: String {
        didSet {
            let normalized = TeachyDictationLanguages.normalized(dictationLanguage)
            if normalized != dictationLanguage { dictationLanguage = normalized; return }
            defaults.set(dictationLanguage, forKey: TeachySettingsKey.dictationLanguage)
        }
    }

    @Published var dictationCleanupEnabled: Bool {
        didSet { defaults.set(dictationCleanupEnabled, forKey: TeachySettingsKey.dictationCleanupEnabled) }
    }

    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: TeachySettingsKey.soundsEnabled) }
    }

    /// Off unless the person turns it on: lets agent tools reuse browser sign-ins.
    @Published var allowBrowserCookieTools: Bool {
        didSet { defaults.set(allowBrowserCookieTools, forKey: TeachySettingsKey.allowBrowserCookieTools) }
    }

    /// On by default: agents act without asking, except for deleting, sending, paying, posting and credentials.
    @Published var agentAutoPermissions: Bool {
        didSet { defaults.set(agentAutoPermissions, forKey: TeachySettingsKey.agentAutoPermissions) }
    }

    /// On by default: a few ideas a day from the notch. Nothing runs until the person presses Do it.
    @Published var suggestionsEnabled: Bool {
        didSet { defaults.set(suggestionsEnabled, forKey: TeachySettingsKey.suggestionsEnabled) }
    }

    @Published var webControlPreference: TeachyWebControlPreference {
        didSet { defaults.set(webControlPreference.rawValue, forKey: TeachySettingsKey.webControlPreference) }
    }

    @Published var pointerControlPreference: TeachyPointerControlPreference {
        didSet { defaults.set(pointerControlPreference.rawValue, forKey: TeachySettingsKey.pointerControlPreference) }
    }

    @Published var shortcuts: TeachyShortcutSet {
        didSet { TeachySettingsStorage.saveShortcuts(shortcuts, defaults) }
    }

    /// "auto" or a language code such as "es".
    @Published var replyLanguage: String {
        didSet {
            let normalized = TeachyReplyLanguages.normalized(replyLanguage)
            if normalized != replyLanguage { replyLanguage = normalized; return }
            defaults.set(replyLanguage, forKey: TeachySettingsKey.replyLanguage)
        }
    }

    @Published var alwaysOnAutoOffMinutes: Int {
        didSet {
            let clamped = min(max(alwaysOnAutoOffMinutes, 1), 60)
            if clamped != alwaysOnAutoOffMinutes { alwaysOnAutoOffMinutes = clamped; return }
            defaults.set(alwaysOnAutoOffMinutes, forKey: TeachySettingsKey.alwaysOnAutoOffMinutes)
        }
    }

    @Published var quietOnCallsEnabled: Bool {
        didSet { defaults.set(quietOnCallsEnabled, forKey: TeachySettingsKey.quietOnCallsEnabled) }
    }

    @Published var screenTapEnabled: Bool {
        didSet { defaults.set(screenTapEnabled, forKey: TeachySettingsKey.screenTapEnabled) }
    }

    @Published var screenTapSensitivity: ScreenTapSensitivity {
        didSet { defaults.set(screenTapSensitivity.rawValue, forKey: TeachySettingsKey.screenTapSensitivity) }
    }

    @Published var eyeTrackingEnabled: Bool {
        didSet { defaults.set(eyeTrackingEnabled, forKey: TeachySettingsKey.eyeTrackingEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voiceName = TeachySettingsStorage.voiceName(defaults)
        speechSpeed = TeachySettingsStorage.speechSpeed(defaults)
        captionsEnabled = TeachySettingsStorage.captionsEnabled(defaults)
        cursorColorName = TeachySettingsStorage.cursorColorName(defaults)
        dictationLanguage = TeachySettingsStorage.dictationLanguage(defaults)
        dictationCleanupEnabled = TeachySettingsStorage.dictationCleanupEnabled(defaults)
        soundsEnabled = TeachySettingsStorage.soundsEnabled(defaults)
        allowBrowserCookieTools = TeachySettingsStorage.allowBrowserCookieTools(defaults)
        agentAutoPermissions = TeachySettingsStorage.agentAutoPermissions(defaults)
        suggestionsEnabled = TeachySettingsStorage.suggestionsEnabled(defaults)
        webControlPreference = TeachySettingsStorage.webControlPreference(defaults)
        pointerControlPreference = TeachySettingsStorage.pointerControlPreference(defaults)
        shortcuts = TeachySettingsStorage.shortcuts(defaults)
        replyLanguage = TeachySettingsStorage.replyLanguage(defaults)
        alwaysOnAutoOffMinutes = TeachySettingsStorage.alwaysOnAutoOffMinutes(defaults)
        quietOnCallsEnabled = TeachySettingsStorage.quietOnCallsEnabled(defaults)
        screenTapEnabled = TeachySettingsStorage.screenTapEnabled(defaults)
        screenTapSensitivity = TeachySettingsStorage.screenTapSensitivity(defaults)
        eyeTrackingEnabled = TeachySettingsStorage.eyeTrackingEnabled(defaults)
    }

    var selectedVoice: TeachyVoice {
        TeachyVoiceCatalog.allVoices.first { $0.name == voiceName } ?? TeachyVoiceCatalog.voices[0]
    }
}
