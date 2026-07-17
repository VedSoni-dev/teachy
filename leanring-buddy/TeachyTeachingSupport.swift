//
//  TeachyTeachingSupport.swift
//  leanring-buddy
//
//  Lesson briefs, Mac capability card for course tutor turns, learner-profile
//  memory tags, and understanding (teach-back) checks.
//

import Foundation

// MARK: - Per-goal teaching brief (authorable JSON)

/// Optional pedagogy packed into a goal so Teachy knows *how* to teach this part —
/// not just the durable outcome.
struct CourseTeachingContext: Codable, Equatable {
    /// Plain-language ideas to cover (one short phrase each).
    var concepts: [String]?
    /// Typical wrong moves / confusion to watch for.
    var commonMistakes: [String]?
    /// Concrete "you'll know it worked when…" examples.
    var successExamples: [String]?
    /// One-line why this goal matters.
    var whyItMatters: String?
    /// Custom teach-back question after they do the goal. If nil, Teachy invents one.
    var teachBackPrompt: String?
    /// When true, skip the understanding beat (rare — default is false / do teach-back).
    var skipTeachBack: Bool?
}

/// How willing Teachy should be to drive the Mac for this goal.
enum CourseToolPolicy: String, Codable, Equatable {
    /// Point and narrate only — never click/type for them.
    case pointOnly
    /// Default: point first; tools only if clearly blocked or they ask.
    case preferPointing
    /// Freely use tools when stuck, then teach what happened.
    case helpWhenStuck
    /// Happy to do-it-for-them when asked (still explain after).
    case canDoForThem

    var coachInstructions: String {
        switch self {
        case .pointOnly:
            return "TOOL POLICY for this goal: POINT only. Do not click, type, or run tools for them — coach them through it."
        case .preferPointing:
            return "TOOL POLICY for this goal: prefer POINTING. Use Mac tools only if they ask \"do it for me\" or are clearly blocked after a hint."
        case .helpWhenStuck:
            return "TOOL POLICY for this goal: if they're stuck, USE TOOLS (open/click/type) then explain what you did in one short sentence and POINT at the result."
        case .canDoForThem:
            return "TOOL POLICY for this goal: if they ask you to do it, cheerfully USE TOOLS, then teach what just happened so they still learn."
        }
    }
}

// MARK: - Durable learner model (per course)

struct CourseLearnerProfile: Codable, Equatable {
    var knows: [String] = []
    var confusedBy: [String] = []
    /// true = lean hints; false = lean do-it-for-me; nil = unknown
    var prefersHintsOverAutomation: Bool?
    var rollingNotes: [String] = []
    /// Detected emotional state from response patterns: "frustrated", "bored", "engaged", "confused", nil
    var detectedMood: String?

    mutating func noteKnows(_ item: String) {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        confusedBy.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        if !knows.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            knows.append(trimmed)
        }
        knows = Array(knows.suffix(12))
    }

    mutating func noteConfusedBy(_ item: String) {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !confusedBy.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            confusedBy.append(trimmed)
        }
        confusedBy = Array(confusedBy.suffix(12))
    }

    mutating func appendRollingNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rollingNotes.append(trimmed)
        rollingNotes = Array(rollingNotes.suffix(16))
    }

    mutating func detectMood(from userResponse: String) {
        let lower = userResponse.lowercased()
        let trimmed = userResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(separator: " ").count

        // Frustrated: very short confused answers, explicit frustration
        if wordCount <= 3 && (lower.contains("idk") || lower.contains("i don't know") || lower.contains("no idea") || lower.contains("confused") || lower.contains("lost")) {
            detectedMood = "frustrated"
        }
        // Bored: very short or dismissive
        else if wordCount <= 2 && (lower == "ok" || lower == "done" || lower == "yes" || lower == "yep" || lower == "sure" || lower == "k") {
            detectedMood = "bored"
        }
        // Engaged: detailed answer or asks a question
        else if wordCount >= 6 || lower.contains("?") {
            detectedMood = "engaged"
        }
        // Confused: long but uncertain
        else if lower.contains("maybe") || lower.contains("i think") || lower.contains("not sure") {
            detectedMood = "confused"
        }
    }

    var promptSection: String {
        var lines: [String] = []
        if !knows.isEmpty {
            lines.append("already knows / skip re-explaining: \(knows.joined(separator: "; "))")
        }
        if !confusedBy.isEmpty {
            lines.append("still shaky on: \(confusedBy.joined(separator: "; "))")
        }
        if let prefersHintsOverAutomation {
            lines.append(
                prefersHintsOverAutomation
                    ? "prefers hints over you driving the Mac"
                    : "comfortable when you do steps for them (still teach after)"
            )
        }
        if !rollingNotes.isEmpty {
            let recent = rollingNotes.suffix(8).enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            lines.append("session notes:\n\(recent)")
        }
        if let mood = detectedMood {
            lines.append("current mood: \(mood) — adjust your tone accordingly")
        }
        guard !lines.isEmpty else { return "" }
        return """

        LEARNER MODEL (durable for this course — respect it):
        \(lines.joined(separator: "\n"))
        """
    }

    var globalPromptSection: String {
        var lines: [String] = []
        if !knows.isEmpty {
            lines.append("already knows from other courses: \(knows.joined(separator: "; "))")
        }
        if !confusedBy.isEmpty {
            lines.append("still shaky on from other courses: \(confusedBy.joined(separator: "; "))")
        }
        guard !lines.isEmpty else { return "" }
        return """

        CROSS-COURSE MEMORY (from previous courses — carry this forward):
        \(lines.joined(separator: "\n"))
        """
    }
}

