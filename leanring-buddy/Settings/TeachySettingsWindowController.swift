import AppKit
import SwiftUI

/// Retains one desktop settings window so closing and reopening preserves its page.
@MainActor
final class TeachySettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = TeachySettingsWindowController()
    static let defaultSize = NSSize(width: 960, height: 680)
    static let minimumSize = NSSize(width: 800, height: 600)

    private var window: NSWindow?
    private let presentation = TeachySettingsWindowPresentation()

    func show(companionManager: CompanionManager) {
        let window = self.window ?? makeWindow(companionManager: companionManager)
        self.window = window
        presentation.isPresented = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(companionManager: CompanionManager) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Teachy Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.surface1)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.delegate = self

        let toolbar = NSToolbar(identifier: "TeachySettingsToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let hostingView = NSHostingView(rootView: TeachySettingsWindowView(
            companionManager: companionManager,
            presentation: presentation,
            onBack: { [weak window] in
                window?.performClose(nil)
                ChatWindowController.shared.show()
            }
        ).ignoresSafeArea())
        // Enforce the window's minimum rather than the current category's ideal size.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.minSize = Self.minimumSize
        window.center()
        window.setFrameAutosaveName("TeachySettingsWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Unmount controls so a microphone test or voice preview stops on close.
        presentation.isPresented = false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, Self.minimumSize.width),
               height: max(frameSize.height, Self.minimumSize.height))
    }
}

@MainActor
final class TeachySettingsWindowPresentation: ObservableObject {
    @Published var isPresented = false
}

struct TeachySettingsWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var presentation: TeachySettingsWindowPresentation
    let onBack: () -> Void
    @State private var selection: TeachySettingsPage = .account

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    Label("Back", systemImage: "arrow.left")
                }
                .teachyButton(.secondary, size: .compact)
                .accessibilityHint("Close settings and return to chat")
                .padding(.leading, 82)
                .frame(width: 200, alignment: .leading)

                Text("Settings")
                    .font(DS.Fonts.bodyEmphasized)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.leading, 24)
                Spacer(minLength: 0)
            }
            .frame(height: 52)
            TeachyRule()
            if presentation.isPresented {
                TeachySettingsWorkspace(companionManager: companionManager, selection: $selection)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Colors.surface1)
        .environment(\.colorScheme, .dark)
    }
}
