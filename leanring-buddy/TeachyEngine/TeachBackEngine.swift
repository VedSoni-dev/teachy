//
//  TeachBackEngine.swift
//  leanring-buddy
//
//  Enhanced teach-back with protégé effect. Goes beyond "explain it to me"
//  by having the learner teach someone else, generating teaching demos,
//  and scoring teaching quality. The deeper you teach, the deeper you learn.
//

import Foundation

// MARK: - Teach-back depth

enum TeachBackDepth: String, Codable, CaseIterable {
    case quickCheck
    case fullExplanation
    case teachSomeoneElse
    case teachWithFollowUp

    var displayName: String {
        switch self {
        case .quickCheck: return "Quick Check"
        case .fullExplanation: return "Full Explanation"
        case .teachSomeoneElse: return "Teach Someone Else"
        case .teachWithFollowUp: return "Teach + Follow-Up"
        }
    }
}

// MARK: - Teach-back result

struct TeachBackResult: Codable {
    let understood: Bool
    let depth: TeachBackDepth
    let qualityScore: Double
    let keyPointsCovered: [String]
    let keyPointsMissed: [String]
    let learnedConcepts: [String]
    let remainingConfusion: [String]
    let followUpQuestion: String?
    let teachingDemo: TeachingDemo?
    let skillUpdates: [SkillUpdate]

    struct SkillUpdate: Codable {
        let skillID: String
        let newLevel: ProficiencyLevel
        let reason: String
    }
}

// MARK: - Teach-back engine

@MainActor
enum TeachBackEngine {

    // MARK: - Public API

    /// Run teach-back at the specified depth. Returns a rich result with
    /// optional teaching demo and skill update suggestions.
    static func runTeachBack(
        goal: CourseLearningGoal,
        depth: TeachBackDepth,
        learnerAnswer: String,
        previousAnswers: [String] = [],
        verifyResult: CourseVerificationResult?,
        claudeAPI: ClaudeAPI
    ) async -> TeachBackResult {
        switch depth {
        case .quickCheck:
            return await runQuickCheck(
                goal: goal,
                learnerAnswer: learnerAnswer,
                claudeAPI: claudeAPI
            )

        case .fullExplanation:
            return await runFullExplanation(
                goal: goal,
                learnerAnswer: learnerAnswer,
                previousAnswers: previousAnswers,
                claudeAPI: claudeAPI
            )

        case .teachSomeoneElse:
            return await runTeachSomeoneElse(
                goal: goal,
                learnerAnswer: learnerAnswer,
                claudeAPI: claudeAPI
            )

        case .teachWithFollowUp:
            return await runTeachWithFollowUp(
                goal: goal,
                learnerAnswer: learnerAnswer,
                previousAnswers: previousAnswers,
                claudeAPI: claudeAPI
            )
        }
    }

    /// Build a teach-back question appropriate for the depth and context.
    static func buildTeachBackQuestion(
        goal: CourseLearningGoal,
        depth: TeachBackDepth,
        verifyResult: CourseVerificationResult?,
        previousAnswers: [String]
    ) -> String {
        switch depth {
        case .quickCheck:
            return buildQuickCheckQuestion(goal: goal, verifyResult: verifyResult)

        case .fullExplanation:
            return buildFullExplanationQuestion(goal: goal, verifyResult: verifyResult, previousAnswers: previousAnswers)

        case .teachSomeoneElse:
            return buildTeachSomeoneElseQuestion(goal: goal)

        case .teachWithFollowUp:
            return buildTeachWithFollowUpQuestion(goal: goal, previousAnswers: previousAnswers)
        }
    }

