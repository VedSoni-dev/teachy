//
//  SpacedRepetitionEngine.swift
//  leanring-buddy
//
//  Spaced repetition using a simplified SM-2 algorithm. Schedules review
//  sessions based on forgetting curves, generates context-aware retention
//  checks, and integrates with the core loop for contextual nudges.
//

import Foundation

// MARK: - Review schedule

struct ReviewSchedule: Codable, Equatable {
    let skillNodeID: String
    let nextReviewDate: Date
    let interval: TimeInterval
    let easeFactor: Double
    let reviewCount: Int
}

// MARK: - Retention check

struct RetentionCheck: Codable, Identifiable {
    let id: String
    let skillNodeID: String
    let skillName: String
    let questionText: String
    let contextHint: String
    let createdAt: Date
    let difficulty: Double

    init(skillNodeID: String, skillName: String, questionText: String, contextHint: String, difficulty: Double) {
        self.id = UUID().uuidString
        self.skillNodeID = skillNodeID
        self.skillName = skillName
        self.questionText = questionText
        self.contextHint = contextHint
        self.createdAt = Date()
        self.difficulty = difficulty
    }
}

// MARK: - Retention check result

struct RetentionCheckResult: Codable {
    let checkID: String
    let skillNodeID: String
    let correct: Bool
    let responseQuality: ReviewPerformance
    let responseTimeMs: Int
    let answeredAt: Date
}

// MARK: - Spaced repetition engine

@MainActor
enum SpacedRepetitionEngine {

    // SM-2 constants
    private static let defaultEaseFactor: Double = 2.5
    private static let minimumEaseFactor: Double = 1.3
    private static let maximumEaseFactor: Double = 3.0
    private static let initialIntervalDays: Double = 1.0
    private static let graduationIntervalDays: Double = 4.0

    // MARK: - Schedule management

    /// Calculate the next review schedule for a skill after a performance rating.
    static func scheduleReview(
        for skill: LearnerSkillNode,
        performance: ReviewPerformance
    ) -> ReviewSchedule {
        let currentInterval = skill.nextReviewAt.map { nextReview in
            max(1.0, Double(Calendar.current.dateComponents([.day], from: Date(), to: nextReview).day ?? 1))
        } ?? Self.initialIntervalDays

        let newEaseFactor: Double
        let newInterval: Double

        switch performance {
        case .forgot:
            newEaseFactor = max(Self.minimumEaseFactor, skill.confidenceScore * Self.defaultEaseFactor - 0.2)
            newInterval = Self.initialIntervalDays

        case .struggled:
            newEaseFactor = max(Self.minimumEaseFactor, skill.confidenceScore * Self.defaultEaseFactor)
            newInterval = max(Self.graduationIntervalDays, currentInterval * newEaseFactor * 0.8)

        case .easy:
            newEaseFactor = min(Self.maximumEaseFactor, skill.confidenceScore * Self.defaultEaseFactor + 0.15)
            if skill.reviewCount <= 1 {
                newInterval = Self.graduationIntervalDays
            } else {
                newInterval = currentInterval * newEaseFactor
            }
        }

        let nextDate = Calendar.current.date(byAdding: .day, value: Int(ceil(newInterval)), to: Date()) ?? Date()

        return ReviewSchedule(
            skillNodeID: skill.id,
            nextReviewDate: nextDate,
            interval: newInterval,
            easeFactor: newEaseFactor,
            reviewCount: skill.reviewCount + 1
        )
    }

    /// Get all skills due for review, sorted by urgency.
    static func getDueReviews(from learnerModel: LearnerModel, now: Date = Date()) -> [LearnerSkillNode] {
        learnerModel.skillNodes
            .filter { node in
                node.proficiencyLevel > .novice
                    && node.totalAttempts > 0
                    && (node.nextReviewAt.map { now >= $0 } ?? false)
            }
            .sorted { a, b in
                let aDate = a.nextReviewAt ?? Date.distantPast
                let bDate = b.nextReviewAt ?? Date.distantPast
                return aDate < bDate
            }
    }

    /// Get skills that are at risk of being forgotten (no practice in a while).
    static func getAtRiskSkills(from learnerModel: LearnerModel, now: Date = Date()) -> [LearnerSkillNode] {
        learnerModel.skillNodes.filter { node in
            guard node.proficiencyLevel > .novice, let lastPracticed = node.lastPracticedAt else {
                return false
            }
            let daysSincePractice = Calendar.current.dateComponents([.day], from: lastPracticed, to: now).day ?? 0
            let riskThreshold = riskThresholdDays(for: node.proficiencyLevel)
            return daysSincePractice >= riskThreshold
        }
    }

    // MARK: - Retention check generation

