// Run: scripts/tests/render_skill_market_shots.sh
// Renders Settings → Skills (the real TeachySkillsSettingsPage) to PNGs without launching Teachy.
// The store reads a temp skills folder and the repo's academy/skillmarket/index.json from disk,
// so no network is used and ~/.teachy is never read. Output: $TMPDIR/teachy-skill-market-shots/
import AppKit
import SwiftUI

@MainActor
func runShots() async {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-skill-market-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var failureCount = 0

    func render<V: View>(_ view: V, width: CGFloat, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let fittedSize = NSSize(width: width, height: hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fittedSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: fittedSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { failureCount += 1; return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failureCount += 1; return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(fittedSize.width))x\(Int(fittedSize.height)))")
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let repo = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-skill-shots-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let userDirectory = temp.appendingPathComponent("skills", isDirectory: true)
    let library = SkillLibrary(bundledDirectories: [repo.appendingPathComponent("leanring-buddy/Skills/Library")], userDirectory: userDirectory)
    let indexURL = repo.appendingPathComponent("academy/skillmarket/index.json")
    let store = SkillStore(library: library, userDirectory: userDirectory, indexURL: indexURL)

    func page() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TeachySettingsPage.skills.rawValue).font(DS.Fonts.workspaceTitle).foregroundColor(DS.Colors.textPrimary)
            Text(TeachySettingsPage.skills.subtitle).font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
            TeachySkillsSettingsPage(store: store, loadsMarketOnAppear: false).padding(.top, 17)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(DS.Colors.workspaceBackground)
    }

    func libraryWindow(_ filter: SkillsLibraryFilter = .all, selecting entryID: String? = nil) -> some View {
        SkillsLibraryView(store: store, loadsMarketOnAppear: false, filter: filter, selectedEntryID: entryID)
            .frame(height: 720)
    }

    await store.loadMarket()
    // Stand-in counts (the real ones come from the counter Worker).
    store.downloadCounts = ["linear": 1204, "zoom": 1, "canva": 0]
    render(page(), width: 600, name: "01-skills-empty")
    render(libraryWindow(selecting: "market:linear"), width: 1000, name: "10-library-linear")

    if let linear = store.listings.first(where: { $0.id == "linear" }) { await store.install(linear) }
    let own = SkillInstaller.newSkillTemplate.replacingOccurrences(of: "name: My App", with: "name: Things 3")
    try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
    try? Data(own.utf8).write(to: userDirectory.appendingPathComponent("things-3.md"))
    store.refreshInstalledSkills()
    render(page(), width: 600, name: "02-skills-installed")
    render(libraryWindow(selecting: "market:linear"), width: 1000, name: "11-library-linear-added")
    render(libraryWindow(.mine), width: 1000, name: "12-library-my-skills")

    if let zoomFile = store.listings.first(where: { $0.id == "zoom" }) {
        store.stageLocalFile(indexURL.deletingLastPathComponent().appendingPathComponent(zoomFile.file))
    }
    if let pending = store.pendingInstall {
        render(libraryWindow(selecting: "pending:" + pending.id.uuidString), width: 1000, name: "13-library-confirm")
    }
    if failureCount > 0 { print("\(failureCount) renders failed"); exit(1) }
}

let done = DispatchSemaphore(value: 0)
Task { @MainActor in await runShots(); exit(0) }
RunLoop.main.run()
