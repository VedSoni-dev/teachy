//
//  LearnerModel.swift
//  leanring-buddy
//
//  Enhanced persistent learner model with skill nodes, proficiency tracking,
//  and cross-domain memory. Replaces the flat knows/confusedBy lists with a
//  structured model that tracks depth, context, and transfer.
//

import Foundation

// MARK: - Proficiency levels

enum ProficiencyLevel: String, Codable, Comparable, CaseIterable {
    case novice       // never done it
    case beginner     // done it with guidance
    case competent    // can do it independently
    case proficient   // can do it quickly and teach it
    case expert       // can adapt it to new contexts

    static func < (lhs: ProficiencyLevel, rhs: ProficiencyLevel) -> Bool {
        let order: [ProficiencyLevel] = [.novice, .beginner, .competent, .proficient, .expert]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    var displayName: String {
        switch self {
        case .novice: return "Novice"
        case .beginner: return "Beginner"
        case .competent: return "Competent"
        case .proficient: return "Proficient"
        case .expert: return "Expert"
        }
    }

    var emoji: String {
        switch self {
        case .novice: return " seedling"
        case .beginner: return " sprout"
        case .competent: return " tree"
        case .proficient: return " evergreen"
        case .expert: return " star"
        }
    }
}

// MARK: - Learner skill node

/// A single skill the learner has demonstrated, with rich metadata about
/// proficiency, struggle points, and review scheduling.
struct LearnerSkillNode: Codable, Identifiable, Equatable {
    let id: String
    var skillName: String
    var domain: String
    var proficiencyLevel: ProficiencyLevel
    var confidenceScore: Double
    var lastVerifiedAt: Date?
    var nextReviewAt: Date?
    var reviewCount: Int
    var totalAttempts: Int
    var struggleNotes: [String]
    var successNotes: [String]
    var contextsUsed: [String]
    var transferLinks: [String]
    var firstLearnedAt: Date
    var lastPracticedAt: Date?

    init(
        id: String,
        skillName: String,
        domain: String = "general",
        proficiencyLevel: ProficiencyLevel = .novice,
        confidenceScore: Double = 0.0
    ) {
        self.id = id
        self.skillName = skillName
        self.domain = domain
        self.proficiencyLevel = proficiencyLevel
        self.confidenceScore = confidenceScore
        self.reviewCount = 0
        self.totalAttempts = 0
        self.struggleNotes = []
        self.successNotes = []
        self.contextsUsed = []
        self.transferLinks = []
        self.firstLearnedAt = Date()
    }

    var isDueForReview: Bool {
        guard let nextReviewAt else { return false }
        return Date() >= nextReviewAt
    }

    var daysSinceLastVerified: Int? {
        guard let lastVerifiedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: lastVerifiedAt, to: Date()).day
    }

    mutating func recordAttempt(performance: ReviewPerformance, context: String) {
        totalAttempts += 1
        lastPracticedAt = Date()
        if !contextsUsed.contains(context) {
            contextsUsed.append(context)
        }
        if contextsUsed.count > 10 {
            contextsUsed = Array(contextsUsed.suffix(10))
        }
    }

    mutating func updateProficiency(newLevel: ProficiencyLevel, reason: String) {
        let oldLevel = proficiencyLevel
        proficiencyLevel = newLevel
        if newLevel > oldLevel {
            successNotes.append(reason)
            successNotes = Array(successNotes.suffix(8))
        }
    }

    mutating func addStruggle(note: String) {
        struggleNotes.append(note)
        struggleNotes = Array(struggleNotes.suffix(8))
    }

    mutating func addSuccess(note: String) {
        successNotes.append(note)
        successNotes = Array(successNotes.suffix(8))
    }

    mutating func addTransfer(skillID: String) {
        if !transferLinks.contains(skillID) {
            transferLinks.append(skillID)
        }
    }
}

// MARK: - Teaching demonstration

struct TeachingDemo: Codable, Identifiable, Equatable {
    let id: String
    let skillID: String
    let transcriptText: String
    let qualityScore: Double       // 0.0 - 1.0, assessed by LLM
    let keyPointsCovered: [String]
    let keyPointsMissed: [String]
    let recordedAt: Date

    init(
        skillID: String,
        transcriptText: String,
        qualityScore: Double = 0.0,
        keyPointsCovered: [String] = [],
        keyPointsMissed: [String] = []
    ) {
        self.id = UUID().uuidString
        self.skillID = skillID
        self.transcriptText = transcriptText
        self.qualityScore = qualityScore
        self.keyPointsCovered = keyPointsCovered
        self.keyPointsMissed = keyPointsMissed
        self.recordedAt = Date()
    }
}

