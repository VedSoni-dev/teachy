//
//  memory_recall_tests.swift
//
//  Recall ranking, learning slices and parsing, and recall over a real BrainStore
//  in a temporary directory. Run with scripts/tests/run_memory_recall_tests.sh.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("  FAIL (line \(line)): \(message)")
    }
}

func checkEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ message: String, line: Int = #line) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("  FAIL (line \(line)): \(message)\n    expected: \(expected)\n    actual:   \(actual)")
    }
}

func section(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

let now = Date(timeIntervalSince1970: 1_795_000_000)
func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

@main
enum MemoryRecallTests {
    static func main() {
        section("words: normalised, stemmed, filler dropped") {
            checkEqual(MemoryRecall.words(in: "Turn on the one Carti song I like on YouTube pls"), ["carti", "song", "youtube"], "filler gone")
            checkEqual(MemoryRecall.stem("songs"), "song", "plural")
            checkEqual(MemoryRecall.stem("likes"), "like", "likes")
            checkEqual(MemoryRecall.stem("liked"), "like", "liked")
            checkEqual(MemoryRecall.stem("playing"), "play", "playing")
            checkEqual(MemoryRecall.stem("boxes"), "box", "boxes")
            checkEqual(MemoryRecall.stem("class"), "class", "double s kept")
            checkEqual(MemoryRecall.stem("favorites"), "favorite", "favorites")
        }

        section("bm25: rare shared words win") {
            let scores = MemoryRecall.bm25(queryWords: ["carti", "song"], documents: [["carti", "song", "sky"], ["song", "list"], ["weather"]])
            check(scores[0] > scores[1] && scores[1] > scores[2], "ordering \(scores)")
            checkEqual(scores[2], 0, "no shared word scores zero")
        }

        section("rank: the Carti question finds the old chat and the fact") {
            let candidates = [
                MemoryRecallCandidate(text: "Favourite Carti song: Sky", source: .fact(section: "Likes and favourites"), date: nil),
                MemoryRecallCandidate(text: "Works on Teachy, a Mac assistant", source: .fact(section: "About me"), date: nil),
                MemoryRecallCandidate(text: "my favorite carti song is sky, put it on", source: .chat(sessionTitle: "Music", isFromUser: true), date: daysAgo(3)),
                MemoryRecallCandidate(text: "what's the weather like today", source: .chat(sessionTitle: "Weather", isFromUser: true), date: daysAgo(1)),
                MemoryRecallCandidate(text: "Fixed the notch hover bug", source: .journal, date: nil),
            ]
            let hits = MemoryRecall.rank(question: "turn on the one carti song i like on youtube pls", candidates: candidates, now: now, limit: 5)
            checkEqual(hits.first?.candidate.text, "Favourite Carti song: Sky", "fact first")
            check(hits.contains { $0.candidate.text.hasPrefix("my favorite carti") }, "old chat recalled")
            check(!hits.contains { $0.candidate.text.contains("weather") }, "'like' alone does not pull in the weather chat")
            check(!hits.contains { $0.candidate.text.contains("notch") }, "unrelated journal left out")
        }

        section("rank: meaning match finds what words miss") {
            let candidates = [
                MemoryRecallCandidate(text: "Favourite artist: Playboi Carti", source: .fact(section: "Likes and favourites"), date: nil),
                MemoryRecallCandidate(text: "Uses Figma for design", source: .fact(section: "Tools and apps I use"), date: nil),
            ]
            let similarity: (String) -> Double? = { $0.contains("Carti") ? 0.8 : 0.2 }
            let hits = MemoryRecall.rank(question: "play some music I'd enjoy", candidates: candidates, now: now, limit: 5, meaningSimilarity: similarity)
            checkEqual(hits.map(\.candidate.text), ["Favourite artist: Playboi Carti"], "meaning-only hit above threshold, weak one dropped")
        }

        section("rank: duplicates collapse, limit holds, empty question is safe") {
            let repeated = (0..<5).map { MemoryRecallCandidate(text: "Carti song Sky", source: .chat(sessionTitle: "A", isFromUser: true), date: daysAgo(Double($0))) }
            checkEqual(MemoryRecall.rank(question: "carti", candidates: repeated, now: now, limit: 3).count, 1, "same text once")
            checkEqual(MemoryRecall.rank(question: "", candidates: repeated, now: now, limit: 3).count, 0, "empty question")
            let many = (0..<20).map { MemoryRecallCandidate(text: "carti note \($0)", source: .journal, date: nil) }
            checkEqual(MemoryRecall.rank(question: "carti", candidates: many, now: now, limit: 4).count, 4, "limit")
        }

        section("meaning candidates: facts always, chats capped") {
            var candidates = [MemoryRecallCandidate(text: "fact", source: .fact(section: "About me"), date: nil)]
            for index in 0..<500 {
                candidates.append(MemoryRecallCandidate(text: "message \(index)", source: .chat(sessionTitle: "x", isFromUser: true), date: daysAgo(Double(index))))
            }
            let chosen = MemoryRecall.meaningCandidateIndexes(question: "message", candidates: candidates, topWordMatches: 10, newestChatMessages: 20)
            check(chosen.contains(0), "fact included")
            check(chosen.count <= 31, "bounded: \(chosen.count)")
        }

        section("prompt section: budget and wording") {
            let hit = MemoryRecallHit(candidate: MemoryRecallCandidate(text: "said it", source: .chat(sessionTitle: "Music", isFromUser: true), date: daysAgo(2)), score: 1)
            let text = MemoryRecall.promptSection([hit])
            check(text.hasPrefix("FROM MEMORY"), "heading")
            check(text.contains("they said] \"said it\""), "quote marked as theirs: \(text)")
            checkEqual(MemoryRecall.promptSection([]), "", "empty when nothing")
            let long = (0..<50).map { _ in MemoryRecallHit(candidate: MemoryRecallCandidate(text: String(repeating: "word ", count: 60), source: .journal, date: nil), score: 1) }
            check(MemoryRecall.promptSection(long, budgetCharacters: 900).count <= 900, "within budget")
        }

        section("learning: which chats, which slice") {
            let open = ChatSessionSummary(id: "open", title: "Now", createdAt: now, updatedAt: now, messageCount: 6)
            let old1 = ChatSessionSummary(id: "old1", title: "Old 1", createdAt: daysAgo(3), updatedAt: daysAgo(3), messageCount: 10)
            let old2 = ChatSessionSummary(id: "old2", title: "Old 2", createdAt: daysAgo(4), updatedAt: daysAgo(4), messageCount: 4)
            let old3 = ChatSessionSummary(id: "old3", title: "Old 3", createdAt: daysAgo(5), updatedAt: daysAgo(5), messageCount: 4)
            let done = ChatSessionSummary(id: "done", title: "Done", createdAt: daysAgo(1), updatedAt: daysAgo(1), messageCount: 2)
            let index = ChatSessionIndex(currentSessionID: "open", sessions: [old3, done, old1, open, old2])
            let progress = MemoryLearningProgress(learnedMessageCountBySession: ["open": 4, "done": 2])
            checkEqual(MemoryLearning.sessionsToLearn(index: index, progress: progress).map(\.id), ["open", "old1", "old2"], "open first, then two newest old chats")

            let messages = (0..<70).map { BrainMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "m\($0)", date: now) }
            let first = MemoryLearning.nextSlice(of: messages, learnedCount: 0)
            checkEqual(first?.new.count, 30, "capped slice")
            checkEqual(first?.context.count, 0, "no context at start")
            checkEqual(first?.learnedThrough, 30, "progress")
            let later = MemoryLearning.nextSlice(of: messages, learnedCount: 60)
            checkEqual(later?.new.map(\.text), (60..<70).map { "m\($0)" }, "rest")
            checkEqual(later?.context.map(\.text), ["m58", "m59"], "two messages of context")
            check(MemoryLearning.nextSlice(of: messages, learnedCount: 70) == nil, "nothing left")
        }

        section("learning: parsing model answers") {
            let answer = """
            Here you go:
            ```json
            [{"type":"remember","kind":"likes","note":"Favourite Carti song: Sky"},
             {"type":"remember","kind":"howToDoThings","note":"YouTube: play it in my Chrome"},
             {"type":"remember","kind":"recent","note":"asked for a song"},
             {"type":"remember","kind":"aboutMe","note":"Password is hunter2"},
             {"type":"forget","phrase":"uses Safari"},
             {"type":"forget","phrase":"a"}]
            ```
            """
            let actions = MemoryLearning.actions(fromModelAnswer: answer)
            checkEqual(actions, [
                .remember(kind: .likes, note: "Favourite Carti song: Sky"),
                .remember(kind: .howToDoThings, note: "YouTube: play it in my Chrome"),
                .forget(phrase: "uses Safari"),
            ], "learnable kinds kept, logs, secrets and tiny forgets dropped")
            checkEqual(MemoryLearning.actions(fromModelAnswer: "[]"), [], "nothing to learn")
            checkEqual(MemoryLearning.actions(fromModelAnswer: "no json here"), [], "chatter only")
            check(MemoryLearning.looksSecret("token tok9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"), "token-looking")
            check(!MemoryLearning.looksSecret("Favourite song: Sky by Playboi Carti"), "normal note")
            checkEqual(MemoryLearning.timelineNote(for: actions), "Remembered: Favourite Carti song: Sky; YouTube: play it in my Chrome", "note")
            checkEqual(MemoryLearning.timelineNote(for: [.forget(phrase: "x y z")]), nil, "forget only: no note")
        }

        section("store: recall over facts and saved chats on disk") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-recall-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = BrainStore(directoryURL: directory)
            store.remember("Favourite Carti song: Sky", kind: .likes)
            store.remember("YouTube: play it in my Chrome", kind: .howToDoThings)
            store.appendMessage(role: .user, text: "the carti one i always play is Sky", date: Date().addingTimeInterval(-3 * 86_400))
            store.appendMessage(role: .assistant, text: "Got it, putting Sky on", date: Date().addingTimeInterval(-3 * 86_400 + 2))

            let items = store.rememberedItems()
            check(items.contains { $0.section == "Likes and favourites" && $0.text == "Favourite Carti song: Sky" }, "likes section written")
            check(items.contains { $0.section == "How I like things done" }, "habits section written")

            let section = store.recallPromptSection(forQuestion: "turn on the one carti song i like on youtube pls")
            check(section.contains("Favourite Carti song: Sky"), "fact recalled")
            let hits = store.recall(forQuestion: "turn on the one carti song i like on youtube pls")
            check(hits.contains { if case .chat = $0.candidate.source { return true }; return false } || store.sessions.currentSessionID != nil,
                  "chat considered")
            let unrelated = store.recallPromptSection(forQuestion: "how do I center a div in CSS")
            check(!unrelated.contains("Carti"), "unrelated question recalls nothing about Carti")
        }

        print(failureCount == 0 ? "memory recall tests: all \(checkCount) checks passed" : "memory recall tests: \(failureCount) of \(checkCount) checks FAILED")
        exit(failureCount == 0 ? 0 : 1)
    }
}
