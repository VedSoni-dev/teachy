import AppKit
import SwiftUI

@MainActor
func runAnnouncementLifecycleChecks() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let suite = "TeachyAnnouncementLifecycle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let history = TeachyAnnouncementHistory(defaults: defaults)
    let controller = TeachyAnnouncementController(history: history)
    defer { defaults.removePersistentDomain(forName: suite) }
    var failures = 0
    func expect(_ condition: Bool, _ description: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL"): \(description)")
    }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
    func updateShortcut(_ keys: [UInt16]) {
        DictationShortcut.fixtureKeys = keys
        NotificationCenter.default.post(name: DictationShortcut.didChangeNotification, object: nil)
        settle()
    }
    let manager = CompanionManager()
    let notch = NotchWindowManager()
    controller.start(companionManager: manager, notchManager: notch)
    controller.showLatest()
    settle()
    guard let window = NSApp.windows.first(where: { $0.title == "What’s new in Teachy" }),
          let hosting = window.contentView else { fatalError("No window") }
    let initialSize = window.frame.size
    let initialTop = window.frame.maxY
    print("INITIAL window=\(initialSize), view=\(hosting.frame.size), fitting=\(hosting.fittingSize)")
    updateShortcut([59, 58, 55])
    print("GROWN window=\(window.frame.size), view=\(hosting.frame.size), fitting=\(hosting.fittingSize)")
    expect(window.frame.height > initialSize.height, "long shortcut grows the same live window")
    expect(abs(window.frame.height - hosting.fittingSize.height) < 1, "grown window matches content")
    expect(abs(window.frame.maxY - initialTop) < 1, "growth preserves top edge")
    updateShortcut([63, 59])
    print("SHRUNK window=\(window.frame.size), view=\(hosting.frame.size), fitting=\(hosting.fittingSize)")
    expect(abs(window.frame.height - initialSize.height) < 1, "short shortcut shrinks to original height")
    expect(abs(window.frame.maxY - initialTop) < 1, "shrink preserves top edge")
    window.performClose(nil)
    settle()
    expect(!window.isVisible, "performClose closes borderless window")
    expect(window.contentView == nil, "close clears hosted content")
    expect(!history.shouldPresent(TeachyAnnouncement.releases[0]), "close acknowledges announcement")
    controller.showLatest()
    settle()
    let reopened = NSApp.windows.first(where: { $0.title == "What’s new in Teachy" && $0.isVisible })
    expect(reopened != nil && reopened !== window, "manual reopen creates a fresh live window")
    reopened?.cancelOperation(nil)
    settle()
    expect(reopened?.contentView == nil && reopened?.isVisible == false, "Escape cancel action clears reopened content")
    let gatedSuite = "TeachyAnnouncementGating.\(UUID().uuidString)"
    let gatedDefaults = UserDefaults(suiteName: gatedSuite)!
    defer { gatedDefaults.removePersistentDomain(forName: gatedSuite) }
    let gatedHistory = TeachyAnnouncementHistory(defaults: gatedDefaults)
    let gatedController = TeachyAnnouncementController(history: gatedHistory)
    TeachyPublikSession.shared.isReady = false
    gatedController.start(companionManager: manager, notchManager: notch)
    RunLoop.main.run(until: Date().addingTimeInterval(1.4))
    expect(!NSApp.windows.contains { $0.title == "What’s new in Teachy" && $0.isVisible }, "sign-in gate suppresses automatic presentation")
    TeachyPublikSession.shared.isReady = true
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    expect(NSApp.windows.contains { $0.title == "What’s new in Teachy" && $0.isVisible }, "ready existing user gets announcement automatically")
    TeachyPublikSession.shared.isReady = false
    settle()
    expect(!NSApp.windows.contains { $0.title == "What’s new in Teachy" && $0.isVisible }, "sign-out closes announcement")
    expect(gatedHistory.shouldPresent(TeachyAnnouncement.releases[0]), "sign-out does not acknowledge unseen announcement")
    TeachyPublikSession.shared.isReady = true
    gatedController.showLatest()
    settle()
    gatedController.close()
    expect(!gatedHistory.shouldPresent(TeachyAnnouncement.releases[0]), "explicit dismissal after signing in acknowledges")
    gatedDefaults.removePersistentDomain(forName: gatedSuite)
    print("\(failures) failures")
    defaults.removePersistentDomain(forName: suite)
    exit(failures == 0 ? 0 : 1)
}
