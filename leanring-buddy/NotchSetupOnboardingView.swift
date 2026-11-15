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

    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    /// Height of the copy on the longest tour page (headline, two lines of body,
    /// the keys and three hints).
    private let tourPageCopyMinimumHeight: CGFloat = 172

    /// Steps and tour pages swap on the standard spring, or a cross-fade when
    /// Reduce Motion is on.
    private var stepChangeAnimation: Animation {
        isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard
    }

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !publikSession.isReady {
                PublikGateView(gate: publikSession.gate)
            } else if !companionManager.allPermissionsGranted {
                PermissionChoreographyView(companionManager: companionManager)
            } else if !hasSeenAutomationPermissionExplainer {
                automationPermissionExplainer
            } else if publikSession.choice == "own_key" && !TeachyAPIKeyStore.isConfigured && !hasSkippedAPIKeySetup {
                apiKeySetupView
            } else if !companionManager.hasCompletedOnboarding {
                teachyProductOnboarding
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same inset as the Home tab, so setup and Home share one left edge.
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var apiKeySetupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            TeachySetupStepHeader(
                headline: "One more thing",
                explanation: "You chose your own key. Paste your OpenRouter API key: Teachy still picks the models for you. Get one at openrouter.ai."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    TextField("sk-or-v1-...", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.mono(12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .onSubmit {
                            validateAndSaveAPIKey()
                        }

                    HStack(spacing: 6) {
                        TeachyStatusMark(kind: apiKeyStateMarkKind)
                        Text(apiKeyStateWord)
                            .font(DS.Fonts.data)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .teachyWell()

                if let error = apiKeyError {
                    Text(error)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                Button("Continue") {
                    validateAndSaveAPIKey()
                }
                .teachyButton(.primary)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKeyIsValidating)

                Button("I'll set it up later") {
                    // Skip for now — the tour still plays, and the Home tab's
                    // AI Brain section is where they can add the key later.
                    withAnimation(stepChangeAnimation) {
                        hasSkippedAPIKeySetup = true
                    }
                }
                .teachyButton(.quiet)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                notchManager.makePanelKey()
            }
        }
    }

    /// The mark beside the key field: live while OpenRouter is checking the key,
    /// failed when the check did not pass, waiting until then.
    private var apiKeyStateMarkKind: TeachyStatusKind {
        if apiKeyIsValidating {
            return .live
        }
        return apiKeyError == nil ? .waiting : .failed
    }

    /// The word or two that goes with `apiKeyStateMarkKind`.
    private var apiKeyStateWord: String {
        if apiKeyIsValidating {
            return "Checking"
        }
        if apiKeyError != nil {
            return "Failed"
        }
        return apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No key yet" : "Not checked"
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

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                TeachySetupStepHeader(
                    headline: page.title,
                    explanation: page.body,
                    progressLabel: "\(page.eyebrow) \u{00B7} \(teachyOnboardingPageIndex + 1) of \(pages.count)",
                    symbolName: page.symbolName
                )

                // The two pages about a held shortcut show the real keys, so the
                // tour matches whatever the person set (push-to-talk is customisable).
                if let shortcutKeyLabels = shortcutKeyLabels(for: page) {
                    HStack(spacing: 4) {
                        Text("Hold")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.trailing, 2)
                        ForEach(Array(shortcutKeyLabels.enumerated()), id: \.offset) { _, keyLabel in
                            KeyboardKeyLabel(text: keyLabel)
                        }
                    }
                }

                if !page.hints.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(page.hints.enumerated()), id: \.offset) { _, hintPieces in
                            onboardingHintLine(hintPieces)
                        }
                    }
                }

                if page == .sayHi {
                    sayHiOutLoudButton
                }
            }
            // Every page is as tall as the longest one, so the buttons under it
            // stay where they are from page to page.
            .frame(maxWidth: .infinity, minHeight: tourPageCopyMinimumHeight, alignment: .topLeading)
            .id("onboarding-page-\(page.rawValue)")
            .transition(.opacity)

            HStack(spacing: 6) {
                if isWatchItPointPage && !companionManager.teachyScreenProofDidPlay {
                    Button("Show me") {
                        companionManager.beginTeachyScreenProofDemo()
                        notchManager.collapse()
                    }
                    .teachyButton(.primary)

                    Button("Skip") {
                        advanceToPageAfterWatchItPoint()
                    }
                    .teachyButton(.quiet)
                } else if isLastPage {
                    Button("Let's go") {
                        finishTeachyProductOnboardingOnHome()
                    }
                    .teachyButton(.primary)
                } else {
                    Button("Next") {
                        companionManager.playTeachyUISound(.pageAdvance)
                        withAnimation(stepChangeAnimation) {
                            teachyOnboardingPageIndex += 1
                        }
                    }
                    .teachyButton(.primary)
                }

                if teachyOnboardingPageIndex > 0 {
                    Button("Back") {
                        companionManager.playTeachyUISound(.pageAdvance)
                        withAnimation(stepChangeAnimation) {
                            teachyOnboardingPageIndex -= 1
                        }
                    }
                    .teachyButton(.quiet)
                }

                Spacer(minLength: 0)

                if isLastPage {
                    Button("Or watch the demo") {
                        companionManager.triggerOnboarding()
                        notchManager.collapse()
                    }
                    .teachyLinkButton()
                }
            }
        }
        .animation(stepChangeAnimation, value: teachyOnboardingPageIndex)
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

    /// One short line under a tour page. A key named in the line is drawn as a
    /// key cap; the rest is plain words.
    private func onboardingHintLine(_ hintPieces: [TeachyOnboardingHintPiece]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2013}")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                ForEach(Array(hintPieces.enumerated()), id: \.offset) { _, hintPiece in
                    switch hintPiece {
                    case .words(let words):
                        Text(words)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .key(let keyLabel):
                        KeyboardKeyLabel(text: keyLabel)
                    }
                }
            }
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
                Text("Say hi")
            }
        }
        .teachyButton(.secondary, size: .compact)
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
        withAnimation(stepChangeAnimation) {
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
        VStack(alignment: .leading, spacing: 14) {
            TeachySetupStepHeader(
                headline: "One heads-up",
                explanation: "Later, when Teachy opens apps or manages tabs for you, macOS will ask each time with a dialog like this. Just click OK."
            )

            AutomationPromptMockView()

            HStack(spacing: 12) {
                Button("Got it") {
                    companionManager.playTeachyUISound(.pageAdvance)
                    withAnimation(stepChangeAnimation) {
                        hasSeenAutomationPermissionExplainer = true
                    }
                }
                .teachyButton(.primary)

                Button("Automation settings") {
                    WindowPositionManager.openAutomationSettings()
                }
                .teachyLinkButton()
            }
        }
    }
}

