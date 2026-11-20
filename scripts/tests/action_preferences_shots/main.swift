// Run: scripts/tests/render_action_preferences_shots.sh
// Renders Settings → Agents → "How Teachy does things" (the real section) to PNGs in
// $TMPDIR/teachy-action-preferences-shots/, without launching Teachy. Settings live in this
// binary's own defaults, not Teachy's.
import AppKit
import SwiftUI

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-action-preferences-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    func render<V: View>(_ view: V, width: CGFloat, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { print("FAIL no bitmap"); exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let settings = TeachySettings.shared
    func page() -> some View {
        TeachyActionPreferencesSection()
            .padding(.horizontal, 28).padding(.vertical, 22)
            .background(DS.Colors.workspaceBackground)
    }
    settings.webControlPreference = .automatic
    settings.pointerControlPreference = .askFirst
    render(page(), width: 600, name: "01-defaults")
    settings.webControlPreference = .backgroundBrowser
    settings.pointerControlPreference = .never
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    render(page(), width: 600, name: "02-background-never")
    settings.webControlPreference = .automatic
    settings.pointerControlPreference = .askFirst
}

MainActor.assumeIsolated { runShots() }
