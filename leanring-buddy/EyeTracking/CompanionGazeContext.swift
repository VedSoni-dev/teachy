//
//  CompanionGazeContext.swift
//  leanring-buddy
//
//  Turns where the person looked while asking (from `GazeTracker`) into context
//  for the voice turn, the same way `CompanionMouseOutlineContext` does for a
//  circled region: the grid cells around the longest fixation are highlighted
//  on that screen's screenshot, and a sentence is added to the question so
//  "what's this?" or "why is that red?" can be resolved.
//
//  Webcam gaze is approximate, so the region is padded by one cell and the
//  sentence says so; the model should prefer it over guessing, not trust it
//  over an explicit pointer or a circled region.
//

import CoreGraphics
import Foundation

struct CompanionGazeContext {
    /// Which screen capture the gaze landed on.
    let screenCaptureIndex: Int
    /// Grid cells around where they looked longest, padded for webcam error.
    let gazeRegionCellLabels: [String]
    /// The cell at the centre of the longest fixation.
    let centerCellLabel: String
    /// Total time spent looking there, in seconds.
    let dwellInSeconds: Double
    /// A second place they looked at, if any (e.g. comparing two things).
    let secondaryCellLabel: String?

    /// Shorter glances than this say little about what "this" is.
    static let minimumUsefulDwellInSeconds = 0.25

    static func build(gazeSamples: [GazeSample], screenCaptures: [CompanionScreenCapture]) -> CompanionGazeContext? {
        let dominantFixations = GazeFixationFinder.dominantFixations(in: gazeSamples, maximumCount: 2)
        guard let primaryFixation = dominantFixations.first,
              primaryFixation.durationInSeconds >= minimumUsefulDwellInSeconds,
              let screenCaptureIndex = screenCaptures.firstIndex(where: { $0.displayFrame.contains(primaryFixation.centerInGlobalCoordinates) })
        else { return nil }

        let screenCapture = screenCaptures[screenCaptureIndex]
        guard let primaryCell = cell(at: primaryFixation.centerInGlobalCoordinates, in: screenCapture) else { return nil }

        let secondaryCellLabel = dominantFixations.dropFirst().first
            .flatMap { $0.durationInSeconds >= minimumUsefulDwellInSeconds ? $0 : nil }
            .flatMap { cell(at: $0.centerInGlobalCoordinates, in: screenCapture) }
            .map { ScreenGridAnnotationUtility.cellLabel(columnIndex: $0.columnIndex, rowIndex: $0.rowIndex) }

        return CompanionGazeContext(
            screenCaptureIndex: screenCaptureIndex,
            gazeRegionCellLabels: paddedRegion(around: primaryCell),
            centerCellLabel: ScreenGridAnnotationUtility.cellLabel(columnIndex: primaryCell.columnIndex, rowIndex: primaryCell.rowIndex),
            dwellInSeconds: primaryFixation.durationInSeconds,
            secondaryCellLabel: secondaryCellLabel == ScreenGridAnnotationUtility.cellLabel(columnIndex: primaryCell.columnIndex, rowIndex: primaryCell.rowIndex)
                ? nil : secondaryCellLabel
        )
    }

    /// Appended to the transcript, like the circled-region hint.
    var questionHint: String {
        var hint = "[Eye tracking: while asking, the user was looking at grid cell \(centerCellLabel)"
        hint += String(format: " for about %.1fs", dwellInSeconds)
        if let secondaryCellLabel { hint += ", and also at \(secondaryCellLabel)" }
        hint += ". Webcam gaze is approximate (within about a cell), so use it to resolve \"this\" or \"that\" when the question is vague; a circled region or an explicit description wins over it.]"
        return hint
    }

    /// Appended to that screenshot's label.
    var imageLabelSuffix: String {
        "user gaze (approximate) centred on cell \(centerCellLabel), region \(gazeRegionCellLabels.joined(separator: ", "))"
    }

    private static func cell(at globalPoint: CGPoint, in screenCapture: CompanionScreenCapture) -> (columnIndex: Int, rowIndex: Int)? {
        guard let screenshotPoint = ScreenGridAnnotationUtility.screenshotPixelCoordinates(
            fromGlobalAppKitPoints: [globalPoint], screenCapture: screenCapture
        ).first,
              let cellLabel = ScreenGridAnnotationUtility.gridCellLabel(
                forScreenshotPixelCoordinate: screenshotPoint,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
              )
        else { return nil }
        return ScreenGridAnnotationUtility.parseCellLabel(cellLabel)
    }

    /// The centre cell and its neighbours, clipped to the grid.
    private static func paddedRegion(around centerCell: (columnIndex: Int, rowIndex: Int)) -> [String] {
        var cellLabels: [String] = []
        for rowIndex in (centerCell.rowIndex - 1)...(centerCell.rowIndex + 1)
        where rowIndex >= 0 && rowIndex < ScreenGridAnnotationUtility.rowCount {
            for columnIndex in (centerCell.columnIndex - 1)...(centerCell.columnIndex + 1)
            where columnIndex >= 0 && columnIndex < ScreenGridAnnotationUtility.columnCount {
                cellLabels.append(ScreenGridAnnotationUtility.cellLabel(columnIndex: columnIndex, rowIndex: rowIndex))
            }
        }
        return cellLabels
    }
}
