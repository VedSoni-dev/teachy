//
//  VerificationEngine.swift
//  leanring-buddy
//
//  Multi-modal verification that goes beyond vision-only checks. Adds
//  understanding depth, near-transfer tests, and code analysis on top
//  of the existing CourseVerifier vision pass.
//

import Foundation

// MARK: - Verification depth

enum VerificationDepth: String, Codable, CaseIterable {
    case visionOnly
    case visionPlusExplain
    case nearTransfer
    case codeAnalysis

    var displayName: String {
        switch self {
        case .visionOnly: return "Visual Check"
        case .visionPlusExplain: return "Visual + Understanding"
        case .nearTransfer: return "Visual + Transfer Test"
        case .codeAnalysis: return "Code Analysis"
        }
    }
}

// MARK: - Extended verification result

struct ExtendedVerificationResult: Codable {
    let baseResult: CourseVerificationResult
    let depth: VerificationDepth
    let understandingScore: Double?
    let transferScore: Double?
    let codeQualityScore: Double?
    let followUpQuestion: String?
    let skillsVerified: [String]
    let suggestedSkillUpdates: [SkillUpdate]

    struct SkillUpdate: Codable {
        let skillID: String
        let newLevel: ProficiencyLevel
        let reason: String
    }
}

// MARK: - Verification engine

@MainActor
enum VerificationEngine {

    // MARK: - Public API

    /// Run verification at the specified depth. Returns a rich result with
    /// optional follow-up questions for understanding checks.
    static func verify(
        goal: CourseLearningGoal,
        depth: VerificationDepth,
        claudeAPI: ClaudeAPI,
        learnerModel: LearnerModel?
    ) async -> ExtendedVerificationResult {
        let baseResult = await CourseVerifier.verifyStructured(
            criteria: CourseSuccessCriteria(
                visionDescription: goal.doneWhen ?? goal.goal,
                urlContains: nil,
                requireUserAdvance: true
            ),
            claudeAPI: claudeAPI,
            treatAsUserAdvance: true
        )

        switch depth {
        case .visionOnly:
            return ExtendedVerificationResult(
                baseResult: baseResult,
                depth: .visionOnly,
                understandingScore: nil,
                transferScore: nil,
                codeQualityScore: nil,
                followUpQuestion: nil,
                skillsVerified: inferSkillsFromGoal(goal),
                suggestedSkillUpdates: skillUpdatesFromVision(goal: goal, result: baseResult)
            )

        case .visionPlusExplain:
            let understanding = await assessUnderstanding(goal: goal, claudeAPI: claudeAPI)
            return ExtendedVerificationResult(
                baseResult: baseResult,
                depth: .visionPlusExplain,
                understandingScore: understanding.score,
                transferScore: nil,
                codeQualityScore: nil,
                followUpQuestion: understanding.followUpQuestion,
                skillsVerified: inferSkillsFromGoal(goal),
                suggestedSkillUpdates: skillUpdatesFromUnderstanding(goal: goal, result: baseResult, understanding: understanding)
            )

        case .nearTransfer:
            let understanding = await assessUnderstanding(goal: goal, claudeAPI: claudeAPI)
            let transfer = await assessTransfer(goal: goal, claudeAPI: claudeAPI)
            return ExtendedVerificationResult(
                baseResult: baseResult,
                depth: .nearTransfer,
                understandingScore: understanding.score,
                transferScore: transfer.score,
                codeQualityScore: nil,
                followUpQuestion: transfer.followUpQuestion,
                skillsVerified: inferSkillsFromGoal(goal),
                suggestedSkillUpdates: skillUpdatesFromTransfer(goal: goal, result: baseResult, transfer: transfer)
            )

        case .codeAnalysis:
            let codeScore = await assessCodeQuality(goal: goal, claudeAPI: claudeAPI)
            return ExtendedVerificationResult(
                baseResult: baseResult,
                depth: .codeAnalysis,
                understandingScore: nil,
                transferScore: nil,
                codeQualityScore: codeScore.score,
                followUpQuestion: codeScore.followUpQuestion,
                skillsVerified: inferSkillsFromGoal(goal),
                suggestedSkillUpdates: skillUpdatesFromCode(goal: goal, result: baseResult, codeScore: codeScore)
            )
        }
    }

    // MARK: - Understanding assessment

