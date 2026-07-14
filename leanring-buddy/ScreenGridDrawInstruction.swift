//
//  ScreenGridDrawInstruction.swift
//  leanring-buddy
//
//  Parsed [DRAW:...] tags and helpers for rendering chalk outlines on screen.
//

import AppKit
import Foundation

struct ScreenGridDrawInstruction: Equatable {
    let gridCellLabels: [String]
    let displayFrame: CGRect
}

enum ScreenGridDrawParser {
    /// Parses [DRAW:M6], [DRAW:M6,N6,O7], or [DRAW:rect:M6-O8] from a model response.
    static func parseDrawInstruction(from responseText: String) -> (spokenText: String, drawInstruction: ScreenGridDrawInstruction?)? {
        let cellToken = ScreenGridAnnotationUtility.gridCellRegexFragment

        if let rectRangeResult = parseRectRangeDrawTag(from: responseText, cellToken: cellToken) {
            return rectRangeResult
        }

        let listPattern = "\\[DRAW:\\s*(" + cellToken + "(?:\\s*,\\s*" + cellToken + ")*)\\s*\\]"
        guard let regex = try? NSRegularExpression(pattern: listPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let cellsRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }

        let gridCellLabels = parseCellLabels(from: String(responseText[cellsRange]))
        guard !gridCellLabels.isEmpty else { return nil }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = responseTextByRemovingTag(from: responseText, tagRange: tagRange)

        return (
            spokenText: spokenText,
            drawInstruction: ScreenGridDrawInstruction(
                gridCellLabels: gridCellLabels,
                displayFrame: .zero
            )
        )
    }

    static func responseTextByRemovingDrawTags(from responseText: String) -> String {
        guard let parsed = parseDrawInstruction(from: responseText) else {
            return responseText
        }
        return parsed.spokenText
    }

    private static func parseRectRangeDrawTag(
        from responseText: String,
        cellToken: String
    ) -> (spokenText: String, drawInstruction: ScreenGridDrawInstruction?)? {
        let rectPattern = "\\[DRAW:\\s*rect:\\s*(" + cellToken + ")\\s*-\\s*(" + cellToken + ")\\s*\\]"
        guard let regex = try? NSRegularExpression(pattern: rectPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let topLeftRange = Range(match.range(at: 1), in: responseText),
              let bottomRightRange = Range(match.range(at: 2), in: responseText) else {
            return nil
        }

        let topLeftCell = String(responseText[topLeftRange]).uppercased()
        let bottomRightCell = String(responseText[bottomRightRange]).uppercased()
        let gridCellLabels = ScreenGridAnnotationUtility.gridCellLabelsInRange(
            fromTopLeft: topLeftCell,
            toBottomRight: bottomRightCell
        )
        guard !gridCellLabels.isEmpty else { return nil }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = responseTextByRemovingTag(from: responseText, tagRange: tagRange)

        return (
            spokenText: spokenText,
            drawInstruction: ScreenGridDrawInstruction(
                gridCellLabels: gridCellLabels,
                displayFrame: .zero
            )
        )
    }

    private static func parseCellLabels(from cellsText: String) -> [String] {
        cellsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private static func responseTextByRemovingTag(from responseText: String, tagRange: Range<String.Index>) -> String {
        var spokenText = responseText
        spokenText.removeSubrange(tagRange)
        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
