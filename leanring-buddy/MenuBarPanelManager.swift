//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and delegates click action to
//  the NotchWindowManager. The menu bar icon triggers the notch under the
//  display's camera area instead of showing a dropdown panel.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickySwitchToCoursesTab = Notification.Name("clickySwitchToCoursesTab")
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var dismissPanelObserver: NSObjectProtocol?
    private var switchToCoursesTabObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private weak var notchManager: NotchWindowManager?

    init(companionManager: CompanionManager, notchManager: NotchWindowManager) {
        self.companionManager = companionManager
        self.notchManager = notchManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notchManager?.collapseIfExpanded()
        }

        switchToCoursesTabObserver = NotificationCenter.default.addObserver(
            forName: .clickySwitchToCoursesTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let notchManager = self.notchManager else { return }
            notchManager.selectedTab = .courses
            if !notchManager.isExpanded {
                notchManager.show()
                notchManager.expand()
            }
        }
    }

    deinit {
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = switchToCoursesTabObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    @objc private func statusItemClicked() {
        notchManager?.toggleExpanded()
    }

    /// Shows the notch on launch so the user sees it right away.
    func showPanelOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.notchManager?.show()
        }
    }
}
