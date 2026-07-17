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

// MARK: - Humor receptivity

/// Lightweight read on what lands — same heuristic spirit as detectedMood,
/// but tracking receptiveness to humor/banter specifically rather than
/// moment-to-moment frustration/engagement.
enum HumorReceptivity: String, Codable, Equatable {
    case warm       // jokes back, seems to enjoy banter
    case neutral    // no strong signal either way
    case efficient  // short/all-business responses — wants to move fast, keep humor light/rare
}

// MARK: - Timestamped personal fact

/// A personal fact about the learner — their job, interests, things they've
/// mentioned — with the date it was captured. Replaces the old flat `[String]`
/// so the coaching prompt can say "you mentioned X two days ago."
struct TimestampedFact: Codable, Equatable {
    var text: String
    var capturedAt: Date
}

// MARK: - Dated signal (evolving personality trend)

/// A value recorded at a specific point in time. Used to build a short dated
/// history of `humorReceptivity` and `detectedMood` so the coach can detect
/// trends ("they've warmed up over recent sessions") rather than only seeing
/// the latest single overwrite.
struct DatedSignal<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value
    var at: Date
}

// MARK: - Learner model

/// The complete persistent model of a learner. Carries knowledge across all
/// courses, tracks proficiency over time, and powers spaced repetition.
/// This is the "persistent learner memory" that makes Teachy un-copyable.
///
/// Codable notes:
/// - `datedPersonalFacts` is the canonical storage for personal facts.
/// - `personalFacts` is a computed accessor over `datedPersonalFacts` so all
///   existing readers (prompt injection, UI, relationship check-in) continue
///   working without changes.
/// - Old `engine-state.json` files that have a flat `personalFacts: [String]`
///   and no `datedPersonalFacts` are migrated transparently in `init(from:)`.
struct LearnerModel: Codable, Equatable {
    var skillNodes: [LearnerSkillNode]
    var teachingDemos: [TeachingDemo]
    var rollingNotes: [String]
    /// Dated personal facts — canonical storage. Use `personalFacts` to read as
    /// plain strings (all existing readers do this via the computed accessor below).
    var datedPersonalFacts: [TimestampedFact]
    /// Lightweight read on what lands — see `HumorReceptivity`. Kept as the
    /// single-value "latest" for all existing readers; `humorReceptivityHistory`
    /// accumulates the dated trail for trend analysis.
    var humorReceptivity: HumorReceptivity?
    /// Short dated history of humor-receptivity readings. Trimmed to last 12 entries.
    /// Used by `LearnerTemporalContext` to derive trend phrases for the coaching prompt.
    var humorReceptivityHistory: [DatedSignal<HumorReceptivity>]
    /// Latest detected mood string. Kept for all existing readers; `moodHistory`
    /// accumulates the dated trail.
    var detectedMood: String?
    /// Short dated history of mood detections. Trimmed to last 12 entries.
    var moodHistory: [DatedSignal<String>]
    /// Last time the outside-lesson relationship check-in card (Home tab) was shown
    /// and reacted to — gates re-showing it (see `TeachyEngine.recordRelationshipCheckInReaction`).
    var lastRelationshipCheckInAt: Date?
    var prefersHintsOverAutomation: Bool?
    var totalCoursesCompleted: Int
    var totalGoalsCompleted: Int
    var totalSessionMinutes: Int
    var currentStreakDays: Int
    var longestStreakDays: Int
    var lastActiveDate: Date?
    var portfolioItemCount: Int
    var createdAt: Date
    var updatedAt: Date

    /// Computed accessor over `datedPersonalFacts` — returns plain text strings.
    /// All existing callers (prompt builders, UI, relationship check-in card) use
    /// this so they keep working without modification.
    var personalFacts: [String] {
        datedPersonalFacts.map(\.text)
    }

