//
//  CompanionMouseOutlineContext.swift
//  Spatial context from the user's mouse outline during push-to-talk.
//

import CoreGraphics
import Foundation

struct CompanionMouseOutlineContext {
    let outlinePointsInScreenshotSpace: [CGPoint]
    let touchedGridCellLabels: [String]
    let spatialContextLabel: String?

    static func build(
        globalOutlinePoints: [CGPoint],
        screenCapture: CompanionScreenCapture
    ) -> CompanionMouseOutlineContext? {
        let screenshotOutlinePoints = ScreenGridAnnotationUtility.screenshotPixelCoordinates(
            fromGlobalAppKitPoints: globalOutlinePoints,
            screenCapture: screenCapture
        )

        guard screenshotOutlinePoints.count >= 2 else { return nil }

        let touchedGridCellLabels = ScreenGridAnnotationUtility.gridCellLabelsTouchedByOutline(
            outlinePointsInScreenshotSpace: screenshotOutlinePoints,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        )

        let spatialContextLabel = ScreenGridAnnotationUtility.spatialContextLabel(
            outlinePointsInScreenshotSpace: screenshotOutlinePoints,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        )

        return CompanionMouseOutlineContext(
            outlinePointsInScreenshotSpace: screenshotOutlinePoints,
            touchedGridCellLabels: touchedGridCellLabels,
            spatialContextLabel: spatialContextLabel
        )
    }
}