/// The top of every setup step: one headline, with the step count beside it
/// when the step is one of several, and one line of explanation under it.
struct TeachySetupStepHeader: View {
    let headline: String
    let explanation: String
    /// A short fact for the trailing edge of the headline, like "2 of 4".
    var progressLabel: String? = nil
    /// An SF Symbol drawn before the headline, in the tint.
    var symbolName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(DS.Fonts.sans(18, weight: .semibold))
                        .foregroundColor(DS.Colors.pointer)
                }

                Text(headline)
                    .font(DS.Fonts.display)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 3)

                if let progressLabel {
                    Text(progressLabel)
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Text(explanation)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Mock of the macOS Automation consent dialog, with OK marked as the chosen
/// answer so users know exactly which button to click when the real dialog
/// appears mid-task. It is a picture, so nothing in it can be clicked.
private struct AutomationPromptMockView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                TeachyAppIconStandIn()

                Text("\u{201C}Teachy\u{201D} wants access to control \u{201C}Safari\u{201D}.")
                    .font(DS.Fonts.bodyEmphasized)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)

                mockDialogAnswer("Don't Allow", isTheOneToClick: false)
                mockDialogAnswer("OK", isTheOneToClick: true)
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .teachyWell()
        .allowsHitTesting(false)
    }

    private func mockDialogAnswer(_ answerTitle: String, isTheOneToClick: Bool) -> some View {
        Text(answerTitle)
            .font(DS.Fonts.controlCompact)
            .foregroundColor(isTheOneToClick ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 24)
            // Half the height, so the answers are capsules like the buttons of a macOS dialog.
            .teachyOption(isSelected: isTheOneToClick, cornerRadius: 12)
    }
}

/// One piece of a hint line under a tour page.
private enum TeachyOnboardingHintPiece {
    /// Plain words.
    case words(String)
    /// The name of a key, drawn as a key cap.
    case key(String)
}

/// In-panel Teachy tour shown once after permissions are granted. Each page is
/// one thing Teachy does, in the order someone would try them.
private enum TeachyOnboardingPage: Int, CaseIterable {
    case sayHi
    case watchItPoint
    case circleAndAsk
    case dictate
    case handItAJob

    /// A short label for the page, shown beside the page count.
    var eyebrow: String {
        switch self {
        case .sayHi: return "Hi"
        case .watchItPoint: return "It sees your screen"
        case .circleAndAsk: return "Ask anything"
        case .dictate: return "Dictation"
        case .handItAJob: return "Do it for me"
        }
    }

    var title: String {
        switch self {
        case .sayHi:
            return "Finally do the thing"
        case .watchItPoint:
            return "Watch it point"
        case .circleAndAsk:
            return "Circle it, then ask"
        case .dictate:
            return "Talk into any text box"
        case .handItAJob:
            return "Or just hand it the job"
        }
    }

    var body: String {
        switch self {
        case .sayHi:
            return "From FL Studio to Claude Code, jump into any tool and ask. Teachy talks back, draws on your screen, and helps you through it, or does it for you."
        case .watchItPoint:
            return "Teachy sees what you see. Tap Show me, the panel tucks away, and your cursor buddy flies to something real on your screen."
        case .circleAndAsk:
            return "While you hold the keys, circle the thing you mean with your mouse and ask. Teachy answers out loud and points or draws right on top of it."
        case .dictate:
            return "Click into a message, a prompt or a doc, hold the keys and talk. Let go and the words land where your cursor is, cleaned up."
        case .handItAJob:
            return "Say \u{201C}do it for me\u{201D} and Teachy takes over: research, files, clicking through an app. It shows its plan and checks with you first."
        }
    }

    /// Short lines under the body. Each is a list of pieces so a key named in
    /// the line can be drawn as a key cap.
    var hints: [[TeachyOnboardingHintPiece]] {
        switch self {
        case .sayHi:
            return [
                [.words("Works in any app on your Mac")],
                [.words("It remembers you, and you can see and edit what it knows on Home")]
            ]
        case .watchItPoint:
            return []
        case .circleAndAsk:
            return [
                [.words("\u{201C}What's this knob do?\u{201D} \u{201C}Why is this red?\u{201D}")],
                [.words("Ask it to draw it out when words aren't enough")],
                [.words("Double-tap"), .key("control"), .words("to type instead")]
            ]
        case .dictate:
            return [
                [.words("Double-tap to keep going hands-free")]
            ]
        case .handItAJob:
            return [
                [.words("It asks before anything risky")],
                [.words("Press"), .key("esc"), .words("or grab the mouse to stop it anytime")]
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