    private static func assessUnderstanding(
        goal: CourseLearningGoal,
        claudeAPI: ClaudeAPI
    ) async -> UnderstandingAssessment {
        let systemPrompt = """
        You are assessing whether a learner truly understands what they just did, \
        not just whether they completed the task. You will NOT see the screen — \
        only the goal description and the learner's explanation.

        Reply with ONLY a JSON object:
        {"score":0.0-1.0,"keyPointsCovered":[""],"keyPointsMissed":[""],"followUpQuestion":"optional deeper question"}

        score guidelines:
        - 0.0-0.3: vague or incorrect understanding
        - 0.4-0.6: partial understanding, missed key concepts
        - 0.7-0.8: solid understanding of core concepts
        - 0.9-1.0: deep understanding, can explain "why" not just "what"

        followUpQuestion should probe a specific gap if score < 0.7, or be empty if understanding is solid.
        """

        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let userPrompt = """
        Goal: \(goal.title)
        Success criteria: \(goal.goal)
        Key concepts: \(concepts)

        The learner just completed this goal. Ask them to explain what they did and why it worked.
        They will respond, and you will assess their understanding.
        """

        do {
            let (rawText, _) = try await claudeAPI.analyzeImageStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )
            return parseUnderstandingAssessment(from: rawText)
        } catch {
            return UnderstandingAssessment(
                score: 0.5,
                keyPointsCovered: [],
                keyPointsMissed: [],
                followUpQuestion: "Can you walk me through what you just did and why it worked?"
            )
        }
    }

    private static func parseUnderstandingAssessment(from rawText: String) -> UnderstandingAssessment {
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
            return UnderstandingAssessment(
                score: 0.5,
                keyPointsCovered: [],
                keyPointsMissed: [],
                followUpQuestion: "Can you explain what you just did in your own words?"
            )
        }

        let score = (object["score"] as? Double) ?? 0.5
        let covered = (object["keyPointsCovered"] as? [String]) ?? []
        let missed = (object["keyPointsMissed"] as? [String]) ?? []
        let followUp = (object["followUpQuestion"] as? String) ?? ""

        return UnderstandingAssessment(
            score: score,
            keyPointsCovered: covered,
            keyPointsMissed: missed,
            followUpQuestion: followUp.isEmpty ? nil : followUp
        )
    }

    // MARK: - Transfer assessment

    private static func assessTransfer(
        goal: CourseLearningGoal,
        claudeAPI: ClaudeAPI
    ) async -> TransferAssessment {
        let systemPrompt = """
        You are testing whether a learner can transfer what they learned to a new context. \
        This is a near-transfer test — same concept, different situation.

        Reply with ONLY a JSON object:
        {"score":0.0-1.0,"transferScenario":"new situation description","followUpQuestion":"test question"}

        score guidelines:
        - 0.0-0.3: cannot apply the concept to a new context
        - 0.4-0.6: partial transfer with hints
        - 0.7-0.8: solid transfer to a similar context
        - 0.9-1.0: can adapt the concept to very different contexts

        transferScenario should describe a realistic new situation where the same skill applies.
        followUpQuestion should be a concrete question about applying the skill in that scenario.
        """

        let concepts = goal.teachingContext?.concepts?.joined(separator: "; ") ?? goal.goal
        let userPrompt = """
        Goal: \(goal.title)
        What they learned: \(goal.goal)
        Key concepts: \(concepts)

        Design a near-transfer test — same concept, different context.
        """

        do {
            let (rawText, _) = try await claudeAPI.analyzeImageStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )
            return parseTransferAssessment(from: rawText)
        } catch {
            return TransferAssessment(
                score: 0.5,
                transferScenario: "a different project or tool",
                followUpQuestion: "How would you apply what you learned to a different project?"
            )
        }
    }

    private static func parseTransferAssessment(from rawText: String) -> TransferAssessment {
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
            return TransferAssessment(
                score: 0.5,
                transferScenario: "a different context",
                followUpQuestion: "How would you use this skill in a different situation?"
            )
        }

        let score = (object["score"] as? Double) ?? 0.5
        let scenario = (object["transferScenario"] as? String) ?? "a different context"
        let question = (object["followUpQuestion"] as? String) ?? "How would you apply this elsewhere?"

        return TransferAssessment(score: score, transferScenario: scenario, followUpQuestion: question)
    }

    // MARK: - Code quality assessment

    private static func assessCodeQuality(
        goal: CourseLearningGoal,
        claudeAPI: ClaudeAPI
    ) async -> CodeQualityAssessment {
        let systemPrompt = """
        You are assessing the quality of code a learner wrote during a coding goal. \
        Look at the screenshot of their code editor or terminal.

        Reply with ONLY a JSON object:
        {"score":0.0-1.0,"strengths":[""],"improvements":[""],"followUpQuestion":"optional"}

        score guidelines:
        - 0.0-0.3: code doesn't work or has major issues
        - 0.4-0.6: code works but has style/readability issues
        - 0.7-0.8: clean, working code with good practices
        - 0.9-0.1.0: excellent code structure, handles edge cases
        """

        do {
            let screenCapture = try await CourseUIGrounder.captureCursorScreen()
            let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
                originalJPEGData: screenCapture.imageData,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
            ) ?? screenCapture.imageData

            let (rawText, _) = try await claudeAPI.analyzeImage(
                images: [(data: annotatedImageData, label: screenCapture.label)],
                systemPrompt: systemPrompt,
                userPrompt: "Assess the code quality for this goal: \(goal.title) — \(goal.goal)"
            )
            return parseCodeQualityAssessment(from: rawText)
        } catch {
            return CodeQualityAssessment(score: 0.5, strengths: [], improvements: [], followUpQuestion: nil)
        }
    }

    private static func parseCodeQualityAssessment(from rawText: String) -> CodeQualityAssessment {
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
            return CodeQualityAssessment(score: 0.5, strengths: [], improvements: [], followUpQuestion: nil)
        }

        let score = (object["score"] as? Double) ?? 0.5
        let strengths = (object["strengths"] as? [String]) ?? []
        let improvements = (object["improvements"] as? [String]) ?? []
        let followUp = object["followUpQuestion"] as? String

        return CodeQualityAssessment(score: score, strengths: strengths, improvements: improvements, followUpQuestion: followUp)
    }

    // MARK: - Skill inference

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

    // MARK: - Skill update suggestions

    private static func skillUpdatesFromVision(
        goal: CourseLearningGoal,
        result: CourseVerificationResult
    ) -> [ExtendedVerificationResult.SkillUpdate] {
        let skills = inferSkillsFromGoal(goal)
        return skills.map { skillID in
            let level: ProficiencyLevel = result.status == .pass ? .beginner : .novice
            return ExtendedVerificationResult.SkillUpdate(
                skillID: skillID,
                newLevel: level,
                reason: "Vision verification \(result.status.rawValue)"
            )
        }
    }

    private static func skillUpdatesFromUnderstanding(
        goal: CourseLearningGoal,
        result: CourseVerificationResult,
        understanding: UnderstandingAssessment
    ) -> [ExtendedVerificationResult.SkillUpdate] {
        let skills = inferSkillsFromGoal(goal)
        return skills.map { skillID in
            let level: ProficiencyLevel
            if result.status == .pass && understanding.score >= 0.7 {
                level = .competent
            } else if result.status == .pass {
                level = .beginner
            } else {
                level = .novice
            }
            return ExtendedVerificationResult.SkillUpdate(
                skillID: skillID,
                newLevel: level,
                reason: "Understanding score: \(String(format: "%.1f", understanding.score))"
            )
        }
    }

    private static func skillUpdatesFromTransfer(
        goal: CourseLearningGoal,
        result: CourseVerificationResult,
        transfer: TransferAssessment
    ) -> [ExtendedVerificationResult.SkillUpdate] {
        let skills = inferSkillsFromGoal(goal)
        return skills.map { skillID in
            let level: ProficiencyLevel
            if result.status == .pass && transfer.score >= 0.7 {
                level = .proficient
            } else if result.status == .pass && transfer.score >= 0.4 {
                level = .competent
            } else if result.status == .pass {
                level = .beginner
            } else {
                level = .novice
            }
            return ExtendedVerificationResult.SkillUpdate(
                skillID: skillID,
                newLevel: level,
                reason: "Transfer score: \(String(format: "%.1f", transfer.score))"
            )
        }
    }

    private static func skillUpdatesFromCode(
        goal: CourseLearningGoal,
        result: CourseVerificationResult,
        codeScore: CodeQualityAssessment
    ) -> [ExtendedVerificationResult.SkillUpdate] {
        let skills = inferSkillsFromGoal(goal)
        return skills.map { skillID in
            let level: ProficiencyLevel
            if result.status == .pass && codeScore.score >= 0.8 {
                level = .proficient
            } else if result.status == .pass && codeScore.score >= 0.5 {
                level = .competent
            } else if result.status == .pass {
                level = .beginner
            } else {
                level = .novice
            }
            return ExtendedVerificationResult.SkillUpdate(
                skillID: skillID,
                newLevel: level,
                reason: "Code quality: \(String(format: "%.1f", codeScore.score))"
            )
        }
    }
}

// MARK: - Assessment types

private struct UnderstandingAssessment {
    let score: Double
    let keyPointsCovered: [String]
    let keyPointsMissed: [String]
    let followUpQuestion: String?
}

private struct TransferAssessment {
    let score: Double
    let transferScenario: String
    let followUpQuestion: String?
}

private struct CodeQualityAssessment {
    let score: Double
    let strengths: [String]
    let improvements: [String]
    let followUpQuestion: String?
}
