//
//  PermissionChoreographyView.swift
//  leanring-buddy
//
//  One-permission-at-a-time setup wizard shown inside the notch panel before
//  anything else. The permissions are one grouped list; the one being asked for
//  right now is open in place. Its system prompt auto-fires shortly after the
//  step comes up, Settings-toggle permissions show an animated mock of the exact
//  System Settings row to flip, and a background poll notices the grant, checks
//  that row off and moves to the next one automatically. The wizard unmounts on
//  its own when `CompanionManager.allPermissionsGranted` flips true (the body
//  branch in NotchSetupOnboardingView moves on to the Automation explainer).
//

import AVFoundation
import AppKit
import Combine
import SwiftUI

/// The permissions walked through by the choreography, in presentation order.
enum PermissionSetupStep: CaseIterable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility

    /// Dialog permissions are granted entirely inside a macOS prompt (Allow /
    /// Don't Allow). Settings-toggle permissions require the user to flip
    /// Teachy's toggle inside System Settings — those steps show the animated
    /// toggle guide so the user knows exactly what to do.
    enum StepKind {
        case dialogPrompt
        case settingsToggle
    }

    var stepKind: StepKind {
        switch self {
        case .microphone, .speechRecognition: return .dialogPrompt
        case .screenRecording, .accessibility: return .settingsToggle
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "hand.raised.fill"
        }
    }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var whyLine: String {
        switch self {
        case .microphone: return "To talk to Teachy: hold Control + Option and speak."
        case .speechRecognition: return "So your Mac can turn your voice into words for Teachy."
        case .screenRecording: return "So Teachy can see your screen and point at real things."
        case .accessibility: return "So push-to-talk and pointing work in every app."
        }
    }
}

/// Where one permission stands in the walk-through. It picks what goes at the
/// end of the row (a green tick, the button to press, or an empty circle) and
/// whether the row is open.
private enum PermissionStepStanding: Equatable {
    /// macOS has granted it.
    case granted
    /// The one Teachy is asking for right now.
    case askingNow
    /// Still to come.
    case upNext
}

