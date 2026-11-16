import AppKit
import Combine
import SwiftUI

// Keep the actual window manager and its asynchronous hover policy; no real app data or windows.
final class CompanionManager: ObservableObject {}
struct ClickyNotchRootView: View {
    var companionManager: CompanionManager
    var notchManager: NotchWindowManager
    var body: some View { EmptyView() }
}
var failures = 0
func expect(_ value: Bool, _ message: String) {
    if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL"): \(message)")
}
func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Task { @MainActor in
    let manager = NotchWindowManager(companionManager: CompanionManager())
    manager.handleNotchHover(true)
    await pause(450)
    expect(manager.isExpanded, "hover opens the panel")
    manager.handleNotchHover(false)
    await pause(70)
    expect(manager.isExpanded, "brief exit does not flicker closed")
    manager.handleNotchHover(true)
    await pause(250)
    expect(manager.isExpanded, "re-entering cancels pending collapse")
    manager.handleNotchHover(false)
    await pause(250)
    expect(!manager.isExpanded, "leaving collapses without an outside click")

    manager.expand()
    manager.setAttachmentDragTargeted(true)
    manager.handleNotchHover(false)
    await pause(250)
    expect(manager.isExpanded, "file drag keeps the panel open")
    manager.setAttachmentDragTargeted(false)
    await pause(250)
    expect(!manager.isExpanded, "ending a drag outside resumes collapse")

    manager.expand()
    let menu = NSMenu()
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    manager.handleNotchHover(false)
    await pause(250)
    expect(manager.isExpanded, "native menu interaction keeps the panel open")
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    await pause(250)
    expect(!manager.isExpanded, "menu dismissal outside resumes collapse")
    manager.hide()
    exit(failures == 0 ? 0 : 1)
}
NSApp.run()
