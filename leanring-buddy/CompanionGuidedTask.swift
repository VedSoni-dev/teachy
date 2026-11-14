//
//  CompanionGuidedTask.swift
//  leanring-buddy
//
//  Fully ephemeral, in-memory step-by-step walkthrough that happens inside a
//  normal voice turn. It has no tab, no session and no persistence — it exists
//  only for as long as the model keeps tagging `[GUIDE: short title]` on its
//  replies. See the lifecycle in `CompanionManager.sendCompanionChatResponse`.
//
//  Also holds the small parsers for the bracket tags a voice reply can carry
//  ([GUIDE:], [DO:], [CLIPBOARD:], [REMEMBER:]). [SHOW:] and [JOB:] go through
//  `VoiceTag` / `SceneDirector`; [POINT:] through `CompanionManager`.
//

import Foundation

/// Whether Teachy walks the person through a step or does it for them.
enum GuidedStepExecutionMode: String, Codable, Equatable {
    /// The person does the work; Teachy guides with voice, pointing, and a screen check.
    case coach
    /// Teachy does this step itself with Mac tools (purely mechanical setup).
    case act
}

/// What one walkthrough step is for and how Teachy can tell it is done.
struct GuidedStepGoal: Equatable, Codable {
    let id: String
    let title: String
    /// What success looks like, in plain words.
    let goal: String
    /// What Teachy should say or ask to move the person through this step.
    let coachAsk: String
    /// How the step looks on screen once it is done. Checked against a screenshot.
    let doneWhen: String?
}

/// A single step in a guided task: the goal plus whether Teachy coaches it or does it.
struct AgenticStep: Equatable {
    let goal: GuidedStepGoal
    var executionMode: GuidedStepExecutionMode
}

struct CompanionGuidedTask {
    var title: String
    /// Steps from the planner. Filled synchronously by `presentGuidedTaskPlan` so the
    /// spoken introduction can reference the real plan.
    var steps: [AgenticStep] = []
    var currentStepIndex: Int = 0
    var lastActivityAt: Date = Date()
    /// Set once, at task creation, when the task's title matches a known
    /// `TeachyRecommendedToolRegistry` entry (e.g. Vapi for phone/voice agents) —
    /// never changed afterward. Grounds both step planning and every later turn in
    /// real knowledge about the tool being used.
    var recommendedTool: TeachyRecommendedTool? = nil
    /// How many times the planner has revised the remaining steps for this task.
    /// Capped at `maximumReflectionRevisionsPerTask` so divergence can't loop the
    /// replanning call indefinitely.
    var reflectionRevisionCount: Int = 0

    /// After this many replans, divergence falls through to guiding the current step as-is.
    static let maximumReflectionRevisionsPerTask = 3

    var currentStep: AgenticStep? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    var isComplete: Bool {
        !steps.isEmpty && currentStepIndex >= steps.count
    }
}

/// Every `[NAME: …]` payload in `text`, in order, plus the text with all of them removed
/// and leftover double spaces collapsed. Shared by the tag parsers below.
private func extractAllTagPayloadsAndStrip(
    tagPattern: String,
    from text: String
) -> (cleanedText: String, payloads: [String]) {
    guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else {
        return (text, [])
    }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)
    let payloads = matches.compactMap { match -> String? in
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
    return (cleaned, payloads)
}

/// Extracts and strips `[GUIDE: short title]` tags from a reply.
enum CompanionGuideTagParser {
    /// Returns the last tagged title in `text` (a turn should only ever contain one),
    /// with every `[GUIDE: ...]` occurrence removed from `cleanedText`.
    static func extractTitleAndStrip(from text: String) -> (cleanedText: String, title: String?) {
        let (cleanedText, titles) = extractAllTagPayloadsAndStrip(tagPattern: "\\[GUIDE:\\s*([^\\]]+)\\]", from: text)
        return (cleanedText, titles.last)
    }
}

/// Extracts and strips `[DO: precise native action]` tags from a reply.
/// The `[DO:]` tag triggers the fast one-shot native-action path: the model emits the
/// spoken heads-up and the action description together, so the tag is stripped before
/// speech but the action string is kept for execution.
enum CompanionActionTagParser {
    /// Multiple tags in one reply become a single numbered sequence ("1. close the
    /// active tab\n2. open Figma") so compound commands ("close my tabs and open
    /// Figma") execute as one ordered action run — the tool loop handles each step.
    static func extractActionAndStrip(from text: String) -> (cleanedText: String, action: String?) {
        let (cleanedText, actions) = extractAllTagPayloadsAndStrip(tagPattern: "\\[DO:\\s*([^\\]]+)\\]", from: text)
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
        return (cleanedText, combinedAction)
    }
}

/// Extracts and strips `[CLIPBOARD: full text]` tags — the prompt-concierge lane.
/// The model crafts a strong, ready-to-paste prompt for whatever AI tool the person
/// wants to use, and hands it over via the clipboard instead of reading it aloud.
///
/// Limitation (documented to the model in the system prompt): the tag ends at the
/// first `]` after the content, so clipboard text must avoid `]` characters. A
/// non-greedy multiline match keeps multi-paragraph prompts intact otherwise.
enum CompanionClipboardTagParser {
    /// Returns the last tagged clipboard payload in `text` (a turn should only carry one).
    static func extractClipboardTextAndStrip(from text: String) -> (cleanedText: String, clipboardText: String?) {
        let (cleanedText, payloads) = extractAllTagPayloadsAndStrip(tagPattern: "\\[CLIPBOARD:\\s*([\\s\\S]+?)\\]", from: text)
        return (cleanedText, payloads.last)
    }
}

/// Extracts and strips `[REMEMBER: fact]` tags. The facts go to the Brain
/// (`BrainStore.shared.remember`) and are never spoken or shown.
enum CompanionRememberTagParser {
    /// Returns every tagged fact in order (someone can share two facts in one turn).
    static func extractFactsAndStrip(from text: String) -> (cleanedText: String, facts: [String]) {
        let (cleanedText, facts) = extractAllTagPayloadsAndStrip(tagPattern: "\\[REMEMBER:\\s*([^\\]]+)\\]", from: text)
        return (cleanedText, facts)
    }
}
