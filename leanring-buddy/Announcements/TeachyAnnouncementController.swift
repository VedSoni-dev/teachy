import AppKit
import Combine
import SwiftUI

@MainActor
final class TeachyAnnouncementController: NSObject, NSWindowDelegate {
    static let shared = TeachyAnnouncementController()
    private let history: TeachyAnnouncementHistory
    private var window: NSWindow?
    private var presentedAnnouncement: TeachyAnnouncement?
    private var subscriptions: Set<AnyCancellable> = []
    private var presentationTask: Task<Void, Never>?
    private var didAutomaticallyPresent = false
    private var suppressAcknowledgement = false
    private weak var companionManager: CompanionManager?
    private weak var notchManager: NotchWindowManager?

    init(history: TeachyAnnouncementHistory? = nil) {
        self.history = history ?? TeachyAnnouncementHistory()
        super.init()
    }

    private var latest: TeachyAnnouncement? {
        TeachyAnnouncement.latest(for: TeachySoftwareUpdater.shared.shortVersionString)
    }

    func start(companionManager: CompanionManager, notchManager: NotchWindowManager) {
        guard subscriptions.isEmpty else { return }
        self.companionManager = companionManager
        self.notchManager = notchManager
        history.prepareForLaunch(wasOnboarded: companionManager.hasCompletedOnboarding,
                                 version: TeachySoftwareUpdater.shared.shortVersionString)
        // objectWillChange fires before @Published writes. Deliver on the next
        // main-loop turn so readiness checks see the updated account/permissions.
        Publishers.Merge(companionManager.objectWillChange, TeachyPublikSession.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleIfReady() }
            .store(in: &subscriptions)
        scheduleIfReady()
    }

    private var isReady: Bool {
        guard let companionManager else { return false }
        let account = TeachyPublikSession.shared
        let needsOwnKey = account.choice == "own_key" && !TeachyAPIKeyStore.isConfigured
            && !UserDefaults.standard.bool(forKey: "teachyHasSkippedAPIKeySetup")
        return account.isReady && !needsOwnKey && companionManager.hasCompletedOnboarding
            && companionManager.allPermissionsGranted && companionManager.voiceState == .idle
    }

    private func scheduleIfReady() {
        if !TeachyPublikSession.shared.isReady {
            presentationTask?.cancel()
            presentationTask = nil
            // Account switching must not leave settings active over the sign-in gate.
            suppressAcknowledgement = true
            close()
            suppressAcknowledgement = false
            return
        }
        guard isReady else {
            presentationTask?.cancel()
            presentationTask = nil
            return
        }
        guard !didAutomaticallyPresent, window?.isVisible != true,
              presentationTask == nil, let latest, history.shouldPresent(latest) else { return }
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.presentationTask = nil
            guard self.isReady, self.window?.isVisible != true,
                  self.history.shouldPresent(latest) else { return }
            self.didAutomaticallyPresent = true
            self.show(latest)
        }
    }

    func showLatest() {
        guard TeachyPublikSession.shared.isReady, let latest else { return }
        presentationTask?.cancel()
        presentationTask = nil
        show(latest)
    }

    private func show(_ announcement: TeachyAnnouncement) {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        presentedAnnouncement = announcement
        let view = TeachyAnnouncementView(
            announcement: announcement,
            dismiss: { [weak self] in self?.close() },
            contentSizeChanged: { [weak self] size in self?.resize(to: size) }
        )
        let hostingView = NSHostingView(rootView: view)
        let newWindow = AnnouncementWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        newWindow.title = "What’s new in Teachy"
        newWindow.delegate = self
        newWindow.contentView = hostingView
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.isReleasedWhenClosed = false
        newWindow.isMovableByWindowBackground = true
        newWindow.appearance = NSAppearance(named: .darkAqua)
        newWindow.tabbingMode = .disallowed
        newWindow.center()
        window = newWindow
        notchManager?.collapse()
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func resize(to size: CGSize) {
        guard let window, size.height > 0, abs(window.frame.height - size.height) > 0.5 else { return }
        var frame = window.frame
        // Keep the close button anchored while a longer shortcut or validation
        // message adds a row. No polling or decorative animation is needed.
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = window.screen {
            frame.origin.y = max(screen.visibleFrame.minY + 12, frame.origin.y)
        }
        window.setFrame(frame, display: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        if !suppressAcknowledgement, let presentedAnnouncement {
            history.acknowledge(presentedAnnouncement)
        }
        presentedAnnouncement = nil
        window?.contentView = nil
        window = nil
    }
}

private final class AnnouncementWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}
