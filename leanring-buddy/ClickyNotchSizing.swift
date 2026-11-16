//
//  ClickyNotchSizing.swift
//  leanring-buddy
//
//  Notch sizing constants — adapted from boring.notch `sizing/matters.swift`.
//  The NSPanel stays at `windowSize`; SwiftUI animates open/closed height inside it.
//

import SwiftUI

enum ClickyNotchSizing {
    /// Compact expanded shell; longer sections scroll below pinned navigation.
    static let openNotchSize = CGSize(width: 520, height: 160)

    static func expandedSize(for tab: NotchPanelTab, setup: Bool = false) -> CGSize {
        if setup { return CGSize(width: 520, height: 440) }
        switch tab {
        case .home: return openNotchSize
        case .chat: return CGSize(width: 520, height: 402)
        default: return CGSize(width: 800, height: 650)
        }
    }

    /// Extra height so soft shadows aren't clipped by the window.
    static let shadowPadding: CGFloat = 24

    static var windowSize: CGSize {
        CGSize(
            width: openNotchSize.width,
            height: openNotchSize.height + shadowPadding
        )
    }

    static let cornerRadiusInsets: (
        opened: (top: CGFloat, bottom: CGFloat),
        closed: (top: CGFloat, bottom: CGFloat)
    ) = (
        opened: (top: 10, bottom: 26),
        closed: (top: 6, bottom: 14)
    )

    /// Hover chin under the closed notch — nearly invisible hit target.
    static let chinHeight: CGFloat = 12

    static let openSpring = Animation.spring(response: 0.38, dampingFraction: 0.9, blendDuration: 0)
    static let closeSpring = Animation.spring(response: 0.32, dampingFraction: 1.0, blendDuration: 0)
    /// Home ↔ Chat ↔ Settings: a touch softer than opening, since both ends are already open.
    static let pageResizeSpring = Animation.spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0)
    static let interactiveSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
}
