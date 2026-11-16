//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Floating notch panel — architecture mirrors boring.notch:
//  fixed-size NSPanel at top-center; SwiftUI animates the notch open/closed inside it.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowManager: NSObject, ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var isHoveringNotch = false
    /// The selected section persists while the panel is collapsed.
    @Published var selectedTab: NotchPanelTab = .home {
        didSet {
            guard selectedTab != oldValue else { return }
            switch selectedTab {
            case .agents: settingsPage = .agents
            case .drawings: settingsPage = .drawings
            case .connections: settingsPage = .integrations
            default: break
            }
            interactionPinned = false
            window?.makeFirstResponder(nil)
            positionAtTopCenter(animated: false)
        }
    }
    @Published var settingsPage: TeachySettingsPage = .account
    @Published private(set) var setupMode = false
    private var interactionPinned = false

    var expandedSize: CGSize {
        let desired = ClickyNotchSizing.expandedSize(for: selectedTab, setup: setupMode)
        guard let screen = window?.screen ?? NSScreen.main else { return desired }
        return CGSize(width: min(desired.width, screen.frame.width - 24),
                      height: min(desired.height, screen.frame.height - 40))
    }
    var hostingSize: CGSize {
        let size = isExpanded ? expandedSize : ClickyNotchSizing.openNotchSize
        return CGSize(width: size.width, height: size.height + ClickyNotchSizing.shadowPadding)
    }
    func setSetupMode(_ needed: Bool) {
        guard setupMode != needed else { return }
        setupMode = needed
        positionAtTopCenter(animated: false)
    }
    func setInteractionPinned(_ pinned: Bool) {
        guard interactionPinned != pinned else { return }
        interactionPinned = pinned
        if pinned { hoverCloseTask?.cancel() } else { scheduleHoverClose() }
    }
    func openSettings(_ page: TeachySettingsPage = .account) {
        settingsPage = page
        selectedTab = .settings
        show()
        expand()
    }

    private var window: NSPanel?
    private let companionManager: CompanionManager
    private var clickOutsideMonitor: Any?
    private var screenConfigurationObserver: NSObjectProtocol?
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var attachmentDragTargeted = false
    private var menuTrackingDepth = 0
    private var menuTrackingObservers: [NSObjectProtocol] = []

    var openSpring: Animation { ClickyNotchSizing.openSpring }
    var closeSpring: Animation { ClickyNotchSizing.closeSpring }

    func currentNotchGeometry() -> NotchScreenGeometry {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first!
        return NotchScreenGeometry.from(screen: screen)
    }

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        installScreenConfigurationObserver()
        menuTrackingObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTrackingDepth += 1
                    self?.hoverCloseTask?.cancel()
                }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                    self.scheduleHoverClose()
                }
            }
        ]
    }

    deinit {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        for observer in menuTrackingObservers { NotificationCenter.default.removeObserver(observer) }
        if let screenConfigurationObserver {
            NotificationCenter.default.removeObserver(screenConfigurationObserver)
        }
    }

    func show() {
        if window == nil {
            createWindow()
        }
        positionAtTopCenter(animated: false)
        window?.orderFrontRegardless()
    }

    func makePanelKey() {
        window?.makeKey()
    }

    func hide() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        window?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    func collapseIfExpanded() {
        guard isExpanded else { return }
        collapse()
    }

    func toggleExpanded() {
        if isExpanded {
            collapse()
        } else {
            show()
            expand()
        }
    }

    func expand() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        withAnimation(openSpring) {
            isExpanded = true
        }
        positionAtTopCenter(animated: false)
        installClickOutsideMonitor()
    }

    func collapse() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        withAnimation(closeSpring) {
            isExpanded = false
            isHoveringNotch = false
        }
        interactionPinned = false
        positionAtTopCenter(animated: false)
        removeClickOutsideMonitor()
    }

    func handleNotchHover(_ hovering: Bool) {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()

        if hovering {
            withAnimation(ClickyNotchSizing.interactiveSpring) {
                isHoveringNotch = true
            }
            if !isExpanded {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            guard !isExpanded else { return }
            hoverOpenTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled, self.isHoveringNotch, !self.isExpanded else { return }
                self.expand()
            }
        } else {
            isHoveringNotch = false
            scheduleHoverClose()
        }
    }

    func setAttachmentDragTargeted(_ targeted: Bool) {
        attachmentDragTargeted = targeted
        if targeted { hoverCloseTask?.cancel() }
        else { scheduleHoverClose() }
    }

    private func scheduleHoverClose() {
        hoverCloseTask?.cancel()
        guard isExpanded, !isHoveringNotch, !interactionPinned, !attachmentDragTargeted, menuTrackingDepth == 0 else { return }
        hoverCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, !self.isHoveringNotch,
                  !self.attachmentDragTargeted, !self.interactionPinned, self.menuTrackingDepth == 0 else { return }
            if self.window?.firstResponder is NSTextView || self.window?.attachedSheet != nil { return }
            self.collapse()
        }
    }

    private func createWindow() {
        let size = hostingSize
        let styleMask: NSWindow.StyleMask = [
            .borderless,
            .nonactivatingPanel,
            .utilityWindow,
            .hudWindow,
        ]
        let window = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        window.appearance = NSAppearance(named: .darkAqua)

        let rootView = ClickyNotchRootView(
            companionManager: companionManager,
            notchManager: self
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        self.window = window
    }

    private func positionAtTopCenter(animated: Bool) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let size = hostingSize
        let origin = NSPoint(
            x: screen.frame.origin.x + (screen.frame.width / 2) - size.width / 2,
            y: screen.frame.origin.y + screen.frame.height - size.height
        )
        let frame = NSRect(origin: origin, size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func installScreenConfigurationObserver() {
        screenConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
            self?.positionAtTopCenter(animated: false)
        }
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            if window.frame.contains(NSEvent.mouseLocation) { return }
            self.collapse()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

/// NSPanel subclass that allows becoming key window (needed for TextFields in setup).
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