// MARK: - Review performance

enum ReviewPerformance: String, Codable {
    case forgot
    case struggled
    case easy
}

// MARK: - Learner model

/// The complete persistent model of a learner. Carries knowledge across all
/// courses, tracks proficiency over time, and powers spaced repetition.
/// This is the "persistent learner memory" that makes Teachy un-copyable.
struct LearnerModel: Codable, Equatable {
    var skillNodes: [LearnerSkillNode]
    var teachingDemos: [TeachingDemo]
    var rollingNotes: [String]
    var prefersHintsOverAutomation: Bool?
    var detectedMood: String?
    var totalCoursesCompleted: Int
    var totalGoalsCompleted: Int
    var totalSessionMinutes: Int
    var currentStreakDays: Int
    var longestStreakDays: Int
    var lastActiveDate: Date?
    var portfolioItemCount: Int
    var createdAt: Date
    var updatedAt: Date

    init() {
        self.skillNodes = []
        self.teachingDemos = []
        self.rollingNotes = []
        self.totalCoursesCompleted = 0
        self.totalGoalsCompleted = 0
        self.totalSessionMinutes = 0
        self.currentStreakDays = 0
        self.longestStreakDays = 0
        self.portfolioItemCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Skill lookups

    func skillNode(byID id: String) -> LearnerSkillNode? {
        skillNodes.first { $0.id == id }
    }

    func skillNode(named name: String) -> LearnerSkillNode? {
        skillNodes.first { $0.skillName.caseInsensitiveCompare(name) == .orderedSame }
    }

    func skills(inDomain domain: String) -> [LearnerSkillNode] {
        skillNodes.filter { $0.domain == domain }
    }

    var dueForReview: [LearnerSkillNode] {
        skillNodes.filter { $0.isDueForReview }
    }

    var masteredSkills: [LearnerSkillNode] {
        skillNodes.filter { $0.proficiencyLevel >= .proficient }
    }

    var totalSkillsLearned: Int {
        skillNodes.filter { $0.proficiencyLevel > .novice }.count
    }

    // MARK: - Skill updates

    mutating func noteSkillUsed(_ skillID: String, skillName: String, domain: String, context: String) {
        if var existing = skillNode(byID: skillID) {
            existing.recordAttempt(performance: .easy, context: context)
            existing.lastPracticedAt = Date()
            if let idx = skillNodes.firstIndex(where: { $0.id == skillID }) {
                skillNodes[idx] = existing
            }
        } else {
            var newNode = LearnerSkillNode(id: skillID, skillName: skillName, domain: domain)
            newNode.contextsUsed = [context]
            newNode.totalAttempts = 1
            newNode.lastPracticedAt = Date()
            skillNodes.append(newNode)
        }
        updatedAt = Date()
    }

    mutating func noteSkillVerified(_ skillID: String, level: ProficiencyLevel, reason: String) {
        if var existing = skillNode(byID: skillID) {
            existing.updateProficiency(newLevel: level, reason: reason)
            existing.confidenceScore = min(1.0, existing.confidenceScore + 0.2)
            existing.lastVerifiedAt = Date()
            existing.reviewCount += 1
            if let idx = skillNodes.firstIndex(where: { $0.id == skillID }) {
                skillNodes[idx] = existing
            }
        } else {
            var newNode = LearnerSkillNode(id: skillID, skillName: skillID, proficiencyLevel: level)
            newNode.confidenceScore = 0.5
            newNode.lastVerifiedAt = Date()
            newNode.reviewCount = 1
            newNode.successNotes = [reason]
            skillNodes.append(newNode)
        }
        updatedAt = Date()
    }

    mutating func noteSkillStruggle(_ skillID: String, note: String) {
        if let idx = skillNodes.firstIndex(where: { $0.id == skillID }) {
            skillNodes[idx].addStruggle(note: note)
            skillNodes[idx].confidenceScore = max(0.0, skillNodes[idx].confidenceScore - 0.1)
        }
        updatedAt = Date()
    }

    mutating func addTeachingDemo(_ demo: TeachingDemo) {
        teachingDemos.append(demo)
        if teachingDemos.count > 20 {
            teachingDemos = Array(teachingDemos.suffix(20))
        }
        updatedAt = Date()
    }

    // MARK: - Mood & preferences

    mutating func detectMood(from userResponse: String) {
        let lower = userResponse.lowercased()
        let trimmed = userResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(separator: " ").count

        if wordCount <= 3 && (lower.contains("idk") || lower.contains("i don't know") || lower.contains("no idea") || lower.contains("confused") || lower.contains("lost")) {
            detectedMood = "frustrated"
        } else if wordCount <= 2 && (lower == "ok" || lower == "done" || lower == "yes" || lower == "yep" || lower == "sure" || lower == "k") {
            detectedMood = "bored"
        } else if wordCount >= 6 || lower.contains("?") {
            detectedMood = "engaged"
        } else if lower.contains("maybe") || lower.contains("i think") || lower.contains("not sure") {
            detectedMood = "confused"
        }
    }

    // MARK: - Rolling notes

    mutating func appendRollingNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rollingNotes.append(trimmed)
        rollingNotes = Array(rollingNotes.suffix(16))
        updatedAt = Date()
    }

