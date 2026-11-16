import AppKit
import Combine
import SwiftUI

final class TeachySettings: ObservableObject {
    static let shared = TeachySettings()
    @Published var dictationLanguage = "auto"
}
struct TeachyDictationLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}
enum TeachyDictationLanguages {
    static let all = [TeachyDictationLanguage(code: "auto", name: "Auto-detect"), TeachyDictationLanguage(code: "en", name: "English"), TeachyDictationLanguage(code: "es", name: "Spanish")]
    static func name(for code: String) -> String { all.first { $0.code == code }?.name ?? code.uppercased() }
}
enum DictationShortcut {
    static var fixtureKeys: [UInt16] = [63, 59]
    static func current() -> [UInt16] { fixtureKeys }
    static let didChangeNotification = Notification.Name("AnnouncementFixtureKeysChanged")
}
final class DictationController {
    static let shared = DictationController()
    enum ShortcutRecordingResult { case saved([UInt16]), cancelled, rejected(String) }
    func recordShortcut(completion: @escaping (ShortcutRecordingResult) -> Void) { completion(.cancelled) }
    func cancelShortcutRecording() {}
}
final class CompanionManager: ObservableObject {
    enum VoiceState { case idle, listening }
    @Published var voiceState = VoiceState.idle
    var hasCompletedOnboarding = true
    var allPermissionsGranted = true
}
final class TeachyPublikSession: ObservableObject {
    static let shared = TeachyPublikSession()
    @Published var isReady = true
    var choice: String? = "publik"
}
enum TeachyAPIKeyStore { static let isConfigured = true }
final class NotchWindowManager { func collapse() {} }
final class TeachySoftwareUpdater {
    static let shared = TeachySoftwareUpdater()
    let shortVersionString = "1.0"
}