    /// Generate a retention check for a specific skill.
    static func generateRetentionCheck(
        for skillNode: LearnerSkillNode,
        skillGraph: SkillGraph
    ) -> RetentionCheck {
        let node = skillGraph.node(byID: skillNode.id)
        let skillName = node?.name ?? skillNode.skillName
        let domain = node?.domain ?? skillNode.domain

        let question = buildRetentionQuestion(
            skillName: skillName,
            domain: domain,
            proficiencyLevel: skillNode.proficiencyLevel,
            struggleNotes: skillNode.struggleNotes,
            contextsUsed: skillNode.contextsUsed
        )

        let contextHint = buildContextHint(
            skillName: skillName,
            domain: domain,
            contextsUsed: skillNode.contextsUsed
        )

        return RetentionCheck(
            skillNodeID: skillNode.id,
            skillName: skillName,
            questionText: question,
            contextHint: contextHint,
            difficulty: Double(skillNode.proficiencyLevel.rawValue.hashValue) / 5.0
        )
    }

    /// Generate contextual nudge text when the learner is about to use a skill.
    static func generateContextualNudge(
        for skillNode: LearnerSkillNode,
        currentContext: String
    ) -> String? {
        guard skillNode.isDueForReview else { return nil }

        let skillName = skillNode.skillName
        let daysSince = skillNode.daysSinceLastVerified ?? 0

        if daysSince >= 14 {
            return "you're about to use \(skillName) — it's been \(daysSince) days. want a quick refresher?"
        } else if daysSince >= 7 {
            return "quick \(skillName) refresher? it's been a week."
        } else {
            return nil
        }
    }

    /// Generate a batch of retention checks for due skills.
    static func generateBatchRetentionChecks(
        from learnerModel: LearnerModel,
        skillGraph: SkillGraph,
        maxChecks: Int = 3
    ) -> [RetentionCheck] {
        let dueSkills = getDueReviews(from: learnerModel)
        return Array(dueSkills.prefix(maxChecks).map { skill in
            generateRetentionCheck(for: skill, skillGraph: skillGraph)
        })
    }

    // MARK: - Difficulty calculation

    /// Calculate retention difficulty based on forgetting curve.
    /// Higher = more likely to be forgotten.
    static func retentionDifficulty(for skill: LearnerSkillNode) -> Double {
        guard let lastPracticed = skill.lastPracticedAt else { return 0.5 }

        let daysSincePractice = Double(Calendar.current.dateComponents([.day], from: lastPracticed, to: Date()).day ?? 0)
        let stability = max(1.0, skill.confidenceScore * 10.0)
        let difficulty = 1.0 - exp(-daysSincePractice / stability)
        return min(1.0, max(0.0, difficulty))
    }

    /// Get the expected retention probability for a skill at a given time.
    static func retentionProbability(for skill: LearnerSkillNode, at date: Date) -> Double {
        guard let lastPracticed = skill.lastPracticedAt else { return 0.5 }

        let daysSincePractice = Double(Calendar.current.dateComponents([.day], from: lastPracticed, to: date).day ?? 0)
        let stability = max(1.0, skill.confidenceScore * 10.0)
        return exp(-daysSincePractice / stability)
    }

    // MARK: - Private helpers

    private static func riskThresholdDays(for level: ProficiencyLevel) -> Int {
        switch level {
        case .novice: return 3
        case .beginner: return 5
        case .competent: return 10
        case .proficient: return 20
        case .expert: return 40
        }
    }

    private static func buildRetentionQuestion(
        skillName: String,
        domain: String,
        proficiencyLevel: ProficiencyLevel,
        struggleNotes: [String],
        contextsUsed: [String]
    ) -> String {
        let contextSnippet = contextsUsed.last ?? "a recent project"

        switch proficiencyLevel {
        case .novice:
            return "What is \(skillName)? Describe it in one sentence."

        case .beginner:
            if let struggle = struggleNotes.last {
                return "Earlier you struggled with: \(struggle). Can you explain how \(skillName) addresses that?"
            }
            return "How do you use \(skillName)? Give a brief example from \(contextSnippet)."

        case .competent:
            return "When would you choose \(skillName) over an alternative approach? What makes it the right tool?"

        case .proficient:
            return "A friend asks you to teach them \(skillName). What's the one thing you'd make sure they understand?"

        case .expert:
            return "How would you adapt \(skillName) to a completely different domain? What's the underlying principle?"
        }
    }

    private static func buildContextHint(
        skillName: String,
        domain: String,
        contextsUsed: [String]
    ) -> String {
        if let lastContext = contextsUsed.last {
            return "Last used in: \(lastContext)"
        }
        return "Domain: \(BundledSkillGraph.domainDisplayName(domain))"
    }
}
