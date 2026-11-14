//
//  NotchHomeTabView.swift
//  leanring-buddy
//
//  Home tab content for the notch panel: how to talk to Teachy, the publik
//  account, then settings as collapsed cards (voice, dictation, shortcuts,
//  cursor, memory, privacy, updates, advanced) and the feedback link.
//  The settings cards themselves live in Settings/SettingsSections.swift.
//

import SwiftUI

struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared
    @ObservedObject private var settings = TeachySettings.shared

    /// Flips locally the moment a reaction is tapped so the card disappears without
    /// needing to reopen the tab (the durable gate lives on `LearnerModel.lastRelationshipCheckInAt`).
    @State private var isCheckInDismissed: Bool = false
    /// Picked once per appearance (see `relationshipCheckInSection`'s `.onAppear`) so the
    /// templated line doesn't re-roll on every unrelated re-render of this view.
    @State private var cachedRelationshipCheckInLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            relationshipCheckInSection

            proactiveMomentsSection

            pushToTalkInstructions

            PublikAccountSection()

            settingsHeader

            VStack(alignment: .leading, spacing: 8) {
                VoiceSettingsSection()

                DictationSettingsSection()

                ShortcutsSettingsSection()

                cursorColorSection

                ConnectorsSection()

                // MOUNT: AgentJobsSection()

                PrivacySettingsSection()

                softwareUpdatesSection

                AdvancedSettingsSection()
            }

            BrainMemorySection()

            teachyRemembersSection

            watchIntroAgainButton

            dmFeedbackButton
        }
    }

    private var settingsHeader: some View {
        Text("SETTINGS")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.leading, 4)
            .padding(.top, 2)
            .padding(.bottom, -6)
    }

    /// Engine-computed wins and nudges (level-ups, retention reminders, celebrations)
    /// queued since the last chat. They also get offered to the coach's next spoken
    /// turn and are consumed there — this card is the visual mirror until that happens.
    @ViewBuilder
    private var proactiveMomentsSection: some View {
        if !companionManager.pendingProactiveMoments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.learnAccent)
                    Text("Since last time")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                ForEach(companionManager.pendingProactiveMoments, id: \.self) { momentText in
                    Text("· \(momentText)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: DS.Colors.learnAccent, prominent: true)
        }
    }

    private var pushToTalkInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Hold")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                KeyboardKeyLabel(text: "control")
                Text("+")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                KeyboardKeyLabel(text: "option")
                Text("to talk")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Text("Ask about your screen, or talk during a course for hints and help.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("While you hold the keys, move the pointer to circle the thing you mean.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("Double-tap")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                KeyboardKeyLabel(text: "control")
                Text("to type a question instead.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var teachyRemembersSection: some View {
        let learnerModel = companionManager.teachyEngine.getLearnerModel()
        let datedFacts = learnerModel.datedPersonalFacts

        // How long this learner has been using Teachy, shown as a header line
        // so there's always a visible signal that Teachy remembers across time.
        let totalDaysLearning = Calendar.current.dateComponents(
            [.day],
            from: learnerModel.createdAt,
            to: Date()
        ).day ?? 0
        let learningDurationLine: String? = totalDaysLearning >= 1
            ? "Learning with Teachy for \(totalDaysLearning) day\(totalDaysLearning == 1 ? "" : "s")"
            : nil

        return VStack(alignment: .leading, spacing: 8) {
            Text("Teachy remembers")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            if let durationLine = learningDurationLine {
                Text(durationLine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.learnAccent.opacity(0.8))
            }

            if datedFacts.isEmpty {
                Text("Nothing yet — the more you talk, the more Teachy remembers.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(datedFacts.suffix(6).reversed()), id: \.text) { fact in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(DS.Colors.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fact.text)
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(LearnerTemporalContext.relativeTimeLabel(for: fact.capturedAt))
                                    .font(.system(size: 9))
                                    .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Relationship check-in (outside any lesson)

    /// Shows only when there's actually a personal fact to reference AND it hasn't
    /// been shown (and reacted to) in the last 24 hours — avoids repeating the same
    /// callback every time someone opens the panel.
    private var shouldShowRelationshipCheckIn: Bool {
        guard !isCheckInDismissed else { return false }
        let learnerModel = companionManager.teachyEngine.getLearnerModel()
        guard !learnerModel.personalFacts.isEmpty else { return false }
        guard let lastCheckIn = learnerModel.lastRelationshipCheckInAt else { return true }
        return Date().timeIntervalSince(lastCheckIn) > 86400
    }

    /// A project that's been idle at least a day — the check-in card offers to
    /// resume it (project momentum beats small talk when both are available).
    private var staleResumableProject: TeachyProject? {
        companionManager.teachyEngine.activeProjects
            .filter { !$0.steps.isEmpty && Date().timeIntervalSince($0.lastWorkedAt) > 86400 }
            .sorted { $0.lastWorkedAt > $1.lastWorkedAt }
            .first
    }

    @ViewBuilder
    private var relationshipCheckInSection: some View {
        if let staleProject = staleResumableProject, !isCheckInDismissed {
            VStack(alignment: .leading, spacing: 10) {
                Text("Want to keep going on \(staleProject.title)? You're at step \(min(staleProject.currentStepIndex + 1, staleProject.steps.count)) of \(staleProject.steps.count).")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        isCheckInDismissed = true
                        companionManager.submitSyntheticCompanionRequest(
                            "Let's keep going on my project \"\(staleProject.title)\" — pick up where we left off."
                        )
                    } label: {
                        Text("Resume")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DS.Colors.learnAccent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        isCheckInDismissed = true
                    } label: {
                        Text("Not now")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: DS.Colors.learnAccent, prominent: true)
        } else if shouldShowRelationshipCheckIn {
            VStack(alignment: .leading, spacing: 10) {
                Text(cachedRelationshipCheckInLine ?? relationshipCheckInLine())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        companionManager.teachyEngine.recordRelationshipCheckInReaction(wasPositive: true)
                        isCheckInDismissed = true
                    } label: {
                        Image(systemName: "hand.thumbsup")
                    }
                    .dsIconButtonStyle(size: 28, tooltip: "Good update")

                    Button {
                        companionManager.teachyEngine.recordRelationshipCheckInReaction(wasPositive: false)
                        isCheckInDismissed = true
                    } label: {
                        Image(systemName: "hand.thumbsdown")
                    }
                    .dsIconButtonStyle(size: 28, isDestructiveOnHover: true, tooltip: "Not really")

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: DS.Colors.learnAccent, prominent: true)
            .onAppear {
                if cachedRelationshipCheckInLine == nil {
                    cachedRelationshipCheckInLine = relationshipCheckInLine()
                }
            }
        }
    }

    /// Templated callback line — no LLM call, same "simple heuristic over classifier"
    /// philosophy already used for humor/mood detection elsewhere in this codebase.
    /// Tone varies by `humorReceptivity` so repeat visits don't feel robotic.
    private func relationshipCheckInLine() -> String {
        let learnerModel = companionManager.teachyEngine.getLearnerModel()
        let recentFacts = Array(learnerModel.personalFacts.suffix(4))
        guard let fact = recentFacts.randomElement() ?? learnerModel.personalFacts.last else {
            return ""
        }
        switch learnerModel.humorReceptivity {
        case .warm:
            let templates = [
                "Ok but real talk — how's the \(fact) thing going?",
                "Still thinking about \(fact). Update me?",
            ]
            return templates.randomElement() ?? templates[0]
        case .efficient, .neutral, .none:
            let templates = [
                "Last time you mentioned \(fact) — how's that going?",
                "Quick one: any update on \(fact)?",
            ]
            return templates.randomElement() ?? templates[0]
        }
    }

    private var softwareUpdatesSection: some View {
        SettingsDisclosureCard(
            icon: "arrow.triangle.2.circlepath",
            title: "Updates",
            summary: "Teachy \(softwareUpdater.shortVersionString)"
        ) {
            Text("Teachy \(softwareUpdater.shortVersionString) (\(softwareUpdater.buildNumberString)). Updates are free and come from GitHub Releases.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                softwareUpdater.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Check for Updates…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!softwareUpdater.canCheckForUpdates)
            .opacity(softwareUpdater.canCheckForUpdates ? 1 : 0.45)
            .pointerCursor(isEnabled: softwareUpdater.canCheckForUpdates)
        }
    }

    private var watchIntroAgainButton: some View {
        Button {
            companionManager.replayOnboarding()
            notchManager.collapse()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 11))
                Text("Watch demo again")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var cursorColorSection: some View {
        SettingsDisclosureCard(
            icon: "cursorarrow",
            title: "Cursor",
            summary: companionManager.selectedCursorColor.rawValue.capitalized
        ) {
            Text("The colour of Teachy's pointer, and of the trail you draw while holding the talk keys.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(ClickyCursorColor.allCases) { cursorColor in
                    cursorColorOptionButton(cursorColor: cursorColor)
                }
            }
        }
    }

    private func cursorColorOptionButton(cursorColor: ClickyCursorColor) -> some View {
        let isSelected = companionManager.selectedCursorColor == cursorColor
        return Button(action: {
            companionManager.setSelectedCursorColor(cursorColor)
            // Same UserDefaults key; this keeps the settings object's copy current.
            settings.cursorColor = cursorColor
        }) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .overlay {
                    ZStack {
                        Triangle()
                            .fill(cursorColor.displayColor)
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-35))
                            .blur(radius: 12)
                            .opacity(isSelected ? 0.55 : 0.2)
                            .scaleEffect(1.8)

                        Triangle()
                            .fill(cursorColor.displayColor)
                            .frame(width: 14, height: 14)
                            .rotationEffect(.degrees(-35))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected ? cursorColor.displayColor : Color.white.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .shadow(
                    color: isSelected ? cursorColor.displayColor.opacity(0.35) : .clear,
                    radius: 8,
                    x: 0,
                    y: 2
                )
                .scaleEffect(isSelected ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var dmFeedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/VedSoni-dev/teachy/issues") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                Text("Give feedback")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
