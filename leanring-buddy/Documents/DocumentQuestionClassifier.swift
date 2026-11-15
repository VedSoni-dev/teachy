//
//  DocumentQuestionClassifier.swift
//  leanring-buddy
//
//  Decides, from the words of a question alone, whether the person is asking
//  about the whole document, page, PDF or article in front of them, so Teachy
//  should read all of it and not just the visible screenshot.
//
//  Conservative on purpose: reading the front document costs up to a couple of
//  seconds, so the answer is "yes" only when the question both points at a
//  document ("this PDF", "the article", "this page") and asks something that
//  needs its text (summarise, what does it say, where does it mention…).
//  "Save this document" or "where is the button on this page" stay "no".
//

import Foundation

nonisolated enum DocumentQuestionClassifier {

    /// Things a person calls the document in front of them.
    private static let documentNouns = [
        "document", "doc", "pdf", "page", "webpage", "web page", "site", "website", "article", "paper", "essay",
        "post", "blog post", "report", "contract", "agreement", "chapter", "book", "file", "text", "story",
        "manual", "readme", "spec", "proposal", "letter", "thread", "transcript", "slides", "deck", "presentation",
        "spreadsheet", "sheet", "email", "memo", "resume", "cv", "terms", "policy", "lease", "draft"
    ]

    /// Words that point at the thing in front of the person.
    private static let pointers = [
        "this", "that", "these", "the", "the current", "the open", "this whole", "the whole", "the entire", "this entire",
        "my", "the full", "this full"
    ]

    /// Phrases that need the document's text, not just a look at the screen.
    private static let readingIntents = [
        "summarize", "summarise", "summary", "sum up", "tl;dr", "tldr", "recap", "key points", "main points",
        "takeaways", "take aways", "takeaway", "gist", "overview of", "outline",
        "say about", "says about", "say anything", "mention", "talk about", "talks about",
        "according to", "based on", "explain", "walk me through",
        "main argument", "main idea", "conclusion", "conclude", "argue", "argues",
        "where does", "which page", "what page", "which section", "how many pages", "how long is",
        "read", "review", "proofread", "critique", "feedback on", "translate", "rewrite",
        "anything about", "is there anything", "who wrote", "who is the author", "list the", "list all",
        "extract", "pull out", "quiz me", "help me understand", "break down",
        "is about", "it about", "about?"
    ]

    /// Asking for the whole thing is itself a reason to read all of it.
    private static let wholeMarkers = [
        "whole", "entire", "rest of", "all of", "everything in", "everything on", "beginning to end"
    ]

    /// Commands that act on a document without needing its text.
    private static let actionVerbs = [
        "open", "close", "save", "print", "delete", "rename", "move", "share", "send", "export", "scroll", "click",
        "create", "make", "start", "download", "upload", "bookmark", "refresh", "reload", "duplicate", "attach",
        "zoom", "resize", "minimize", "minimise", "go to", "switch to", "point", "show me where", "where is", "where's",
        "how do i"
    ]

    /// Reading requests strong enough to win over a leading command ("open this PDF and summarise it").
    private static let strongIntents = [
        "summarize", "summarise", "summary", "explain", "tl;dr", "tldr", "key points", "takeaways", "say about", "says about"
    ]

    /// Words that, right after the noun, mean a control and not the document ("the file menu").
    private static let controlWords = [
        "menu", "button", "bar", "toolbar", "icon", "setup", "settings", "number", "numbers", "break", "layout", "size",
        "margin", "margins", "format", "picker", "name", "extension", "type", "path", "url", "link", "title", "zoom"
    ]

    /// Requests that mean "the thing in front of me" with no noun at all.
    private static let bareRequests = [
        "summarize this", "summarise this", "summarize it", "summarise it", "summarize that", "summarise that",
        "tl;dr", "tldr", "give me a summary", "give me the summary", "sum this up", "sum it up",
        "what are the key points", "what are the main points", "what are the takeaways", "give me the gist"
    ]

    static func refersToCurrentDocument(_ question: String) -> Bool {
        let text = normalized(question)
        guard text.count >= 4, text.count <= 400 else { return false }

        if bareRequests.contains(where: { containsPhrase(text, $0) }) { return true }

        guard let nounPhrase = documentPhrase(in: text) else { return false }
        let hasWholeMarker = wholeMarkers.contains { containsPhrase(text, $0) }
        let hasReadingIntent = readingIntents.contains { containsPhrase(text, $0) }
            || text.range(of: #"\bwhat (does|do|did) .*\b(say|mean|cover|claim|recommend|propose|state|conclude|suggest|argue)\b"#, options: .regularExpression) != nil
        guard hasReadingIntent || hasWholeMarker else { return false }

        // "Open this PDF", "save the document", "scroll down this page" act on it; they don't read it.
        let startsWithCommand = actionVerbs.contains { verb in
            ["", "can you ", "could you ", "please ", "hey ", "now "].contains { text.hasPrefix($0 + verb + " ") }
        }
        if startsWithCommand, !strongIntents.contains(where: { containsPhrase(text, $0) }) { return false }

        // "The file menu", "the page number": the noun names a control, not the document.
        if controlWords.contains(where: { containsPhrase(text, nounPhrase + " " + $0) }) { return false }
        return true
    }

    /// The first "this PDF" / "the article" style phrase in the text, if any.
    private static func documentPhrase(in text: String) -> String? {
        for pointer in pointers {
            for noun in documentNouns {
                let phrase = pointer + " " + noun
                if containsPhrase(text, phrase) { return phrase }
            }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `phrase` appears in `text` on word boundaries.
    private static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex, let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let startsClean = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let phraseEndsInWord = phrase.last.map(isWordCharacter) ?? false
            let endsClean = !phraseEndsInWord || range.upperBound == text.endIndex
                || !isWordCharacter(text[range.upperBound])
            if startsClean && endsClean { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