struct PermissionChoreographyView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Index into `activePermissionSteps` of the step currently on stage.
    @State private var currentStepIndex: Int = 0
    /// Steps whose system request has already been auto-fired this visit, so the
    /// 1-second poll can never re-fire a dialog on every tick.
    @State private var stepsAlreadyAutoFired: Set<PermissionSetupStep> = []
    /// True during the ~0.8s "checkmark moment" between a grant landing and the
    /// move to the next step — blocks the poll from double-advancing.
    @State private var isHoldingOnGrantedCheckmark: Bool = false
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    private let permissionPollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The permission's symbol sits in a column this wide, the same as the
    /// symbol column of a settings row on Home.
    private let permissionSymbolColumnWidth: CGFloat = 20
    private let spacingAfterPermissionSymbol: CGFloat = 10
    /// Where a row's name starts. The dividers and the opened content line up with it.
    private var rowContentLeadingInset: CGFloat {
        permissionSymbolColumnWidth + spacingAfterPermissionSymbol
    }
    /// The height of the compact button, so a row is as tall with a tick at
    /// its end as with a button: 38 pt with its padding, the height of a
    /// settings row on Home.
    private let rowTrailingStateHeight: CGFloat = 22
    /// Wide enough for the longest name ("Speech Recognition"), so every
    /// why-line starts at the same place.
    private let permissionNameColumnWidth: CGFloat = 124

    /// Speech recognition only applies when the Apple Speech transcription
    /// provider is active — otherwise that step is skipped entirely.
    private var activePermissionSteps: [PermissionSetupStep] {
        PermissionSetupStep.allCases.filter { step in
            if step == .speechRecognition {
                return companionManager.requiresSpeechRecognitionPermission
            }
            return true
        }
    }

    private var currentStep: PermissionSetupStep? {
        activePermissionSteps.indices.contains(currentStepIndex)
            ? activePermissionSteps[currentStepIndex]
            : nil
    }

    /// Rows open, close and check themselves off on the standard spring, or a
    /// cross-fade when Reduce Motion is on.
    private var stepChangeAnimation: Animation {
        isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TeachySetupStepHeader(
                headline: "Let's get set up",
                explanation: "I'll walk you through each permission. Watch for the prompts.",
                progressLabel: "\(currentStepIndex + 1) of \(activePermissionSteps.count)"
            )

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(activePermissionSteps.enumerated()), id: \.element) { stepIndex, step in
                    if stepIndex > 0 {
                        // Inset past the symbol, the way System Settings draws it.
                        TeachyRule()
                            .padding(.leading, rowContentLeadingInset)
                    }
                    permissionRow(for: step)
                }
            }
            .teachyGroup()
        }
        // Rows open and close in place when a grant lands or the next step comes up.
        .animation(stepChangeAnimation, value: activePermissionSteps.map { standing(of: $0) })
        .onAppear {
            jumpToFirstUngrantedStep()
            autoFireRequestForCurrentStepAfterDelay()
        }
        .onReceive(permissionPollTimer) { _ in
            companionManager.refreshAllPermissions()
            advanceIfCurrentStepGranted()
        }
    }

    // MARK: - Permission rows

    private func standing(of step: PermissionSetupStep) -> PermissionStepStanding {
        if isGranted(step) {
            return .granted
        }
        return step == currentStep ? .askingNow : .upNext
    }

    /// One row of the grouped list, laid out like a settings row on Home: the
    /// permission's symbol and name, why Teachy needs it, and its state on the
    /// right. The row being asked for right now is open, with what to do under
    /// its name.
    @ViewBuilder
    private func permissionRow(for step: PermissionSetupStep) -> some View {
        let stepStanding = standing(of: step)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: spacingAfterPermissionSymbol) {
                Image(systemName: step.symbolName)
                    .font(DS.Fonts.sans(13, weight: .medium))
                    .foregroundColor(DS.Colors.pointer)
                    .frame(width: permissionSymbolColumnWidth)

                Text(step.title)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: permissionNameColumnWidth, alignment: .leading)

                Text(step.whyLine)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                permissionRowTrailingState(for: step, standing: stepStanding)
            }
            .frame(minHeight: rowTrailingStateHeight)
            .padding(.vertical, 8)

            if stepStanding == .askingNow {
                Group {
                    switch step.stepKind {
                    case .dialogPrompt:
                        dialogPromptStepContent(for: step)
                    case .settingsToggle:
                        settingsToggleStepContent(for: step)
                    }
                }
                .padding(.leading, rowContentLeadingInset)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }

    /// The right end of a row: a green tick once macOS has granted the
    /// permission, the button that asks for it while it is this row's turn, an
    /// empty circle until then.
    @ViewBuilder
    private func permissionRowTrailingState(for step: PermissionSetupStep, standing stepStanding: PermissionStepStanding) -> some View {
        switch stepStanding {
        case .granted:
            // The tick lands with a small scale, on the same spring as the row closing.
            TeachyStatusMark(kind: .done, sideLength: 16)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        case .askingNow:
            Button(step.stepKind == .settingsToggle ? "Open System Settings" : "Ask again") {
                fireSystemPermissionRequest(for: step)
            }
            .teachyButton(.primary, size: .compact)
            .transition(.opacity)
        case .upNext:
            TeachyStatusMark(kind: .waiting, sideLength: 16)
                .transition(.opacity)
        }
    }

    private func dialogPromptStepContent(for step: PermissionSetupStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Look for the macOS prompt and click Allow.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)

            if step == .speechRecognition {
                dictationShortcutWarning
            }
        }
    }

    /// The mock of the System Settings row on the left; what to do about it on the right.
    private func settingsToggleStepContent(for step: PermissionSetupStep) -> some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsToggleGuideView(rowLabel: "Teachy")
                .frame(width: 236)

            VStack(alignment: .leading, spacing: 4) {
                Text("Find Teachy in the list and flip this on.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)

                if step == .screenRecording {
                    // Dev rebuilds can leave a stale screen-recording grant behind;
                    // the existing fix path resets it without hunting through Settings.
                    Button("Fix") {
                        WindowPositionManager.fixScreenRecordingAfterRebuild()
                    }
                    .teachyLinkButton()
                }

                if step == .accessibility {
                    // If Teachy isn't listed yet, the user may need to drag the app
                    // into the Accessibility list — reveal it in Finder to make that easy.
                    Button("Find app in Finder") {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }
                    .teachyLinkButton()
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Enabling Dictation also arms macOS's own dictation keyboard shortcut.
    /// If that shortcut involves the Control key (e.g. "Press Control twice"),
    /// it collides with Teachy's ctrl+option push-to-talk and Apple's dictation
    /// popover fires instead — steer users to the globe-key shortcut.
    /// Marked "needs you", because this is the one place in setup where the
    /// person has to change something themselves.
    private var dictationShortcutWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            TeachyStatusMark(kind: .needsYou)

            Text("Dictation must be on for voice input. In the same settings, set Dictation's shortcut to \(Image(systemName: "globe")) (globe): if it is set to Control, it pops up while you talk to Teachy.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Dictation settings") {
                WindowPositionManager.openDictationSettings()
            }
            .teachyLinkButton()
        }
    }

    // MARK: - Choreography

    private func isGranted(_ step: PermissionSetupStep) -> Bool {
        switch step {
        case .microphone: return companionManager.hasMicrophonePermission
        case .speechRecognition: return companionManager.hasSpeechRecognitionPermission
        case .screenRecording: return companionManager.hasScreenRecordingPermission
        case .accessibility: return companionManager.hasAccessibilityPermission
        }
    }

    private func jumpToFirstUngrantedStep() {
        if let firstUngrantedIndex = activePermissionSteps.firstIndex(where: { !isGranted($0) }) {
            currentStepIndex = firstUngrantedIndex
        }
    }

    /// Fires the current step's system request ~0.6s after it lands on stage, so
    /// the macOS prompt appears "by itself" without the user clicking anything.
    /// Guarded per-step so the poll can never re-trigger a dialog.
    private func autoFireRequestForCurrentStepAfterDelay() {
        guard let step = currentStep, !isGranted(step), !stepsAlreadyAutoFired.contains(step) else { return }
        stepsAlreadyAutoFired.insert(step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // The user may have granted (or the wizard advanced) during the delay.
            guard !isGranted(step) else { return }
            fireSystemPermissionRequest(for: step)
        }
    }

    private func fireSystemPermissionRequest(for step: PermissionSetupStep) {
        switch step {
        case .microphone:
            let microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if microphoneAuthorizationStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(microphoneSettingsURL)
            }
        case .speechRecognition:
            WindowPositionManager.requestSpeechRecognitionPermission()
        case .screenRecording:
            WindowPositionManager.requestScreenRecordingPermission()
        case .accessibility:
            WindowPositionManager.requestAccessibilityPermission()
        }
    }

    /// Called every poll tick: when the current step's grant lands, celebrate
    /// with the checkmark beat, then move to the next un-granted step.
    private func advanceIfCurrentStepGranted() {
        guard !isHoldingOnGrantedCheckmark,
              let step = currentStep,
              isGranted(step)
        else { return }

        isHoldingOnGrantedCheckmark = true
        companionManager.playTeachyUISound(.celebration)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(stepChangeAnimation) {
                jumpToFirstUngrantedStep()
            }
            isHoldingOnGrantedCheckmark = false
            autoFireRequestForCurrentStepAfterDelay()
        }
    }
}

