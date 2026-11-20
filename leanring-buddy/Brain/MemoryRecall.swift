//
//  MemoryRecall.swift
//  leanring-buddy
//
//  Finds what Teachy should remember for one question, the way memory layers
//  like supermemory or mem0 do it: every remembered fact, every journal line
//  and every past chat message is a candidate, ranked by
//
//    - word match (BM25 over normalised, lightly stemmed words, so "songs" finds "song"),
//    - meaning match (an on-device sentence embedding, passed in as a closure, so
//      "music I like" can find "favourite Carti song"),
//    - a small boost for remembered facts (they are distilled) and for recent things.
//
//  Pure: no files, no models. `BrainStore+Recall.swift` gathers the candidates and
//  supplies the embedding. Runs on every voice turn and agent job, not only when
//  the question says "remember" or "last time".
//

import Foundation

nonisolated enum MemoryRecallSource: Equatable, Sendable {
    /// A bullet in PROFILE.md or VOLATILE.md, with its section title.
    case fact(section: String)
    /// A line of JOURNAL.md.
    case journal
    /// A message from a saved chat.
    case chat(sessionTitle: String, isFromUser: Bool)
}

nonisolated struct MemoryRecallCandidate: Equatable, Sendable {
    var text: String
    var source: MemoryRecallSource
    var date: Date?
}

nonisolated struct MemoryRecallHit: Equatable, Sendable {
    var candidate: MemoryRecallCandidate
    var score: Double
}

