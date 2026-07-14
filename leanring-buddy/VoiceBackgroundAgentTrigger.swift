//
//  VoiceBackgroundAgentTrigger.swift
//  leanring-buddy
//
//  Detects when the user starts a push-to-talk sentence with a background-agent
//  trigger phrase (e.g. "agent, research my competitors") and returns the task
//  prompt with the trigger stripped.
//

import Foundation

enum VoiceBackgroundAgentTrigger {
    /// Spoken prefix patterns that route voice input to the background agent.
    /// Order matters — longer / more specific patterns are checked first.
    private static let triggerPrefixPatterns: [String] = [
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?(?:please\s+)?(?:start|run)\s+(?:a\s+)?background\s+agent(?:\s+task)?[,:]?\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?background\s+agent[,:]?\s+"#,
        #"^(?:hey\s+)?(?:(?:clicky|teachy)\s+)?agent[,:]?\s+"#,
    ]

    /// Example phrase shown in the notch panel so users know how to invoke the agent.
    static let exampleInvocationPhrase = "agent, research my competitors in private equity"

    /// Returns the background-agent task prompt when `transcript` starts with a trigger phrase.
    static func parseBackgroundAgentTask(from transcript: String) -> String? {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return nil }

        for triggerPrefixPattern in triggerPrefixPatterns {
            guard let regex = try? NSRegularExpression(
                pattern: triggerPrefixPattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let fullTranscriptRange = NSRange(normalizedTranscript.startIndex..., in: normalizedTranscript)
            guard let match = regex.firstMatch(in: normalizedTranscript, range: fullTranscriptRange),
                  let matchedPrefixRange = Range(match.range, in: normalizedTranscript) else {
                continue
            }

            let taskPrompt = String(normalizedTranscript[matchedPrefixRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !taskPrompt.isEmpty else { return nil }

            return taskPrompt
        }

        return nil
    }
}
