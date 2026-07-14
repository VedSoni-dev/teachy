//
//  ScreenGridAnnotationUtility.swift
//  leanring-buddy
//
//  Draws a coordinate grid onto screenshots before they are sent to vision models.
//  The grid is invisible on the user's real display — it only exists in the
//  JPEG we attach to model requests so weaker models can point using cell
//  labels (e.g. E4) instead of unreliable raw pixel coordinates.
//

import AppKit
import Foundation

enum ScreenGridAnnotationUtility {
    static let columnCount = 20
    static let rowCount = 12

    /// Regex fragment for a single grid cell label (columns A–T, rows 1–12).
    static let gridCellRegexFragment = #"[A-T](?:1[0-2]|[1-9])"#

    /// Instructions appended to system prompts so models know how to use the grid.
    static let modelInstructions = """
    SCREEN POINTING (invisible grid on screenshots):
    - Every screenshot has a hidden grid burned in — columns A–T, rows 1–12. The user cannot see it.
    - To point at something, end your response with [POINT:E4:short label] for the cell that best contains the target. Example: [POINT:M6:search bar]
    - Prefer grid cells over raw pixel coordinates.
    - Use [POINT:none] when there's nothing useful to point at.
    - Only add a POINT tag when it would actually help them find something.

    USER MOUSE OUTLINE:
    - A yellow chalk stroke means they circled that area while asking.
    - The image label lists which grid cells the outline touches — answer about what's in that region.
    """

    /// Burns grid labels, optional user mouse outline, and cell highlights onto a model-facing screenshot copy.
    static func annotateScreenshotForModel(
        originalJPEGData: Data,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        mouseOutlinePointsInScreenshotSpace: [CGPoint] = [],
        highlightedGridCellLabels: [String] = []
    ) -> Data? {
        guard let sourceImage = NSImage(data: originalJPEGData) else { return nil }

        let imageSize = NSSize(
            width: CGFloat(screenshotWidthInPixels),
            height: CGFloat(screenshotHeightInPixels)
        )

        let annotatedImage = NSImage(size: imageSize)
        annotatedImage.lockFocus()

        sourceImage.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )

        let cellWidth = imageSize.width / CGFloat(columnCount)
        let cellHeight = imageSize.height / CGFloat(rowCount)

        drawHighlightedGridCells(
            cellLabels: highlightedGridCellLabels,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            imageHeight: imageSize.height
        )

        drawChalkOutlineOnImage(
            outlinePointsInScreenshotSpace: mouseOutlinePointsInScreenshotSpace,
            imageHeight: imageSize.height
        )

        let gridLineColor = NSColor(calibratedRed: 1.0, green: 0.0, blue: 1.0, alpha: 0.42)
        gridLineColor.setStroke()

        for columnIndex in 0...columnCount {
            let xPosition = CGFloat(columnIndex) * cellWidth
            let verticalLine = NSBezierPath()
            verticalLine.move(to: NSPoint(x: xPosition, y: 0))
            verticalLine.line(to: NSPoint(x: xPosition, y: imageSize.height))
            verticalLine.lineWidth = 1.0
            verticalLine.stroke()
        }

        for rowIndex in 0...rowCount {
            let yPosition = CGFloat(rowIndex) * cellHeight
            let horizontalLine = NSBezierPath()
            horizontalLine.move(to: NSPoint(x: 0, y: yPosition))
            horizontalLine.line(to: NSPoint(x: imageSize.width, y: yPosition))
            horizontalLine.lineWidth = 1.0
            horizontalLine.stroke()
        }

