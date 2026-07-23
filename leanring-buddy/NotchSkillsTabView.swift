//
//  NotchSkillsTabView.swift
//  leanring-buddy
//
//  Skills tab content for the notch panel — learner model proficiency,
//  retention review, at-risk skills, domain breakdown, and streaks.
//

import SwiftUI

struct NotchSkillsTabView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Skills whose evidence trail is currently expanded in the "proof behind
    /// your skills" section. Local UI state only — nothing persisted.
    @State private var expandedSkillIDs: Set<String> = []

    @ViewBuilder
    var body: some View {
        let learnerModel = companionManager.teachyEngine.getLearnerModel()
        let skillGraph = companionManager.teachyEngine.state.skillGraph
        let dueReviews = companionManager.teachyEngine.getDueRetentionChecks()
        let atRiskSkills = companionManager.teachyEngine.getAtRiskSkills()

        VStack(alignment: .leading, spacing: 14) {
            skillsHeader

            if learnerModel.skillNodes.isEmpty {
                emptySkillsCard
            } else {
                skillsSummaryCard(learnerModel: learnerModel)

                evidenceBehindSkillsSection(learnerModel: learnerModel)

                if !dueReviews.isEmpty {
                    retentionReviewCard(reviews: dueReviews)
                }

                retentionStrengthSection(learnerModel: learnerModel)

                if !atRiskSkills.isEmpty {
                    atRiskSkillsCard(skills: atRiskSkills)
                }

                skillsByDomainSection(learnerModel: learnerModel, skillGraph: skillGraph)

                suggestedNextSkillsSection(learnerModel: learnerModel, skillGraph: skillGraph)

                streakCard(learnerModel: learnerModel)
            }
        }
    }

    private var skillsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Skills")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Track your AI fluency across domains. Skills grow with verification and practice.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var emptySkillsCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.5))

            Text("No skills tracked yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Complete course goals and your skills will appear here, tracked across proficiency levels.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(tint: DS.Colors.skillsAccent)
    }

    private func skillsSummaryCard(learnerModel: LearnerModel) -> some View {
        let learned = learnerModel.skillNodes.filter { $0.proficiencyLevel > .novice }
        let proficient = learnerModel.skillNodes.filter { $0.proficiencyLevel >= .proficient }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(learned.count)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("skills learned")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(proficient.count)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.skillsAccent)
                    Text("proficient+")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(learnerModel.totalSkillsLearned)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("total")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            // Autonomy transfer — the point of the product made visible: Teachy does
            // less for you as you level up. Derived (never stored) from proficiency.
            autonomyRow(learnerModel: learnerModel)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: DS.Colors.skillsAccent, prominent: true)
    }

    private func autonomyRow(learnerModel: LearnerModel) -> some View {
        let autonomyLevel = CoachAutonomy.level(for: learnerModel)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.skillsAccent)
                .padding(.top, 1)
            Text("Coach autonomy: \(autonomyLevel.graduationPhrase)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func retentionReviewCard(reviews: [RetentionCheck]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.skillsAccent)
                Text("Due for Review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("\(reviews.count) skill\(reviews.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            ForEach(reviews.prefix(3)) { review in
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.skillName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(review.questionText)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.skillsAccent.opacity(0.08))
                )
            }

            if reviews.count > 3 {
                Text("+\(reviews.count - 3) more")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .glassCard(tint: DS.Colors.skillsAccent)
    }

    /// Per-skill forgetting-curve strength, sorted weakest first. Uses
    /// `SpacedRepetitionEngine.retentionProbability` (SM-2 forgetting curve
    /// already computed from `lastPracticedAt` + `confidenceScore` — no new
    /// storage, just a read of existing state at "now").
    private func retentionStrengthSection(learnerModel: LearnerModel) -> some View {
        let now = Date()
        let weakestSkillsFirst = learnerModel.skillNodes
            .filter { $0.proficiencyLevel > .novice }
            .map { skill in (skill: skill, retention: SpacedRepetitionEngine.retentionProbability(for: skill, at: now)) }
            .sorted { $0.retention < $1.retention }
            .prefix(6)

        guard !weakestSkillsFirst.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.skillsAccent)
                    Text("Retention Strength")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text("weakest first")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                ForEach(Array(weakestSkillsFirst), id: \.skill.id) { entry in
                    retentionStrengthRow(skill: entry.skill, retention: entry.retention)
                }
            }
            .padding(14)
            .glassCard(tint: DS.Colors.skillsAccent)
        )
    }

    private func retentionStrengthRow(skill: LearnerSkillNode, retention: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(skill.skillName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                if skill.isDueForReview {
                    Text("review now")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                }

                Text("\(Int(retention * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)
                    Capsule()
                        .fill(DS.Colors.skillsAccent)
                        .frame(width: geometry.size.width * retention, height: 3)
                }
            }
            .frame(height: 3)
        }
    }

    private func atRiskSkillsCard(skills: [LearnerSkillNode]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.warning)
                Text("At Risk of Forgetting")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            ForEach(skills.prefix(4)) { skill in
                HStack {
                    Text(skill.skillName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    if let days = skill.daysSinceLastVerified {
                        Text("\(days)d ago")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.warning)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(tint: DS.Colors.warning)
    }

    private func skillsByDomainSection(learnerModel: LearnerModel, skillGraph: SkillGraph) -> some View {
        let domains = BundledSkillGraph.domains

        return VStack(alignment: .leading, spacing: 10) {
            Text("Skills by Domain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            ForEach(domains, id: \.self) { domain in
                let domainSkills = learnerModel.skills(inDomain: domain)
                let graphNodes = skillGraph.nodes(inDomain: domain)
                let learnedCount = domainSkills.filter { $0.proficiencyLevel > .novice }.count

                if !graphNodes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(BundledSkillGraph.domainDisplayName(domain))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Text("\(learnedCount)/\(graphNodes.count)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(DS.Colors.textTertiary)
                        }

                        GeometryReader { geometry in
                            let progress = graphNodes.isEmpty ? 0.0 : Double(learnedCount) / Double(graphNodes.count)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DS.Colors.skillsAccent)
                                    .frame(width: geometry.size.width * progress, height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(14)
        .glassCard()
    }

    private func suggestedNextSkillsSection(learnerModel: LearnerModel, skillGraph: SkillGraph) -> some View {
        let suggested = skillGraph.suggestedNextSkills(for: learnerModel)

        guard !suggested.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.info)
                    Text("Suggested Next")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                ForEach(suggested.prefix(4)) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(skill.description)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DS.Colors.info.opacity(0.06))
                    )
                }
            }
            .padding(14)
            .glassCard(tint: DS.Colors.info)
        )
    }

    private func streakCard(learnerModel: LearnerModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "flame")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                Text("Learning Streak")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(learnerModel.currentStreakDays)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                    Text("current days")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(learnerModel.longestStreakDays)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("longest streak")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()
            }
        }
        .padding(14)
        .glassCard(tint: DS.Colors.skillsAccent, prominent: true)
    }

    // MARK: - Proof behind your skills (the "show it to a person" surface)

    /// The core MyChart surface: each skill the learner has actually learned,
    /// expandable to the captured moments that earned its level — teach-backs,
    /// verifications, spaced-review recalls, real-world contexts. Reads only
    /// existing `LearnerModel` state, so it works today; when the gbrain record
    /// lands (learner-brain/README.md) these moments become tap-through links to
    /// the actual teachback/review pages.
    @ViewBuilder
    private func evidenceBehindSkillsSection(learnerModel: LearnerModel) -> some View {
        let learnedSkills = learnerModel.skillNodes
            .filter { $0.proficiencyLevel > .novice }
            .sorted { lhs, rhs in
                if lhs.proficiencyLevel != rhs.proficiencyLevel {
                    return lhs.proficiencyLevel > rhs.proficiencyLevel
                }
                return (lhs.lastVerifiedAt ?? lhs.firstLearnedAt) > (rhs.lastVerifiedAt ?? rhs.firstLearnedAt)
            }

        if !learnedSkills.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.skillsAccent)
                    Text("Proof Behind Your Skills")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                Text("Every level here is backed by a moment you can point to — not a number we assigned you.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(learnedSkills) { skill in
                    evidenceSkillRow(skill: skill, moments: evidenceMoments(for: skill, in: learnerModel))
                }
            }
            .padding(14)
            .glassCard(tint: DS.Colors.skillsAccent)
        }
    }

    private func evidenceSkillRow(skill: LearnerSkillNode, moments: [SkillEvidenceMoment]) -> some View {
        let isExpanded = expandedSkillIDs.contains(skill.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedSkillIDs.remove(skill.id)
                    } else {
                        expandedSkillIDs.insert(skill.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(skill.skillName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 6)

                    Text(skill.proficiencyLevel.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.skillsAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(DS.Colors.skillsAccent.opacity(0.14))
                        )

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(moments) { moment in
                        evidenceMomentRow(moment: moment)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.skillsAccent.opacity(0.06))
        )
    }

    private func evidenceMomentRow(moment: SkillEvidenceMoment) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: moment.iconName)
                .font(.system(size: 9))
                .foregroundColor(moment.tint)
                .frame(width: 12)
                .padding(.top, 1)

            Text(moment.text)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)

            if let dateLabel = moment.dateLabel {
                Text(dateLabel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Evidence extraction

    /// A single captured moment behind a skill — the atomic unit of "proof."
    private struct SkillEvidenceMoment: Identifiable {
        let id = UUID()
        let iconName: String
        let text: String
        let date: Date?
        let tint: Color

        var dateLabel: String? {
            guard let date else { return nil }
            return NotchSkillsTabView.evidenceDateFormatter.string(from: date)
        }
    }

    private static let evidenceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// Gather every real moment behind a skill from existing learner state,
    /// dated moments in chronological order and undated evidence (contexts,
    /// level-up reasons) after them. Falls back to an honest "no captured
    /// moment yet" line for skills leveled up without a recorded artifact.
    private func evidenceMoments(for skill: LearnerSkillNode, in learnerModel: LearnerModel) -> [SkillEvidenceMoment] {
        var moments: [SkillEvidenceMoment] = []

        // Teach-backs — the strongest evidence: the learner explaining it.
        let teachBacks = learnerModel.teachingDemos
            .filter { $0.skillID == skill.id }
            .sorted { $0.recordedAt < $1.recordedAt }
        for teachBack in teachBacks {
            let qualitySuffix = teachBack.qualityScore > 0
                ? " · \(Int((teachBack.qualityScore * 100).rounded()))% clear"
                : ""
            moments.append(SkillEvidenceMoment(
                iconName: "bubble.left.and.bubble.right",
                text: "Taught it back in your own words\(qualitySuffix)",
                date: teachBack.recordedAt,
                tint: DS.Colors.skillsAccent
            ))
        }

        // Vision / verifier confirmation of a done-when.
        if let lastVerifiedAt = skill.lastVerifiedAt {
            moments.append(SkillEvidenceMoment(
                iconName: "checkmark.seal.fill",
                text: "Verified by Teachy",
                date: lastVerifiedAt,
                tint: DS.Colors.success
            ))
        }

        // Spaced-repetition recall — remembered it unaided, later.
        if skill.reviewCount > 0 {
            moments.append(SkillEvidenceMoment(
                iconName: "arrow.clockwise",
                text: "Recalled in \(skill.reviewCount) spaced review\(skill.reviewCount == 1 ? "" : "s")",
                date: skill.lastPracticedAt,
                tint: DS.Colors.skillsAccent
            ))
        }

        // Dated moments chronological; undated evidence appended after.
        moments.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }

        // Where the skill was actually applied.
        let recentContexts = skill.contextsUsed.suffix(3)
        if !recentContexts.isEmpty {
            moments.append(SkillEvidenceMoment(
                iconName: "hammer",
                text: "Applied while building: \(recentContexts.joined(separator: ", "))",
                date: nil,
                tint: DS.Colors.textTertiary
            ))
        }

        // Why it leveled up (verified reasons only ever level a skill up).
        for reason in skill.successNotes.suffix(2).reversed() {
            moments.append(SkillEvidenceMoment(
                iconName: "arrow.up.forward",
                text: reason,
                date: nil,
                tint: DS.Colors.textTertiary
            ))
        }

        // Honest fallback: a learned skill with no captured artifact yet
        // (e.g. imported/seeded). Never fabricate a moment.
        if moments.isEmpty {
            moments.append(SkillEvidenceMoment(
                iconName: "sparkles",
                text: "Proven while building — no single captured moment recorded yet.",
                date: nil,
                tint: DS.Colors.textTertiary
            ))
        }

        return moments
    }
}
