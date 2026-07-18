//
//  NotchSetupOnboardingView.swift
//  leanring-buddy
//
//  Setup / onboarding content for the notch panel — permissions, API key
//  setup, and the in-panel Teachy product tour.
//

import AVFoundation
import SwiftUI

struct NotchSetupOnboardingView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager

    @State private var apiKeyInput: String = ""
    @State private var apiKeyIsValidating: Bool = false
    @State private var apiKeyError: String?
    @State private var teachyOnboardingPageIndex: Int = 0

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !companionManager.allPermissionsGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Almost ready")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Teachy needs a few permissions to see your screen and hear you.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                permissionsList
            } else if !TeachyAPIKeyStore.isConfigured {
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

                Text("Paste your OpenRouter API key so Teachy can talk to AI models. Get one free at openrouter.ai.")
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
                // Skip for now — they can set it later
                withAnimation {
                    companionManager.completeTeachyProductOnboarding()
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
                    Button {
                        finishTeachyProductOnboarding(startFirstWin: false)
                    } label: {
                        Text("Browse paths")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        companionManager.playTeachyUISound(.celebration)
                        finishTeachyProductOnboarding(startFirstWin: true)
                    } label: {
                        Text("Start First Win")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
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
        notchManager.selectedTab = .courses
        if startFirstWin {
            companionManager.startClickyCourse(courseID: "build-a-website")
            notchManager.collapse()
        }
    }

    private var permissionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 4) {
                permissionRow(label: "Microphone", icon: "mic", isGranted: companionManager.hasMicrophonePermission) {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }

                if companionManager.requiresSpeechRecognitionPermission {
                    speechRecognitionPermissionSection
                }

                accessibilityPermissionRow

                screenRecordingPermissionRow

                automationSystemSettingRow
            }
        }
    }

    /// Automation (Apple Events) lets Teachy natively control apps for you — open/quit
    /// apps, manage browser tabs. macOS grants this per-app on first use (you'll see
    /// "Teachy wants to control X" prompts), so this is an informational row that just
    /// points to the Automation settings pane rather than a live granted/not-granted
    /// toggle like the others.
    private var automationSystemSettingRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automation")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Lets Teachy open apps and manage tabs. Allow each prompt as it appears.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(action: {
                WindowPositionManager.openAutomationSettings()
            }) {
                Text("Settings")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    private var screenRecordingPermissionRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 11))
                    .foregroundColor(companionManager.hasScreenRecordingPermission ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 14)
                Text("Screen Recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            if companionManager.hasScreenRecordingPermission {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        WindowPositionManager.requestScreenRecordingPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        WindowPositionManager.fixScreenRecordingAfterRebuild()
                    }) {
                        Text("Fix")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var speechRecognitionPermissionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                label: "Speech Recognition",
                icon: "waveform",
                isGranted: companionManager.hasSpeechRecognitionPermission
            ) {
                WindowPositionManager.requestSpeechRecognitionPermission()
            }

            dictationSystemSettingRow

            if !companionManager.hasSpeechRecognitionPermission {
                Text("Tap Grant, then allow Teachy in the Speech Recognition list.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dictationSystemSettingRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("System setting — must be ON for voice input.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer()
            Button(action: {
                WindowPositionManager.openDictationSettings()
            }) {
                Text("Turn On")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    private var accessibilityPermissionRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11))
                    .foregroundColor(companionManager.hasAccessibilityPermission ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 14)
                Text("Accessibility")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            if companionManager.hasAccessibilityPermission {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func permissionRow(
        label: String,
        icon: String,
        isGranted: Bool,
        grantAction: @escaping () -> Void
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            if isGranted {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button(action: grantAction) {
                    Text("Grant")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
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
            return "Start with a tiny First Win"
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
            return "First Win takes about ten minutes and shows the whole loop. Or browse paths — AI, coding, GitHub, YouTube, and more."
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
