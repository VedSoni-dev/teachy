//
//  NotchScreenGeometry.swift
//  leanring-buddy
//
//  Reads NSScreen notch dimensions (auxiliaryTopLeftArea, safeAreaInsets)
//  so the collapsed Clicky icon sits in the menu bar strip left of the camera.
//

import AppKit

struct NotchScreenGeometry {
    let screenFrame: CGRect
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    let notchLeftEdgeX: CGFloat
    let notchCenterX: CGFloat
    let leftAuxiliaryAreaWidth: CGFloat
    let hasNotch: Bool

    /// M1/M2/M3 MacBook Pro 14" logical notch width (measured via auxiliaryTopLeftArea).
    private static let referenceNotchWidthOn1512Screen: CGFloat = 185

    static func from(screen: NSScreen) -> NotchScreenGeometry {
        let screenFrame = screen.frame
        let topSafeAreaInset = screen.safeAreaInsets.top

        if #available(macOS 15.0, *) {
            let leftAuxiliaryArea = screen.auxiliaryTopLeftArea
            let rightAuxiliaryArea = screen.auxiliaryTopRightArea

            if topSafeAreaInset > 0,
               let leftAuxiliaryArea,
               let rightAuxiliaryArea,
               leftAuxiliaryArea.width > 0,
               rightAuxiliaryArea.width > 0 {
                let notchWidth = screenFrame.width - leftAuxiliaryArea.width - rightAuxiliaryArea.width
                let notchLeftEdgeX = screenFrame.minX + leftAuxiliaryArea.width

                return NotchScreenGeometry(
                    screenFrame: screenFrame,
                    notchHeight: topSafeAreaInset,
                    notchWidth: notchWidth,
                    notchLeftEdgeX: notchLeftEdgeX,
                    notchCenterX: notchLeftEdgeX + notchWidth / 2,
                    leftAuxiliaryAreaWidth: leftAuxiliaryArea.width,
                    hasNotch: true
                )
            }
        }

        // Fallback when safeAreaInsets reports a notch but auxiliary areas are unavailable.
        if topSafeAreaInset > 0 {
            let estimatedNotchWidth = screenFrame.width * (referenceNotchWidthOn1512Screen / 1512.0)
            let estimatedLeftAuxiliaryWidth = (screenFrame.width - estimatedNotchWidth) / 2
            let notchLeftEdgeX = screenFrame.minX + estimatedLeftAuxiliaryWidth

            return NotchScreenGeometry(
                screenFrame: screenFrame,
                notchHeight: topSafeAreaInset,
                notchWidth: estimatedNotchWidth,
                notchLeftEdgeX: notchLeftEdgeX,
                notchCenterX: notchLeftEdgeX + estimatedNotchWidth / 2,
                leftAuxiliaryAreaWidth: estimatedLeftAuxiliaryWidth,
                hasNotch: true
            )
        }

        return NotchScreenGeometry(
            screenFrame: screenFrame,
            notchHeight: 0,
            notchWidth: 0,
            notchLeftEdgeX: screenFrame.midX,
            notchCenterX: screenFrame.midX,
            leftAuxiliaryAreaWidth: screenFrame.width / 2,
            hasNotch: false
        )
    }

    /// Resting icon: right edge sits `gapFromNotch` points left of the camera housing.
    func collapsedFrame(width: CGFloat, height: CGFloat, gapFromNotch: CGFloat = 14) -> CGRect {
        if hasNotch {
            let originX = notchLeftEdgeX - gapFromNotch - width
            // Vertically center inside the notch/menu-bar band.
            let originY = screenFrame.maxY - notchHeight + (notchHeight - height) / 2
            return CGRect(x: originX, y: originY, width: width, height: height)
        }

        let originX = screenFrame.midX - width / 2
        let originY = screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Closed notch widget: centered on the camera housing (boring.notch style).
    func collapsedNotchFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let anchorX = hasNotch ? notchCenterX : screenFrame.midX
        let originX = anchorX - width / 2
        let originY = screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Course-mode dock: sits `gapFromNotch` points right of the camera housing.
    func rightOfNotchFrame(width: CGFloat, height: CGFloat, gapFromNotch: CGFloat = 10) -> CGRect {
        if hasNotch {
            let notchRightEdgeX = notchLeftEdgeX + notchWidth
            let originX = notchRightEdgeX + gapFromNotch
            let originY = screenFrame.maxY - notchHeight + (notchHeight - height) / 2
            return CGRect(x: originX, y: originY, width: width, height: height)
        }

        let originX = screenFrame.midX + 72
        let originY = screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Expanded panel: centered on the notch, content starts below the camera band.
    func expandedFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let anchorX = hasNotch ? notchCenterX : screenFrame.midX
        let originX = anchorX - width / 2
        let originY = screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Width of each side "ear" that wraps around the physical notch.
    static let expandedEarWidth: CGFloat = 148

    /// Expanded panel spans both ears plus the notch gap — UI flanks the camera.
    func expandedPanelWidth(earWidth: CGFloat = expandedEarWidth) -> CGFloat {
        hasNotch ? notchWidth + earWidth * 2 : 420
    }

    /// Notch width expressed in the expanded panel's local coordinate space.
    func notchWidthInExpandedPanel(panelWidth: CGFloat) -> CGFloat {
        hasNotch ? notchWidth : 0
    }
}
