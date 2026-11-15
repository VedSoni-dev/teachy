//
//  DocumentRetrieval.swift
//  leanring-buddy
//
//  Finding the parts of a long document that answer a question, on this Mac,
//  with no model call: the text is cut into chunks that never cross a page, and
//  the chunks are ranked by BM25 word scoring (the standard keyword ranking
//  used by search engines) plus a small bonus for words that appear next to
//  each other as they do in the question.
//

import Foundation

/// A piece of one page or section, small enough to rank and to quote.
nonisolated struct DocumentChunk: Equatable, Sendable {
    /// Which document in the list this came from.
    var documentIndex: Int
    /// Position among all chunks of that document, in reading order.
    var order: Int
    /// Page (PDF) or section number, 1-based.
    var sectionNumber: Int
    var sectionTitle: String?
    var text: String
}

nonisolated struct ScoredChunk: Equatable, Sendable {
    var chunk: DocumentChunk
    var score: Double
}

nonisolated enum DocumentChunker {
    static let defaultChunkCharacters = 1100

    /// Chunks for one document. A chunk never crosses a page, so its page number is exact.
    static func chunks(
        for document: ReadDocument,
        documentIndex: Int = 0,
        targetCharacters: Int = defaultChunkCharacters
    ) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        for section in document.sections {
            // A page a little over the target becomes two even halves, not a full chunk and a sliver.
            let partCount = Int((Double(section.text.count) / Double(targetCharacters)).rounded(.up))
            let evenTarget = partCount > 1 ? min(targetCharacters, section.text.count / partCount + 140) : targetCharacters
            for piece in DocumentTextTools.pieces(section.text, targetCharacters: evenTarget) {
                let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                chunks.append(DocumentChunk(
                    documentIndex: documentIndex,
                    order: chunks.count,
                    sectionNumber: section.number,
                    sectionTitle: section.title,
                    text: body
                ))
            }
        }
        return chunks
    }
}

nonisolated enum DocumentRetriever {
    private static let k1 = 1.4
    private static let b = 0.75

    /// Chunks ordered best first. Chunks that share no word with the question score 0
    /// and keep their reading order at the end.
    static func rank(question: String, chunks: [DocumentChunk]) -> [ScoredChunk] {
        let queryWords = DocumentTextTools.searchWords(question)
        guard !queryWords.isEmpty, !chunks.isEmpty else {
            return chunks.map { ScoredChunk(chunk: $0, score: 0) }
        }
        let uniqueQueryWords = Array(Set(queryWords))
        let queryPairs = zip(queryWords, queryWords.dropFirst()).map { $0 + " " + $1 }

        let chunkWords = chunks.map { DocumentTextTools.searchWords(($0.sectionTitle ?? "") + " " + $0.text) }
        let averageLength = max(1, Double(chunkWords.reduce(0) { $0 + $1.count }) / Double(chunks.count))

        var chunksContaining: [String: Int] = [:]
        var counts: [[String: Int]] = []
        counts.reserveCapacity(chunks.count)
        for words in chunkWords {
            var wordCounts: [String: Int] = [:]
            for word in words { wordCounts[word, default: 0] += 1 }
            for word in uniqueQueryWords where wordCounts[word] != nil { chunksContaining[word, default: 0] += 1 }
            counts.append(wordCounts)
        }

        let total = Double(chunks.count)
        var scored: [ScoredChunk] = []
        scored.reserveCapacity(chunks.count)
        for (position, chunk) in chunks.enumerated() {
            let words = chunkWords[position]
            let length = Double(words.count)
            var score = 0.0
            for word in uniqueQueryWords {
                guard let frequency = counts[position][word] else { continue }
                let containing = Double(chunksContaining[word] ?? 0)
                let rarity = log(1 + (total - containing + 0.5) / (containing + 0.5))
                let tf = Double(frequency)
                score += rarity * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * length / averageLength))
            }
            if score > 0, !queryPairs.isEmpty {
                let chunkPairs = Set(zip(words, words.dropFirst()).map { $0 + " " + $1 })
                let matchingPairs = queryPairs.filter { chunkPairs.contains($0) }.count
                score *= 1 + 0.25 * Double(matchingPairs)
            }
            scored.append(ScoredChunk(chunk: chunk, score: score))
        }
        return scored.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            if first.chunk.documentIndex != second.chunk.documentIndex { return first.chunk.documentIndex < second.chunk.documentIndex }
            return first.chunk.order < second.chunk.order
        }
    }
}
