// Exercise the actual rail coordinator and views while keeping fixture windows off the desktop.
import AppKit
import SwiftUI

final class FixturePanel: NSPanel {
    var presented = false
    override var screen: NSScreen? { NSScreen.main }
    override func orderFrontRegardless() { presented = true }
    override func orderOut(_ sender: Any?) { presented = false }
}

enum AgentNotchLayout {
    static var panels: [FixturePanel] = []
    static func screenUnderPointer() -> NSScreen? { NSScreen.main }
    static func makePanel(size: NSSize, acceptsClicks: Bool) -> NSPanel {
        let panel = FixturePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.ignoresMouseEvents = !acceptsClicks
        panels.append(panel)
        return panel
    }
}

@MainActor
func runTest() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    guard NSScreen.main != nil else { fatalError("A macOS display session is needed") }
    let rail = AgentSideRail()
    let plan = AgentPlan.parse(arguments: ["steps": ["Read source files", "Trace the render loop", "Summarize changes"], "current_step": 2])!.plan
    var jobs = [
        AgentJobCardModel(id: "render", title: "Render performance", agentName: "Research", status: .running, plan: plan),
        AgentJobCardModel(id: "assets", title: "Prepare assets", status: .waitingForConsent),
        AgentJobCardModel(id: "report", title: "Weekly report", status: .queued)
    ]
    var clicked: String?
    rail.onSelect = { clicked = $0 }
    rail.update(jobs, selected: nil)
    let tiles = AgentNotchLayout.panels
    func square(_ index: Int) -> AgentRailSquare {
        (tiles[index].contentView as! NSHostingView<AgentRailSquare>).rootView
    }
    precondition(tiles.count == 3 && tiles.allSatisfy { $0.presented && !$0.ignoresMouseEvents && $0.frame.size == NSSize(width: 32, height: 32) })
    precondition(tiles[0].frame.minY > tiles[1].frame.maxY && tiles[1].frame.minY > tiles[2].frame.maxY)
    let colors = tiles.indices.map { square($0).accent }
    precondition(Set(colors).count == 3)

    square(0).hover(true)
    let previewPanel = AgentNotchLayout.panels.last!
    func preview() -> AgentRailPreview { (previewPanel.contentView as! NSHostingView<AgentRailPreview>).rootView }
    precondition(previewPanel.presented && previewPanel.ignoresMouseEvents && preview().job.id == jobs[0].id)
    precondition(previewPanel.frame.maxX < tiles[0].frame.minX)
    let fixture = HStack(alignment: .top, spacing: 6) {
        preview().padding(.top, 4)
        VStack(spacing: 2) { ForEach(tiles.indices, id: \.self) { square($0) } }
    }
    .padding(24)
    .background(Color(red: 0.21, green: 0.23, blue: 0.27))
    let renderer = ImageRenderer(content: fixture.environment(\.colorScheme, .dark))
    renderer.scale = 2
    guard let bitmap = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else { fatalError("Unable to render preview") }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

    jobs[0].plan.markAllDone()
    jobs[0].status = .done
    jobs[0].answer = "Reduced redundant frames."
    rail.update(jobs, selected: nil)
    precondition(preview().job.answer == jobs[0].answer && preview().job.status.isFinished)
    square(1).hover(true)
    square(0).hover(false)
    precondition(previewPanel.presented && preview().job.id == "assets")
    square(1).hover(false)
    precondition(!previewPanel.presented)
    square(2).click()
    precondition(clicked == "report")
    rail.update(Array(jobs.dropFirst()), selected: clicked)
    precondition(!tiles[0].presented && square(2).selected && square(2).accent == colors[2])
    rail.update([], selected: nil)
    precondition(AgentNotchLayout.panels.allSatisfy { !$0.presented })
    print("Passed rail layout, colors, hover, progress updates, selection and cleanup. Wrote " + CommandLine.arguments[1])
}

try MainActor.assumeIsolated { try runTest() }
