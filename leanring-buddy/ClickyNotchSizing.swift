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
    static let openNotchSize = CGSize(width: 520, height: 240)

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
        opened: (top: 19, bottom: 24),
        closed: (top: 6, bottom: 14)
    )

    /// Hover chin under the closed notch — nearly invisible hit target.
    static let chinHeight: CGFloat = 12

    static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    static let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    static let interactiveSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
}
