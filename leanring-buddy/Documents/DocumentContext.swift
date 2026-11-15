//
//  DocumentContext.swift
//  leanring-buddy
//
//  Turns read documents into the text handed to the model for one question.
//  A document that fits the budget goes in whole. One that doesn't goes in as:
//  a table of contents, the first page, and the parts that best match the
//  question (see DocumentRetrieval), each under its page number so the answer
//  can say "on page 12". The result never exceeds the budget.
//

import Foundation

nonisolated struct DocumentContextResult: Sendable {
    /// The text for the model. Empty when there is nothing to hand over.
    var text: String
    /// For each input document: the page or section numbers whose text is in `text`.
    var includedSections: [[Int]]
    /// For each input document: true when all of its text is in `text`.
    var isWhole: [Bool]
}

nonisolated enum DocumentContext {
    /// About 12,000 tokens: small enough to keep a voice answer fast.
    static let defaultBudgetCharacters = 48_000

    static let preamble = """
    ATTACHED DOCUMENTS
    The person gave you what is below. Answer from it. When you use something from it, say where it is, like "on page 12". If the answer is not in what is shown, say that instead of guessing.
    """

    static func build(
        for question: String,
        documents: [ReadDocument],
        budgetCharacters: Int = defaultBudgetCharacters
    ) -> String {
        buildDetailed(for: question, documents: documents, budgetCharacters: budgetCharacters).text
    }

    static func buildDetailed(
        for question: String,
        documents: [ReadDocument],
        budgetCharacters: Int = defaultBudgetCharacters
    ) -> DocumentContextResult {
        let empty = DocumentContextResult(
            text: "",
            includedSections: documents.map { _ in [] },
            isWhole: documents.map { _ in false }
        )
        guard !documents.isEmpty, budgetCharacters > 0 else { return empty }

        let separator = "\n\n"
        let fixedCost = preamble.count + separator.count * documents.count
        let wholeTexts = documents.enumerated().map { renderWhole($1, number: $0 + 1) }

        var parts = [String](repeating: "", count: documents.count)
        var included = documents.map { $0.sections.filter { !$0.text.isEmpty }.map(\.number) }
        var whole = [Bool](repeating: true, count: documents.count)

        if fixedCost + wholeTexts.reduce(0, { $0 + $1.count }) <= budgetCharacters {
            parts = wholeTexts
        } else {
            // Small documents go in whole; what they don't use is shared by the long ones.
            var remaining = max(0, budgetCharacters - fixedCost)
            let smallestFirst = documents.indices.sorted { wholeTexts[$0].count < wholeTexts[$1].count }
            for (position, documentIndex) in smallestFirst.enumerated() {
                let share = remaining / (smallestFirst.count - position)
                if wholeTexts[documentIndex].count <= share {
                    parts[documentIndex] = wholeTexts[documentIndex]
                } else {
                    let excerpt = renderExcerpt(
                        documents[documentIndex],
                        number: documentIndex + 1,
                        question: question,
                        budget: share
                    )
                    parts[documentIndex] = excerpt.text
                    included[documentIndex] = excerpt.sections
                    whole[documentIndex] = false
                }
                remaining = max(0, remaining - parts[documentIndex].count)
            }
        }

        var text = ([preamble] + parts.filter { !$0.isEmpty }).joined(separator: separator)
        if text.count > budgetCharacters {
            // Only reachable with a budget too small for even the headers.
            text = DocumentTextTools.truncate(text, to: budgetCharacters)
        }
        return DocumentContextResult(text: text, includedSections: included, isWhole: whole)
    }

    // MARK: - Labels

    static func header(_ document: ReadDocument, number: Int, mode: String) -> String {
        let title = document.title.replacingOccurrences(of: "\"", with: "'")
        var line = "=== Document \(number): \"\(title)\" (\(document.kind.displayName), \(document.sizeDescription)) — \(mode) ==="
        if document.imageData != nil { line += "\nThe picture itself is attached to this message as an image." }
        if let note = document.truncationNote, !note.isEmpty { line += "\nNote: \(note)" }
        return line
    }

    static func label(for section: DocumentSection, in document: ReadDocument) -> String {
        if document.kind == .pdf { return "[page \(section.number)]" }
        if let title = section.title, !title.isEmpty {
            return "[section \(section.number) · \(String(title.prefix(60)))]"
        }
        return "[section \(section.number)]"
    }

    // MARK: - Whole document

    private static func renderWhole(_ document: ReadDocument, number: Int) -> String {
        let sections = document.sections.filter { !$0.text.isEmpty }
        guard !sections.isEmpty else {
            return header(document, number: number, mode: document.imageData != nil ? "picture only, no text found in it" : "no text could be read")
        }
        var lines = [header(document, number: number, mode: "full text")]
        let needsLabels = document.kind == .pdf || sections.count > 1
        for section in sections {
            if needsLabels { lines.append(label(for: section, in: document)) }
            lines.append(section.text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Selected parts

    private static func tableOfContents(_ document: ReadDocument, budget: Int) -> String {
        let sections = document.sections.filter { !$0.text.isEmpty }
        func lines(headingLength: Int, stride step: Int) -> [String] {
            Swift.stride(from: 0, to: sections.count, by: step).map { position in
                let section = sections[position]
                let firstLine = section.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let heading = (section.title?.isEmpty == false && document.kind != .pdf) ? section.title! : firstLine
                let short = heading.count > headingLength ? String(heading.prefix(headingLength - 1)) + "…" : heading
                return "- \(document.unitName) \(section.number): \(short)"
            }
        }
        let intro = "Contents (first line of each \(document.unitName)):"
        for (headingLength, step) in [(70, 1), (40, 1), (40, 2), (40, 4), (30, 8), (30, 16), (30, 32)] {
            let candidate = ([intro] + lines(headingLength: headingLength, stride: step)).joined(separator: "\n")
            if candidate.count <= budget { return candidate }
        }
        return ""
    }

    private static func renderExcerpt(
        _ document: ReadDocument,
        number: Int,
        question: String,
        budget: Int
    ) -> (text: String, sections: [Int]) {
        let headerText = header(document, number: number, mode: "selected parts")
            + "\nThis document is too long to show whole. Below: its contents, its first \(document.unitName), then the parts that best match the question, each under its \(document.unitName) number. What is not shown was left out for length."
        guard budget > headerText.count + 200 else {
            return (DocumentTextTools.truncate(headerText, to: max(0, budget)), [])
        }

        let chunks = DocumentChunker.chunks(for: document, documentIndex: number - 1)
        guard let firstSectionNumber = chunks.first?.sectionNumber else { return (headerText, []) }
        let ranked = DocumentRetriever.rank(question: question, chunks: chunks).filter { $0.score > 0 }

        // The best match comes before everything else: the contents and the first
        // page only get the room that is left once it is in.
        let perChunkOverhead = 28
        let bestMatchCost = ranked.first.map { $0.chunk.text.count + perChunkOverhead } ?? 0
        let roomAfterBestMatch = max(0, budget - headerText.count - bestMatchCost - 2 * perChunkOverhead)
        let contents = tableOfContents(document, budget: min(budget / 5, roomAfterBestMatch / 2))

        // The first page: whole if it is short, otherwise its opening sentences.
        let firstPageChunks = chunks.filter { $0.sectionNumber == firstSectionNumber }
        let firstPageRoom = min(max(200, budget / 4), roomAfterBestMatch - contents.count)
        var selected = Set<Int>()
        var selectionOrder: [Int] = []
        var firstPageUsed = 0
        for chunk in firstPageChunks {
            if firstPageUsed + chunk.text.count > firstPageRoom { break }
            selected.insert(chunk.order)
            firstPageUsed += chunk.text.count
        }
        // A first page whose first chunk alone is too long gets cut at a sentence.
        var firstPageOpening: String?
        if selected.isEmpty, firstPageRoom >= 120, let opening = firstPageChunks.first {
            firstPageOpening = DocumentTextTools.truncate(opening.text, to: firstPageRoom)
        }
        let pinned = selected

        // Every chunk is charged for its text, a separator and (generously) a page label.
        var used = headerText.count + contents.count + firstPageUsed + (firstPageOpening?.count ?? 0)
            + perChunkOverhead * (selected.count + 1) + 8
        func cost(_ chunk: DocumentChunk) -> Int { chunk.text.count + perChunkOverhead }
        func take(_ chunk: DocumentChunk) -> Bool {
            guard !selected.contains(chunk.order), used + cost(chunk) <= budget else { return false }
            // The cut opening of page one stands in for its first chunk.
            if firstPageOpening != nil, chunk.order == firstPageChunks.first?.order { return false }
            selected.insert(chunk.order)
            selectionOrder.append(chunk.order)
            used += cost(chunk)
            return true
        }

        func takeNeighbours(of chunk: DocumentChunk) {
            for neighbour in [chunk.order + 1, chunk.order - 1] where neighbour >= 0 && neighbour < chunks.count {
                _ = take(chunks[neighbour])
            }
        }
        // The best three matches bring the text around them; then the other matches;
        // then the text around those, while there is room.
        for hit in ranked.prefix(3) {
            if take(hit.chunk) || selected.contains(hit.chunk.order) { takeNeighbours(of: hit.chunk) }
        }
        for hit in ranked.dropFirst(3) { _ = take(hit.chunk) }
        for hit in ranked.dropFirst(3) where selected.contains(hit.chunk.order) { takeNeighbours(of: hit.chunk) }

        // Room left (or a question like "summarise this" that matches nothing):
        // fill with chunks spread evenly through the document.
        let unselected = chunks.filter { !selected.contains($0.order) }
        let room = budget - used
        if room > 400, !unselected.isEmpty {
            // Each chunk earns its share of the room; one is taken whenever enough has
            // built up to pay for it. That spreads the picks by length, not by count.
            let unselectedCharacters = unselected.reduce(0) { $0 + cost($1) }
            let share = min(1, Double(room) / Double(unselectedCharacters))
            var saved = 0.0
            for chunk in unselected {
                saved += Double(cost(chunk)) * share
                if saved >= Double(cost(chunk)) * 0.999, take(chunk) { saved -= Double(cost(chunk)) }
            }
        }

        func render() -> String {
            var lines = [headerText]
            if !contents.isEmpty { lines.append(contents) }
            var previousOrder: Int?
            var previousSection: Int?
            if let firstPageOpening, let opening = firstPageChunks.first {
                lines.append(labelText(sectionNumber: opening.sectionNumber, title: opening.sectionTitle, document: document))
                lines.append(firstPageOpening)
                previousSection = opening.sectionNumber
                previousOrder = opening.order
            }
            for chunk in chunks where selected.contains(chunk.order) {
                let isNextInOrder = previousOrder.map { chunk.order == $0 + 1 } ?? false
                if chunk.sectionNumber != previousSection {
                    lines.append(labelText(sectionNumber: chunk.sectionNumber, title: chunk.sectionTitle, document: document))
                } else if !isNextInOrder {
                    lines.append("[…]")
                }
                lines.append(chunk.text)
                previousOrder = chunk.order
                previousSection = chunk.sectionNumber
            }
            return lines.joined(separator: "\n")
        }

        var text = render()
        // The charges above are generous, so this rarely runs; it makes the limit exact.
        while text.count > budget, let last = selectionOrder.popLast() {
            selected.remove(last)
            text = render()
        }
        if text.count > budget {
            selected = pinned
            text = DocumentTextTools.truncate(render(), to: budget)
        }
        var sectionNumbers = Set(chunks.filter { selected.contains($0.order) }.map(\.sectionNumber))
        if firstPageOpening != nil { sectionNumbers.insert(firstSectionNumber) }
        return (text, sectionNumbers.sorted())
    }

    private static func labelText(sectionNumber: Int, title: String?, document: ReadDocument) -> String {
        label(for: DocumentSection(number: sectionNumber, title: title, text: ""), in: document)
    }
}
