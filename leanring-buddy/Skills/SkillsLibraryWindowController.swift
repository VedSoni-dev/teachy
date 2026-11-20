import AppKit
import SwiftUI

/// Keeps one Skills Library window. Opened from Settings → Skills, the Home tab, and
/// `teachy://skill?url=` links (which stage the skill for confirmation first).
@MainActor
final class SkillsLibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = SkillsLibraryWindowController()
    static let defaultSize = NSSize(width: 1000, height: 720)
    static let minimumSize = NSSize(width: 860, height: 600)

    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Skills Library"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.surface1)
        window.tabbingMode = .disallowed
        window.delegate = self
        let hostingView = NSHostingView(rootView: SkillsLibraryView().ignoresSafeArea())
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.minSize = Self.minimumSize
        window.center()
        window.setFrameAutosaveName("TeachySkillsLibraryWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // A skill left waiting is dropped with the window, so it is never added later by surprise.
        SkillStore.shared.cancelPendingInstall()
    }
}
