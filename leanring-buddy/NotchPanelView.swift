//
//  NotchPanelView.swift
//  leanring-buddy
//
//  Expanded notch body (Courses / Home). Agents UI is retained but hidden —
//  teaching stays the primary product. Shell lives in ClickyNotchRootView.
//

import AVFoundation
import SwiftUI

enum NotchPanelTab: String, CaseIterable {
    case home
    case courses
    case agents
}

struct NotchPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared
    @State private var courseInstallURLText: String = ""
    @State private var teachyOnboardingPageIndex: Int = 0
    @State private var courseQuestionText: String = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tabContent
                    .id(notchManager.selectedTab)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity
                        )
                    )
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .animation(.smooth(duration: 0.28), value: notchManager.selectedTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var needsSetup: Bool {
        !companionManager.allPermissionsGranted || !companionManager.hasCompletedOnboarding
    }

    @ViewBuilder
    private var tabContent: some View {
        // Permissions + intro must show even when Courses is the default tab.
        if needsSetup {
            setupContent
        } else {
            switch notchManager.selectedTab {
            case .home:
                activeHomeContent
            case .courses:
                coursesTabContent
            case .agents:
                coursesTabContent
            }
        }
    }

    // MARK: - Home Tab

    private var activeHomeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            pushToTalkInstructions

            trustAndPrivacySection

            softwareUpdatesSection

            cursorColorSection

            modeAndModelSection

            watchIntroAgainButton

            dmFeedbackButton
        }
    }

    private var pushToTalkInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Hold")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textPrimary)

                KeyboardKeyLabel(text: "control")
                Text("+")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
                KeyboardKeyLabel(text: "option")
                Text("to talk")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textPrimary)
            }

            Text("Ask about your screen, or talk during a course for hints and help.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Double-tap Control for text mode.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private var trustAndPrivacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trust & privacy")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(NotchPanelColors.textPrimary)

            Text("Teachy is free by design. Screen captures and voice go to your configured Teachy proxy so the tutor can see what you’re doing — only for the turn you’re in. Course memory stays on this Mac. You can wipe progress anytime by Retaking a path.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("We don’t sell your screen. No subscription funnel.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(NotchPanelColors.courseAccent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NotchPanelColors.courseAccent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(NotchPanelColors.courseAccent.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private var softwareUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(NotchPanelColors.textPrimary)

            Text("Teachy \(softwareUpdater.shortVersionString) (\(softwareUpdater.buildNumberString)) — free updates via GitHub Releases.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
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
                .foregroundColor(NotchPanelColors.textPrimary)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
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
            .foregroundColor(NotchPanelColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var cursorColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cursor color")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NotchPanelColors.textSecondary)

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
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isSelected)
    }

    private var modeAndModelSection: some View {
        openRouterModelPickerRow(
            title: "Tutor model",
            models: OpenRouterModelOption.models,
            selectedModelID: companionManager.selectedModel
        ) { modelID in
            companionManager.setSelectedModel(modelID)
        }
    }

    private func openRouterModelPickerRow(
        title: String,
        models: [OpenRouterModelOption],
        selectedModelID: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let selectedOption = models.first(where: { $0.id == selectedModelID }) ?? models[0]

        return HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NotchPanelColors.textSecondary)
            Spacer()
            Menu {
                ForEach(models) { model in
                    Button(action: { onSelect(model.id) }) {
                        HStack {
                            Text(model.displayName)
                            if model.id == selectedModelID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(selectedOption.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(NotchPanelColors.textPrimary)
                        Text(selectedOption.subtitle)
                            .font(.system(size: 9))
                            .foregroundColor(NotchPanelColors.textTertiary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .pointerCursor()
        }
    }

    private func segmentedControl<T: Equatable>(
        options: [(String, T)],
        selectedValue: T,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.1 == selectedValue
                Button(action: { onSelect(option.1) }) {
                    Text(option.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSelected ? NotchPanelColors.textPrimary : NotchPanelColors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Setup / Onboarding

    @ViewBuilder
    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !companionManager.allPermissionsGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Almost ready")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(NotchPanelColors.textPrimary)

                    Text("Teachy needs a few permissions to see your screen and hear you.")
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                permissionsList
            } else if !companionManager.hasCompletedOnboarding {
                teachyProductOnboarding
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
                    .foregroundColor(NotchPanelColors.courseAccent)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(NotchPanelColors.courseAccent.opacity(0.16))
                    )

                Text(page.eyebrow)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(NotchPanelColors.courseAccent)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer(minLength: 0)

                Text("\(teachyOnboardingPageIndex + 1) / \(pages.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(NotchPanelColors.textTertiary)
            }

            Text(page.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(NotchPanelColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .id("onboarding-title-\(page.rawValue)")
                .transition(.opacity.combined(with: .move(edge: .bottom)))

            Text(page.body)
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .id("onboarding-body-\(page.rawValue)")
                .transition(.opacity)

            if !page.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(page.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(NotchPanelColors.courseAccent.opacity(0.85))
                                .frame(width: 4, height: 4)
                                .padding(.top, 4)
                            Text(bullet)
                                .font(.system(size: 11))
                                .foregroundColor(NotchPanelColors.textSecondary)
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
                                ? NotchPanelColors.courseAccent
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
                            .foregroundColor(NotchPanelColors.textSecondary)
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
                                    Capsule().fill(NotchPanelColors.courseAccent)
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
                                    Capsule().fill(NotchPanelColors.accentBlue)
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
                                .foregroundColor(NotchPanelColors.textTertiary)
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
                            .foregroundColor(NotchPanelColors.textPrimary)
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
                                Capsule().fill(NotchPanelColors.courseAccent)
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
                                Capsule().fill(NotchPanelColors.accentBlue)
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
                    .foregroundColor(NotchPanelColors.textTertiary)
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
            companionManager.startClickyCourse(courseID: "ai-first-win")
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
            }
        }
    }

    private var screenRecordingPermissionRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 11))
                    .foregroundColor(companionManager.hasScreenRecordingPermission ? NotchPanelColors.textTertiary : .orange)
                    .frame(width: 14)
                Text("Screen Recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
            }
            Spacer()
            if companionManager.hasScreenRecordingPermission {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
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
                            .background(Capsule().fill(NotchPanelColors.accentBlue))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        WindowPositionManager.fixScreenRecordingAfterRebuild()
                    }) {
                        Text("Fix")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(NotchPanelColors.textSecondary)
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
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dictationSystemSettingRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(NotchPanelColors.textSecondary)
                    Text("System setting — must be ON for voice input.")
                        .font(.system(size: 10))
                        .foregroundColor(NotchPanelColors.textTertiary)
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
                    .background(Capsule().fill(NotchPanelColors.accentBlue))
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
                    .foregroundColor(companionManager.hasAccessibilityPermission ? NotchPanelColors.textTertiary : .orange)
                    .frame(width: 14)
                Text("Accessibility")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
            }
            Spacer()
            if companionManager.hasAccessibilityPermission {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
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
                            .background(Capsule().fill(NotchPanelColors.accentBlue))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(NotchPanelColors.textSecondary)
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
                    .foregroundColor(isGranted ? NotchPanelColors.textTertiary : .orange)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
            }
            Spacer()
            if isGranted {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
            } else {
                Button(action: grantAction) {
                    Text("Grant")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(NotchPanelColors.accentBlue))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Courses Tab

    @ViewBuilder
    private var coursesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !companionManager.isBackendReachable {
                backendOfflineBanner
            }

            if let activeSession = companionManager.coursesManager.activeSession {
                activeCourseSessionCard(session: activeSession)
            } else {
                if let celebration = companionManager.coursesManager.completionCelebration {
                    courseCompletionCard(celebration)
                }
                coursesCatalogIntroduction
                if let continueCourse = companionManager.coursesManager.continueCourse {
                    continueLearningCard(course: continueCourse)
                }
                coursesCatalogList

                if companionManager.coursesManager.preferSimplifiedCatalog {
                    Button {
                        companionManager.coursesManager.setPreferSimplifiedCatalog(false)
                    } label: {
                        Text("Show all paths")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(NotchPanelColors.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .onAppear {
            companionManager.refreshBackendReachability()
        }
    }

    private func courseCompletionCard(_ celebration: CourseCompletionCelebration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(NotchPanelColors.courseAccent)
                Text("You finished")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPanelColors.courseAccent)
                Spacer()
                Button {
                    companionManager.coursesManager.dismissCompletionCelebration()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Text(celebration.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(NotchPanelColors.textPrimary)

            Text(celebration.message)
                .font(.system(size: 12))
                .foregroundColor(NotchPanelColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if celebration.courseID == "ai-first-win" {
                Button {
                    companionManager.coursesManager.dismissCompletionCelebration()
                    companionManager.startClickyCourse(courseID: "ai-to-code")
                    notchManager.collapse()
                } label: {
                    Text("Start Use AI to Code")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(NotchPanelColors.courseAccent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NotchPanelColors.courseAccent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NotchPanelColors.courseAccent.opacity(0.35), lineWidth: 1)
        )
    }

    private func continueLearningCard(course: ClickyCourse) -> some View {
        let resumeIndex = companionManager.coursesManager.resumeStepIndex(for: course)
        let label = resumeIndex > 0 ? "Continue" : "Start"

        return Button {
            companionManager.startClickyCourse(courseID: course.id)
            notchManager.collapse()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: course.iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(NotchPanelColors.courseAccent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(NotchPanelColors.courseAccent.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue learning")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.courseAccent)
                    Text(course.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(NotchPanelColors.textPrimary)
                    Text(
                        resumeIndex > 0
                            ? "Goal \(resumeIndex + 1) of \(course.stepCount)"
                            : "~\(course.estimatedMinutes) min · \(course.stepCount) goals"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(NotchPanelColors.textTertiary)
                }

                Spacer()

                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(NotchPanelColors.courseAccent))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(NotchPanelColors.courseAccent.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var academyInstallSection: some View {
        let coursesManager = companionManager.coursesManager

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Teachy Academy")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(NotchPanelColors.textPrimary)
                Spacer()
                Button("Open site") {
                    companionManager.openTeachyAcademyWebsite()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NotchPanelColors.accentBlue)
                .pointerCursor()
            }

            Text("Paste a course JSON URL (GitHub or raw). Free packs install into \(TeachyDataPaths.coursesDirectoryDisplayPath)/")
                .font(.system(size: 10))
                .foregroundColor(NotchPanelColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://github.com/…/course.json", text: $courseInstallURLText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                Button {
                    let urlString = courseInstallURLText
                    companionManager.installCourseFromURL(urlString)
                } label: {
                    if coursesManager.isInstallingCourse {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 52, height: 28)
                    } else {
                        Text("Add")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(NotchPanelColors.accentBlue))
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(
                    coursesManager.isInstallingCourse
                        || courseInstallURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let status = coursesManager.courseInstallStatusMessage, !status.isEmpty {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var academyFeaturedSection: some View {
        let coursesManager = companionManager.coursesManager
        if let registry = coursesManager.academyRegistry, !registry.courses.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("From the wall")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NotchPanelColors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.3)
                    if coursesManager.isLoadingAcademyRegistry {
                        ProgressView().scaleEffect(0.5)
                    }
                }

                ForEach(registry.courses.prefix(4)) { featured in
                    academyFeaturedRow(featured)
                }
            }
        } else if coursesManager.isLoadingAcademyRegistry {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.55)
                Text("Loading academy…")
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textTertiary)
            }
        }
    }

    private func academyFeaturedRow(_ featured: ClickyAcademyRegistryCourse) -> some View {
        let alreadyHave = companionManager.coursesManager.course(withID: featured.id) != nil
            || featured.isBundledWithApp

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(featured.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textPrimary)
                Text("\(featured.authorName) · \(featured.estimatedMinutes) min · \(featured.goalCount) goals")
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textTertiary)
                Text(featured.blurb)
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if alreadyHave {
                if featured.isBundledWithApp || companionManager.coursesManager.course(withID: featured.id) != nil {
                    Button("Start") {
                        companionManager.startClickyCourse(courseID: featured.id)
                        notchManager.collapse()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(NotchPanelColors.accentBlue))
                    .pointerCursor()
                    .disabled(
                        companionManager.coursesManager.isCourseActive
                            || !companionManager.isBackendReachable
                    )
                    .opacity(
                        companionManager.coursesManager.isCourseActive
                            || !companionManager.isBackendReachable ? 0.4 : 1
                    )
                }
            } else {
                Button("Add") {
                    courseInstallURLText = featured.installURL
                    companionManager.installCourseFromURL(featured.installURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(NotchPanelColors.accentBlue))
                .pointerCursor()
                .disabled(companionManager.coursesManager.isInstallingCourse)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private var backendOfflineBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("backend offline")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.orange)
            }

            Text("Courses need the local proxy. In Terminal:")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textSecondary)

            Text(companionManager.backendConnectionHint ?? "cd worker && npm run local")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(NotchPanelColors.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                companionManager.refreshBackendReachability()
            }) {
                Text("Check again")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private var coursesCatalogIntroduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learn with Teachy")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(NotchPanelColors.textPrimary)

            Text("A free 1:1 tutor on your Mac — warm, playful, beside your cursor. Paths can include teacher clips (your face next to Teachy), then hands-on coaching.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private func activeCourseSessionCard(session: ClickyCourseSession) -> some View {
        let coursesManager = companionManager.coursesManager
        let lessonPlayer = companionManager.lessonPlayer
        let stepNumber = session.currentStepIndex + 1
        let stepCount = session.course.stepCount
        let phase = lessonPlayer.phase

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: phase.systemImageName)
                    .font(.system(size: 14))
                    .foregroundColor(NotchPanelColors.courseAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.currentStep.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(NotchPanelColors.textPrimary)
                        .lineLimit(1)

                    Text("Step \(stepNumber) of \(stepCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.courseAccent)
                }

                Spacer(minLength: 0)

                if coursesManager.isCourseInteractionRunning || lessonPlayer.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                }

                Button {
                    companionManager.exitClickyCourse(voiceInitiated: false)
                } label: {
                    Text("Exit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            courseProgressBar(session: session)
                .padding(.top, 8)

            Text(session.currentStep.goal)
                .font(.system(size: 12))
                .foregroundColor(NotchPanelColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            courseConversationArea(session: session)
                .padding(.top, 10)

            if phase.isPlacement {
                coursePhasePromptRow(
                    icon: "questionmark.circle",
                    title: "Quick check",
                    subtitle: "Tell Teachy what you already know — it'll skip ahead if you're ready."
                )
            } else if phase.isWatchingVideo {
                coursePhasePromptRow(
                    icon: "play.rectangle",
                    title: "Teacher clip",
                    subtitle: "Watch the clip, then Teachy will check in."
                )
            } else if phase.isYourTurn {
                coursePhasePromptRow(
                    icon: "hand.raised",
                    title: "Your turn",
                    subtitle: "Try it out. Say \"next step\" when you're done, or ask a question."
                )
            } else if phase.isUnderstanding {
                coursePhasePromptRow(
                    icon: "lightbulb",
                    title: "Quick check",
                    subtitle: "Explain it in your own words."
                )
            } else if phase == .checking {
                coursePhasePromptRow(
                    icon: "checkmark.circle",
                    title: "Checking…",
                    subtitle: "Teachy is verifying your work."
                )
            }

            if phase.isWatchingVideo {
                HStack(spacing: 8) {
                    courseActionChip(title: "Skip video", isPrimary: true) {
                        companionManager.skipCourseVideo()
                    }
                    Text("or say \"skip\"")
                        .font(.system(size: 10))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
                .padding(.top, 8)
            } else if phase.isYourTurn || phase.isPlacement || phase.isUnderstanding {
                HStack(spacing: 8) {
                    courseActionChip(title: "Hint", isPrimary: false) {
                        companionManager.requestCourseHint()
                    }
                    courseActionChip(title: "I did it", isPrimary: true) {
                        companionManager.confirmCourseBeat()
                    }
                }
                .padding(.top, 8)
            }

            courseQuestionInput()
                .padding(.top, 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func courseConversationArea(session: ClickyCourseSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(session.stepConversationHistory.enumerated()), id: \.offset) { _, exchange in
                        courseConversationExchange(exchange)
                    }

                    if let coachMessage = companionManager.coursesManager.lastCoachMessage {
                        courseCoachMessageBlock(message: coachMessage)
                    } else if !companionManager.coursesManager.lastCoachSpokenText.isEmpty {
                        courseCoachMessageBlock(
                            message: CourseCoachMessageParts(
                                infoText: nil,
                                todoText: companionManager.coursesManager.lastCoachSpokenText,
                                spokenText: companionManager.coursesManager.lastCoachSpokenText
                            )
                        )
                    }
                }
                .id("conversation")
            }
            .frame(maxHeight: 200)
            .onChange(of: companionManager.coursesManager.lastCoachMessage) { _ in
                withAnimation { proxy.scrollTo("conversation", anchor: .bottom) }
            }
        }
    }

    private func courseConversationExchange(_ exchange: ClickyCourseStepExchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 8))
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .frame(width: 14)

                Text(exchange.userTranscript)
                    .font(.system(size: 11))
                    .foregroundColor(NotchPanelColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 8))
                    .foregroundColor(NotchPanelColors.courseAccent)
                    .frame(width: 14)

                Text(exchange.assistantResponse)
                    .font(.system(size: 11))
                    .foregroundColor(NotchPanelColors.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func courseCoachMessageBlock(message: CourseCoachMessageParts) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let infoText = message.infoText, !infoText.isEmpty {
                courseCoachBlock(kindLabel: "FYI", text: infoText, accent: Color(red: 0.35, green: 0.55, blue: 0.95))
            }
            if let todoText = message.todoText, !todoText.isEmpty {
                courseCoachBlock(kindLabel: "Teachy", text: todoText, accent: NotchPanelColors.courseAccent)
            }
            if !message.hasStructuredParts, !message.spokenText.isEmpty {
                courseCoachBlock(kindLabel: "Teachy", text: message.spokenText, accent: NotchPanelColors.courseAccent)
            }
        }
    }

    private func courseCoachBlock(kindLabel: String, text: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kindLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(accent)
                .tracking(0.4)

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(NotchPanelColors.textPrimary.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func coursePhasePromptRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(NotchPanelColors.courseAccent)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(NotchPanelColors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    private func courseQuestionInput() -> some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $courseQuestionText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(NotchPanelColors.textPrimary)
                .onSubmit {
                    let question = courseQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return }
                    courseQuestionText = ""
                    companionManager.submitCourseTextQuestion(question)
                }

            if !courseQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    let question = courseQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return }
                    courseQuestionText = ""
                    companionManager.submitCourseTextQuestion(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(NotchPanelColors.courseAccent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func courseActionChip(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isPrimary ? NotchPanelColors.courseBackground : NotchPanelColors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isPrimary ? NotchPanelColors.courseAccent : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func courseProgressBar(session: ClickyCourseSession) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 4)
                Capsule()
                    .fill(NotchPanelColors.courseAccent)
                    .frame(
                        width: max(4, geometry.size.width * session.progressFraction),
                        height: 4
                    )
            }
        }
        .frame(height: 4)
    }

    private var coursesCatalogList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(companionManager.coursesManager.catalogSections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if let sectionTitle = section.title {
                        Text(sectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(NotchPanelColors.textSecondary)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }

                    ForEach(section.courses) { course in
                        courseCatalogRow(course: course)
                    }
                }
            }
        }
    }

    private func courseCatalogRow(course: ClickyCourse) -> some View {
        let progress = companionManager.coursesManager.progress(forCourseID: course.id)
        let isActive = companionManager.coursesManager.activeSession?.course.id == course.id
        let anotherCourseIsActive = companionManager.coursesManager.isCourseActive && !isActive
        let prerequisitesMet = companionManager.coursesManager.isPrerequisiteLikelyMet(for: course)
        let isCompleted = progress?.isFullyCompleted == true

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: course.iconSystemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(NotchPanelColors.accentBlue)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(NotchPanelColors.accentBlue.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    if let trackPartLabel = course.trackPartLabel {
                        Text(trackPartLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(NotchPanelColors.accentBlue)
                    }

                    HStack(spacing: 6) {
                        Text(course.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(NotchPanelColors.textPrimary)
                            .lineLimit(1)

                        if course.hasTeacherVideos {
                            Text("video")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(NotchPanelColors.courseAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(NotchPanelColors.courseAccent.opacity(0.16))
                                )
                        }

                        if isCompleted {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                        }
                    }

                    Text(course.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textTertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if !prerequisitesMet, let prerequisiteIDs = course.prerequisiteCourseIDs {
                let prerequisiteTitles = prerequisiteIDs.compactMap { id in
                    companionManager.coursesManager.course(withID: id)?.title
                }
                if !prerequisiteTitles.isEmpty {
                    Text("Best after: \(prerequisiteTitles.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
            }

            HStack {
                Text("\(course.stepCount) goals · ~\(course.estimatedMinutes) min")
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textTertiary)

                Spacer()

                if isActive {
                    Text("In progress")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.accentBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(NotchPanelColors.accentBlue.opacity(0.15)))
                } else {
                    if companionManager.coursesManager.installedCourseSourcesByID[course.id] != nil {
                        Button("Remove") {
                            companionManager.uninstallInstalledCourse(courseID: course.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .pointerCursor()
                    }

                    Button(action: {
                        notchManager.selectedTab = .courses
                        companionManager.startClickyCourse(courseID: course.id)
                        notchManager.collapse()
                    }) {
                        Text(
                            isCompleted
                                ? "Retake"
                                : (companionManager.coursesManager.resumeStepIndex(for: course) > 0 ? "Continue" : "Start")
                        )
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NotchPanelColors.accentBlue))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(anotherCourseIsActive || !companionManager.isBackendReachable)
                    .opacity(anotherCourseIsActive || !companionManager.isBackendReachable ? 0.4 : 1)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isActive ? NotchPanelColors.accentBlue.opacity(0.35) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Agents Tab

    @ViewBuilder
    private var agentsTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teachy can build apps, open tabs, run terminal commands, and automate your Mac — like Cursor or Claude Code.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NotchPanelColors.textSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Try saying:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textTertiary)
                Text("\"\(VoiceAutomationTrigger.exampleInvocationPhrase)\"")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NotchPanelColors.textSecondary)
                Text("or \"\(VoiceBackgroundAgentTrigger.exampleInvocationPhrase)\"")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NotchPanelColors.textSecondary)
            }

            Text("Tools: bash, write files, open browser tabs, AppleScript, screen capture. Progress shows in the side dock.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            openRouterModelPickerRow(
                title: "Model",
                models: OpenRouterModelOption.models,
                selectedModelID: companionManager.selectedModel
            ) { modelID in
                companionManager.setSelectedModel(modelID)
            }

            connectionsSection
            agentStatusContent
        }
    }

    private var connectionsSection: some View {
        let connectorManager = companionManager.backgroundAgentManager.appConnectorManager
        let composioManager = companionManager.composioConnectionManager
        let installedBrowsers = BrowserSessionStore.installedBrowserNames()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
                Spacer()
                Button(action: {
                    Task {
                        await composioManager.refreshComposioConfigurationAndConnections()
                        await connectorManager.refreshConnectors()
                    }
                }) {
                    Text("Refresh")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.accentBlue)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Text("Sync SaaS apps via Composio, or add custom OpenAPI connections.")
                .font(.system(size: 11))
                .foregroundColor(NotchPanelColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            composioConnectionsSection(composioManager: composioManager)

            VStack(alignment: .leading, spacing: 6) {
                Text("Browser sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textSecondary)

                if installedBrowsers.isEmpty {
                    Text("No supported browsers found.")
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textTertiary)
                } else {
                    Text("Cookies from: \(installedBrowsers.joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom connections")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textSecondary)

                if connectorManager.connectionStates.isEmpty {
                    Text("No custom connections configured.")
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textTertiary)
                } else {
                    ForEach(connectorManager.connectionStates) { connector in
                        connectionRow(connector)
                    }
                }

                Text("Demo: run connectors/plant-maint (npm start) for OpenAPI custom connection.")
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            Task {
                await composioManager.refreshComposioConfigurationAndConnections()
            }
        }
    }

    private func composioConnectionsSection(composioManager: ComposioConnectionManager) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apps (Composio)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPanelColors.textSecondary)
                Spacer()
                if composioManager.isComposioConfigured {
                    Text("\(composioManager.connectedToolkitSlugs.count) connected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(
                            composioManager.connectedToolkitSlugs.isEmpty
                                ? NotchPanelColors.textTertiary
                                : .green
                        )
                }
            }

            if !composioManager.isComposioConfigured {
                Text("Add COMPOSIO_API_KEY to worker/.env, then restart the proxy.")
                    .font(.system(size: 11))
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Teachy also offers to sync when you open a supported app. Add manually below anytime.")
                    .font(.system(size: 11))
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textTertiary)

                    TextField("Search apps to sync…", text: Binding(
                        get: { composioManager.manualToolkitSearchQuery },
                        set: { composioManager.manualToolkitSearchQuery = $0 }
                    ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(NotchPanelColors.textPrimary)
                        .onSubmit {
                            Task {
                                await composioManager.refreshAvailableToolkits()
                            }
                        }
                        .onChange(of: composioManager.manualToolkitSearchQuery) { _, _ in
                            composioManager.scheduleToolkitSearchRefresh()
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )

                if composioManager.isLoadingAvailableToolkits {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.55)
                        Text("Loading apps…")
                            .font(.system(size: 10))
                            .foregroundColor(NotchPanelColors.textTertiary)
                    }
                }

                if let lastConnectionError = composioManager.lastConnectionError {
                    Text(lastConnectionError)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 6) {
                    ForEach(composioManager.displayedManualToolkits.prefix(10)) { toolkit in
                        composioToolkitRow(toolkit: toolkit, composioManager: composioManager)
                    }
                }

                if composioManager.displayedManualToolkits.count > 10 {
                    Text("+ \(composioManager.displayedManualToolkits.count - 10) more — refine search to find them")
                        .font(.system(size: 10))
                        .foregroundColor(NotchPanelColors.textTertiary)
                }
            }
        }
    }

    private func composioToolkitRow(
        toolkit: ComposioToolkitOption,
        composioManager: ComposioConnectionManager
    ) -> some View {
        let isConnected = composioManager.connectedToolkitSlugs.contains(toolkit.slug)
        let isConnecting = composioManager.connectingToolkitSlug == toolkit.slug

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toolkit.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
                if !toolkit.description.isEmpty {
                    Text(toolkit.description)
                        .font(.system(size: 10))
                        .foregroundColor(NotchPanelColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isConnected {
                Text("Connected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            } else {
                Button(action: {
                    Task {
                        await composioManager.connectToolkit(
                            slug: toolkit.slug,
                            displayName: toolkit.name
                        )
                    }
                }) {
                    HStack(spacing: 5) {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                        Text(isConnecting ? "Connecting…" : "Sync")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(NotchPanelColors.accentBlue))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isConnecting)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func connectionRow(_ connector: AppConnectorConnectionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionStatusColor(connector.status))
                    .frame(width: 7, height: 7)
                Text(connector.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
                Spacer()
                Text(connectionStatusLabel(connector))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(connectionStatusColor(connector.status))
            }

            if let description = connector.description {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(NotchPanelColors.textTertiary)
                    .lineLimit(2)
            }

            if !connector.registeredToolNames.isEmpty {
                Text("\(connector.registeredToolNames.count) tools · \(connector.transportKind.rawValue)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NotchPanelColors.textTertiary)
            }

            if let lastError = connector.lastError {
                Text(lastError)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func connectionStatusColor(_ status: AppConnectorStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .disabled:
            return NotchPanelColors.textTertiary
        case .unreachable:
            return .orange
        case .misconfigured:
            return .red
        }
    }

    private func connectionStatusLabel(_ connector: AppConnectorConnectionState) -> String {
        switch connector.status {
        case .connected:
            return connector.transportKind == .openapi ? "OpenAPI" : "Connected"
        case .disabled:
            return "Disabled"
        case .unreachable:
            return "Unreachable"
        case .misconfigured:
            return "Misconfigured"
        }
    }

    @ViewBuilder
    private var agentStatusContent: some View {
        let agent = companionManager.backgroundAgentManager

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(agentStatusColor)
                    .frame(width: 8, height: 8)
                Text(agentStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NotchPanelColors.textSecondary)
                Spacer()
                if case .running = agent.status {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            if case .completed(let result) = agent.status {
                Text(result.prefix(200))
                    .font(.system(size: 11))
                    .foregroundColor(NotchPanelColors.textSecondary)
                    .lineLimit(4)
            }

            if case .failed(let error) = agent.status {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            if !agent.stepLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPanelColors.textTertiary)
                    ForEach(agent.stepLog.suffix(5)) { step in
                        Text("\(step.toolName) · \(step.duration, format: .number.precision(.fractionLength(1)))s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NotchPanelColors.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Shared Components

    private func primaryActionButton(title: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isEnabled ? NotchPanelColors.accentBlue : NotchPanelColors.accentBlue.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!isEnabled)
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
            .foregroundColor(NotchPanelColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var agentStatusColor: Color {
        switch companionManager.backgroundAgentManager.status {
        case .idle: return NotchPanelColors.textTertiary
        case .reasoning, .running: return NotchPanelColors.accentBlue
        case .completed: return .green
        case .failed: return .orange
        }
    }

    private var agentStatusText: String {
        switch companionManager.backgroundAgentManager.status {
        case .idle: return "Idle"
        case .reasoning: return "Thinking..."
        case .running(let tool): return "Running \(tool)..."
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Keyboard Key Label

private struct KeyboardKeyLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(NotchPanelColors.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - Notch Panel Colors

enum NotchPanelColors {
    /// Teachy soft-ink surfaces (education calm, not hacker charcoal).
    static let background = Color(hex: "#12151A")
    static let courseBackground = Color(hex: "#14181F")
    /// Teachy accent — matches site Apple blue.
    static let accentBlue = Color(hex: "#0071E3")
    static let courseAccent = Color(hex: "#0F8A6A")
    static let textPrimary = Color(hex: "#F5F5F7")
    static let textSecondary = Color(hex: "#A1A1A6")
    static let textTertiary = Color(hex: "#6E6E73")
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
