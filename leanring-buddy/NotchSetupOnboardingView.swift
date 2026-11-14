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
        let isProofPage = page == .seeYourScreen

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
                        Text("Back")
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

                if isProofPage {
                    if companionManager.teachyScreenProofDidPlay {
                        Button {
                            companionManager.playTeachyUISound(.pageAdvance)
                            withAnimation(.smooth(duration: 0.22)) {
                                teachyOnboardingPageIndex = TeachyOnboardingPage.ready.rawValue
                            }
                        } label: {
                            Text("Continue")
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
                            companionManager.beginTeachyScreenProofDemo()
                            notchManager.collapse()
                        } label: {
                            Text("Show me")
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
                            companionManager.playTeachyUISound(.pageAdvance)
                            withAnimation(.smooth(duration: 0.22)) {
                                teachyOnboardingPageIndex = TeachyOnboardingPage.ready.rawValue
                            }
                        } label: {
                            Text("Skip")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                } else if isLastPage {
                    // Quiet secondary — browse the full catalog without a guided seed.
                    Button {
                        finishTeachyProductOnboarding(startFirstWin: false)
                    } label: {
                        Text("Browse paths")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
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
                        Text("Next")
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
                // Three tappable seeds — each completes onboarding, collapses the
                // panel, and hands a build-shaped request to the companion so the
                // [GUIDE:]/[PROJECT:] machinery takes over immediately.
                VStack(spacing: 6) {
                    firstShipSeedButton(
                        label: "A page for someone I love",
                        seedRequest: "I want to build my first ever website — a little page for someone I love — and actually put it online today. Walk me through the whole thing like I've never done this before."
                    )
                    firstShipSeedButton(
                        label: "A site for my work or side thing",
                        seedRequest: "I want to build my first website for my work or side project and get it live online today. Walk me through everything from scratch — I've never built a site before."
                    )
                    firstShipSeedButton(
                        label: "Surprise me",
                        seedRequest: "Pick something small and fun for my very first website and walk me through building it and putting it online today — I've never done this before, make it something I'll want to show people."
                    )
                }

                Button {
                    companionManager.triggerOnboarding()
                    notchManager.collapse()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 10))
                        Text("Or watch the full intro")
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
            guard didPlay, page == .seeYourScreen else { return }
            // When they reopen after the live proof, land them on the ready page.
            if notchManager.isExpanded {
                withAnimation(.smooth(duration: 0.22)) {
                    teachyOnboardingPageIndex = TeachyOnboardingPage.ready.rawValue
                }
            }
        }
        .onChange(of: notchManager.isExpanded) { _, isExpanded in
            guard isExpanded,
                  companionManager.teachyScreenProofDidPlay,
                  teachyOnboardingPageIndex == TeachyOnboardingPage.seeYourScreen.rawValue
            else { return }
            companionManager.playTeachyUISound(.pageAdvance)
            withAnimation(.smooth(duration: 0.22)) {
                teachyOnboardingPageIndex = TeachyOnboardingPage.ready.rawValue
            }
        }
    }

    private func finishTeachyProductOnboarding(startFirstWin: Bool) {
        companionManager.completeTeachyProductOnboarding()
        notchManager.selectedTab = .home
        if startFirstWin {
            notchManager.collapse()
        }
    }

    /// A full-width tappable seed button for the "What should your first ship be?"
    /// final onboarding page. Completes onboarding, collapses the panel, then
    /// fires a synthesized companion request so the build arc starts immediately.
    private func firstShipSeedButton(label: String, seedRequest: String) -> some View {
        Button {
            companionManager.playTeachyUISound(.celebration)
            companionManager.completeTeachyProductOnboarding()
            notchManager.collapse()
            companionManager.submitSyntheticCompanionRequest(seedRequest)
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DS.Colors.learnAccent)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
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

/// In-panel Teachy product tour shown once after permissions are granted.
private enum TeachyOnboardingPage: Int, CaseIterable {
    case welcome
    case howItWorks
    case howToLearn
    case seeYourScreen
    case ready

    var eyebrow: String {
        switch self {
        case .welcome: return "Welcome"
        case .howItWorks: return "How it works"
        case .howToLearn: return "How to learn"
        case .seeYourScreen: return "The magic beat"
        case .ready: return "You’re ready"
        }
    }

    var title: String {
        switch self {
        case .welcome:
            return "A free 1:1 tutor on your Mac"
        case .howItWorks:
            return "Learn by doing — on the real screen"
        case .howToLearn:
            return "Talk, watch it point, then do the step"
        case .seeYourScreen:
            return "I can see your screen"
        case .ready:
            return "What should your first ship be?"
        }
    }

    var body: String {
        switch self {
        case .welcome:
            return "Teachy lives in your menu bar notch. It’s not another playlist of tutorials — it’s a tutor that sits with you while you work."
        case .howItWorks:
            return "You pick a learning path. Teachy looks at your screen, points at the next real UI, coaches the move, and checks when you’re actually done."
        case .howToLearn:
            return "During a path, a lesson HUD shows the coach line plus Hint / Do it for me / I did it. Voice always works too."
        case .seeYourScreen:
            return "Same vibe as the intro — collapse Teachy, and your blue buddy will fly to something real on your desk."
        case .ready:
            return "Let's make something real that goes live today. Pick what you want to build and Teachy will walk you through the whole thing — code, deploy, live URL."
        }
    }

    var bullets: [String] {
        switch self {
        case .welcome:
            return [
                "Free by design — no subscription funnel",
                "Built to get you a real outcome, not watch-time"
            ]
        case .howItWorks:
            return [
                "Points at real buttons and windows on your Mac",
                "Advances only when the goal’s doneWhen looks true"
            ]
        case .howToLearn:
            return [
                "Hold Control + Option to talk anytime",
                "Ask for a hint, or say “do it for me” when stuck",
                "Say “I did it” when you’ve finished the step"
            ]
        case .seeYourScreen:
            return [
                "Hit Show me — music stays under, cursor does the proof",
                "Skip if you already felt the intro"
            ]
        case .ready:
            return []
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: return "sparkles"
        case .howItWorks: return "hand.point.up.left.fill"
        case .howToLearn: return "waveform"
        case .seeYourScreen: return "eye.fill"
        case .ready: return "flag.checkered"
        }
    }
}
