//
//  VoiceTags.swift
//  leanring-buddy
//
//  Bracket tags the voice model can add to a reply, e.g. [SHOW: a turbofan] or
//  [JOB: find three flights]. One small parser instead of one regex per call site.
//

import Foundation

enum VoiceTag {
    /// Finds the first `[NAME: payload]` in `text`. Returns the text without it and the payload.
    static func extract(_ name: String, from text: String) -> (text: String, payload: String?) {
        let pattern = "\\[" + NSRegularExpression.escapedPattern(for: name) + ":\\s*([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let inner = Range(match.range(at: 1), in: text)
        else { return (text, nil) }
        let payload = text[inner].trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = text
        stripped.removeSubrange(whole)
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), payload.isEmpty ? nil : payload)
    }
}
