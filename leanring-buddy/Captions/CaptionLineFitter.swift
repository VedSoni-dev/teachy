//
//  CaptionLineFitter.swift
//  leanring-buddy
//
//  Pure text layout for the caption bar: wraps a spoken sentence into lines that
//  fit the bar, groups the lines into two-line pages, and says how long each page
//  should stay up so long sentences roll along with the voice. No AppKit: the
//  caller passes a function that measures a string's width.
//

import Foundation

nonisolated enum CaptionLineFitter {
    /// Measures by character count. Used in tests and as a fallback.
    static let characterWidth: (String) -> Double = { Double($0.count) }

    /// Collapses runs of whitespace and newlines into single spaces.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Greedy word wrap. A single word wider than the line is broken across lines.
    static func wrap(_ text: String, maxWidth: Double, measure: (String) -> Double = characterWidth) -> [String] {
        guard maxWidth > 0 else { return [] }
        var lines: [String] = []
        var current = ""
        for word in normalized(text).split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if measure(candidate) <= maxWidth {
                current = candidate
                continue
            }
            if !current.isEmpty {
                lines.append(current)
                current = ""
            }
            // The word starts a new line. Break it if it is too wide by itself.
            var rest = word
            while measure(rest) > maxWidth, rest.count > 1 {
                var cut = rest.count - 1
                while cut > 1, measure(String(rest.prefix(cut))) > maxWidth { cut -= 1 }
                lines.append(String(rest.prefix(cut)))
                rest = String(rest.dropFirst(cut))
            }
            current = rest
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// The wrapped lines in groups of `maxLines`. Each group is shown on its own.
    static func pages(
        _ text: String,
        maxWidth: Double,
        maxLines: Int = 2,
        measure: (String) -> Double = characterWidth
    ) -> [[String]] {
        let lines = wrap(text, maxWidth: maxWidth, measure: measure)
        guard maxLines > 0, !lines.isEmpty else { return [] }
        return stride(from: 0, to: lines.count, by: maxLines).map {
            Array(lines[$0..<min($0 + maxLines, lines.count)])
        }
    }

    /// Roughly how long the voice takes to say `text` (about 15 characters a second at 1×).
    static func estimatedSpeechSeconds(for text: String, speed: Double = 1.0) -> Double {
        let characters = Double(normalized(text).count)
        let safeSpeed = min(max(speed, 0.25), 4.0)
        return max(0.6, characters / 15.0 / safeSpeed)
    }

    /// How long each page stays up before the next one replaces it.
    static func pageDurations(_ pages: [[String]], speed: Double = 1.0) -> [Double] {
        pages.map { estimatedSpeechSeconds(for: $0.joined(separator: " "), speed: speed) }
    }
}