    // MARK: - Streak

    mutating func recordActivity() {
        let today = Calendar.current.startOfDay(for: Date())
        guard let lastActive = lastActiveDate else {
            currentStreakDays = 1
            longestStreakDays = 1
            lastActiveDate = today
            return
        }
        let lastActiveDay = Calendar.current.startOfDay(for: lastActive)
        let daysBetween = Calendar.current.dateComponents([.day], from: lastActiveDay, to: today).day ?? 0
        if daysBetween == 0 {
            return
        } else if daysBetween == 1 {
            currentStreakDays += 1
            longestStreakDays = max(longestStreakDays, currentStreakDays)
        } else {
            currentStreakDays = 1
        }
        lastActiveDate = today
    }

    // MARK: - Legacy migration

    /// Migrate from the old CourseLearnerProfile format.
    init(from legacyProfile: CourseLearnerProfile) {
        self.init()
        for concept in legacyProfile.knows {
            var node = LearnerSkillNode(id: concept, skillName: concept)
            node.proficiencyLevel = .beginner
            node.confidenceScore = 0.4
            skillNodes.append(node)
        }
        for concept in legacyProfile.confusedBy {
            var node = LearnerSkillNode(id: concept, skillName: concept)
            node.proficiencyLevel = .novice
            node.confidenceScore = 0.1
            node.addStruggle(note: "marked as confused in legacy profile")
            skillNodes.append(node)
        }
        if let prefersHints = legacyProfile.prefersHintsOverAutomation {
            prefersHintsOverAutomation = prefersHints
        }
        rollingNotes = legacyProfile.rollingNotes
        detectedMood = legacyProfile.detectedMood
    }

    // MARK: - Prompt sections for LLM

    var promptSection: String {
        var lines: [String] = []
        let learned = skillNodes.filter { $0.proficiencyLevel > .novice }
        if !learned.isEmpty {
            let summaries = learned.prefix(12).map { node in
                "\(node.skillName) (\(node.proficiencyLevel.displayName))"
            }
            lines.append("skills demonstrated: \(summaries.joined(separator: "; "))")
        }
        let struggling = skillNodes.filter { $0.confidenceScore < 0.3 && $0.proficiencyLevel > .novice }
        if !struggling.isEmpty {
            let summaries = struggling.prefix(6).map { $0.skillName }
            lines.append("still shaky on: \(summaries.joined(separator: "; "))")
        }
        if let prefersHintsOverAutomation {
            lines.append(
                prefersHintsOverAutomation
                    ? "prefers hints over you driving the tools"
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
        if currentStreakDays > 1 {
            lines.append("on a \(currentStreakDays)-day learning streak")
        }
        guard !lines.isEmpty else { return "" }
        return """

        LEARNER MODEL (durable — respect it):
        \(lines.joined(separator: "\n"))
        """
    }

    var globalPromptSection: String {
        let learned = skillNodes.filter { $0.proficiencyLevel >= .competent }
        let struggling = skillNodes.filter { $0.confidenceScore < 0.3 && $0.proficiencyLevel > .novice }
        var lines: [String] = []
        if !learned.isEmpty {
            let summaries = learned.prefix(8).map { "\($0.skillName) (\($0.proficiencyLevel.displayName))" }
            lines.append("already proficient from other contexts: \(summaries.joined(separator: "; "))")
        }
        if !struggling.isEmpty {
            let summaries = struggling.prefix(4).map { $0.skillName }
            lines.append("still shaky on from other contexts: \(summaries.joined(separator: "; "))")
        }
        guard !lines.isEmpty else { return "" }
        return """

        CROSS-COURSE MEMORY (carry this forward):
        \(lines.joined(separator: "\n"))
        """
    }
}