    /// Determine the appropriate teach-back depth based on goal difficulty,
    /// learner history, and verification result.
    static func recommendedDepth(
        goal: CourseLearningGoal,
        learnerModel: LearnerModel,
        verifyResult: CourseVerificationResult?
    ) -> TeachBackDepth {
        if goal.teachingContext?.skipTeachBack == true {
            return .quickCheck
        }

        let hasStruggled = learnerModel.skillNodes.contains { node in
            node.confidenceScore < 0.3
                && goal.teachingContext?.concepts?.contains(where: { concept in
                    node.skillName.localizedCaseInsensitiveContains(concept)
                }) ?? false
        }

        if verifyResult?.status == .partial {
            return .fullExplanation
        }

        if hasStruggled {
            return .teachWithFollowUp
        }

        if let concepts = goal.teachingContext?.concepts, concepts.count >= 3 {
            return .teachSomeoneElse
        }

        return .fullExplanation
    }

    // MARK: - Quick check

    private static func runQuickCheck(
        goal: CourseLearningGoal,
        learnerAnswer: String,
        claudeAPI: ClaudeAPI
    ) async -> TeachBackResult {
        let systemPrompt = """
        You are doing a quick understanding check. Be brief and kind.

        Reply with ONLY a JSON object:
        {"understood":true,"qualityScore":0.0-1.0,"reason":"short explanation"}

        understood = true if they show even basic grasp of what they did.
        qualityScore reflects how well they explained, 0.0-1.0.
        """

        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let userPrompt = """
        Goal: \(goal.title) — \(goal.goal)
        Key concepts: \(concepts)
        Learner said: \(learnerAnswer)
        """

        let result = await callLLMForTeachBack(systemPrompt: systemPrompt, userPrompt: userPrompt, claudeAPI: claudeAPI)

        return TeachBackResult(
            understood: result.understood,
            depth: .quickCheck,
            qualityScore: result.qualityScore,
            keyPointsCovered: [],
            keyPointsMissed: [],
            learnedConcepts: result.understood ? inferSkillsFromGoal(goal) : [],
            remainingConfusion: result.understood ? [] : [goal.title],
            followUpQuestion: nil,
            teachingDemo: nil,
            skillUpdates: quickCheckSkillUpdates(goal: goal, understood: result.understood, qualityScore: result.qualityScore)
        )
    }

    // MARK: - Full explanation

