//
//  BrainMarkdown.swift
//  leanring-buddy
//
//  Lossless model of a sectioned Markdown memory file (PROFILE.md / VOLATILE.md).
//  The files are the source of truth and people edit them by hand, so parsing
//  keeps every line exactly as written: `BrainDocument(markdown: text).markdown == text`
//  for any input. Pure — no file IO here.
//

import Foundation

/// A Markdown file split at its `## ` headings. Everything before the first
/// heading is the preamble; each section keeps its raw heading line and raw body lines.
nonisolated struct BrainDocument: Equatable, Sendable {
    nonisolated struct Section: Equatable, Sendable {
        /// The heading exactly as written, e.g. `## About me`.
        var headingLine: String
        /// Body lines exactly as written (blank lines, prose, bullets, anything).
        var lines: [String]

        var title: String {
            String(headingLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// One thing remembered inside a section: a top-level bullet with its indented
    /// continuation lines, or a single line of hand-written prose.
    nonisolated struct Item: Equatable, Sendable {
        /// Line range inside `Section.lines`.
        var range: Range<Int>
        var isBullet: Bool
        /// The text without the bullet marker, continuation lines joined with spaces.
        var text: String
    }

    var preamble: [String]
    var sections: [Section]

    init(markdown: String) {
        var preamble: [String] = []
        var sections: [Section] = []
        var isInsideCodeFence = false

        for line in markdown.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                isInsideCodeFence.toggle()
            }
            if !isInsideCodeFence && Self.isSectionHeading(line) {
                sections.append(Section(headingLine: line, lines: []))
            } else if sections.isEmpty {
                preamble.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }

        self.preamble = preamble
        self.sections = sections
    }

    var markdown: String {
        var allLines = preamble
        for section in sections {
            allLines.append(section.headingLine)
            allLines.append(contentsOf: section.lines)
        }
        return allLines.joined(separator: "\n")
    }

    // MARK: - Reading

    /// Index of the first section whose title matches, ignoring case and punctuation.
    func sectionIndex(titled title: String) -> Int? {
        let wantedTitle = BrainText.normalized(title)
        return sections.firstIndex { BrainText.normalized($0.title) == wantedTitle }
    }

    /// The remembered items of a section, in file order. Blank lines and one-line
    /// HTML comments are not items.
    func items(inSectionAt sectionIndex: Int) -> [Item] {
        let lines = sections[sectionIndex].lines
        var items: [Item] = []
        var isCurrentItemOpen = false

        for (lineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty || (trimmedLine.hasPrefix("<!--") && trimmedLine.hasSuffix("-->")) {
                isCurrentItemOpen = false
                continue
            }

            let isIndented = line.first == " " || line.first == "\t"
            if isIndented && isCurrentItemOpen {
                items[items.count - 1].range = items[items.count - 1].range.lowerBound..<(lineIndex + 1)
                items[items.count - 1].text += " " + trimmedLine
                continue
            }

            if !isIndented, let bulletText = Self.topLevelBulletText(trimmedLine) {
                items.append(Item(range: lineIndex..<(lineIndex + 1), isBullet: true, text: bulletText))
            } else {
                items.append(Item(range: lineIndex..<(lineIndex + 1), isBullet: false, text: trimmedLine))
            }
            isCurrentItemOpen = true
        }
        return items
    }

    /// Every remembered item across all sections.
    var totalItemCount: Int {
        sections.indices.reduce(0) { $0 + items(inSectionAt: $1).count }
    }

    // MARK: - Editing

    /// Adds a new `## title` section at the end of the file and returns its index.
    mutating func appendSection(titled title: String) -> Int {
        // Leave exactly one blank line between the previous content and the new heading.
        if sections.isEmpty {
            Self.endWithOneBlankLine(&preamble, evenWhenEmpty: false)
        } else {
            Self.endWithOneBlankLine(&sections[sections.count - 1].lines, evenWhenEmpty: true)
        }
        sections.append(Section(headingLine: "## \(title)", lines: [""]))
        return sections.count - 1
    }

    private static func endWithOneBlankLine(_ lines: inout [String], evenWhenEmpty: Bool) {
        while let lastLine = lines.last, lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        if evenWhenEmpty || !lines.isEmpty {
            lines.append("")
        }
    }

    // MARK: - Line classification

    private static func isSectionHeading(_ line: String) -> Bool {
        guard line.hasPrefix("## ") else { return false }
        return !line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func topLevelBulletText(_ trimmedLine: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(marker) {
            return String(trimmedLine.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// Text helpers shared by de-duplication, superseding and forgetting.
nonisolated enum BrainText {
    /// Lowercased, accents folded, punctuation dropped, whitespace collapsed —
    /// two notes are "the same" when this matches.
    static func normalized(_ text: String) -> String {
        let foldedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var result = ""
        var isSpacePending = false
        for character in foldedText {
            if character.isLetter || character.isNumber {
                if isSpacePending && !result.isEmpty { result.append(" ") }
                result.append(character)
                isSpacePending = false
            } else if character != "'" && character != "\u{2019}" {
                // Apostrophes vanish ("don't" == "dont"); other punctuation separates words.
                isSpacePending = true
            }
        }
        return result
    }

    /// Removes a leading `2026-11-14: ` or `2026-11-14 15:04: ` stamp from a note.
    static func removingDateStamp(_ text: String) -> String {
        guard let stampRange = text.range(
            of: #"^\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?:\s*"#,
            options: .regularExpression
        ) else { return text }
        return String(text[stampRange.upperBound...])
    }

    /// Splits a trailing ` (x3)` repeat counter off a note. Count is 1 when absent.
    static func splittingRepeatCount(_ text: String) -> (text: String, count: Int) {
        guard let counterRange = text.range(of: #"\s*\(x\d+\)\s*$"#, options: .regularExpression) else {
            return (text, 1)
        }
        let digits = text[counterRange].filter(\.isNumber)
        return (String(text[..<counterRange.lowerBound]), max(1, Int(digits) ?? 1))
    }

    /// What a note says, ignoring its date stamp and repeat counter.
    static func comparisonKey(_ text: String) -> String {
        normalized(splittingRepeatCount(removingDateStamp(text)).text)
    }

    /// The short subject before a `: ` ("Length: short" → "length"), or nil when
    /// the note has no clear subject. Deliberately strict so URLs, times and long
    /// sentences with a colon are never treated as keyed notes.
    static func leadingSubject(_ text: String) -> String? {
        guard let colonIndex = text.firstIndex(of: ":") else { return nil }
        let textAfterColon = text[text.index(after: colonIndex)...]
        guard textAfterColon.first == " " else { return nil }
        let subject = normalized(String(text[..<colonIndex]))
        guard !subject.isEmpty, subject.count <= 40, subject.split(separator: " ").count <= 5 else { return nil }
        return subject
    }

    /// Makes model- or migration-supplied text safe to store as one bullet line.
    static func singleLineNote(_ rawNote: String, maximumCharacters: Int = 400) -> String {
        var note = rawNote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while note.hasPrefix("- ") || note.hasPrefix("* ") || note.hasPrefix("#") {
            note = String(note.dropFirst(note.hasPrefix("#") ? 1 : 2)).trimmingCharacters(in: .whitespaces)
        }
        if note.count > maximumCharacters {
            note = String(note.prefix(maximumCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return note
    }
}
