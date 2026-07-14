//
//  CourseModeNotchDockWindow.swift
//  leanring-buddy
//
//  Persistent course-mode pill docked to the right of the camera notch.
//  Always visible while a course is active — not buried inside the panel.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CourseModeNotchDockManager: ObservableObject {
    private var panel: NSPanel?
    private var screenConfigurationObserver: NSObjectProtocol?

    private let dockWidth: CGFloat = 268
    private let dockHeight: CGFloat = 36

    func show(companionManager: CompanionManager) {
        if panel == nil {
            createPanel(companionManager: companionManager)
        } else if let hostingView = panel?.contentView as? NSHostingView<CourseModeNotchDockView> {
            hostingView.rootView = CourseModeNotchDockView(
                companionManager: companionManager,
                dockManager: self
            )
        }

        positionRightOfNotch()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        installScreenConfigurationObserver()
    }

    func hide() {
        removeScreenConfigurationObserver()

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.contentView = nil
            self?.panel = nil
        })
    }

    func repositionIfNeeded() {
        guard panel != nil else { return }
        positionRightOfNotch()
    }

    private func createPanel(companionManager: CompanionManager) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: dockWidth, height: dockHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        let hostingView = NSHostingView(
            rootView: CourseModeNotchDockView(
                companionManager: companionManager,
                dockManager: self
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: dockWidth, height: dockHeight)
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionRightOfNotch() {
        guard let panel else { return }

        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }

        let notchGeometry = NotchScreenGeometry.from(screen: targetScreen)
        let dockFrame = notchGeometry.rightOfNotchFrame(
            width: dockWidth,
            height: dockHeight
        )
        panel.setFrame(dockFrame, display: true)
    }

    private func installScreenConfigurationObserver() {
        removeScreenConfigurationObserver()
        screenConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionRightOfNotch()
        }
    }

    private func removeScreenConfigurationObserver() {
        if let screenConfigurationObserver {
            NotificationCenter.default.removeObserver(screenConfigurationObserver)
            self.screenConfigurationObserver = nil
        }
    }
}

// MARK: - Dock View

private struct CourseModeNotchDockView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var dockManager: CourseModeNotchDockManager
    @ObservedObject private var coursesManager: CoursesManager
    @State private var awaitingUserPulseOpacity: Double = 1

    init(companionManager: CompanionManager, dockManager: CourseModeNotchDockManager) {
        self.companionManager = companionManager
        self.dockManager = dockManager
        self._coursesManager = ObservedObject(wrappedValue: companionManager.coursesManager)
    }

    var body: some View {
        if let session = coursesManager.activeSession {
            let teachingPhase = coursesManager.courseTeachingPhase
            let isAwaitingUser = teachingPhase.isYourTurn || teachingPhase.isPlacement

            HStack(spacing: 8) {
                Image(systemName: teachingPhase.systemImageName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(NotchPanelColors.courseAccent)
                    .opacity(isAwaitingUser ? awaitingUserPulseOpacity : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(teachingPhase.displayLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(NotchPanelColors.courseAccent)
                    Text(stepSummary(for: session))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(NotchPanelColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if coursesManager.isCourseInteractionRunning {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 14, height: 14)
                }

                Button(action: {
                    companionManager.exitClickyCourse(voiceInitiated: false)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(NotchPanelColors.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(NotchPanelColors.courseBackground.opacity(0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                NotchPanelColors.courseAccent.opacity(isAwaitingUser ? 0.7 : 0.45),
                                lineWidth: isAwaitingUser ? 1.5 : 1
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
            )
            .animation(.easeInOut(duration: 0.25), value: teachingPhase.displayLabel)
            .onChange(of: isAwaitingUser) { isActive in
                if isActive {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        awaitingUserPulseOpacity = 0.45
                    }
                } else {
                    awaitingUserPulseOpacity = 1
                }
            }
        }
    }

    private func stepSummary(for session: ClickyCourseSession) -> String {
        let stepNumber = session.currentStepIndex + 1
        return "step \(stepNumber)/\(session.course.stepCount) · \(session.currentStep.title)"
    }
}
