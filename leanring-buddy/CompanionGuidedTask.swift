//
//  CompanionGuidedTask.swift
//  leanring-buddy
//
//  Fully ephemeral, in-memory step-by-step walkthrough that can happen inside
//  normal companion Q&A (push-to-talk outside a formal Course). Reuses the same
//  vision-verification rigor Courses have (`CourseVerifier`, `CourseLearningGoal`)
//  but has no HUD, no tab, no session, and no persistence — it exists only for as
//  long as the model keeps tagging `[GUIDE: short title]` on its replies. See the
//  lifecycle in `CompanionManager.sendCompanionChatResponse`.
//

import Foundation

struct CompanionGuidedTask {
    var title: String
    /// Reuses the existing Course goal shape (same `doneWhen`/`coachAsk` fields) —
    /// populated asynchronously in the background after the task starts, so the turn
    /// that triggers it isn't slowed down by an extra generation round-trip.
    var steps: [CourseLearningGoal] = []
    var currentStepIndex: Int = 0
    var lastActivityAt: Date = Date()

    var currentStep: CourseLearningGoal? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    var isComplete: Bool {
        !steps.isEmpty && currentStepIndex >= steps.count
    }
}

/// Extracts and strips `[GUIDE: short title]` tags from a coach response — the
/// same tag-parsing shape as `CoachRememberTagParser` (`ClickyCourse.swift`), kept
/// as a small parallel parser rather than generalizing the REMEMBER helper, so the
/// working REMEMBER path is never touched by this change.
enum CompanionGuideTagParser {
    /// Returns the last tagged title in `text` (if any — a turn should only ever
    /// contain one), with every `[GUIDE: ...]` occurrence removed from `cleanedText`.
    static func extractTitleAndStrip(from text: String) -> (cleanedText: String, title: String?) {
        guard let regex = try? NSRegularExpression(pattern: "\\[GUIDE:\\s*([^\\]]+)\\]", options: [.caseInsensitive]) else {
            return (text, nil)
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let titles = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2, let contentRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, titles.last)
    }
}
