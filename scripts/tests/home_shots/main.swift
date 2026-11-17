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

    let companionManager = CompanionManager()
    let notchManager = NotchWindowManager()
    notchManager.notchGeometry = NotchScreenGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchHeight: 32, notchWidth: 185, notchLeftEdgeX: 663.5, notchCenterX: 756,
        leftAuxiliaryAreaWidth: 663.5, hasNotch: true
    )
    func panel() -> some View {
        ClickyNotchRootView(companionManager: companionManager, notchManager: notchManager)
            .frame(width: notchManager.hostingSize.width, height: notchManager.hostingSize.height)
            .background(Color(white: 0.7))
    }
    notchManager.expand()
    render(panel(), width: notchManager.hostingSize.width, name: "01-home")
    companionManager.globalPushToTalkShortcutMonitor.isRecordingNewShortcut = true
    render(panel(), width: notchManager.hostingSize.width, name: "02-home-recording-new-keys")
    companionManager.globalPushToTalkShortcutMonitor.isRecordingNewShortcut = false
    for tab in [NotchPanelTab.chat, .agents, .drawings, .connections, .settings] {
        notchManager.selectedTab = tab
        switch tab {
        case .agents: notchManager.settingsPage = .agents
        case .drawings: notchManager.settingsPage = .drawings
        case .connections: notchManager.settingsPage = .integrations
        default: notchManager.settingsPage = .account
        }
        render(panel(), width: notchManager.hostingSize.width, name: "03-" + tab.rawValue)
    }
    notchManager.collapse()
    render(panel(), width: notchManager.hostingSize.width, name: "04-idle-notched")
    companionManager.voiceState = .listening
    render(panel(), width: notchManager.hostingSize.width, name: "05-live-notched")
    companionManager.voiceState = .idle
    notchManager.notchGeometry = NotchScreenGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        notchHeight: 0, notchWidth: 0, notchLeftEdgeX: 960, notchCenterX: 960,
        leftAuxiliaryAreaWidth: 960, hasNotch: false
    )
    render(panel(), width: notchManager.hostingSize.width, name: "06-idle-external-display")
    companionManager.voiceState = .listening
    render(panel(), width: notchManager.hostingSize.width, name: "07-live-external-display")
    companionManager.voiceState = .idle

    defer { try? FileManager.default.removeItem(at: ProjectsFixture.root) }
    if let project = try? AgentProjectStore.shared.create(name: "Mechanical design") {
        AgentJobCenter.shared.activeJobs = [AgentJob(projectID: project.id)]
        SceneHistory.shared.entries[0].projectID = project.id
        render(VStack(alignment: .leading, spacing: 18) {
            Text("Projects").font(DS.Fonts.workspaceTitle)
            TeachyProjectsPage(companionManager: companionManager)
        }.padding(24).background(DS.Colors.workspaceBackground), width: 550, name: "08-projects")
    } else {
        failureCount += 1
    }

    if failureCount > 0 {
        print("\(failureCount) FAILED")
        exit(1)
    }
    print("ALL RENDERED")
}

MainActor.assumeIsolated { runShots() }