    private static func runFullExplanation(
        goal: CourseLearningGoal,
        learnerAnswer: String,
        previousAnswers: [String],
        claudeAPI: ClaudeAPI
    ) async -> TeachBackResult {
        let systemPrompt = """
        You are assessing whether a learner truly understands what they just did.
        They should explain the concept in their own words, not just describe steps.

        Reply with ONLY a JSON object:
        {"understood":true,"qualityScore":0.0-1.0,"keyPointsCovered":[""],"keyPointsMissed":[""],"reason":"explanation"}

        understood = false if they can only describe WHAT they did but not WHY it worked.
        understood = true if they grasp the underlying concept, even with messy wording.
        qualityScore: 0.0 = vague/wrong, 0.5 = describes steps but not concepts, 1.0 = explains WHY clearly.
        """

        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let previousBlock: String
        if !previousAnswers.isEmpty {
            let history = previousAnswers.enumerated().map { "  Turn \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            previousBlock = "\n\nPrevious answers:\n\(history)"
        } else {
            previousBlock = ""
        }

        let userPrompt = """
        Goal: \(goal.title)
        Success criteria: \(goal.goal)
        Key concepts: \(concepts)
        Teach-back question: \(goal.teachingContext?.teachBackPrompt ?? "what did we just do and why did it work?")

        Learner said: \(learnerAnswer)\(previousBlock)
        """

        let result = await callLLMForTeachBack(systemPrompt: systemPrompt, userPrompt: userPrompt, claudeAPI: claudeAPI)

        let inferredSkills = inferSkillsFromGoal(goal)
        let skillLevel: ProficiencyLevel = result.understood && result.qualityScore >= 0.7 ? .competent : .beginner

        return TeachBackResult(
            understood: result.understood,
            depth: .fullExplanation,
            qualityScore: result.qualityScore,
            keyPointsCovered: result.keyPointsCovered,
            keyPointsMissed: result.keyPointsMissed,
            learnedConcepts: result.understood ? inferredSkills : [],
            remainingConfusion: result.understood ? [] : result.keyPointsMissed.isEmpty ? [goal.title] : result.keyPointsMissed,
            followUpQuestion: result.understood ? nil : "Let me clarify — \(result.keyPointsMissed.first ?? goal.title). Can you try explaining that specific part?",
            teachingDemo: nil,
            skillUpdates: inferredSkills.map { skillID in
                TeachBackResult.SkillUpdate(skillID: skillID, newLevel: skillLevel, reason: "Full explanation quality: \(String(format: "%.1f", result.qualityScore))")
            }
        )
    }

    // MARK: - Teach someone else

    private static func runTeachSomeoneElse(
        goal: CourseLearningGoal,
        learnerAnswer: String,
        claudeAPI: ClaudeAPI
    ) async -> TeachBackResult {
        let systemPrompt = """
        You are evaluating a learner's teaching ability. They just learned something \
        and are now teaching it to an imaginary friend. Assess whether their explanation \
        would actually help someone else understand.

        Reply with ONLY a JSON object:
        {"understood":true,"qualityScore":0.0-1.0,"keyPointsCovered":[""],"keyPointsMissed":[""],"teachingQuality":0.0-1.0,"wouldListenerUnderstand":true,"reason":"explanation"}

        teachingQuality: 0.0 = incomprehensible, 0.5 = explains steps but confuses listener, 1.0 = clear, engaging, builds understanding.
        wouldListenerUnderstand: would someone hearing this explanation actually get it?
        """

        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let userPrompt = """
        Goal: \(goal.title)
        What they learned: \(goal.goal)
        Key concepts: \(concepts)

        The learner is teaching this to an imaginary friend. Their explanation:
        \(learnerAnswer)

        Would this explanation actually help someone else understand?
        """

        let result = await callLLMForTeachBack(systemPrompt: systemPrompt, userPrompt: userPrompt, claudeAPI: claudeAPI)

        let inferredSkills = inferSkillsFromGoal(goal)
        let qualityScore = (result.qualityScore + (result.wouldListenerUnderstand ? 0.3 : 0.0)) / 1.3

        let demo = TeachingDemo(
            skillID: inferredSkills.first ?? goal.id,
            transcriptText: learnerAnswer,
            qualityScore: qualityScore,
            keyPointsCovered: result.keyPointsCovered,
            keyPointsMissed: result.keyPointsMissed
        )

        let skillLevel: ProficiencyLevel
        if result.understood && qualityScore >= 0.8 {
            skillLevel = .proficient
        } else if result.understood {
            skillLevel = .competent
        } else {
            skillLevel = .beginner
        }

        return TeachBackResult(
            understood: result.understood,
            depth: .teachSomeoneElse,
            qualityScore: qualityScore,
            keyPointsCovered: result.keyPointsCovered,
            keyPointsMissed: result.keyPointsMissed,
            learnedConcepts: result.understood ? inferredSkills : [],
            remainingConfusion: result.understood ? [] : result.keyPointsMissed,
            followUpQuestion: nil,
            teachingDemo: demo,
            skillUpdates: inferredSkills.map { skillID in
                TeachBackResult.SkillUpdate(skillID: skillID, newLevel: skillLevel, reason: "Teaching quality: \(String(format: "%.1f", qualityScore))")
            }
        )
    }

    // MARK: - Teach with follow-up

    private static func runTeachWithFollowUp(
        goal: CourseLearningGoal,
        learnerAnswer: String,
        previousAnswers: [String],
        claudeAPI: ClaudeAPI
    ) async -> TeachBackResult {
        let systemPrompt = """
        The learner struggled with this concept earlier. They've now given an explanation. \
        Assess their understanding deeply — focus on whether they've overcome their confusion.

        Reply with ONLY a JSON object:
        {"understood":true,"qualityScore":0.0-1.0,"keyPointsCovered":[""],"keyPointsMissed":[""],"confusionCleared":true,"followUpQuestion":"deeper probe"}

        confusionCleared: has the learner moved past their earlier confusion?
        followUpQuestion: a question that tests whether they can apply this in a different scenario.
        """

        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let previousBlock: String
        if !previousAnswers.isEmpty {
            let history = previousAnswers.enumerated().map { "  Turn \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            previousBlock = "\n\nPrevious answers:\n\(history)"
        } else {
            previousBlock = ""
        }

        let userPrompt = """
        Goal: \(goal.title)
        What they learned: \(goal.goal)
        Key concepts: \(concepts)
        They previously struggled with: \(goal.teachingContext?.concepts?.first ?? "the core concept")

        Learner's explanation: \(learnerAnswer)\(previousBlock)
        """

        let result = await callLLMForTeachBack(systemPrompt: systemPrompt, userPrompt: userPrompt, claudeAPI: claudeAPI)

        let inferredSkills = inferSkillsFromGoal(goal)
        let skillLevel: ProficiencyLevel
        if result.understood && result.confusionCleared {
            skillLevel = .competent
        } else if result.understood {
            skillLevel = .beginner
        } else {
            skillLevel = .novice
        }

        return TeachBackResult(
            understood: result.understood,
            depth: .teachWithFollowUp,
            qualityScore: result.qualityScore,
            keyPointsCovered: result.keyPointsCovered,
            keyPointsMissed: result.keyPointsMissed,
            learnedConcepts: result.understood ? inferredSkills : [],
            remainingConfusion: result.confusionCleared ? [] : result.keyPointsMissed,
            followUpQuestion: result.followUpQuestion,
            teachingDemo: nil,
            skillUpdates: inferredSkills.map { skillID in
                TeachBackResult.SkillUpdate(skillID: skillID, newLevel: skillLevel, reason: "Confusion cleared: \(result.confusionCleared)")
            }
        )
    }

    // MARK: - Question builders

    private static func buildQuickCheckQuestion(
        goal: CourseLearningGoal,
        verifyResult: CourseVerificationResult?
    ) -> String {
        if verifyResult?.status == .partial, let missing = verifyResult?.whatsMissing {
            return "you got partway — can you briefly say what's still needed to finish \(goal.title)?"
        }
        return "quick check — what did we just do? one or two sentences."
    }

    private static func buildFullExplanationQuestion(
        goal: CourseLearningGoal,
        verifyResult: CourseVerificationResult?,
        previousAnswers: [String]
    ) -> String {
        if verifyResult?.status == .partial, let missing = verifyResult?.whatsMissing {
            return "you got partway there — can you walk me through what's still needed to finish \(goal.title)?"
        }

        if let authored = goal.teachingContext?.teachBackPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authored.isEmpty {
            return authored
        }

        if !previousAnswers.isEmpty {
            return "can you try explaining the core concept again? focus on WHY it works, not just what you did."
        }

        return "in your own words — what did we just do and why did it work?"
    }

    private static func buildTeachSomeoneElseQuestion(goal: CourseLearningGoal) -> String {
        return "imagine you're teaching a friend who knows nothing about this. explain \(goal.title) in a way they'd actually understand. go step by step."
    }

    private static func buildTeachWithFollowUpQuestion(
        goal: CourseLearningGoal,
        previousAnswers: [String]
    ) -> String {
        if !previousAnswers.isEmpty {
            return "let's try again — explain the core concept in your own words, and this time try to say WHY it matters, not just what you did."
        }
        return "walk me through the key idea here. what's the one thing you'd want someone to remember about \(goal.title)?"
    }

    // MARK: - LLM call

    private static func callLLMForTeachBack(
        systemPrompt: String,
        userPrompt: String,
        claudeAPI: ClaudeAPI
    ) async -> TeachBackLLMResult {
        do {
            let (rawText, _) = try await claudeAPI.analyzeImageStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )
            return parseTeachBackResult(from: rawText)
        } catch {
            return TeachBackLLMResult(
                understood: true,
                qualityScore: 0.5,
                keyPointsCovered: [],
                keyPointsMissed: [],
                confusionCleared: true,
                wouldListenerUnderstand: true,
                followUpQuestion: nil,
                reason: "LLM error — soft pass"
            )
        }
    }

    private static func parseTeachBackResult(from rawText: String) -> TeachBackLLMResult {
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
            let softYes = lowered.contains("\"understood\": true") || lowered.hasPrefix("yes")
            return TeachBackLLMResult(
                understood: softYes,
                qualityScore: softYes ? 0.5 : 0.2,
                keyPointsCovered: [],
                keyPointsMissed: [],
                confusionCleared: softYes,
                wouldListenerUnderstand: softYes,
                followUpQuestion: nil,
                reason: "unparsed teach-back"
            )
        }

        return TeachBackLLMResult(
            understood: (object["understood"] as? Bool) ?? ((object["understood"] as? NSNumber)?.boolValue) ?? false,
            qualityScore: (object["qualityScore"] as? Double) ?? (object["teachingQuality"] as? Double) ?? 0.5,
            keyPointsCovered: (object["keyPointsCovered"] as? [String]) ?? [],
            keyPointsMissed: (object["keyPointsMissed"] as? [String]) ?? [],
            confusionCleared: (object["confusionCleared"] as? Bool) ?? true,
            wouldListenerUnderstand: (object["wouldListenerUnderstand"] as? Bool) ?? true,
            followUpQuestion: object["followUpQuestion"] as? String,
            reason: (object["reason"] as? String) ?? "ok"
        )
    }