        let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
        let labelColor = NSColor(calibratedRed: 0.0, green: 1.0, blue: 1.0, alpha: 0.88)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
            .strokeColor: NSColor.black.withAlphaComponent(0.6),
            .strokeWidth: -2.0
        ]

        for rowIndex in 0..<rowCount {
            for columnIndex in 0..<columnCount {
                let cellLabel = cellLabel(columnIndex: columnIndex, rowIndex: rowIndex)
                let labelX = CGFloat(columnIndex) * cellWidth + 4
                // NSImage drawing uses bottom-left origin; row 1 is at the top.
                let labelY = imageSize.height - CGFloat(rowIndex + 1) * cellHeight + 4
                cellLabel.draw(
                    at: NSPoint(x: labelX, y: labelY),
                    withAttributes: labelAttributes
                )
            }
        }

        annotatedImage.unlockFocus()

        guard let bitmapRepresentation = NSBitmapImageRep(data: annotatedImage.tiffRepresentation ?? Data()),
              let annotatedJPEGData = bitmapRepresentation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.82]
              ) else {
            return nil
        }

        return annotatedJPEGData
    }

    /// Returns the center of a grid cell in screenshot pixel coordinates (top-left origin).
    static func screenshotPixelCoordinate(
        forCellLabel rawCellLabel: String,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGPoint? {
        guard let (columnIndex, rowIndex) = parseCellLabel(rawCellLabel) else { return nil }

        let cellWidth = CGFloat(screenshotWidthInPixels) / CGFloat(columnCount)
        let cellHeight = CGFloat(screenshotHeightInPixels) / CGFloat(rowCount)

        let centerX = (CGFloat(columnIndex) + 0.5) * cellWidth
        let centerY = (CGFloat(rowIndex) + 0.5) * cellHeight

        return CGPoint(x: centerX, y: centerY)
    }

    /// Converts a screenshot-space coordinate (top-left origin) to global AppKit screen coordinates.
    static func globalAppKitCoordinate(
        screenshotPixelCoordinate: CGPoint,
        screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)

        let clampedX = max(0, min(screenshotPixelCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPixelCoordinate.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + screenCapture.displayFrame.origin.x,
            y: appKitY + screenCapture.displayFrame.origin.y
        )
    }

    static func cellLabel(columnIndex: Int, rowIndex: Int) -> String {
        let columnLetter = Character(UnicodeScalar(65 + columnIndex)!)
        return "\(columnLetter)\(rowIndex + 1)"
    }

    static func parseCellLabel(_ rawCellLabel: String) -> (columnIndex: Int, rowIndex: Int)? {
        let trimmedLabel = rawCellLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmedLabel.count >= 2 else { return nil }

        let columnCharacter = trimmedLabel.first!
        guard columnCharacter.isLetter else { return nil }

        let rowNumberString = String(trimmedLabel.dropFirst())
        guard let rowNumber = Int(rowNumberString), rowNumber >= 1, rowNumber <= rowCount else {
            return nil
        }

        let columnIndex = Int(columnCharacter.asciiValue! - 65)
        guard columnIndex >= 0, columnIndex < columnCount else { return nil }

        return (columnIndex: columnIndex, rowIndex: rowNumber - 1)
    }

    // MARK: - Spatial context (mouse outline → grid cells)

    static func screenshotPixelCoordinates(
        fromGlobalAppKitPoints globalPoints: [CGPoint],
        screenCapture: CompanionScreenCapture
    ) -> [CGPoint] {
        let displayFrame = screenCapture.displayFrame
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)

        return globalPoints.compactMap { globalPoint in
            guard displayFrame.contains(globalPoint) else { return nil }

            let displayLocalX = globalPoint.x - displayFrame.origin.x
            let displayLocalY = globalPoint.y - displayFrame.origin.y
            let topLeftDisplayY = displayHeight - displayLocalY

            return CGPoint(
                x: displayLocalX * (screenshotWidth / displayWidth),
                y: topLeftDisplayY * (screenshotHeight / displayHeight)
            )
        }
    }

    static func globalAppKitCoordinates(
        fromScreenshotPixelPoints screenshotPoints: [CGPoint],
        screenCapture: CompanionScreenCapture
    ) -> [CGPoint] {
        screenshotPoints.map { screenshotPoint in
            globalAppKitCoordinate(
                screenshotPixelCoordinate: screenshotPoint,
                screenCapture: screenCapture
            )
        }
    }

    static func gridCellLabel(
        forScreenshotPixelCoordinate point: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> String? {
        let cellWidth = CGFloat(screenshotWidthInPixels) / CGFloat(columnCount)
        let cellHeight = CGFloat(screenshotHeightInPixels) / CGFloat(rowCount)

        let columnIndex = Int(point.x / cellWidth)
        let rowIndex = Int(point.y / cellHeight)

        guard columnIndex >= 0, columnIndex < columnCount,
              rowIndex >= 0, rowIndex < rowCount else {
            return nil
        }

        return cellLabel(columnIndex: columnIndex, rowIndex: rowIndex)
    }

    static func gridCellLabelsTouchedByOutline(
        outlinePointsInScreenshotSpace: [CGPoint],
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> [String] {
        guard !outlinePointsInScreenshotSpace.isEmpty else { return [] }

        var touchedCellLabels = Set<String>()

        for outlinePoint in outlinePointsInScreenshotSpace {
            if let cellLabel = gridCellLabel(
                forScreenshotPixelCoordinate: outlinePoint,
                screenshotWidthInPixels: screenshotWidthInPixels,
                screenshotHeightInPixels: screenshotHeightInPixels
            ) {
                touchedCellLabels.insert(cellLabel)
            }
        }

        if outlinePointsInScreenshotSpace.count >= 2 {
            let xCoordinates = outlinePointsInScreenshotSpace.map(\.x)
            let yCoordinates = outlinePointsInScreenshotSpace.map(\.y)

            let boundingRect = CGRect(
                x: xCoordinates.min() ?? 0,
                y: yCoordinates.min() ?? 0,
                width: (xCoordinates.max() ?? 0) - (xCoordinates.min() ?? 0),
                height: (yCoordinates.max() ?? 0) - (yCoordinates.min() ?? 0)
            )

            let cellWidth = CGFloat(screenshotWidthInPixels) / CGFloat(columnCount)
            let cellHeight = CGFloat(screenshotHeightInPixels) / CGFloat(rowCount)

            for rowIndex in 0..<rowCount {
                for columnIndex in 0..<columnCount {
                    let cellRect = CGRect(
                        x: CGFloat(columnIndex) * cellWidth,
                        y: CGFloat(rowIndex) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    if cellRect.intersects(boundingRect) {
                        touchedCellLabels.insert(cellLabel(columnIndex: columnIndex, rowIndex: rowIndex))
                    }
                }
            }
        }

        return touchedCellLabels.sorted()
    }

    static func spatialContextLabel(
        outlinePointsInScreenshotSpace: [CGPoint],
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> String? {
        let touchedCells = gridCellLabelsTouchedByOutline(
            outlinePointsInScreenshotSpace: outlinePointsInScreenshotSpace,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )

        guard !touchedCells.isEmpty else { return nil }

        return "user mouse outline touches grid cells: \(touchedCells.joined(separator: ", "))"
    }

    static func swiftUIPoints(
        forGridCellLabels gridCellLabels: [String],
        screenFrame: CGRect
    ) -> [CGPoint] {
        gridCellLabels.compactMap { gridCellLabel in
            guard let cellRect = cellRectInSwiftUICoordinates(
                gridCellLabel: gridCellLabel,
                screenFrame: screenFrame
            ) else {
                return nil
            }
            return CGPoint(x: cellRect.midX, y: cellRect.midY)
        }
    }

    static func cellRectInSwiftUICoordinates(
        gridCellLabel: String,
        screenFrame: CGRect
    ) -> CGRect? {
        guard let (columnIndex, rowIndex) = parseCellLabel(gridCellLabel) else { return nil }

        let cellWidthInPoints = screenFrame.width / CGFloat(columnCount)
        let cellHeightInPoints = screenFrame.height / CGFloat(rowCount)

        return CGRect(
            x: CGFloat(columnIndex) * cellWidthInPoints,
            y: CGFloat(rowIndex) * cellHeightInPoints,
            width: cellWidthInPoints,
            height: cellHeightInPoints
        )
    }

    /// Tightens a coarse model DRAW selection around an anchor cell (usually from POINT).
    static func refinedOutlineCellLabels(
        from gridCellLabels: [String],
        anchorGridCellLabel: String? = nil
    ) -> [String] {
        let parsedDrawCells = gridCellLabels.compactMap { parseCellLabel($0) }
        guard !parsedDrawCells.isEmpty else { return gridCellLabels }

        let minimumColumnIndex = parsedDrawCells.map(\.columnIndex).min() ?? 0
        let maximumColumnIndex = parsedDrawCells.map(\.columnIndex).max() ?? 0
        let minimumRowIndex = parsedDrawCells.map(\.rowIndex).min() ?? 0
        let maximumRowIndex = parsedDrawCells.map(\.rowIndex).max() ?? 0
        let columnSpan = maximumColumnIndex - minimumColumnIndex
        let rowSpan = maximumRowIndex - minimumRowIndex

        // Model already sent a wide rect — trust it, don't balloon further.
        if columnSpan >= 2 && rowSpan >= 1 {
            return gridCellLabels
        }

        // Resolve anchor: POINT tag wins, otherwise bottom-most picked cell.
        let anchorColumnIndex: Int
        let anchorRowIndex: Int
        if let anchorGridCellLabel, let parsedAnchor = parseCellLabel(anchorGridCellLabel) {
            anchorColumnIndex = parsedAnchor.columnIndex
            anchorRowIndex = parsedAnchor.rowIndex
        } else {
            anchorColumnIndex = (minimumColumnIndex + maximumColumnIndex) / 2
            anchorRowIndex = maximumRowIndex
        }

        // Single icon / button — keep one tight cell.
        if gridCellLabels.count == 1, columnSpan == 0, rowSpan == 0 {
            return [cellLabel(columnIndex: anchorColumnIndex, rowIndex: anchorRowIndex)]
        }

        // List row / card — ~4 columns × 1 row on the anchor.
        let listRowColumnCount = 4
        let leftColumnIndex = max(0, anchorColumnIndex - 1)
        let rightColumnIndex = min(columnCount - 1, leftColumnIndex + listRowColumnCount - 1)
        let targetRowIndex = min(anchorRowIndex, rowCount - 1)

        return gridCellLabelsInRange(
            fromTopLeft: cellLabel(columnIndex: leftColumnIndex, rowIndex: targetRowIndex),
            toBottomRight: cellLabel(columnIndex: rightColumnIndex, rowIndex: targetRowIndex)
        )
    }

    /// Smooth chalk target — union of cells, tuned for list rows and icons.
    static func chalkOutlineRectInSwiftUICoordinates(
        gridCellLabels: [String],
        screenFrame: CGRect
    ) -> CGRect? {
        guard !gridCellLabels.isEmpty else { return nil }

        var unionRect: CGRect?
        for gridCellLabel in gridCellLabels {
            guard let cellRect = cellRectInSwiftUICoordinates(
                gridCellLabel: gridCellLabel,
                screenFrame: screenFrame
            ) else { continue }
            unionRect = unionRect?.union(cellRect) ?? cellRect
        }

        guard var outlineRect = unionRect else { return nil }

        let cellWidth = screenFrame.width / CGFloat(columnCount)
        let cellHeight = screenFrame.height / CGFloat(rowCount)

        if gridCellLabels.count == 1 {
            outlineRect = outlineRect.insetBy(
                dx: outlineRect.width * 0.14,
                dy: outlineRect.height * 0.12
            )
        }

        let paddingInPoints: CGFloat = 4
        outlineRect = outlineRect.insetBy(dx: -paddingInPoints, dy: -paddingInPoints)

        // Small downward nudge — models often label half a cell too high.
        outlineRect.origin.y += cellHeight * 0.35

        // Hard cap so we never blanket a huge area.
        let maximumOutlineWidth = cellWidth * 5.5
        let maximumOutlineHeight = cellHeight * 1.35
        if outlineRect.width > maximumOutlineWidth {
            let excessWidth = outlineRect.width - maximumOutlineWidth
            outlineRect.origin.x += excessWidth / 2
            outlineRect.size.width = maximumOutlineWidth
        }
        if outlineRect.height > maximumOutlineHeight {
            let excessHeight = outlineRect.height - maximumOutlineHeight
            outlineRect.origin.y += excessHeight / 2
            outlineRect.size.height = maximumOutlineHeight
        }

        return outlineRect
    }

    /// All cells in an inclusive rectangular range, e.g. M6-O8.
    static func gridCellLabelsInRange(fromTopLeft topLeftCell: String, toBottomRight bottomRightCell: String) -> [String] {
        guard let (startColumn, startRow) = parseCellLabel(topLeftCell),
              let (endColumn, endRow) = parseCellLabel(bottomRightCell) else {
            return []
        }

        let minColumn = min(startColumn, endColumn)
        let maxColumn = max(startColumn, endColumn)
        let minRow = min(startRow, endRow)
        let maxRow = max(startRow, endRow)

        var labels: [String] = []
        for rowIndex in minRow...maxRow {
            for columnIndex in minColumn...maxColumn {
                labels.append(cellLabel(columnIndex: columnIndex, rowIndex: rowIndex))
            }
        }
        return labels
    }

    // MARK: - Chalk drawing (screenshot + shared colors)

    static let chalkStrokeColor = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.35, alpha: 0.92)
    static let chalkHighlightFillColor = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.35, alpha: 0.22)

    private static func drawHighlightedGridCells(
        cellLabels: [String],
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        imageHeight: CGFloat
    ) {
        for cellLabel in cellLabels {
            guard let (columnIndex, rowIndex) = parseCellLabel(cellLabel) else { continue }

            let cellRect = NSRect(
                x: CGFloat(columnIndex) * cellWidth,
                y: imageHeight - CGFloat(rowIndex + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )

            chalkHighlightFillColor.setFill()
            NSBezierPath(rect: cellRect).fill()
        }
    }

    private static func drawChalkOutlineOnImage(
        outlinePointsInScreenshotSpace: [CGPoint],
        imageHeight: CGFloat
    ) {
        guard outlinePointsInScreenshotSpace.count >= 2 else { return }

        let chalkPath = NSBezierPath()
        chalkPath.lineWidth = 5.0
        chalkPath.lineCapStyle = .round
        chalkPath.lineJoinStyle = .round

        for (pointIndex, screenshotPoint) in outlinePointsInScreenshotSpace.enumerated() {
            let appKitPoint = NSPoint(x: screenshotPoint.x, y: imageHeight - screenshotPoint.y)
            if pointIndex == 0 {
                chalkPath.move(to: appKitPoint)
            } else {
                chalkPath.line(to: appKitPoint)
            }
        }

        if outlinePointsInScreenshotSpace.count >= 8 {
            chalkPath.close()
        }

        chalkStrokeColor.withAlphaComponent(0.35).setStroke()
        let wideStroke = chalkPath.copy() as! NSBezierPath
        wideStroke.lineWidth = 9.0
        wideStroke.stroke()

        chalkStrokeColor.setStroke()
        chalkPath.stroke()
    }
}
