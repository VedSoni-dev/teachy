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
    static let shortcuts = "teachyShortcuts"
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

    static func isKnown(_ name: String) -> Bool {
        voices.contains { $0.name == name }
    }

    /// The stored name if publik has that voice, else the default.
    static func resolved(_ name: String?) -> String {
        guard let name, let match = voices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
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

    @Published var shortcuts: TeachyShortcutSet {
        didSet { TeachySettingsStorage.saveShortcuts(shortcuts, defaults) }
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
        shortcuts = TeachySettingsStorage.shortcuts(defaults)
    }

    var selectedVoice: TeachyVoice {
        TeachyVoiceCatalog.voices.first { $0.name == voiceName } ?? TeachyVoiceCatalog.voices[0]
    }
}
