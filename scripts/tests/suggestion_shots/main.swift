// Renders the real suggestion panel (collapsed and expanded) to PNGs in
// $TMPDIR/teachy-suggestion-shots/ with made-up ideas. No app, no user data.
import AppKit
import SwiftUI

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-suggestion-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    func render<V: View>(_ view: V, name: String) {
        let hosting = NSHostingView(rootView: view.padding(24).background(Color(white: 0.32)).environment(\.colorScheme, .dark))
        let size = hosting.fittingSize
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
    let ideas = [
        TeachySuggestion(id: "1", appName: "Gmail", symbolName: "envelope.fill", estimatedMinutes: 9,
                         headline: "I'll move next week's plans while you're away", outcome: "3 replies, in your voice",
                         planSteps: ["See what's on next week", "Write to Sam, Aisha and the clinic", "Leave each reply in your drafts"],
                         resultLocation: "In your Gmail drafts", task: "x"),
        TeachySuggestion(id: "2", appName: "YouTube", symbolName: "play.rectangle.fill", estimatedMinutes: 4,
                         headline: "I'll score all 15 of your thumbnails", outcome: "What works, what doesn't",
                         planSteps: ["Open your channel's videos", "Score each thumbnail", "Write a short report"],
                         resultLocation: "A report in Teachy", task: "y"),
        TeachySuggestion(id: "3", appName: "Linear", symbolName: "checklist", estimatedMinutes: 6,
                         headline: "I'll tidy the 12 tickets nobody touched since May", outcome: "A tidy backlog",
                         planSteps: ["Find tickets untouched since May", "Propose close or keep for each"],
                         resultLocation: "A list for you to approve", task: "z"),
    ]
    let noop: () -> Void = {}
    let collapsedModel = SuggestionPanelModel()
    collapsedModel.suggestions = ideas
    render(SuggestionPanelView(model: collapsedModel, onClose: noop, onDoIt: { _ in }, onAdjust: { _, _ in }, onNah: { _ in }), name: "01-collapsed")

    let expandedModel = SuggestionPanelModel()
    expandedModel.suggestions = ideas
    expandedModel.isExpanded = true
    render(SuggestionPanelView(model: expandedModel, onClose: noop, onDoIt: { _ in }, onAdjust: { _, _ in }, onNah: { _ in }), name: "02-expanded")

    let adjustingModel = SuggestionPanelModel()
    adjustingModel.suggestions = [ideas[0]]
    adjustingModel.isExpanded = true
    adjustingModel.adjustingSuggestionID = "1"
    adjustingModel.adjustText = "Only Sam and Aisha"
    render(SuggestionPanelView(model: adjustingModel, onClose: noop, onDoIt: { _ in }, onAdjust: { _, _ in }, onNah: { _ in }), name: "03-adjusting")
}

MainActor.assumeIsolated { runShots() }
