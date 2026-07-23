//
//  NotchProgressTabView.swift
//  leanring-buddy
//
//  Progress tab — a dead-simple per-learner tracker: their streak, what they've
//  built, skills learned, current course, recent moments, and one "next up"
//  nudge. Everything reads existing engine state (no gbrain, no receipts) so it
//  reflects exactly what this learner has actually done.
//

import SwiftUI

struct NotchProgressTabView: View {
    @ObservedObject var companionManager: CompanionManager

    /// The Progress tab's single accent — the friendly green that reads as
    /// "growing," distinct from Skills (purple) and Portfolio (orange).
    private let accent = DS.Colors.success

    @ViewBuilder
    var body: some View {
        let engine = companionManager.teachyEngine
        let learnerModel = engine.getLearnerModel()
        let coursesManager = companionManager.coursesManager
        let portfolio = engine.portfolioManager

        let skillsLearned = learnerModel.skillNodes.filter { $0.proficiencyLevel > .novice }.count
        let thingsBuilt = portfolio.items.count
        let streakDays = learnerModel.currentStreakDays
        let hasAnyProgress = skillsLearned > 0
            || thingsBuilt > 0
            || streakDays > 0
            || coursesManager.isCourseActive

        VStack(alignment: .leading, spacing: 14) {
            progressHeader

            if !hasAnyProgress {
                emptyProgressCard
            } else {
                statsHeroCard(streakDays: streakDays, thingsBuilt: thingsBuilt, skillsLearned: skillsLearned)

                if let activeSession = coursesManager.activeSession {
                    currentCourseCard(session: activeSession, coursesManager: coursesManager)
                }

                let moments = recentMoments(learnerModel: learnerModel, portfolio: portfolio)
                if !moments.isEmpty {
                    recentSection(moments: moments)
                }

                if let nudge = nextUpNudge(coursesManager: coursesManager, learnerModel: learnerModel, engine: engine) {
                    nextUpCard(nudge: nudge)
                }
            }
        }
    }

    // MARK: - Header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Progress")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Everything you've built and learned, at a glance.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var emptyProgressCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.5))

            Text("Your progress starts with your first course")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Text("Once you begin learning, your streak, the things you build, and the skills you pick up all show up here.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(tint: accent)
    }

    // MARK: - Stats hero (streak · built · skills)

    private func statsHeroCard(streakDays: Int, thingsBuilt: Int, skillsLearned: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.orange)
                    Text("\(streakDays)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                }
                Text("day streak")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Divider().frame(height: 34).background(Color.white.opacity(0.08))

            statColumn(value: thingsBuilt, label: "things built", tint: DS.Colors.textPrimary)

            statColumn(value: skillsLearned, label: "skills learned", tint: accent)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: accent, prominent: true)
    }

    private func statColumn(value: Int, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Current course

    private func currentCourseCard(session: ClickyCourseSession, coursesManager: CoursesManager) -> some View {
        let totalSteps = session.course.goals.count
        let completedSteps = coursesManager.progress(forCourseID: session.course.id)?.completedStepCount
            ?? session.currentStepIndex
        let fraction = totalSteps > 0 ? min(1.0, Double(completedSteps) / Double(totalSteps)) : 0
        let percent = Int((fraction * 100).rounded())

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current course")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .textCase(.uppercase)
                    Text(session.course.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text("\(percent)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(accent)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 7)
                    Capsule()
                        .fill(accent)
                        .frame(width: geometry.size.width * fraction, height: 7)
                }
            }
            .frame(height: 7)
        }
        .padding(14)
        .glassCard(tint: accent)
    }

    // MARK: - Recent moments

    private func recentSection(moments: [ProgressMoment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            ForEach(moments) { moment in
                HStack(spacing: 10) {
                    Image(systemName: moment.iconName)
                        .font(.system(size: 12))
                        .foregroundColor(moment.tint)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(moment.tint.opacity(0.14))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        (
                            Text(moment.title).font(.system(size: 12, weight: .semibold))
                                + Text("  \(moment.subtitle)").font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                        )
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(moment.date, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
        }
        .padding(14)
        .glassCard(tint: accent)
    }

    // MARK: - Next up

    private func nextUpCard(nudge: NextUpNudge) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(accent.opacity(0.25), lineWidth: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text("Next up · \(nudge.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = nudge.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accent)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 1)
                )
        )
    }

    // MARK: - Data derivation

    /// A single recent-activity line — a real dated moment from what the learner
    /// has done (shipped an artifact, explained a skill).
    private struct ProgressMoment: Identifiable {
        let id = UUID()
        let iconName: String
        let tint: Color
        let title: String
        let subtitle: String
        let date: Date
    }

    private struct NextUpNudge {
        let title: String
        let subtitle: String?
    }

    /// The learner's three most recent dated moments, newest first — merged from
    /// shipped artifacts and teach-backs. Never fabricated: an empty history
    /// simply hides the section.
    private func recentMoments(learnerModel: LearnerModel, portfolio: PortfolioManager) -> [ProgressMoment] {
        var moments: [ProgressMoment] = []

        for item in portfolio.items {
            moments.append(ProgressMoment(
                iconName: "paperplane.fill",
                tint: accent,
                title: "Shipped",
                subtitle: item.title,
                date: item.createdAt
            ))
        }

        for demo in learnerModel.teachingDemos {
            let skillName = learnerModel.skillNode(byID: demo.skillID)?.skillName
                ?? demo.skillID.replacingOccurrences(of: "-", with: " ")
            moments.append(ProgressMoment(
                iconName: "bubble.left.and.bubble.right",
                tint: DS.Colors.skillsAccent,
                title: "Explained",
                subtitle: skillName,
                date: demo.recordedAt
            ))
        }

        return Array(moments.sorted { $0.date > $1.date }.prefix(3))
    }

    /// One actionable "what's next": the current course step when a course is
    /// active, otherwise the graph's suggested next skill. Nil hides the nudge.
    private func nextUpNudge(coursesManager: CoursesManager, learnerModel: LearnerModel, engine: TeachyEngine) -> NextUpNudge? {
        if let activeSession = coursesManager.activeSession {
            return NextUpNudge(
                title: activeSession.currentStep.title,
                subtitle: "keep going in \(activeSession.course.title)"
            )
        }
        if let suggestedSkill = engine.state.skillGraph.suggestedNextSkills(for: learnerModel).first {
            return NextUpNudge(title: "Try \(suggestedSkill.name)", subtitle: suggestedSkill.description)
        }
        return nil
    }
}
