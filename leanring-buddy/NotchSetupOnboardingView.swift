//
//  NotchSetupOnboardingView.swift
//  leanring-buddy
//
//  Setup / onboarding content for the notch panel — permissions, API key
//  setup, and the in-panel Teachy product tour.
//

import SwiftUI

struct NotchSetupOnboardingView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager

    @State private var apiKeyInput: String = ""
    @State private var apiKeyIsValidating: Bool = false
    @State private var apiKeyError: String?
    @State private var teachyOnboardingPageIndex: Int = 0
    // The Automation (Apple Events) permission can't be pre-granted — macOS only
    // prompts the moment Teachy first sends an Apple Event — so it isn't part of
    // `allPermissionsGranted`. This flag gates a one-time explainer stage that
    // would otherwise never appear: the instant the last required permission is
    // granted, the wizard branch below is yanked away by SwiftUI.
    @AppStorage("teachyHasSeenAutomationPermissionExplainer") private var hasSeenAutomationPermissionExplainer = false
    // Mirrors NotchPanelView's setup gate — set by "I'll set it up later" so
    // key-less users can continue to the tour and the app instead of being
    // re-trapped on the key screen. The Home tab's AI Brain section is the
    // add-a-key-later path.
    @AppStorage("teachyHasSkippedAPIKeySetup") private var hasSkippedAPIKeySetup = false
    @ObservedObject private var publikSession = TeachyPublikSession.shared

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !publikSession.isReady {
                PublikGateView(gate: publikSession.gate)
            } else if !companionManager.allPermissionsGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let's get set up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("I'll walk you through each permission — watch for the prompts.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PermissionChoreographyView(companionManager: companionManager)
            } else if !hasSeenAutomationPermissionExplainer {
                automationPermissionExplainer
            } else if publikSession.choice == "own_key" && !TeachyAPIKeyStore.isConfigured && !hasSkippedAPIKeySetup {
                apiKeySetupView
            } else if !companionManager.hasCompletedOnboarding {
                teachyProductOnboarding
            }
        }
    }

    private var apiKeySetupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One more thing")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("You chose your own key. Paste your OpenRouter API key — Teachy still picks the models for you. Get one at openrouter.ai.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("sk-or-v1-...", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(8)
                    .glassCard(cornerRadius: 8, tint: DS.Colors.learnAccent)
                    .onSubmit {
                        validateAndSaveAPIKey()
                    }

                if let error = apiKeyError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }

            Button {
                validateAndSaveAPIKey()
            } label: {
                HStack {
                    if apiKeyIsValidating {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text("Continue")
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
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKeyIsValidating)

            Button {
                // Skip for now — the tour still plays, and the Home tab's
                // AI Brain section is where they can add the key later.
                withAnimation(.smooth(duration: 0.22)) {
                    hasSkippedAPIKeySetup = true
                }
            } label: {
                Text("I'll set it up later")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                notchManager.makePanelKey()
            }
        }
    }

    private func validateAndSaveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        apiKeyIsValidating = true
        apiKeyError = nil

        Task {
            // Quick validation: hit OpenRouter with the key
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            request.timeoutInterval = 10
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    TeachyAPIKeyStore.apiKey = key
                    await MainActor.run {
                        apiKeyIsValidating = false
                    }
                } else {
                    await MainActor.run {
                        apiKeyIsValidating = false
                        apiKeyError = "That key doesn't seem valid. Check it and try again."
                    }
                }
            } catch {
                await MainActor.run {
                    apiKeyIsValidating = false
                    apiKeyError = "Couldn't reach OpenRouter. Check your connection."
                }
            }
        }
    }

    private var teachyProductOnboarding: some View {
        let pages = TeachyOnboardingPage.allCases
        let page = pages[teachyOnboardingPageIndex]
        let isLastPage = teachyOnboardingPageIndex == pages.count - 1
        let isWatchItPointPage = page == .watchItPoint

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: page.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.learnAccent)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(DS.Colors.learnAccent.opacity(0.16))
                    )

                Text(page.eyebrow)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.learnAccent)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer(minLength: 0)

                Text("\(teachyOnboardingPageIndex + 1) / \(pages.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(page.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .id("onboarding-title-\(page.rawValue)")
                .transition(.opacity.combined(with: .move(edge: .bottom)))

            Text(page.body)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .id("onboarding-body-\(page.rawValue)")
                .transition(.opacity)

            // The two pages about a held shortcut show the real keys, so the
            // tour matches whatever the person set (push-to-talk is customisable).
            if let shortcutKeyLabels = shortcutKeyLabels(for: page) {
                HStack(spacing: 6) {
                    Text("hold")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    ForEach(Array(shortcutKeyLabels.enumerated()), id: \.offset) { keyIndex, keyLabel in
                        if keyIndex > 0 {
                            Text("+")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        KeyboardKeyLabel(text: keyLabel)
                    }
                }
                .id("onboarding-keys-\(page.rawValue)")
                .transition(.opacity)
            }

            if !page.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(page.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(DS.Colors.learnAccent.opacity(0.85))
                                .frame(width: 4, height: 4)
                                .padding(.top, 4)
                            Text(bullet)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .id("onboarding-bullets-\(page.rawValue)")
                .transition(.opacity)
            }

            if page == .sayHi {
                sayHiOutLoudButton
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Capsule()
                        .fill(
                            index == teachyOnboardingPageIndex
                                ? DS.Colors.learnAccent
                                : Color.white.opacity(0.16)
                        )
                        .frame(
                            width: index == teachyOnboardingPageIndex ? 14 : 6,
                            height: 6
                        )
                        .animation(.easeInOut(duration: 0.18), value: teachyOnboardingPageIndex)
                }

                Spacer(minLength: 0)

                if teachyOnboardingPageIndex > 0 {
                    Button {
                        companionManager.playTeachyUISound(.pageAdvance)
                        withAnimation(.smooth(duration: 0.22)) {
                            teachyOnboardingPageIndex -= 1
                        }
                    } label: {
                        Text("back")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                if isWatchItPointPage && !companionManager.teachyScreenProofDidPlay {
                    Button {
                        companionManager.beginTeachyScreenProofDemo()
                        notchManager.collapse()
                    } label: {
                        Text("show me")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        advanceToPageAfterWatchItPoint()
                    } label: {
                        Text("skip")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else if isLastPage {
                    Button {
                        finishTeachyProductOnboardingOnHome()
                    } label: {
                        Text("let's go")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(DS.Colors.learnAccent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Button {
                        companionManager.playTeachyUISound(.pageAdvance)
                        withAnimation(.smooth(duration: 0.22)) {
                            teachyOnboardingPageIndex += 1
                        }
                    } label: {
                        Text("next")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if isLastPage {
                Button {
                    companionManager.triggerOnboarding()
                    notchManager.collapse()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 10))
                        Text("or watch the demo")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .animation(.smooth(duration: 0.22), value: teachyOnboardingPageIndex)
        .onAppear {
            companionManager.startOnboardingMusic()
        }
        .onChange(of: companionManager.teachyScreenProofDidPlay) { _, didPlay in
            guard didPlay, page == .watchItPoint else { return }
            // When they reopen after the live proof, carry on to the next beat.
            if notchManager.isExpanded {
                advanceToPageAfterWatchItPoint()
            }
        }
        .onChange(of: notchManager.isExpanded) { _, isExpanded in
            guard isExpanded,
                  companionManager.teachyScreenProofDidPlay,
                  teachyOnboardingPageIndex == TeachyOnboardingPage.watchItPoint.rawValue
            else { return }
            advanceToPageAfterWatchItPoint()
        }
    }

    /// Asks Teachy to greet the person out loud through the normal voice turn,
    /// so the very first thing they hear is the real voice, not a recording.
    private var sayHiOutLoudButton: some View {
        Button {
            companionManager.playTeachyUISound(.pageAdvance)
            companionManager.submitSyntheticCompanionRequest(
                "hi teachy! say hi back out loud in one short, warm sentence, and tell me one thing you can see on my screen right now."
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("say hi")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(DS.Colors.learnAccent)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Key labels to show under a page's body, or nil when the page isn't about a
    /// held shortcut. Push-to-talk reads the saved shortcut; dictation is fixed.
    private func shortcutKeyLabels(for page: TeachyOnboardingPage) -> [String]? {
        switch page {
        case .circleAndAsk:
            return PushToTalkShortcutKeys.currentKeyCapsuleLabels
        case .dictate:
            return ["fn", "control"]
        case .sayHi, .watchItPoint, .handItAJob:
            return nil
        }
    }

    private func advanceToPageAfterWatchItPoint() {
        companionManager.playTeachyUISound(.pageAdvance)
        withAnimation(.smooth(duration: 0.22)) {
            teachyOnboardingPageIndex = TeachyOnboardingPage.watchItPoint.rawValue + 1
        }
    }

    /// Ends the tour on Home, where the shortcut, memory and settings live.
    private func finishTeachyProductOnboardingOnHome() {
        companionManager.playTeachyUISound(.celebration)
        companionManager.completeTeachyProductOnboarding()
        notchManager.selectedTab = .home
    }

    /// One-time heads-up about macOS Automation (Apple Events) prompts. Shown
    /// after the permission choreography finishes because Automation can't be
    /// pre-granted — macOS only asks the first time Teachy sends an Apple Event
    /// to another app (managing tabs, opening/quitting apps).
    private var automationPermissionExplainer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One heads-up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Later, when Teachy opens apps or manages tabs for you, macOS will ask each time with a dialog like this — just click OK.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AutomationPromptMockView()

            Button {
                companionManager.playTeachyUISound(.pageAdvance)
                withAnimation(.smooth(duration: 0.22)) {
                    hasSeenAutomationPermissionExplainer = true
                }
            } label: {
                Text("Got it")
                    .font(.system(size: 12, weight: .semibold))
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

            Button {
                WindowPositionManager.openAutomationSettings()
            } label: {
                Text("Automation settings")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }
}

/// Animated mock of the macOS Automation consent dialog, with the OK button
/// gently pulsing so users know exactly which button to click when the real
/// dialog appears mid-task.
private struct AutomationPromptMockView: View {
    @State private var okButtonIsPulsing: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.warning)

                Text("\u{201C}Teachy\u{201D} wants access to control \u{201C}Safari\u{201D}.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)

                Text("Don't Allow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Text("OK")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.learnAccent))
                    .scaleEffect(okButtonIsPulsing ? 1.08 : 1.0)
                    .shadow(color: DS.Colors.learnAccent.opacity(okButtonIsPulsing ? 0.5 : 0.0), radius: 6)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: okButtonIsPulsing)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 10, tint: DS.Colors.learnAccent)
        .onAppear {
            okButtonIsPulsing = true
        }
    }
}

/// In-panel Teachy tour shown once after permissions are granted. Each page is
/// one thing Teachy does, in the order someone would try them.
private enum TeachyOnboardingPage: Int, CaseIterable {
    case sayHi
    case watchItPoint
    case circleAndAsk
    case dictate
    case handItAJob

    var eyebrow: String {
        switch self {
        case .sayHi: return "hi"
        case .watchItPoint: return "it sees your screen"
        case .circleAndAsk: return "ask anything"
        case .dictate: return "dictation"
        case .handItAJob: return "do it for me"
        }
    }

    var title: String {
        switch self {
        case .sayHi:
            return "finally do the thing"
        case .watchItPoint:
            return "watch it point"
        case .circleAndAsk:
            return "circle it, then ask"
        case .dictate:
            return "talk into any text box"
        case .handItAJob:
            return "or just hand it the job"
        }
    }

    var body: String {
        switch self {
        case .sayHi:
            return "from fl studio to claude code, jump into any tool and ask. teachy talks back, draws on your screen, and helps you through it, or does it for you."
        case .watchItPoint:
            return "teachy sees what you see. tap show me, the panel tucks away, and your cursor buddy flies to something real on your screen."
        case .circleAndAsk:
            return "while you hold the keys, circle the thing you mean with your mouse and ask. teachy answers out loud and points or draws right on top of it."
        case .dictate:
            return "click into a message, a prompt or a doc, hold the keys and talk. let go and the words land where your cursor is, cleaned up."
        case .handItAJob:
            return "say “do it for me” and teachy takes over: research, files, clicking through an app. it shows its plan and checks with you first."
        }
    }

    var bullets: [String] {
        switch self {
        case .sayHi:
            return [
                "works in any app on your mac",
                "it remembers you, and you can see and edit what it knows on home"
            ]
        case .watchItPoint:
            return []
        case .circleAndAsk:
            return [
                "“what's this knob do?” “why is this red?”",
                "ask it to draw it out when words aren't enough",
                "double-tap control to type instead"
            ]
        case .dictate:
            return [
                "double-tap to keep going hands-free"
            ]
        case .handItAJob:
            return [
                "it asks before anything risky",
                "press esc or grab the mouse to stop it anytime"
            ]
        }
    }

    var symbolName: String {
        switch self {
        case .sayHi: return "hand.wave.fill"
        case .watchItPoint: return "eye.fill"
        case .circleAndAsk: return "scribble.variable"
        case .dictate: return "mic.fill"
        case .handItAJob: return "wand.and.stars"
        }
    }
}