    // MARK: - Helpers

    private static func inferSkillsFromGoal(_ goal: CourseLearningGoal) -> [String] {
        var skills: [String] = []
        let titleLower = goal.title.lowercased()
        let goalLower = goal.goal.lowercased()

        let skillPatterns: [(String, [String])] = [
            ("prompt-engineering-basics", ["prompt", "ask ai", "write a prompt"]),
            ("output-verification", ["verify", "check", "review output", "validate"]),
            ("ai-assisted-coding", ["code", "program", "function", "script", "debug"]),
            ("ai-writing-assistance", ["write", "draft", "edit", "proofread"]),
            ("ai-research", ["research", "find information", "look up"]),
            ("ai-data-analysis", ["data", "analyze", "chart", "visualization"]),
            ("cursor-ide-usage", ["cursor", "ide", "editor"]),
            ("claude-code-usage", ["claude code", "terminal", "command line"]),
            ("chatgpt-usage", ["chatgpt", "chat gpt"]),
            ("claude-usage", ["claude"]),
            ("ai-automation", ["automate", "automation", "workflow"]),
            ("ai-agent-usage", ["agent", "autonomous", "multi-step"])
        ]

        for (skillID, patterns) in skillPatterns {
            let matches = patterns.contains { pattern in
                titleLower.contains(pattern) || goalLower.contains(pattern)
            }
            if matches {
                skills.append(skillID)
            }
        }

        return skills
    }

    private static func quickCheckSkillUpdates(
        goal: CourseLearningGoal,
        understood: Bool,
        qualityScore: Double
    ) -> [TeachBackResult.SkillUpdate] {
        let skills = inferSkillsFromGoal(goal)
        return skills.map { skillID in
            let level: ProficiencyLevel = understood ? .beginner : .novice
            return TeachBackResult.SkillUpdate(skillID: skillID, newLevel: level, reason: "Quick check: \(understood ? "passed" : "needs work")")
        }
    }
}

// MARK: - LLM result

private struct TeachBackLLMResult {
    let understood: Bool
    let qualityScore: Double
    let keyPointsCovered: [String]
    let keyPointsMissed: [String]
    let confusionCleared: Bool
    let wouldListenerUnderstand: Bool
    let followUpQuestion: String?
    let reason: String
}
