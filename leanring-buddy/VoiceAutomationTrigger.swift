//
//  VoiceAutomationTrigger.swift
//  leanring-buddy
//
//  Detects when the user asks Teachy to DO something on their Mac — build apps,
//  open tabs, run scripts, automate tasks — without requiring the "agent," prefix.
//

import Foundation

enum VoiceAutomationTrigger {
    /// Example phrase shown in the notch panel.
    static let exampleInvocationPhrase = "build me a basic Spotify Mac app player"

    /// Question-style openers that should stay in companion chat, not dispatch an agent.
    private static let questionOnlyPatterns: [String] = [
        #"^how (?:do|can|would|to|should)\b"#,
        #"^what (?:is|are|was|were)\b"#,
        #"^why (?:is|are|do|does|did|would)\b"#,
        #"^when (?:do|does|did|should|is)\b"#,
        #"^where (?:is|are|can|do)\b"#,
        #"^who (?:is|are|was|were)\b"#,
        #"^(?:explain|describe|define)\b"#,
        #"^tell me (?:about|how)\b"#,
        #"^can you explain\b"#,
        #"^could you explain\b"#,
        #"^what's\b"#,
        #"^whats\b"#,
    ]

    /// Imperative patterns that route to the agent with full Mac tool access.
    private static let automationPatterns: [String] = [
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?build(?:\s+me)?\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?create(?:\s+me)?\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?make(?:\s+me)?\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?write(?:\s+me)?\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?scaffold\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?generate\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?automate\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?set up\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?install\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?fix\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?deploy\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?download\s+(?:and\s+)?(?:install|set up)?\s*"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?open(?:\s+a)?(?:\s+new)?\s+tab\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?open\s+(?:the\s+)?(?:url|website|page|link)\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?navigate to\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?go to\s+(?:https?://|www\.)"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?run (?:a )?(?:script|command)\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?do (?:this|that) for me\b"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?code\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:can you\s+)?implement\s+"#,
    ]

    /// Returns the automation task prompt when the user asks Teachy to act on their Mac.
    static func parseAutomationTask(from transcript: String) -> String? {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return nil }

        let lowercasedTranscript = normalizedTranscript.lowercased()

        for questionPattern in questionOnlyPatterns {
            guard let regex = try? NSRegularExpression(pattern: questionPattern, options: [.caseInsensitive]) else {
                continue
            }
            let fullRange = NSRange(lowercasedTranscript.startIndex..., in: lowercasedTranscript)
            if regex.firstMatch(in: lowercasedTranscript, range: fullRange) != nil {
                return nil
            }
        }

        for automationPattern in automationPatterns {
            guard let regex = try? NSRegularExpression(pattern: automationPattern, options: [.caseInsensitive]) else {
                continue
            }
            let fullRange = NSRange(normalizedTranscript.startIndex..., in: normalizedTranscript)
            if regex.firstMatch(in: normalizedTranscript, range: fullRange) != nil {
                return normalizedTranscript
            }
        }

        return nil
    }
}
