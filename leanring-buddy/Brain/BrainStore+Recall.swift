//
//  BrainStore+Recall.swift
//  leanring-buddy
//
//  Gathers everything Teachy could remember for one question (facts, journal,
//  every saved chat) and ranks it with `MemoryRecall`, using Apple's on-device
//  sentence embedding for meaning. Nothing leaves the Mac to do this.
//
//  Never logs memory contents.
//

import Foundation
import NaturalLanguage

extension BrainStore {
    /// The "FROM MEMORY" prompt section for a question. Empty when nothing relevant is remembered.
    /// Safe from any thread; takes a few milliseconds plus the first embedding load.
    func recallPromptSection(forQuestion question: String, limit: Int = 8, budgetCharacters: Int = 1_800) -> String {
        let hits = recall(forQuestion: question, limit: limit)
        return MemoryRecall.promptSection(hits, budgetCharacters: budgetCharacters)
    }

    /// The memories most relevant to the question, best first.
    func recall(forQuestion question: String, limit: Int = 8) -> [MemoryRecallHit] {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return [] }
        let candidates = recallCandidates()
        let meaningIndexes = MemoryRecall.meaningCandidateIndexes(question: trimmedQuestion, candidates: candidates)
        let embedder = MemoryEmbedder.shared
        let questionVector = embedder.vector(for: trimmedQuestion)
        return MemoryRecall.rank(
            question: trimmedQuestion,
            candidates: candidates,
            now: Date(),
            limit: limit,
            meaningCandidateIndexes: meaningIndexes,
            meaningSimilarity: questionVector.map { questionVector in
                { text in embedder.vector(for: text).map { MemoryEmbedder.cosine(questionVector, $0) } }
            }
        )
    }

    /// Facts, journal lines and saved chat messages. The open chat's recent messages are
    /// left out: they are already sent word for word as the conversation.
    private func recallCandidates(maximumSessions: Int = 200, openChatMessagesAlreadySent: Int = 24) -> [MemoryRecallCandidate] {
        var candidates: [MemoryRecallCandidate] = rememberedItems().map {
            MemoryRecallCandidate(text: BrainText.removingDateStamp($0.text), source: .fact(section: $0.section), date: nil)
        }
        for line in sessions.journalText().components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            candidates.append(MemoryRecallCandidate(text: String(trimmed.dropFirst(2)), source: .journal, date: nil))
        }
        let index = sessions.index()
        for session in index.sessionsNewestFirst.prefix(maximumSessions) {
            var messages = sessions.messages(in: session.id)
            if session.id == index.currentSessionID { messages = Array(messages.dropLast(openChatMessagesAlreadySent)) }
            for message in messages where message.text.count >= 8 {
                candidates.append(MemoryRecallCandidate(
                    text: message.text,
                    source: .chat(sessionTitle: session.title, isFromUser: message.role == .user),
                    date: message.date
                ))
            }
        }
        return candidates
    }
}

/// Apple's on-device English sentence embedding, with a bounded cache so a long
/// history is embedded once per launch, not once per question.
nonisolated final class MemoryEmbedder: @unchecked Sendable {
    static let shared = MemoryEmbedder()

    private let lock = NSLock()
    private var embedding: NLEmbedding?
    private var didTryLoading = false
    private var cache: [String: [Double]] = [:]
    private let maximumCachedVectors = 6_000
    /// Long messages are embedded by their opening, which is where the point usually is.
    private let maximumEmbeddedCharacters = 600

    func vector(for text: String) -> [Double]? {
        let key = String(text.prefix(maximumEmbeddedCharacters))
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        if !didTryLoading {
            didTryLoading = true
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        guard let embedding, let vector = embedding.vector(for: key) else { return nil }
        if cache.count >= maximumCachedVectors { cache.removeAll(keepingCapacity: true) }
        cache[key] = vector
        return vector
    }

    static func cosine(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var dot = 0.0, firstLength = 0.0, secondLength = 0.0
        for position in first.indices {
            dot += first[position] * second[position]
            firstLength += first[position] * first[position]
            secondLength += second[position] * second[position]
        }
        guard firstLength > 0, secondLength > 0 else { return 0 }
        return dot / (firstLength.squareRoot() * secondLength.squareRoot())
    }
}
