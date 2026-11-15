// Run: scripts/tests/render_chrome_shots.sh
// Renders the Browser settings card in each of its states to PNG files, without
// launching Teachy and without putting anything on screen.
// Output: $TMPDIR/teachy-chrome/shots/
import AppKit
import SwiftUI

// MARK: - Stand-ins for app types Settings/SettingsSections.swift refers to

enum ClickyCursorColor: String, CaseIterable, Identifiable {
    case red, blue, yellow, green
    var id: String { rawValue }
    var displayColor: Color { .blue }
}

enum TeachyElevenLabsKeyStore {
    static var apiKey: String?
    static var isConfigured: Bool { apiKey != nil }
    static let voiceID = "preview"
}

/// The real row needs the dictation controller; this card does not show it.
struct DictationShortcutPickerRow: View {
    var body: some View { EmptyView() }
}

extension VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer { _, _, _ in Data() }
}

// MARK: - Rendering

@MainActor
func runShots() {
    let base = ProcessInfo.processInfo.environment["TEACHY_TEST_SCRATCH"] ?? NSTemporaryDirectory()
    let outputDirectory = URL(fileURLWithPath: base).appendingPathComponent("shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    var failures = 0
    func render<V: View>(_ view: V, width: CGFloat, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { failures += 1; print("FAIL no bitmap for \(name)"); return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failures += 1; print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        if size.height < 40 { failures += 1; print("FAIL \(name) is only \(Int(size.height)) pt tall") }
        print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    }

    // The Home tab's content width: 640 panel, 12 shell padding and 8 scroll padding each side.
    let width: CGFloat = 640 - 2 * 12 - 2 * 8 + 16
    func onNotch<V: View>(_ view: V) -> some View { view.padding(8).background(Color.black) }

    let steps = [
        "In Terminal, from the Teachy folder, run: scripts/install-chrome-host.sh",
        "In Chrome, open chrome://extensions and turn on Developer mode (top right).",
        "Click “Load unpacked” and choose the chrome-extension folder.",
        "Come back here: this card turns green when Chrome finds Teachy."
    ]

    render(onNotch(VStack(spacing: 8) {
        BrowserExtensionCard(state: .notInstalled)
        BrowserExtensionCard(state: .waitingForChrome)
        BrowserExtensionCard(state: .connected(browserName: "Chrome"))
    }), width: width, name: "01-collapsed")
    render(onNotch(BrowserExtensionCard(state: .notInstalled, canInstall: true, manualSteps: steps, startsExpanded: true)), width: width, name: "02-not-installed")
    render(onNotch(BrowserExtensionCard(state: .notInstalled, canInstall: false, manualSteps: steps, startsExpanded: true)), width: width, name: "03-not-installed-steps")
    render(onNotch(BrowserExtensionCard(state: .notInstalled, canInstall: true, isInstalling: true, startsExpanded: true)), width: width, name: "04-installing")
    render(onNotch(BrowserExtensionCard(state: .waitingForChrome, browsersWithHelper: ["Chrome", "Chrome Beta", "Edge", "Brave", "Arc", "Vivaldi"],
                                        message: "Installed. Restart your browser, or click the Teachy button in its toolbar.", startsExpanded: true)), width: width, name: "05-waiting")
    render(onNotch(BrowserExtensionCard(state: .connected(browserName: "Arc"), startsExpanded: true)), width: width, name: "06-connected")
    render(onNotch(BrowserExtensionCard(state: .notInstalled, canInstall: true, message: "The helper could not be installed: No helper to install: set TEACHY_HOST_BINARY or run this from the Teachy repository.",
                                        messageIsProblem: true, startsExpanded: true)), width: width, name: "07-problem")

    print(failures == 0 ? "ALL RENDERED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runShots() }
