//
//  NextSteps.swift
//  leanring-buddy
//
//  After an answer, a row of buttons under the notch with the obvious next steps:
//  "Find a table for six", "Add it to my calendar". The voice model proposes them
//  with [NEXT: short label] tags (up to three). After Teachy typed something for the
//  person ([WRITE:]), two more appear: "Make it shorter" and "Make it warmer", which
//  rewrite the text it just typed, in place.
//
//  Pure rules here; `NextStepChipsPresenter` shows them.
//

import Foundation

struct NextStepChip: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Asks Teachy the label as a new request.
        case askTeachy
        /// Rewrites the text Teachy just typed with this change.
        case rewriteLastWriting(change: String)
    }

    let label: String
    let kind: Kind
    var id: String { label }
}

enum NextStepRules {
    static let maximumModelChips = 3
    static let maximumLabelLength = 42
    /// How long the row stays up when nobody touches it.
    static let secondsBeforeHiding: TimeInterval = 25

    /// The line added to the voice system prompt.
    static let voicePromptRule = """
    - Next steps: after your answer you may add up to three [NEXT: label] tags, each the obvious next thing they might want you to do, phrased as they would ask it, under 6 words ("Find a table for six", "Add it to my calendar", "Show me on a map"). Teachy shows them as buttons; a press asks you that. Only add ones you could really do, never filler, and none when the conversation is clearly over.
    """

    /// Takes every [NEXT: …] tag out of the reply. Returns the reply without them and the
    /// cleaned labels (de-duplicated, capped).
    static func extract(from reply: String) -> (text: String, labels: [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[NEXT:\s*([^\]]+)\]"#, options: [.caseInsensitive]) else {
            return (reply, [])
        }
        let fullRange = NSRange(reply.startIndex..., in: reply)
        var labels: [String] = []
        for match in regex.matches(in: reply, range: fullRange) {
            guard let labelRange = Range(match.range(at: 1), in: reply) else { continue }
            let label = cleanedLabel(String(reply[labelRange]))
            guard !label.isEmpty, !labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { continue }
            labels.append(label)
        }
        let stripped = regex.stringByReplacingMatches(in: reply, range: fullRange, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, Array(labels.prefix(maximumModelChips)))
    }

    /// The chips to show after a reply.
    static func chips(modelLabels: [String], typedTextJustNow: Bool) -> [NextStepChip] {
        var chips: [NextStepChip] = []
        if typedTextJustNow {
            chips.append(NextStepChip(label: "Make it shorter", kind: .rewriteLastWriting(change: "make it shorter")))
            chips.append(NextStepChip(label: "Make it warmer", kind: .rewriteLastWriting(change: "make it warmer and friendlier")))
        }
        for label in modelLabels where !chips.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
            chips.append(NextStepChip(label: label, kind: .askTeachy))
        }
        return chips
    }

    /// The instruction for rewriting text Teachy typed earlier.
    static func rewriteInstruction(originalText: String, change: String) -> String {
        """
        Rewrite the text below: \(change). Keep the meaning, the language and the person's voice, keep any names, \
        dates and numbers exactly, and return only the new text.

        Text:
        \(originalText)
        """
    }

    /// Where the text Teachy typed sits in the field now: its last occurrence, as an NSRange
    /// (UTF-16, as Accessibility counts). nil when the person already changed it.
    static func rangeOfLastWriting(_ writtenText: String, in fieldValue: String) -> NSRange? {
        guard !writtenText.isEmpty else { return nil }
        let range = (fieldValue as NSString).range(of: writtenText, options: .backwards)
        return range.location == NSNotFound ? nil : range
    }

    private static func cleanedLabel(_ raw: String) -> String {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”")))
        if label.count > maximumLabelLength {
            label = String(label.prefix(maximumLabelLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return label
    }
}
