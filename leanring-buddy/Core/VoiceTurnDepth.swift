//
//  VoiceTurnDepth.swift
//  leanring-buddy
//
//  How much thought one voice turn deserves. "Open Spotify" or "what time is
//  it in Tokyo" should come back instantly; "explain how this works", "teach
//  me", "why is this failing" should get a real answer: more reasoning, a
//  longer reply, marks on the screen and a link worth opening. Pure, so it is
//  unit-tested (scripts/tests/run_voice_depth_tests.sh).
//

import Foundation

enum VoiceTurnDepth: Equatable {
    /// A command, a quick fact, a "where is…": answer fast.
    case quick
    /// Teach, explain, debug, compare, plan: think, then go above and beyond.
    case deep

    /// Reasoning effort sent with the voice request. nil = the job's default (minimal).
    var reasoningEffort: String? {
        switch self {
        case .quick: return nil
        case .deep: return "low"
        }
    }

    /// Room for the reply. A teaching answer with marks and a link needs more than a one-liner.
    var maxTokens: Int {
        switch self {
        case .quick: return 1024
        case .deep: return 2048
        }
    }

    private static let deepPhrases: [String] = [
        "explain", "teach me", "teach", "help me understand", "walk me through why", "how does", "how do", "how is",
        "why does", "why is", "why do", "why are", "why did", "why would", "what does this mean", "what is this", "what's this",
        "what am i looking at", "what's going on", "what is going on", "break down", "break it down", "learn", "understand",
        "difference between", "compare", "vs", "versus", "pros and cons", "should i", "which is better", "how should i",
        "debug", "fix this", "why isn't", "why won't", "why doesn't", "not working", "error", "broken", "stuck",
        "summarize", "summarise", "review", "critique", "feedback on", "improve", "make this better", "plan", "strategy",
        "how would you", "what would you", "brainstorm", "ideas for", "go deeper", "in depth", "in detail", "tell me more", "eli5"
    ]

    private static let quickPrefixes: [String] = [
        "open ", "close ", "quit ", "switch to ", "go to ", "play ", "pause", "stop", "mute", "next", "skip", "hide ",
        "where is ", "where's ", "find the ", "click ", "what time", "set a timer", "remind me", "copy ", "paste "
    ]

    static func classify(_ transcript: String) -> VoiceTurnDepth {
        let lower = " " + transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "
        let trimmed = lower.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(whereSeparator: { $0 == " " }).count

        for phrase in deepPhrases {
            let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![a-z])"
            if lower.range(of: pattern, options: .regularExpression) != nil { return .deep }
        }
        if quickPrefixes.contains(where: { trimmed.hasPrefix($0.trimmingCharacters(in: .whitespaces)) }) { return .quick }
        // A long, open question is usually worth thinking about.
        if words >= 14 && trimmed.contains("?") { return .deep }
        if words >= 22 { return .deep }
        return .quick
    }
}

/// [OPEN: https://…] — links the voice model wants opened for them (a doc page, a video,
/// a search). Only http(s); at most two per reply so a reply can never spray tabs.
enum VoiceOpenLinks {
    static let maximumLinksPerReply = 2

    static func extract(from text: String) -> (text: String, urls: [URL]) {
        var remaining = text
        var urls: [URL] = []
        while true {
            let (stripped, payload) = VoiceTag.extract("OPEN", from: remaining)
            guard let payload else { break }
            remaining = stripped
            if urls.count < maximumLinksPerReply, let url = safeURL(payload), !urls.contains(url) {
                urls.append(url)
            }
        }
        return (remaining, urls)
    }

    /// The payload as a web URL, or nil. Bare "example.com/x" gets https.
    static func safeURL(_ payload: String) -> URL? {
        var candidate = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.contains(" ") { return nil }
        if !candidate.lowercased().hasPrefix("http://") && !candidate.lowercased().hasPrefix("https://") {
            guard candidate.contains("."), !candidate.contains(":") else { return nil }
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
