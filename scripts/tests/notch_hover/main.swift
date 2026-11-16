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
    let sizes: [(NotchPanelTab, CGSize)] = [
        (.home, CGSize(width: 520, height: 160)),
        (.chat, CGSize(width: 520, height: 402)),
        (.settings, CGSize(width: 800, height: 650))
    ]
    for (tab, expected) in sizes {
        expect(ClickyNotchSizing.expandedSize(for: tab) == expected,
               "\(tab.title) requests \(Int(expected.width))×\(Int(expected.height))")
        manager.selectedTab = tab
        manager.expand()
        let screen = NSScreen.main?.frame.size
        let fitted = CGSize(width: min(expected.width, screen.map { $0.width - 24 } ?? expected.width),
                            height: min(expected.height, screen.map { $0.height - 40 } ?? expected.height))
        expect(manager.expandedSize == fitted, "\(tab.title) manager uses the requested size within screen bounds")
        expect(manager.hostingSize == CGSize(width: fitted.width, height: fitted.height + ClickyNotchSizing.shadowPadding),
               "\(tab.title) hosting frame follows the expanded surface and shadow padding")
    }
    manager.setSetupMode(true)
    expect(ClickyNotchSizing.expandedSize(for: .chat, setup: true) == CGSize(width: 520, height: 440),
           "setup overrides the selected page size")
    manager.setSetupMode(false)
    manager.collapse()
    expect(manager.hostingSize == CGSize(width: 520, height: 160 + ClickyNotchSizing.shadowPadding),
           "collapse returns the hosting frame to compact dimensions")
    manager.selectedTab = .home
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

    manager.selectedTab = .chat
    manager.expand()
    manager.setInteractionPinned(false)
    await pause(250)
    expect(manager.isExpanded, "mounting an idle chat does not synthesize a hover exit")
    manager.handleNotchHover(false)
    await pause(70)
    manager.setInteractionPinned(true)
    await pause(250)
    expect(manager.isExpanded, "typing pin cancels an already pending hover collapse")
    manager.handleNotchHover(true)
    manager.handleNotchHover(false)
    await pause(250)
    expect(manager.isExpanded, "a pinned composer remains open after another hover exit")

    // Microphone dictation can pin Chat without an NSTextView first responder.
    // Reselecting its header tab must preserve that pin until dictation ends.
    manager.handleNotchHover(true)
    manager.selectedTab = .chat
    manager.handleNotchHover(false)
    await pause(250)
    expect(manager.isExpanded, "reselecting Chat preserves the active interaction pin after hover exit")

    manager.setInteractionPinned(false)
    await pause(70)
    expect(manager.isExpanded, "unpinning keeps the normal hover-close grace period")
    await pause(200)
    expect(!manager.isExpanded, "unpinning outside resumes hover collapse")

    manager.expand()
    manager.handleNotchHover(true)
    manager.setInteractionPinned(true)
    manager.setInteractionPinned(false)
    await pause(250)
    expect(manager.isExpanded, "unpinning while hovered does not collapse the panel")
    manager.handleNotchHover(false)
    await pause(250)
    expect(!manager.isExpanded, "the next exit after unpinning collapses normally")

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
    print(failures == 0 ? "ALL NOTCH HOVER AND SIZING CHECKS PASSED" : "\(failures) CHECKS FAILED")
    exit(failures == 0 ? 0 : 1)
}
NSApp.run()
