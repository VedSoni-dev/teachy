//
//  PermissionChoreographyView.swift
//  leanring-buddy
//
//  One-permission-at-a-time setup wizard shown inside the notch panel before
//  anything else. Instead of a checklist of Grant buttons, each permission gets
//  its own animated step card: the system prompt auto-fires shortly after the
//  step appears, Settings-toggle permissions show an animated mock of the exact
//  System Settings row to flip, and a background poll notices the grant and
//  glides to the next step automatically. The wizard unmounts on its own when
//  `CompanionManager.allPermissionsGranted` flips true (the body branch in
//  NotchSetupOnboardingView moves on to the Automation explainer).
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
        case .microphone: return "So you can talk to Teachy — hold Control + Option and speak."
        case .speechRecognition: return "So your Mac can turn your voice into words for Teachy."
        case .screenRecording: return "So Teachy can see your screen and point at real things."
        case .accessibility: return "So Teachy's push-to-talk shortcut and pointing work everywhere."
        }
    }
}

struct PermissionChoreographyView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Index into `activePermissionSteps` of the step currently on stage.
    @State private var currentStepIndex: Int = 0
    /// Steps whose system request has already been auto-fired this visit, so the
    /// 1-second poll can never re-fire a dialog on every tick.
    @State private var stepsAlreadyAutoFired: Set<PermissionSetupStep> = []
    /// True during the ~0.8s "checkmark moment" between a grant landing and the
    /// slide to the next step — blocks the poll from double-advancing.
    @State private var isHoldingOnGrantedCheckmark: Bool = false
    /// Drives the gentle repeating pulse on the current step's icon.
    @State private var stepIconIsPulsing: Bool = false

    private let permissionPollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let currentStep {
                stepCard(for: currentStep)
                    .id(currentStep)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }

            progressDots
        }
        .onAppear {
            jumpToFirstUngrantedStep()
            autoFireRequestForCurrentStepAfterDelay()
        }
        .onReceive(permissionPollTimer) { _ in
            companionManager.refreshAllPermissions()
            advanceIfCurrentStepGranted()
        }
    }

    // MARK: - Step card

    @ViewBuilder
    private func stepCard(for step: PermissionSetupStep) -> some View {
        let stepIsGranted = isGranted(step)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: stepIsGranted ? "checkmark.circle.fill" : step.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(stepIsGranted ? DS.Colors.success : DS.Colors.learnAccent)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill((stepIsGranted ? DS.Colors.success : DS.Colors.learnAccent).opacity(0.16))
                    )
                    .scaleEffect(stepIsGranted ? 1.0 : (stepIconIsPulsing ? 1.08 : 1.0))
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: stepIconIsPulsing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: stepIsGranted)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(step.whyLine)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !stepIsGranted {
                switch step.stepKind {
                case .dialogPrompt:
                    dialogPromptStepContent(for: step)
                case .settingsToggle:
                    settingsToggleStepContent(for: step)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, tint: DS.Colors.learnAccent)
        .onAppear {
            stepIconIsPulsing = true
        }
    }

    @ViewBuilder
    private func dialogPromptStepContent(for step: PermissionSetupStep) -> some View {
        Text("Look for the macOS prompt and click Allow.")
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)

        if step == .speechRecognition {
            dictationShortcutWarning
        }

        Button {
            fireSystemPermissionRequest(for: step)
        } label: {
            Text("Ask again")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .underline()
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private func settingsToggleStepContent(for step: PermissionSetupStep) -> some View {
        SettingsToggleGuideView(rowLabel: "Teachy")

        HStack(spacing: 8) {
            Button {
                fireSystemPermissionRequest(for: step)
            } label: {
                Text("Open System Settings")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if step == .screenRecording {
                // Dev rebuilds can leave a stale screen-recording grant behind;
                // the existing fix path resets it without hunting through Settings.
                Button {
                    WindowPositionManager.fixScreenRecordingAfterRebuild()
                } label: {
                    Text("Fix")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if step == .accessibility {
                // If Teachy isn't listed yet, the user may need to drag the app
                // into the Accessibility list — reveal it in Finder to make that easy.
                Button {
                    WindowPositionManager.revealAppInFinder()
                    WindowPositionManager.openAccessibilitySettings()
                } label: {
                    Text("Find app in Finder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    /// Enabling Dictation also arms macOS's own dictation keyboard shortcut.
    /// If that shortcut involves the Control key (e.g. "Press Control twice"),
    /// it collides with Teachy's ctrl+option push-to-talk and Apple's dictation
    /// popover fires instead — steer users to the globe-key shortcut.
    private var dictationShortcutWarning: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dictation must be ON for voice input. In the same settings, set Dictation's shortcut to \u{1F310} (globe) — if it's set to Control, it'll pop up while you talk to Teachy.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                WindowPositionManager.openDictationSettings()
            } label: {
                Text("Dictation settings")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(activePermissionSteps.enumerated()), id: \.element) { stepIndex, step in
                Capsule()
                    .fill(
                        stepIndex == currentStepIndex || isGranted(step)
                            ? DS.Colors.learnAccent
                            : Color.white.opacity(0.16)
                    )
                    .frame(
                        width: stepIndex == currentStepIndex ? 14 : 6,
                        height: 6
                    )
                    .animation(.easeInOut(duration: 0.18), value: currentStepIndex)
            }
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
    /// with the checkmark beat, then slide to the next un-granted step.
    private func advanceIfCurrentStepGranted() {
        guard !isHoldingOnGrantedCheckmark,
              let step = currentStep,
              isGranted(step)
        else { return }

        isHoldingOnGrantedCheckmark = true
        companionManager.playTeachyUISound(.celebration)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.smooth(duration: 0.3)) {
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

    /// Flips every 0.9s so the toggle holds briefly at each end of its loop.
    private let toggleLoopTimer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // App-icon stand-in matching the small icon in a real Settings row.
                RoundedRectangle(cornerRadius: 5)
                    .fill(DS.Colors.learnAccent)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                    )

                Text(rowLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer(minLength: 0)

                // Mock macOS toggle: gray track when off, green when on.
                Capsule()
                    .fill(mockToggleIsOn ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 30, height: 17)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 13, height: 13)
                            .offset(x: mockToggleIsOn ? 6 : -6)
                    )

                // Pointing cue nudging toward the toggle in rhythm with the flip.
                Image(systemName: "hand.point.left.fill")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.learnAccent)
                    .offset(x: mockToggleIsOn ? 0 : 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
            )

            Text("Find Teachy in the list and flip this on")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .onReceive(toggleLoopTimer) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                mockToggleIsOn.toggle()
            }
        }
    }
}
