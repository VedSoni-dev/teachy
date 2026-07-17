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
    /// Teaching-first: open on the course catalog. Lesson flow is unchanged.
    @Published var selectedTab: NotchPanelTab = .courses

    private var window: NSPanel?
    private let companionManager: CompanionManager
    private var clickOutsideMonitor: Any?
    private var screenConfigurationObserver: NSObjectProtocol?
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?

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
    }

    deinit {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
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
        installClickOutsideMonitor()
    }

    func collapse() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        withAnimation(closeSpring) {
            isExpanded = false
            isHoveringNotch = false
        }
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
            hoverCloseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                withAnimation(ClickyNotchSizing.interactiveSpring) {
                    self.isHoveringNotch = false
                }
                // Do not auto-close on hover leave — Clicky's panel is interactive
                // (scroll, menus). Click-outside / Collapse / menu bar toggle close it.
            }
        }
    }

    private func createWindow() {
        let size = ClickyNotchSizing.windowSize
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
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        self.window = window
    }

    private func positionAtTopCenter(animated: Bool) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let size = ClickyNotchSizing.windowSize
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
