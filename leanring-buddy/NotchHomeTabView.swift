//
//  NotchHomeTabView.swift
//  leanring-buddy
//
//  Home tab content for the notch panel — push-to-talk instructions, trust
//  copy, software updates, cursor color, model picker, and feedback link.
//

import SwiftUI

struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared

    @State private var elevenLabsAPIKeyInput: String = ""
    @State private var elevenLabsIsValidating: Bool = false
    @State private var elevenLabsError: String?
    @State private var elevenLabsIsConfigured: Bool = TeachyElevenLabsKeyStore.isConfigured


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

            trustAndPrivacySection

            teachyRemembersSection

            softwareUpdatesSection

            PublikAccountSection()

            BrainMemorySection()

            voiceSection

            cursorColorSection

            watchIntroAgainButton

            dmFeedbackButton
        }
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

            Text("Double-tap Control for text mode.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var trustAndPrivacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trust & privacy")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Screen captures go to publik’s AI so the tutor can see what you’re doing — only for the turn you’re in. publik doesn’t train on them or keep them. Voice is transcribed on this Mac, and course memory stays here too. You can wipe progress anytime by Retaking a path.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("We don’t sell your screen.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.learnAccent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: DS.Colors.learnAccent)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Teachy \(softwareUpdater.shortVersionString) (\(softwareUpdater.buildNumberString)) — free updates via GitHub Releases.")
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Optional — use your own ElevenLabs key so Teachy speaks with its real voice. Get a key at elevenlabs.io (their pricing applies) — Teachy sounds great without one too.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if elevenLabsIsConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.learnAccent)
                    Text("Voice configured")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    Button {
                        TeachyElevenLabsKeyStore.apiKey = nil
                        elevenLabsAPIKeyInput = ""
                        elevenLabsError = nil
                        elevenLabsIsConfigured = false
                    } label: {
                        Text("Remove")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("ElevenLabs API key", text: $elevenLabsAPIKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(8)
                        .glassCard(cornerRadius: 8, tint: DS.Colors.learnAccent)
                        .onSubmit {
                            validateAndSaveElevenLabsKey()
                        }

                    if let error = elevenLabsError {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }

                Button {
                    validateAndSaveElevenLabsKey()
                } label: {
                    HStack {
                        if elevenLabsIsValidating {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Text("Save")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.Colors.learnAccent)
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(
                    elevenLabsAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || elevenLabsIsValidating
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func validateAndSaveElevenLabsKey() {
        let key = elevenLabsAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        elevenLabsIsValidating = true
        elevenLabsError = nil

        Task {
            // Validate against the REAL endpoint Teachy uses (text-to-speech), not a
            // side endpoint like /v1/voices or /v1/user. ElevenLabs keys can be scoped
            // to specific permissions at creation — a key restricted to "Text to Speech
            // only" is exactly what Teachy needs and is completely valid, but it 401s
            // on /v1/voices (missing voices_read) or /v1/user (missing user_read). This
            // sends a 1-character synthesis request so "validation passes" reliably
            // means "the actual feature will work," not just "some other scope exists."
            let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(TeachyElevenLabsKeyStore.voiceID)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": "Hi",
                "model_id": "eleven_turbo_v2_5",
            ])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    TeachyElevenLabsKeyStore.apiKey = key
                    await MainActor.run {
                        elevenLabsIsValidating = false
                        elevenLabsIsConfigured = true
                    }
                } else {
                    await MainActor.run {
                        elevenLabsIsValidating = false
                        elevenLabsError = Self.elevenLabsErrorMessage(from: data)
                    }
                }
            } catch {
                await MainActor.run {
                    elevenLabsIsValidating = false
                    elevenLabsError = "Couldn't reach ElevenLabs. Check your connection."
                }
            }
        }
    }

    /// ElevenLabs distinguishes an outright-invalid key from a valid key that's
    /// missing a required permission scope — surface that distinction instead of
    /// a generic "invalid key" message that sends people chasing the wrong fix.
    private static func elevenLabsErrorMessage(from responseData: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let detail = json["detail"] as? [String: Any],
            let status = detail["status"] as? String
        else {
            return "That key doesn't seem valid. Check it and try again."
        }
        if status == "missing_permissions" {
            return "That key is missing the Text to Speech permission — enable it in ElevenLabs → API Keys."
        }
        return "That key doesn't seem valid. Check it and try again."
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Cursor color")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

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
