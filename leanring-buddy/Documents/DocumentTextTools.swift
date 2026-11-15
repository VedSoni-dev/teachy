//
//  DocumentTextTools.swift
//  leanring-buddy
//
//  Small pure text helpers for documents: sentences, words for search, cutting
//  text to a length without breaking a sentence, splitting long text into
//  sections, CSV tables, and HTML to plain text.
//

import Foundation

nonisolated enum DocumentTextTools {

    // MARK: - Cleaning

    /// Collapses runs of spaces and blank lines, and removes control characters.
    static func tidy(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{000C}", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #" ?\n ?"#, with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sentences

    /// Splits text into sentences, keeping every character (joining the result gives the text back).
    /// A sentence ends at `.`, `!` or `?` followed by white space, or at a line break.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousWasTerminator = false
        for character in text {
            if character == "\n" {
                current.append(character)
                result.append(current)
                current = ""
                previousWasTerminator = false
                continue
            }
            if previousWasTerminator, character == " " || character == "\t" {
                current.append(character)
                result.append(current)
                current = ""
                previousWasTerminator = false
                continue
            }
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                previousWasTerminator = true
            } else if character == "\"" || character == ")" || character == "”" || character == "'" {
                // A closing quote or bracket right after the full stop still ends the sentence.
            } else {
                previousWasTerminator = false
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// True when `text` ends where a sentence or a line ends.
    static func endsAtSentenceBoundary(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        if last == "\n" { return true }
        return ".!?\"”)'".contains(last)
    }

    /// Cuts `text` to at most `limit` characters. Prefers the end of a sentence, then
    /// the end of a word. The mark " […]" is added when something was cut, and counts
    /// towards the limit.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let mark = " […]"
        let room = limit - mark.count
        guard room > 0 else { return String(text.prefix(limit)) }

        var kept = ""
        for sentence in sentences(text) {
            if kept.count + sentence.count > room { break }
            kept += sentence
        }
        // Use the sentence cut only when it keeps a fair share of the room.
        if kept.trimmingCharacters(in: .whitespacesAndNewlines).count >= room / 3 {
            return kept.trimmingCharacters(in: .whitespacesAndNewlines) + mark
        }
        let hardCut = String(text.prefix(room))
        if let lastSpace = hardCut.lastIndex(where: { $0 == " " || $0 == "\n" }),
           hardCut.distance(from: hardCut.startIndex, to: lastSpace) >= room / 2 {
            return String(hardCut[..<lastSpace]) + mark
        }
        return hardCut + mark
    }

    /// Splits text into pieces of about `targetCharacters`, breaking between paragraphs
    /// first, then sentences, then words. Joining the pieces gives the text back.
    static func pieces(_ text: String, targetCharacters: Int) -> [String] {
        let target = max(50, targetCharacters)
        guard text.count > target else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { result.append(current); current = "" }
        }
        for sentence in sentences(text) {
            if sentence.count > target {
                flush()
                // A single run with no sentence ends (a table, minified code): break on spaces.
                var word = ""
                for character in sentence {
                    word.append(character)
                    if character == " ", current.count + word.count >= target {
                        current += word
                        word = ""
                        flush()
                    } else if word.count >= target {
                        current += word
                        word = ""
                        flush()
                    } else if character == " " {
                        current += word
                        word = ""
                    }
                }
                current += word
                continue
            }
            if current.count + sentence.count > target { flush() }
            current += sentence
            // A blank line after a good amount of text is a natural place to stop.
            if current.count >= target * 3 / 4, current.hasSuffix("\n\n") { flush() }
        }
        flush()
        return result
    }

    // MARK: - Words for search

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "could", "did", "do", "doe", "for",
        "from", "had", "has", "have", "he", "her", "his", "how", "i", "if", "in", "into", "is", "it", "its", "me",
        "my", "of", "on", "or", "our", "she", "so", "than", "that", "the", "their", "them", "then", "there", "these",
        "they", "thi", "this", "those", "to", "wa", "was", "we", "were", "what", "when", "where", "which", "who",
        "why", "will", "with", "would", "you", "your", "about", "tell", "say", "said", "please", "according",
        "document", "pdf", "page", "file", "article", "paper", "mention", "much", "many", "any", "some"
    ]

    /// Lower-cased search words with common words removed and simple endings trimmed
    /// ("batteries" and "battery" match, "charging" and "charge" match).
    static func searchWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let word = stem(current)
            current = ""
            if word.count >= 2 || word.first?.isNumber == true, !stopWords.contains(word) { words.append(word) }
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    static func stem(_ word: String) -> String {
        guard word.count > 3, word.first?.isLetter == true else { return word }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        if word.hasSuffix("ing"), word.count > 5 { return dropFinalE(String(word.dropLast(3))) }
        if word.hasSuffix("ed"), word.count > 4 { return dropFinalE(String(word.dropLast(2))) }
        if word.hasSuffix("es"), word.count > 4 { return dropFinalE(String(word.dropLast(2))) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { return dropFinalE(String(word.dropLast(1))) }
        return dropFinalE(word)
    }

    /// "charge", "charged" and "charging" should all meet at "charg".
    private static func dropFinalE(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("e") ? String(word.dropLast(1)) : word
    }

    // MARK: - Sections for text without pages

    /// Splits plain text into sections of about `targetCharacters`, each titled with its line range.
    static func lineRangeSections(_ text: String, targetCharacters: Int = 3000) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        var firstLine = 1
        for piece in pieces(text, targetCharacters: targetCharacters) {
            let lineBreaks = piece.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let endsWithBreak = piece.hasSuffix("\n")
            let lastLine = firstLine + max(0, lineBreaks - (endsWithBreak ? 1 : 0))
            let body = piece.trimmingCharacters(in: .newlines)
            if !body.trimmingCharacters(in: .whitespaces).isEmpty {
                sections.append(DocumentSection(
                    number: sections.count + 1,
                    title: firstLine == lastLine ? "line \(firstLine)" : "lines \(firstLine)–\(lastLine)",
                    text: body
                ))
            }
            firstLine += lineBreaks
        }
        return sections
    }

    /// Splits Markdown at its headings; long stretches without a heading are split by length.
    static func markdownSections(_ text: String, targetCharacters: Int = 3000) -> [DocumentSection] {
        var blocks: [(title: String?, body: String)] = []
        var currentTitle: String?
        var currentBody = ""
        var insideFence = false
        func flush() {
            if !currentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append((currentTitle, currentBody))
            }
            currentBody = ""
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideFence.toggle() }
            let isHeading = !insideFence && line.range(of: #"^#{1,4} +\S"#, options: .regularExpression) != nil
            if isHeading {
                flush()
                currentTitle = line.replacingOccurrences(of: #"^#+ +"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            currentBody += line + "\n"
        }
        flush()

        var sections: [DocumentSection] = []
        for block in blocks {
            for piece in pieces(block.body, targetCharacters: targetCharacters) {
                let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                sections.append(DocumentSection(number: sections.count + 1, title: block.title, text: body))
            }
        }
        return sections
    }

    /// Splits flowing text (a web page, a Word file) into numbered sections by length.
    static func plainSections(_ text: String, targetCharacters: Int = 3000) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        for piece in pieces(text, targetCharacters: targetCharacters) {
            let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            sections.append(DocumentSection(number: sections.count + 1, text: body))
        }
        return sections
    }

    // MARK: - HTML

    /// Readable text from an HTML page: scripts, styles and tags removed, block tags turned into line breaks.
    static func plainText(fromHTML html: String) -> (title: String?, text: String) {
        var title: String?
        if let titleRange = html.range(of: #"(?is)<title\b[^>]*>(.*?)</title>"#, options: .regularExpression) {
            let inner = String(html[titleRange])
                .replacingOccurrences(of: #"(?is)</?title\b[^>]*>"#, with: "", options: .regularExpression)
            let cleaned = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { title = cleaned }
        }
        var text = html
        for pattern in [
            #"(?is)<head\b.*?</head>"#, #"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#,
            #"(?is)<noscript\b.*?</noscript>"#, #"(?is)<svg\b.*?</svg>"#, #"(?s)<!--.*?-->"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<h[1-6]\b[^>]*>"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/blockquote|/pre|/table)\b[^>]*>"#,
            with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " | ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return (title, tidy(decodeEntities(text)))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = [
            "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
            "&rdquo;": "”", "&ldquo;": "“", "&copy;": "©", "&amp;": "&"
        ]
        for (entity, replacement) in named where entity != "&amp;" {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]{1,6});") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let hexFlag = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hexFlag].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - CSV

/// A parsed table and a short preview of it that a person (or a model) can read at a glance.
nonisolated struct CSVTable: Equatable, Sendable {
    var header: [String]
    var rows: [[String]]
    var delimiter: Character

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// Parses comma, tab or semicolon separated text. Quoted cells may hold the
    /// delimiter, line breaks and doubled quotes.
    static func parse(_ text: String, delimiter: Character? = nil) -> CSVTable {
        let separator = delimiter ?? guessDelimiter(text)
        var records: [[String]] = []
        var record: [String] = []
        var cell = ""
        var insideQuotes = false
        var cellWasQuoted = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextCharacter() -> Character? {
            if let held = pending { pending = nil; return held }
            return iterator.next()
        }
        func endCell() {
            record.append(cellWasQuoted ? cell : cell.trimmingCharacters(in: .whitespaces))
            cell = ""
            cellWasQuoted = false
        }
        func endRecord() {
            endCell()
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }

        while let character = nextCharacter() {
            if insideQuotes {
                if character == "\"" {
                    if let following = nextCharacter() {
                        if following == "\"" { cell.append("\"") } else { insideQuotes = false; pending = following }
                    } else {
                        insideQuotes = false
                    }
                } else {
                    cell.append(character)
                }
                continue
            }
            if character == "\"", cell.trimmingCharacters(in: .whitespaces).isEmpty {
                insideQuotes = true
                cellWasQuoted = true
                cell = ""
            } else if character == separator {
                endCell()
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                endRecord()
            } else {
                cell.append(character)
            }
        }
        if !cell.isEmpty || !record.isEmpty { endRecord() }

        guard let first = records.first else { return CSVTable(header: [], rows: [], delimiter: separator) }
        return CSVTable(header: first, rows: Array(records.dropFirst()), delimiter: separator)
    }

    static func guessDelimiter(_ text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let candidates: [Character] = [",", "\t", ";", "|"]
        let counts = candidates.map { candidate in firstLine.reduce(0) { $1 == candidate ? $0 + 1 : $0 } }
        guard let best = counts.max(), best > 0, let position = counts.firstIndex(of: best) else { return "," }
        return candidates[position]
    }

    /// A Markdown table of `rows` under the header, with long cells shortened.
    func markdownTable(rows shownRows: [[String]], maximumCellCharacters: Int = 40) -> String {
        func clean(_ cell: String) -> String {
            let oneLine = cell.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
            return oneLine.count > maximumCellCharacters ? String(oneLine.prefix(maximumCellCharacters - 1)) + "…" : oneLine
        }
        let columns = columnCount
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, columns - cells.count))
            return "| " + padded.prefix(columns).map(clean).joined(separator: " | ") + " |"
        }
        var lines = [line(header), "|" + Array(repeating: " --- |", count: columns).joined()]
        lines.append(contentsOf: shownRows.map(line))
        return lines.joined(separator: "\n")
    }

    /// What the table is: its size, its columns (with the range of each numeric
    /// column), then the first rows and the last rows.
    func preview(firstRows: Int = 12, lastRows: Int = 3, wasCutShort: Bool = false) -> String {
        var lines: [String] = []
        let rowWord = rows.count == 1 ? "row" : "rows"
        lines.append("Table: \(rows.count)\(wasCutShort ? "+" : "") \(rowWord), \(columnCount) columns.")

        var columnNotes: [String] = []
        for (position, name) in header.enumerated() {
            let values = rows.compactMap { position < $0.count ? $0[position] : nil }.filter { !$0.isEmpty }
            let numbers = values.compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            let label = name.isEmpty ? "column \(position + 1)" : name
            if !values.isEmpty, numbers.count == values.count, let low = numbers.min(), let high = numbers.max() {
                columnNotes.append("\(label) (number, \(Self.format(low)) to \(Self.format(high)))")
            } else {
                let distinct = Set(values).count
                columnNotes.append(distinct > 0 && distinct <= 6 && values.count > distinct
                    ? "\(label) (\(distinct) different values)"
                    : label)
            }
        }
        if !columnNotes.isEmpty { lines.append("Columns: " + columnNotes.joined(separator: "; ") + ".") }

        if rows.count <= firstRows + lastRows {
            lines.append(markdownTable(rows: rows))
        } else {
            lines.append("First \(firstRows) rows:")
            lines.append(markdownTable(rows: Array(rows.prefix(firstRows))))
            lines.append("Last \(lastRows) rows:")
            lines.append(markdownTable(rows: Array(rows.suffix(lastRows))))
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    /// The preview as section 1, then every row in blocks of `rowsPerSection` so a
    /// search can find a row that the preview doesn't show.
    func sections(rowsPerSection: Int = 60, wasCutShort: Bool = false) -> [DocumentSection] {
        var sections = [DocumentSection(number: 1, title: "overview", text: preview(wasCutShort: wasCutShort))]
        guard rows.count > 15 else { return sections }
        var start = 0
        while start < rows.count {
            let end = min(rows.count, start + rowsPerSection)
            sections.append(DocumentSection(
                number: sections.count + 1,
                title: "rows \(start + 1)–\(end)",
                text: markdownTable(rows: Array(rows[start..<end]), maximumCellCharacters: 80)
            ))
            start = end
        }
        return sections
    }
}
