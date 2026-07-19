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

/// Whether Teachy coaches the user through a step or acts on it directly.
/// In Layer 1, only `.coach` is behaviorally active — `.act` is recorded from the
/// reasoning planner's output but has no effect until Layer 2 wires the tool loop.
enum GuidedStepExecutionMode: String, Codable, Equatable {
    /// User does the work; Teachy guides with voice, pointing, and verification.
    case coach
    /// Teachy should execute this step itself via Mac tools (mechanical/tedious setup).
    /// RECORDED in Layer 1 but not acted on — reserved for Layer 2.
    case act
}

/// A single step in an agentic guided task, wrapping the existing `CourseLearningGoal`
/// shape with an execution-mode tag from the reasoning planner.
struct AgenticStep: Equatable {
    /// The goal content (id, title, goal, coachAsk, doneWhen) — reuses the existing
    /// Course goal struct so verification and coaching logic are unchanged.
    let goal: CourseLearningGoal
    /// How this step should be executed. Layer 1 always treats both modes as `.coach`.
    var executionMode: GuidedStepExecutionMode
}

struct CompanionGuidedTask {
    var title: String
    /// Agentic steps from the reasoning planner — each wraps a `CourseLearningGoal` plus
    /// an execution-mode tag. Populated synchronously by `presentGuidedTaskPlan` so the
    /// spoken introduction can reference the real plan.
    var steps: [AgenticStep] = []
    var currentStepIndex: Int = 0
    var lastActivityAt: Date = Date()
    /// Set once, at task creation, when the task's title matches a known
    /// `TeachyRecommendedToolRegistry` entry (e.g. Vapi for phone/voice agents) —
    /// never changed afterward. Grounds both initial step generation and ongoing
    /// per-turn coaching in real knowledge about the tool being used.
    var recommendedTool: TeachyRecommendedTool? = nil
    /// How many times the reasoning model has revised the remaining steps for this task.
    /// Caps at `CompanionGuidedTask.maximumReflectionRevisionsPerTask` so divergence
    /// can't loop the reflection call indefinitely.
    var reflectionRevisionCount: Int = 0

    /// Maximum number of reasoning-model reflection/replanning calls allowed per task.
    /// After this cap, divergence falls through to coaching the current step as-is.
    static let maximumReflectionRevisionsPerTask = 3

    var currentStep: AgenticStep? {
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

/// Extracts and strips `[DO: precise native action]` tags from a coach response.
/// Exact mirror of `CompanionGuideTagParser` — same shape, different tag name.
/// The `[DO:]` tag triggers the fast one-shot native-action path in Phase L:
/// the model emits the spoken heads-up and the action description together, so
/// the tag is stripped before TTS but the action string is kept for execution.
enum CompanionActionTagParser {
    /// Returns the tagged action(s) in `text` (if any), with every `[DO: ...]`
    /// occurrence removed from `cleanedText`. Whitespace is collapsed after removal
    /// so the spoken text flows naturally without gaps.
    ///
    /// Multiple tags in one reply become a single numbered sequence ("1. close the
    /// active tab\n2. open Figma") so compound commands ("close my tabs and open
    /// Figma") execute as one ordered action run — the tool loop handles each step.
    static func extractActionAndStrip(from text: String) -> (cleanedText: String, action: String?) {
        guard let regex = try? NSRegularExpression(pattern: "\\[DO:\\s*([^\\]]+)\\]", options: [.caseInsensitive]) else {
            return (text, nil)
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let actions = matches.compactMap { match -> String? in
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

        let combinedAction: String?
        switch actions.count {
        case 0:
            combinedAction = nil
        case 1:
            combinedAction = actions[0]
        default:
            combinedAction = actions.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }
        return (cleaned, combinedAction)
    }
}