/// Animated mock of the System Settings permission row: a "Teachy" row whose
/// toggle flips off→on in a loop, showing the user exactly what to go flip.
struct SettingsToggleGuideView: View {
    let rowLabel: String

    @State private var mockToggleIsOn: Bool = false
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    /// Flips every 0.9s so the toggle holds briefly at each end of its loop.
    private let toggleLoopTimer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 9) {
            TeachyAppIconStandIn()

            Text(rowLabel)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)

            Spacer(minLength: 0)

            SystemSettingsSwitchMock(isOn: mockToggleIsOn)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // A well on the group reads as a row raised on it, which is what a row
        // of System Settings looks like.
        .teachyWell()
        .onReceive(toggleLoopTimer) { _ in
            withAnimation(isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard) {
                mockToggleIsOn.toggle()
            }
        }
    }
}

/// The switch the way System Settings shows it: the shape of `TeachySwitch`,
/// but green when on. It is part of the picture of System Settings, not a
/// control of Teachy's, which is why it does not take the tint.
private struct SystemSettingsSwitchMock: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? DS.Colors.success : DS.Colors.surface3)
            .frame(width: 36, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(DS.Colors.textPrimary)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
    }
}

/// Stand-in for Teachy's app icon at the size macOS shows it in a Settings row
/// or a consent dialog: the black tile with the pointer on it.
struct TeachyAppIconStandIn: View {
    var sideLength: CGFloat = 18

    private var iconTileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: sideLength * 0.26, style: .continuous)
    }

    var body: some View {
        iconTileShape
            .fill(DS.Colors.notchBlack)
            .overlay(iconTileShape.strokeBorder(DS.Colors.hairlineStrong, lineWidth: 1))
            .overlay(
                TeachyPointerShape()
                    .fill(DS.Colors.pointer)
                    .frame(width: sideLength * 0.44, height: sideLength * 0.44)
            )
            .frame(width: sideLength, height: sideLength)
    }
}