nonisolated enum MemoryRecall {
    nonisolated struct Weights: Equatable, Sendable {
        var wordMatch = 0.6
        var meaningMatch = 0.4
        /// Added for remembered facts, which are already distilled and checked.
        var factBoost = 0.12
        /// Added for things from the last week, fading to nothing over 30 days.
        var recencyBoost = 0.06
        /// Cosine similarity below this counts as no meaning match at all.
        var meaningFloor = 0.35
        /// A candidate with no word in common needs at least this much meaning match.
        var meaningOnlyThreshold = 0.62
        /// Below this final score nothing is recalled.
        var minimumScore = 0.22

        init() {}
    }

    /// Words that carry no meaning for recall.
    static let ignoredWords: Set<String> = [
        "the", "and", "for", "you", "that", "this", "with", "what", "was", "were", "are", "did", "can", "how",
        "about", "from", "have", "has", "had", "but", "not", "our", "your", "my", "me", "it", "is", "of", "to",
        "in", "on", "we", "a", "an", "i", "im", "its", "be", "do", "does", "so", "just", "pls", "please", "plz",
        "one", "some", "any", "there", "here", "they", "them", "then", "than", "will", "would", "could", "should",
        "get", "got", "put", "turn", "make", "let", "lets", "want", "need", "okay", "ok", "yeah", "yes", "no",
        "hey", "teachy", "thing", "things", "stuff", "really", "very", "also", "too", "up", "out", "at", "by",
        "or", "if", "as", "all", "when", "who", "which", "say", "said", "tell", "told", "know",
        // "like" is mostly filler in speech ("like, the one…", "looks like"); meaning match covers preferences.
        "like", "kind", "sort", "maybe", "probably", "actually", "basically",
    ]

    /// Normalised words with a light stem ("songs" → "song", "liked" → "like", "playing" → "play").
    static func words(in text: String) -> [String] {
        BrainText.normalized(text)
            .split(separator: " ")
            .map { stem(String($0)) }
            .filter { $0.count >= 2 && !ignoredWords.contains($0) }
    }

    static func stem(_ word: String) -> String {
        guard word.count > 4 else {
            if word.count == 4, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
            return word
        }
        for suffix in ["ing", "ies", "ed", "es", "s"] where word.hasSuffix(suffix) {
            if suffix == "s" && word.hasSuffix("ss") { return word }
            let base = String(word.dropLast(suffix.count))
            if suffix == "ies" { return base + "y" }
            // "boxes" → "box", but "likes" → "like" (only the "s" goes).
            if suffix == "es" && !["s", "x", "z", "ch", "sh"].contains(where: { base.hasSuffix($0) }) {
                return String(word.dropLast())
            }
            if suffix == "ed" || suffix == "ing" {
                // "liked" → "lik" → "like"; "played" → "play".
                return base.count >= 3 ? (base.hasSuffix("k") || base.hasSuffix("v") || base.hasSuffix("z") ? base + "e" : base) : word
            }
            return base.count >= 3 ? base : word
        }
        return word
    }

    /// BM25 score of every document for the query words. Documents are word lists.
    static func bm25(queryWords: [String], documents: [[String]], k1: Double = 1.2, b: Double = 0.75) -> [Double] {
        guard !documents.isEmpty else { return [] }
        let uniqueQueryWords = Array(Set(queryWords))
        guard !uniqueQueryWords.isEmpty else { return Array(repeating: 0, count: documents.count) }
        let averageLength = max(1, Double(documents.reduce(0) { $0 + $1.count }) / Double(documents.count))
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for word in Set(document) where uniqueQueryWords.contains(word) {
                documentFrequency[word, default: 0] += 1
            }
        }
        let documentCount = Double(documents.count)
        return documents.map { document in
            guard !document.isEmpty else { return 0 }
            var termCounts: [String: Int] = [:]
            for word in document where documentFrequency[word] != nil { termCounts[word, default: 0] += 1 }
            var total = 0.0
            for (word, count) in termCounts {
                let frequency = Double(documentFrequency[word] ?? 0)
                let inverseDocumentFrequency = log(1 + (documentCount - frequency + 0.5) / (frequency + 0.5))
                let termFrequency = Double(count)
                total += inverseDocumentFrequency * (termFrequency * (k1 + 1))
                    / (termFrequency + k1 * (1 - b + b * Double(document.count) / averageLength))
            }
            return total
        }
    }

    /// For each document, the share of the question's distinctive words it contains, each
    /// word weighted by how rare it is. Words found in no document are left out of the
    /// total (they cannot tell candidates apart), so "carti" decides more than "song".
    static func coverage(queryWords: [String], documents: [[String]]) -> [Double] {
        let uniqueQueryWords = Set(queryWords)
        let documentSets = documents.map(Set.init)
        let documentCount = Double(documents.count)
        var weights: [String: Double] = [:]
        for word in uniqueQueryWords {
            let frequency = Double(documentSets.filter { $0.contains(word) }.count)
            guard frequency > 0 else { continue }
            weights[word] = log(1 + (documentCount - frequency + 0.5) / (frequency + 0.5))
        }
        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else { return Array(repeating: 0, count: documents.count) }
        return documentSets.map { document in
            weights.reduce(0) { $0 + (document.contains($1.key) ? $1.value : 0) } / totalWeight
        }
    }

    /// Ranks every candidate for the question, best first.
    ///
    /// - Parameters:
    ///   - meaningSimilarity: cosine similarity between the question and a candidate's text,
    ///     or nil when no embedding is available. Called only for `meaningCandidateIndexes`
    ///     (or every candidate when that is nil), because embeddings cost time.
    ///   - meaningCandidateIndexes: which candidates get a meaning score; pass the facts plus
    ///     the best word matches so a turn never embeds thousands of old messages.
    static func rank(
        question: String,
        candidates: [MemoryRecallCandidate],
        now: Date,
        limit: Int,
        weights: Weights = Weights(),
        meaningCandidateIndexes: Set<Int>? = nil,
        meaningSimilarity: ((String) -> Double?)? = nil
    ) -> [MemoryRecallHit] {
        guard !candidates.isEmpty, limit > 0 else { return [] }
        let queryWords = words(in: question)
        let documents = candidates.map { words(in: $0.text) }
        let wordScores = bm25(queryWords: queryWords, documents: documents)
        let bestWordScore = wordScores.max() ?? 0
        let coverages = coverage(queryWords: queryWords, documents: documents)

        var hits: [MemoryRecallHit] = []
        for (position, candidate) in candidates.enumerated() {
            // How much of the question's distinctive words this covers, nudged by BM25 strength.
            let wordMatch = bestWordScore > 0
                ? coverages[position] * (0.5 + 0.5 * wordScores[position] / bestWordScore)
                : 0
            var meaningMatch = 0.0
            if let meaningSimilarity, meaningCandidateIndexes?.contains(position) ?? true,
               let cosine = meaningSimilarity(candidate.text) {
                meaningMatch = max(0, (cosine - weights.meaningFloor) / (1 - weights.meaningFloor))
                if wordMatch == 0 && cosine < weights.meaningOnlyThreshold { meaningMatch = 0 }
            }
            guard wordMatch > 0 || meaningMatch > 0 else { continue }

            var score = weights.wordMatch * wordMatch + weights.meaningMatch * meaningMatch
            if case .fact = candidate.source { score += weights.factBoost }
            if let date = candidate.date {
                let ageInDays = now.timeIntervalSince(date) / 86_400
                if ageInDays <= 7 {
                    score += weights.recencyBoost
                } else if ageInDays < 30 {
                    score += weights.recencyBoost * (30 - ageInDays) / 23
                }
            }
            guard score >= weights.minimumScore else { continue }
            hits.append(MemoryRecallHit(candidate: candidate, score: score))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : ($0.candidate.date ?? .distantPast) > ($1.candidate.date ?? .distantPast) }

        // The same sentence said in two chats is one memory.
        var seenTexts = Set<String>()
        var unique: [MemoryRecallHit] = []
        for hit in hits {
            let key = BrainText.normalized(hit.candidate.text)
            guard !key.isEmpty, seenTexts.insert(key).inserted else { continue }
            unique.append(hit)
            if unique.count == limit { break }
        }
        return unique
    }

    /// Indexes of the candidates worth a meaning score: every fact and journal line,
    /// plus the `topWordMatches` best word-matching chat messages and the newest chat messages.
    static func meaningCandidateIndexes(
        question: String,
        candidates: [MemoryRecallCandidate],
        topWordMatches: Int = 40,
        newestChatMessages: Int = 60
    ) -> Set<Int> {
        var chosen = Set<Int>()
        var chatPositions: [Int] = []
        for (position, candidate) in candidates.enumerated() {
            if case .chat = candidate.source { chatPositions.append(position) } else { chosen.insert(position) }
        }
        let scores = bm25(queryWords: words(in: question), documents: candidates.map { words(in: $0.text) })
        let bestChat = chatPositions.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] }.prefix(topWordMatches)
        chosen.formUnion(bestChat)
        let newestChat = chatPositions.sorted { (candidates[$0].date ?? .distantPast) > (candidates[$1].date ?? .distantPast) }.prefix(newestChatMessages)
        chosen.formUnion(newestChat)
        return chosen
    }

    // MARK: - Prompt text

    static let promptHeading = "FROM MEMORY (what this person told you before, most relevant to this question first. Use it: if it answers \"which one\", act on it instead of asking again. Facts are their memory files; quotes are from past chats, with dates):"

    /// The prompt section for the hits, at most `budgetCharacters` long. Empty when nothing was recalled.
    static func promptSection(_ hits: [MemoryRecallHit], budgetCharacters: Int = 1_800) -> String {
        guard !hits.isEmpty else { return "" }
        var lines: [String] = []
        var used = promptHeading.count
        for hit in hits {
            let line = "- " + describe(hit.candidate)
            guard used + line.count + 1 <= budgetCharacters else { break }
            lines.append(line)
            used += line.count + 1
        }
        guard !lines.isEmpty else { return "" }
        return ([promptHeading] + lines).joined(separator: "\n")
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func describe(_ candidate: MemoryRecallCandidate) -> String {
        let text = ChatContextWindow.clip(ChatContextWindow.oneLine(candidate.text), to: 260)
        switch candidate.source {
        case .fact(let section):
            return "[\(section)] \(text)"
        case .journal:
            return "[journal] \(text)"
        case .chat(let sessionTitle, let isFromUser):
            let day = candidate.date.map { dayFormatter.string(from: $0) } ?? "earlier"
            return "[\(day), chat \"\(ChatContextWindow.clip(sessionTitle, to: 40))\", \(isFromUser ? "they said" : "you said")] \"\(text)\""
        }
    }
}