// MARK: - Memory tags in coach replies (stripped before TTS / HUD)

enum TeachyMemoryTagParser {
    /// Parses and strips `[MEMORY:knows:…]` / `[MEMORY:confused:…]` (case-insensitive).
    static func consumeMemoryTags(from text: String) -> (cleanedText: String, knows: [String], confused: [String]) {
        var knows: [String] = []
        var confused: [String] = []
        var cleaned = text

        let patterns: [(String, (String) -> Void)] = [
            (#"\[MEMORY:knows:([^\]]+)\]"#, { knows.append($0) }),
            (#"\[MEMORY:confused:([^\]]+)\]"#, { confused.append($0) }),
        ]

        for (pattern, collector) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let fullRange = NSRange(cleaned.startIndex..., in: cleaned)
            let matches = regex.matches(in: cleaned, options: [], range: fullRange)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let valueRange = Range(match.range(at: 1), in: cleaned) else { continue }
                collector(String(cleaned[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines))
                if let full = Range(match.range(at: 0), in: cleaned) {
                    cleaned.removeSubrange(full)
                }
            }
        }

        cleaned = cleaned
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, knows, confused)
    }
}

// MARK: - Capability card (merged into every course tutor system prompt)

enum TeachyCourseCapabilityCard {
    /// What Teachy can actually do on the Mac during a lesson — keep in sync with agent tools.
    static let text = """
    YOUR MAC CAPABILITIES (course mode — use when policy allows):
    - see the live screen (screenshot attached every turn; invisible A–T / 1–12 grid for [POINT:…])
    - open_browser_tab: open a URL in their browser
    - bash / read_file / write_file: terminal + files when the goal needs it
    - run_applescript: control native Mac apps
    - ui_action: click, type, keys in the frontmost app (Accessibility) — last resort for "do it for me"
    - capture_screen: fresher look mid-turn if the UI changed
    - authenticated_fetch / list_browser_sessions: logged-in web pages via their browser cookies

    teaching rules for tools:
    - default is coach + POINT so THEY do the move (learning > automation)
    - when you do act: one short [INFO] of what you did, then [TODO]/POINT so they see the result
    - never dump a tool log. never read raw paths like a robot unless they asked
    """
}

// MARK: - Understanding (teach-back) check

struct CourseUnderstandingResult {
    let understood: Bool
    let reason: String
    /// Optional facts to store in learner profile.
    let learnedConcepts: [String]
    let remainingConfusion: [String]
}

enum CourseUnderstandingVerifier {
    @MainActor
    static func assessTeachBack(
        goal: CourseLearningGoal,
        learnerAnswer: String,
        previousAnswers: [String] = [],
        claudeAPI: ClaudeAPI
    ) async throws -> CourseUnderstandingResult {
        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let previousAnswersBlock: String
        if previousAnswers.count > 1 {
            let history = previousAnswers.enumerated()
                .map { "  Turn \($0.offset + 1): \($0.element)" }
                .joined(separator: "\n")
            previousAnswersBlock = "\n\nPrevious answers in this teach-back:\n\(history)"
        } else {
            previousAnswersBlock = ""
        }
        let systemPrompt = """
        you check whether a learner understood a Teachy goal. reply with ONLY one JSON object:
        {"understood":true,"reason":"short","knows":["optional"],"confused":["optional"]}
        be kind but honest — vague "yeah" with no substance → understood false.
        if they clearly get the main idea in their own words → true even if wording is messy.
        when confusedBy has entries, name the specific concept that wasn't understood.
        """
        let userPrompt = """
        Goal title: \(goal.title)
        Success looks like: \(goal.goal)
        Key concepts: \(concepts)
        Teach-back question context: \(goal.teachingContext?.teachBackPrompt ?? "what did we just do / why did it work?")

        Learner said: \(learnerAnswer)\(previousAnswersBlock)
        """

        let (rawText, _) = try await claudeAPI.analyzeImageStreaming(
            images: [],
            systemPrompt: systemPrompt,
            conversationHistory: [],
            userPrompt: userPrompt,
            onTextChunk: { _ in }
        )

        return parse(from: rawText)
    }

    static func parse(from rawText: String) -> CourseUnderstandingResult {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonCandidate: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            jsonCandidate = String(trimmed[start...end])
        } else {
            jsonCandidate = trimmed
        }

        guard let data = jsonCandidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let lowered = trimmed.lowercased()
            let softYes = lowered.contains("\"understood\": true")
                || lowered.hasPrefix("yes")
            return CourseUnderstandingResult(
                understood: softYes,
                reason: "unparsed teach-back",
                learnedConcepts: [],
                remainingConfusion: softYes ? [] : ["couldn't confirm understanding"]
            )
        }

        let understood = (object["understood"] as? Bool)
            ?? ((object["understood"] as? NSNumber)?.boolValue)
            ?? false
        let reason = (object["reason"] as? String) ?? (understood ? "ok" : "needs another pass")
        let knows = (object["knows"] as? [String]) ?? []
        let confused = (object["confused"] as? [String]) ?? []
        return CourseUnderstandingResult(
            understood: understood,
            reason: reason,
            learnedConcepts: knows,
            remainingConfusion: confused
        )
    }
}
