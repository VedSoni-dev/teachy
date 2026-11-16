// Run: scripts/tests/render_touch_gaze_shots.sh
// Renders Settings → Touch & Eyes and the calibration screen to PNGs without launching
// Teachy. The views are real; the managers behind them run in this test process (their
// settings live in this binary's own defaults, not Teachy's), and the camera is never opened.
// Output: $TMPDIR/teachy-touch-gaze-shots/
import AppKit
import SwiftUI

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-touch-gaze-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var failureCount = 0

    func render<V: View>(_ view: V, size: NSSize, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width).environment(\.colorScheme, .dark))
        let fittedSize = NSSize(width: size.width, height: size.height > 0 ? size.height : hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fittedSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: fittedSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { failureCount += 1; print("FAIL no bitmap for \(name)"); return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failureCount += 1; print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(fittedSize.width))x\(Int(fittedSize.height)))")
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // This binary's own defaults domain: start from a clean slate every run.
    let settings = TeachySettings.shared
    settings.screenTapEnabled = false
    settings.eyeTrackingEnabled = false
    // No calibration is saved in this binary's defaults, so this never opens the camera.
    GazeTracker.shared.startFollowingSettings()

    func page() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TeachySettingsPage.touchAndGaze.rawValue).font(DS.Fonts.workspaceTitle).foregroundColor(DS.Colors.textPrimary)
            Text(TeachySettingsPage.touchAndGaze.subtitle).font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
            TeachyTouchAndGazeSettingsPage().padding(.top, 17)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(DS.Colors.workspaceBackground)
    }

    render(page(), size: NSSize(width: 600, height: 0), name: "01-touch-and-eyes-off")
    settings.screenTapEnabled = true
    settings.eyeTrackingEnabled = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    render(page(), size: NSSize(width: 600, height: 0), name: "02-touch-and-eyes-on")

    let run = GazeCalibrationRun(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)) {}
    render(GazeCalibrationView(run: run), size: NSSize(width: 1512, height: 982), name: "03-calibration-intro")

    settings.screenTapEnabled = false
    settings.eyeTrackingEnabled = false
    if failureCount > 0 { print("\(failureCount) renders failed"); exit(1) }
}

MainActor.assumeIsolated { runShots() }
