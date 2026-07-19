//
//  CoachAutonomy.swift
//  leanring-buddy
//
//  Derived (never stored) autonomy transfer. Teachy measurably does LESS as the
//  learner levels up — the anti-dependency mechanic. A `CoachAutonomyLevel` is
//  computed purely from the learner's skill-node proficiency; nothing here is
//  persisted, so there are no Codable/CodingKeys changes anywhere.
//
//  The sacred invariant across every consumer of this level: autonomy only ever
//  TIGHTENS defaults (Teachy volunteers to act less). It never loosens an
//  author's restrictive policy, and it never refuses an explicit spoken
//  "do it for me" — that path always still works.
//

import Foundation

// MARK: - Autonomy level

/// How much of the mechanical work Teachy does versus the learner, derived from
/// measured skill. Ordered from most hand-holding to fully hands-off.
///
/// `Comparable` by declaration order — mirrors `ProficiencyLevel`'s pattern so
/// callers can write `autonomy >= .watchThem` naturally.
enum CoachAutonomyLevel: String, Codable, Comparable, CaseIterable {
    /// novice/beginner — Teachy handles the mechanical steps for them.
    case doForThem
    /// competent — Teachy narrates while they drive, acts only when stuck.
    case doTogether
    /// proficient — they drive, Teachy verifies and hints.
    case watchThem
    /// expert — Teachy only speaks when asked.
    case handsOff

    static func < (lhs: CoachAutonomyLevel, rhs: CoachAutonomyLevel) -> Bool {
        let order: [CoachAutonomyLevel] = [.doForThem, .doTogether, .watchThem, .handsOff]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    /// Short human phrase for the Skills tab, framed as the point of the product.
    var graduationPhrase: String {
        switch self {
        case .doForThem:
            return "Getting you started — Teachy handles the mechanical setup for now."
        case .doTogether:
            return "Driving together — Teachy narrates while you do it, and steps in when you're stuck."
        case .watchThem:
            return "Watching you drive — Teachy does less as you level up. That's the point."
        case .handsOff:
            return "Hands off — you've got this. Teachy only steps in when you ask."
        }
    }
}

// MARK: - Derivation

/// Pure functions that derive an autonomy level from a learner model. No stored
/// state, no persistence — recompute on demand wherever the level is needed.
enum CoachAutonomy {
    /// Overall autonomy from the learner's skill nodes in the given domains (or all
    /// domains when `domains` is empty). Uses the MEDIAN proficiency of the relevant
    /// skills so a single outlier skill can't swing the whole level.
    ///
    /// Threshold mapping (simple and explainable):
    /// - novice / beginner  → `.doForThem`
    /// - competent          → `.doTogether`
    /// - proficient         → `.watchThem`
    /// - expert             → `.handsOff`
    ///
    /// No skills recorded at all (or none in the requested domains) → `.doForThem`,
    /// because a brand-new learner should get the most hand-holding by default.
    static func level(for model: LearnerModel, inDomains domains: [String] = []) -> CoachAutonomyLevel {
        let relevantSkills: [LearnerSkillNode]
        if domains.isEmpty {
            relevantSkills = model.skillNodes
        } else {
            let requestedDomains = Set(domains)
            relevantSkills = model.skillNodes.filter { requestedDomains.contains($0.domain) }
        }

        guard !relevantSkills.isEmpty else { return .doForThem }

        let medianProficiency = medianProficiencyLevel(of: relevantSkills)
        return autonomyLevel(forProficiency: medianProficiency)
    }

    /// One-line prompt guidance per level. Injected into both the course coach prompt
    /// and the guided-task prompt so the model's *tone and volunteering* match the
    /// autonomy level, on top of the harder tool-policy / execution-mode tightening
    /// enforced in code.
    static func promptGuidance(for level: CoachAutonomyLevel) -> String {
        switch level {
        case .doForThem:
            return "AUTONOMY: this learner is new here — handle the mechanical setup for them, then teach what you did so they learn."
        case .doTogether:
            return "AUTONOMY: this learner can drive with narration — talk them through it and act only when they're clearly stuck."
        case .watchThem:
            return "AUTONOMY: this learner drives their own setup now — verify and hint, don't reach for the tools yourself unless they explicitly ask you to do it for them."
        case .handsOff:
            return "AUTONOMY: this learner is fluent here — stay quiet unless asked, then answer tightly. Don't volunteer to do things for them."
        }
    }

    // MARK: - Helpers

    /// The median proficiency level of a non-empty skill set. Sorts by the
    /// `ProficiencyLevel` ordering and picks the middle element (lower-middle for an
    /// even count) so one very high or very low skill can't swing the result.
    private static func medianProficiencyLevel(of skills: [LearnerSkillNode]) -> ProficiencyLevel {
        let sortedLevels = skills.map(\.proficiencyLevel).sorted()
        // Non-empty is guaranteed by the caller; the lower-middle index is safe.
        let middleIndex = (sortedLevels.count - 1) / 2
        return sortedLevels[middleIndex]
    }

    /// Maps a single proficiency level to its autonomy level. Kept as its own
    /// function so the level-up transition detection in `TeachyEngine` and the
    /// median-based `level(for:)` above share exactly one mapping.
    static func autonomyLevel(forProficiency proficiency: ProficiencyLevel) -> CoachAutonomyLevel {
        switch proficiency {
        case .novice, .beginner:
            return .doForThem
        case .competent:
            return .doTogether
        case .proficient:
            return .watchThem
        case .expert:
            return .handsOff
        }
    }
}
