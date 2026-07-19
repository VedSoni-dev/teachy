//
//  NotchPortfolioTabView.swift
//  leanring-buddy
//
//  Portfolio tab content for the notch panel — shareable artifacts captured
//  from completed course goals.
//

import SwiftUI

struct NotchPortfolioTabView: View {
    @ObservedObject var companionManager: CompanionManager

    @ViewBuilder
    var body: some View {
        let portfolio = companionManager.teachyEngine.portfolioManager

        VStack(alignment: .leading, spacing: 14) {
            portfolioHeader

            if portfolio.items.isEmpty {
                emptyPortfolioCard
            } else {
                portfolioSummaryCard(portfolio: portfolio)

                ForEach(portfolio.recentItems(limit: 10)) { item in
                    portfolioItemCard(item: item)
                }

                if portfolio.items.count > 10 {
                    Text("\(portfolio.items.count) items total")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var portfolioHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Portfolio")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("What you've built and learned — real artifacts, not practice reps.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var emptyPortfolioCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.5))

            Text("Your portfolio is empty")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Complete course goals to start building your portfolio. Each verified achievement creates a shareable artifact.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(tint: DS.Colors.portfolioAccent)
    }

    private func portfolioSummaryCard(portfolio: PortfolioManager) -> some View {
        let summary = portfolio.summary

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary?.totalItems ?? 0)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("artifacts")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary?.skillsDemonstrated.count ?? 0)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("skills")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary?.totalCoursesCompleted ?? 0)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("courses")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                if let avgScore = summary?.averageQualityScore, avgScore > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(avgScore * 100))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(DS.Colors.portfolioAccent)
                        Text("quality")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            if let topSkills = summary?.topSkills, !topSkills.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.08))

                Text("Top skills")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                FlowLayout(spacing: 6) {
                    ForEach(topSkills, id: \.self) { skill in
                        Text(skill.replacingOccurrences(of: "-", with: " "))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.portfolioAccent.opacity(0.15))
                            )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: DS.Colors.portfolioAccent, prominent: true)
    }

    private func portfolioItemCard(item: PortfolioItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.portfolioAccent)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                if let score = item.qualityScore {
                    Text("\(Int(score * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(DS.Colors.portfolioAccent)
                }
            }

            Text(item.description)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !item.skillsUsed.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.skillsUsed.prefix(3), id: \.self) { skill in
                        Text(skill.replacingOccurrences(of: "-", with: " "))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    if item.skillsUsed.count > 3 {
                        Text("+\(item.skillsUsed.count - 3)")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            HStack {
                Text(item.createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                // Live artifact link — populated by shipped projects (v2).
                if let artifactURL = item.artifactURL, let liveURL = URL(string: artifactURL) {
                    Button {
                        NSWorkspace.shared.open(liveURL)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Live")
                                .font(.system(size: 9, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundColor(DS.Colors.success)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                if item.shareable {
                    Button {
                        copyShareText(for: item)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 9))
                            Text("Share")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(DS.Colors.portfolioAccent)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 12, tint: DS.Colors.portfolioAccent)
    }

    /// Puts a ready-to-send brag on the clipboard. The live artifact URL is the
    /// star when there is one; the Teachy share URL rides along as attribution.
    private func copyShareText(for item: PortfolioItem) {
        let shareCard = companionManager.teachyEngine.portfolioManager.generateShareCard(
            for: item,
            learnerName: "",
            courseTitle: item.courseID == "project" ? "a Teachy project" : item.courseID
        )
        var shareLines = ["I built this: \(item.title)"]
        if let artifactURL = item.artifactURL, !artifactURL.isEmpty {
            shareLines.append(artifactURL)
        }
        if let shareCard {
            shareLines.append("(made with Teachy — \(shareCard.shareURL))")
        }
        let shareText = shareLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareText, forType: .string)
        print("📋 Share text copied for portfolio item: \(item.title)")
    }
}
