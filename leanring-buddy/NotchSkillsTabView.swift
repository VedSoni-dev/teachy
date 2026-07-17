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

                if !dueReviews.isEmpty {
                    retentionReviewCard(reviews: dueReviews)
                }

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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: DS.Colors.skillsAccent, prominent: true)
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
}
