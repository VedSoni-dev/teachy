import AppKit
import SwiftUI

@MainActor
func renderAnnouncements() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var failures = 0
    func render(_ name: String, announcement: TeachyAnnouncement = TeachyAnnouncement.releases[0], highContrast: Bool = false) {
        let view = TeachyAnnouncementView(announcement: announcement, dismiss: {})
            .environment(\.teachyIsDrawnIntoPicture, true)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { failures += 1; return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failures += 1; return }
        try! data.write(to: output.appendingPathComponent(name + ".png"))
        print("Rendered \(name): \(Int(size.width)) × \(Int(size.height)) pt")
        if size.width != 440 || size.height > 560 { failures += 1 }
    }
    render("01-dictation")
    DictationShortcut.fixtureKeys = [59, 58, 55]
    render("02-three-key-shortcut")
    render("03-increased-contrast", highContrast: true)
    render("04-general-announcement", announcement: TeachyAnnouncement(id: "fixture", version: "1.0", title: "A little less in your way", message: "A smaller home for Teachy, with more room for the things you’re working on.", symbol: "sparkles", showsDictationControls: false))
    print(failures == 0 ? "ALL ANNOUNCEMENTS RENDERED" : "FAIL: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--check-lifecycle") { runAnnouncementLifecycleChecks() }
    else { renderAnnouncements() }
}