    init() {
        self.skillNodes = []
        self.teachingDemos = []
        self.rollingNotes = []
        self.datedPersonalFacts = []
        self.humorReceptivityHistory = []
        self.moodHistory = []
        self.totalCoursesCompleted = 0
        self.totalGoalsCompleted = 0
        self.totalSessionMinutes = 0
        self.currentStreakDays = 0
        self.longestStreakDays = 0
        self.portfolioItemCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Custom Codable (backward-compat migration)

    /// Custom coding keys — `personalFacts` is no longer a stored property, so it
    /// must NOT appear as a case here. `datedPersonalFacts` is the stored key.
    /// All other fields mirror the struct properties exactly.
    enum CodingKeys: String, CodingKey {
        case skillNodes
        case teachingDemos
        case rollingNotes
        case datedPersonalFacts
        case humorReceptivity
        case humorReceptivityHistory
        case detectedMood
        case moodHistory
        case lastRelationshipCheckInAt
        case prefersHintsOverAutomation
        case totalCoursesCompleted
        case totalGoalsCompleted
        case totalSessionMinutes
        case currentStreakDays
        case longestStreakDays
        case lastActiveDate
        case portfolioItemCount
        case createdAt
        case updatedAt
    }

    /// Decodes from persisted JSON. If `datedPersonalFacts` is absent (old format),
    /// migrates the legacy flat `personalFacts: [String]` array by wrapping each
    /// string into a `TimestampedFact` with `capturedAt = createdAt` (or `Date()`
    /// when `createdAt` is also absent). All other fields have plain `decodeIfPresent`
    /// calls so they default gracefully when absent in older JSON.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        skillNodes = try container.decodeIfPresent([LearnerSkillNode].self, forKey: .skillNodes) ?? []
        teachingDemos = try container.decodeIfPresent([TeachingDemo].self, forKey: .teachingDemos) ?? []
        rollingNotes = try container.decodeIfPresent([String].self, forKey: .rollingNotes) ?? []
        humorReceptivity = try container.decodeIfPresent(HumorReceptivity.self, forKey: .humorReceptivity)
        humorReceptivityHistory = try container.decodeIfPresent([DatedSignal<HumorReceptivity>].self, forKey: .humorReceptivityHistory) ?? []
        detectedMood = try container.decodeIfPresent(String.self, forKey: .detectedMood)
        moodHistory = try container.decodeIfPresent([DatedSignal<String>].self, forKey: .moodHistory) ?? []
        lastRelationshipCheckInAt = try container.decodeIfPresent(Date.self, forKey: .lastRelationshipCheckInAt)
        prefersHintsOverAutomation = try container.decodeIfPresent(Bool.self, forKey: .prefersHintsOverAutomation)
        totalCoursesCompleted = try container.decodeIfPresent(Int.self, forKey: .totalCoursesCompleted) ?? 0
        totalGoalsCompleted = try container.decodeIfPresent(Int.self, forKey: .totalGoalsCompleted) ?? 0
        totalSessionMinutes = try container.decodeIfPresent(Int.self, forKey: .totalSessionMinutes) ?? 0
        currentStreakDays = try container.decodeIfPresent(Int.self, forKey: .currentStreakDays) ?? 0
        longestStreakDays = try container.decodeIfPresent(Int.self, forKey: .longestStreakDays) ?? 0
        lastActiveDate = try container.decodeIfPresent(Date.self, forKey: .lastActiveDate)
        portfolioItemCount = try container.decodeIfPresent(Int.self, forKey: .portfolioItemCount) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // Migration: decode `datedPersonalFacts` if present (new format), otherwise
        // fall back to the legacy `personalFacts: [String]` key. The legacy key is
        // NOT in `CodingKeys` because it conflicts with the computed accessor's name,
        // so we re-open the raw container to read the legacy key directly.
        if let dated = try container.decodeIfPresent([TimestampedFact].self, forKey: .datedPersonalFacts) {
            datedPersonalFacts = dated
        } else {
            // Legacy flat array — wrap each string with a date anchored to `createdAt`
            // so "2 days ago" timestamps are plausible rather than all "just now".
            let legacyFactsContainer = try decoder.container(keyedBy: LegacyPersonalFactsCodingKey.self)
            let legacyStrings = try legacyFactsContainer.decodeIfPresent([String].self, forKey: .personalFacts) ?? []
            let migrationDate = createdAt
            datedPersonalFacts = legacyStrings.map { factText in
                TimestampedFact(text: factText, capturedAt: migrationDate)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skillNodes, forKey: .skillNodes)
        try container.encode(teachingDemos, forKey: .teachingDemos)
        try container.encode(rollingNotes, forKey: .rollingNotes)
        try container.encode(datedPersonalFacts, forKey: .datedPersonalFacts)
        try container.encodeIfPresent(humorReceptivity, forKey: .humorReceptivity)
        try container.encode(humorReceptivityHistory, forKey: .humorReceptivityHistory)
        try container.encodeIfPresent(detectedMood, forKey: .detectedMood)
        try container.encode(moodHistory, forKey: .moodHistory)
        try container.encodeIfPresent(lastRelationshipCheckInAt, forKey: .lastRelationshipCheckInAt)
        try container.encodeIfPresent(prefersHintsOverAutomation, forKey: .prefersHintsOverAutomation)
        try container.encode(totalCoursesCompleted, forKey: .totalCoursesCompleted)
        try container.encode(totalGoalsCompleted, forKey: .totalGoalsCompleted)
        try container.encode(totalSessionMinutes, forKey: .totalSessionMinutes)
        try container.encode(currentStreakDays, forKey: .currentStreakDays)
        try container.encode(longestStreakDays, forKey: .longestStreakDays)
        try container.encodeIfPresent(lastActiveDate, forKey: .lastActiveDate)
        try container.encode(portfolioItemCount, forKey: .portfolioItemCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Separate coding key enum for the legacy `personalFacts: [String]` key.
    /// Because `personalFacts` is now a computed property on `LearnerModel`,
    /// we cannot add it to the primary `CodingKeys` enum. This secondary enum
    /// lets the migration path in `init(from:)` re-open the decoder container
    /// to read the old key without conflicting with the computed accessor's name.
    private enum LegacyPersonalFactsCodingKey: String, CodingKey {
        case personalFacts
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

        let newMood: String?
        if wordCount <= 3 && (lower.contains("idk") || lower.contains("i don't know") || lower.contains("no idea") || lower.contains("confused") || lower.contains("lost")) {
            newMood = "frustrated"
        } else if wordCount <= 2 && (lower == "ok" || lower == "done" || lower == "yes" || lower == "yep" || lower == "sure" || lower == "k") {
            newMood = "bored"
        } else if wordCount >= 6 || lower.contains("?") {
            newMood = "engaged"
        } else if lower.contains("maybe") || lower.contains("i think") || lower.contains("not sure") {
            newMood = "confused"
        } else {
            newMood = nil
        }

        if let mood = newMood {
            detectedMood = mood
            // Also record in the dated history for trend analysis.
            moodHistory.append(DatedSignal(value: mood, at: Date()))
            moodHistory = Array(moodHistory.suffix(12))
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

    // MARK: - Personal facts & humor

    mutating func appendPersonalFact(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedupe against existing facts (case-insensitive, using the computed accessor).
        let alreadyKnown = personalFacts.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !alreadyKnown else { return }
        datedPersonalFacts.append(TimestampedFact(text: trimmed, capturedAt: Date()))
        // Keep at most 20 facts — trim from the oldest end.
        datedPersonalFacts = Array(datedPersonalFacts.suffix(20))
        updatedAt = Date()
    }

    mutating func updateHumorReceptivity(_ value: HumorReceptivity) {
        humorReceptivity = value
        // Also record in the dated history so trend analysis works across sessions.
        humorReceptivityHistory.append(DatedSignal(value: value, at: Date()))
        humorReceptivityHistory = Array(humorReceptivityHistory.suffix(12))
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
        if let mood = legacyProfile.detectedMood {
            detectedMood = mood
            moodHistory.append(DatedSignal(value: mood, at: createdAt))
        }
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
