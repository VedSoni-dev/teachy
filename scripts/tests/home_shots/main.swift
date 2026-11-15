// Run: scripts/tests/render_home_shots.sh
// Renders the Home tab of the notch panel to PNG files without launching Teachy.
// The view is the real NotchHomeTabView; the managers it talks to are stand-ins
// (Stubs.swift), and the sections that need live data are placeholders that mark their place.
// Output: $TMPDIR/teachy-home-shots/
import AppKit
import Combine
import SwiftUI

// MARK: - Rendering

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-home-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var failureCount = 0

    func render<V: View>(_ view: V, width: CGFloat, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { failureCount += 1; print("FAIL no bitmap for \(name)"); return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failureCount += 1; print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // The panel is 640 wide; the shell pads the open panel by 19 + 12 on each
    // side and NotchPanelView adds 8, which leaves 562 for the content.
    let panelWidth: CGFloat = 640
    func onNotchPanel<V: View>(_ view: V) -> some View {
        view
            .padding(.horizontal, 39)
            .padding(.vertical, 14)
            // The open panel is glass; off screen that is the frosted stand-in.
            .background(TeachyGlassSurface(shape: Rectangle()))
    }

    let companionManager = CompanionManager()
    let notchManager = NotchWindowManager()

    render(
        onNotchPanel(NotchHomeTabView(companionManager: companionManager, notchManager: notchManager)),
        width: panelWidth, name: "01-home"
    )

    let yellowCompanionManager = CompanionManager()
    yellowCompanionManager.selectedCursorColor = .yellow
    yellowCompanionManager.globalPushToTalkShortcutMonitor.isRecordingNewShortcut = true
    render(
        onNotchPanel(NotchHomeTabView(companionManager: yellowCompanionManager, notchManager: notchManager)),
        width: panelWidth, name: "02-home-recording-new-keys"
    )

    if failureCount > 0 {
        print("\(failureCount) FAILED")
        exit(1)
    }
    print("ALL RENDERED")
}

MainActor.assumeIsolated { runShots() }
