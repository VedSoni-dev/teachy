//
//  BackgroundAgentSideDockWindow.swift
//  leanring-buddy
//
//  A small Clicky mascot docked to the right edge of the screen while a
//  background agent task runs. Hover to expand a progress card with status
//  and recent tool steps.
//

import AppKit
import Combine
import SwiftUI

enum ClickySideDockPresentationMode: Equatable {
    case hidden
    case composioSync(ComposioSyncPromptState)
}

@MainActor
final class BackgroundAgentSideDockManager: ObservableObject {
    private var panel: NSPanel?
    private var scheduledHideTask: Task<Void, Never>?
    @Published private(set) var presentationMode: ClickySideDockPresentationMode = .hidden
    @Published private(set) var shouldAutoExpandComposioPrompt = false

    private let expandedPanelWidth: CGFloat = 320
    private let expandedPanelHeight: CGFloat = 380

    func showComposioSyncPrompt(
        companionManager: CompanionManager,
        syncPrompt: ComposioSyncPromptState,
        playAttentionFeedback: Bool
    ) {
        scheduledHideTask?.cancel()
        scheduledHideTask = nil
        presentationMode = .composioSync(syncPrompt)
        shouldAutoExpandComposioPrompt = true
        presentPanel(companionManager: companionManager)

        if playAttentionFeedback {
            ComposioSyncAttentionFeedback.play()
        }
    }

    func hideComposioSyncPrompt() {
        guard case .composioSync = presentationMode else { return }
        hide()
    }

    func hide() {
        scheduledHideTask?.cancel()
        scheduledHideTask = nil
        presentationMode = .hidden
        shouldAutoExpandComposioPrompt = false

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.contentView = nil
            self?.panel = nil
        })
    }

    func scheduleHide(after delaySeconds: TimeInterval) {
        scheduledHideTask?.cancel()
        scheduledHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func presentPanel(companionManager: CompanionManager) {
        if panel == nil {
            createPanel(companionManager: companionManager)
        } else if let hostingView = panel?.contentView as? NSHostingView<BackgroundAgentSideDockView> {
            hostingView.rootView = BackgroundAgentSideDockView(
                companionManager: companionManager,
                sideDockManager: self
            )
        }

        positionOnCursorScreen()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
    }

    private func createPanel(companionManager: CompanionManager) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: expandedPanelWidth, height: expandedPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        let contentView = BackgroundAgentSideDockView(
            companionManager: companionManager,
            sideDockManager: self
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: expandedPanelWidth, height: expandedPanelHeight)
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionOnCursorScreen() {
        guard let panel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let targetScreen else { return }

        let originX = targetScreen.frame.maxX - expandedPanelWidth
        let originY = targetScreen.frame.midY - (expandedPanelHeight / 2)
        panel.setFrame(
            NSRect(x: originX, y: originY, width: expandedPanelWidth, height: expandedPanelHeight),
            display: true
        )
    }
}

// MARK: - Dock View

struct BackgroundAgentSideDockView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var sideDockManager: BackgroundAgentSideDockManager
    @ObservedObject private var backgroundAgentManager: BackgroundAgentManager
    @ObservedObject private var composioConnectionManager: ComposioConnectionManager

    @State private var isHoveringOverDock = false
    @State private var isComposioPromptExpanded = false
    @State private var mascotBobOffset: CGFloat = 0
    @State private var completionGlowPulseOpacity: Double = 0.35
    @State private var completionBounceScale: CGFloat = 1.0

    init(companionManager: CompanionManager, sideDockManager: BackgroundAgentSideDockManager) {
        self.companionManager = companionManager
        self.sideDockManager = sideDockManager
        self._backgroundAgentManager = ObservedObject(wrappedValue: companionManager.backgroundAgentManager)
        self._composioConnectionManager = ObservedObject(wrappedValue: companionManager.composioConnectionManager)
    }

    private var isComposioSyncMode: Bool {
        if case .composioSync = sideDockManager.presentationMode {
            return true
        }
        return false
    }

    private var shouldShowExpandedCard: Bool {
        if isComposioSyncMode {
            return isComposioPromptExpanded || isHoveringOverDock
        }
        return isHoveringOverDock
    }

    private var cursorAccentColor: Color {
        companionManager.selectedCursorColor.displayColor
    }

    private var isAgentActivelyWorking: Bool {
        switch backgroundAgentManager.status {
        case .reasoning, .running:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    private var mascotDockVisualState: BackgroundAgentMascotDockVisualState {
        switch backgroundAgentManager.status {
        case .idle:
            return .idle
        case .reasoning, .running:
            return .working
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    private var mascotDockAccentColor: Color {
        switch mascotDockVisualState {
        case .idle, .working:
            return cursorAccentColor
        case .completed:
            return BackgroundAgentSideDockColors.successGreen
        case .failed:
            return BackgroundAgentSideDockColors.failureOrange
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)

            if shouldShowExpandedCard, let syncPrompt = composioConnectionManager.activeSyncPrompt {
                composioSyncCard(syncPrompt: syncPrompt)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            mascotDock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: shouldShowExpandedCard)
        .onAppear {
            startMascotBobAnimationIfNeeded()
            if sideDockManager.shouldAutoExpandComposioPrompt {
                isComposioPromptExpanded = true
            }
            if case .completed = backgroundAgentManager.status {
                triggerCompletionCelebrationAnimation()
            } else if case .failed = backgroundAgentManager.status {
                triggerFailureAttentionAnimation()
            }
        }
        .onChange(of: sideDockManager.shouldAutoExpandComposioPrompt) { _, shouldAutoExpand in
            if shouldAutoExpand {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    isComposioPromptExpanded = true
                }
            }
        }
        .onChange(of: composioConnectionManager.activeSyncPrompt) { _, newPrompt in
            if newPrompt != nil, sideDockManager.shouldAutoExpandComposioPrompt {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    isComposioPromptExpanded = true
                }
            }
        }
        .onChange(of: isAgentActivelyWorking) { _, isWorking in
            if isWorking {
                startMascotBobAnimationIfNeeded()
            } else {
                mascotBobOffset = 0
            }
        }
        .onChange(of: backgroundAgentManager.status) { _, newStatus in
            switch newStatus {
            case .completed:
                triggerCompletionCelebrationAnimation()
            case .failed:
                triggerFailureAttentionAnimation()
            default:
                completionGlowPulseOpacity = 0.35
                completionBounceScale = 1.0
            }
        }
    }

    private var mascotDock: some View {
        VStack(spacing: 0) {
            ZStack {
                if mascotDockVisualState == .completed {
                    Circle()
                        .stroke(
                            BackgroundAgentSideDockColors.successGreen.opacity(completionGlowPulseOpacity),
                            lineWidth: 3
                        )
                        .frame(width: 50, height: 50)
                        .blur(radius: 1)

                    Circle()
                        .fill(BackgroundAgentSideDockColors.successGreen.opacity(0.18))
                        .frame(width: 38, height: 38)
                }

                if mascotDockVisualState == .failed {
                    Circle()
                        .stroke(
                            BackgroundAgentSideDockColors.failureOrange.opacity(0.55),
                            lineWidth: 2.5
                        )
                        .frame(width: 48, height: 48)
                }

                if isAgentActivelyWorking {
                    ProgressView()
                        .scaleEffect(0.55)
                        .offset(x: -4, y: 4)
                }

                Triangle()
                    .fill(mascotDockAccentColor)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: mascotDockAccentColor.opacity(mascotDockVisualState == .completed ? 1.0 : 0.85), radius: mascotDockGlowRadius, x: 0, y: 0)
                    .offset(y: mascotBobOffset)

                if mascotDockVisualState == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(BackgroundAgentSideDockColors.successGreen)
                        .background(Circle().fill(Color.black.opacity(0.85)))
                        .offset(x: 14, y: -14)
                }

                if mascotDockVisualState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(BackgroundAgentSideDockColors.failureOrange)
                        .offset(x: 14, y: -14)
                }
            }
            .scaleEffect(completionBounceScale)
            .frame(width: 44, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(mascotDockBackgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(mascotDockBorderColor, lineWidth: mascotDockBorderWidth)
                    )
            )
            .shadow(color: mascotDockAccentColor.opacity(mascotDockShadowOpacity), radius: mascotDockShadowRadius, x: -2, y: 0)
        }
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.45, dampingFraction: 0.68), value: mascotDockVisualState)
        .onHover { isHovering in
            isHoveringOverDock = isHovering
        }
        .pointerCursor()
    }

    private var mascotDockGlowRadius: CGFloat {
        switch mascotDockVisualState {
        case .completed:
            return 16
        case .failed:
            return 14
        case .working, .idle:
            return 10
        }
    }

    private var mascotDockBackgroundFill: Color {
        switch mascotDockVisualState {
        case .completed:
            return BackgroundAgentSideDockColors.successGreen.opacity(isHoveringOverDock ? 0.28 : 0.22)
        case .failed:
            return BackgroundAgentSideDockColors.failureOrange.opacity(isHoveringOverDock ? 0.22 : 0.16)
        case .working, .idle:
            return Color.black.opacity(isHoveringOverDock ? 0.72 : 0.55)
        }
    }

    private var mascotDockBorderColor: Color {
        switch mascotDockVisualState {
        case .completed:
            return BackgroundAgentSideDockColors.successGreen.opacity(isHoveringOverDock ? 0.95 : 0.75)
        case .failed:
            return BackgroundAgentSideDockColors.failureOrange.opacity(isHoveringOverDock ? 0.9 : 0.7)
        case .working, .idle:
            return cursorAccentColor.opacity(isHoveringOverDock ? 0.55 : 0.28)
        }
    }

    private var mascotDockBorderWidth: CGFloat {
        mascotDockVisualState == .completed || mascotDockVisualState == .failed ? 2 : 1
    }

    private var mascotDockShadowOpacity: Double {
        switch mascotDockVisualState {
        case .completed:
            return 0.55
        case .failed:
            return 0.45
        case .working, .idle:
            return 0.25
        }
    }

    private var mascotDockShadowRadius: CGFloat {
        switch mascotDockVisualState {
        case .completed:
            return 20
        case .failed:
            return 16
        case .working, .idle:
            return 12
        }
    }

    private func triggerCompletionCelebrationAnimation() {
        completionBounceScale = 1.0
        completionGlowPulseOpacity = 0.35

        withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) {
            completionBounceScale = 1.14
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                completionBounceScale = 1.0
            }
        }

        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            completionGlowPulseOpacity = 0.95
        }
    }

    private func triggerFailureAttentionAnimation() {
        completionBounceScale = 1.0

        withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) {
            completionBounceScale = 1.08
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                completionBounceScale = 1.0
            }
        }
    }

    private func composioSyncCard(syncPrompt: ComposioSyncPromptState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(BackgroundAgentSideDockColors.accentBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync \(syncPrompt.displayName) with Teachy")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(BackgroundAgentSideDockColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("You're in \(syncPrompt.frontmostAppName). Connect once so Teachy can help in the background.")
                        .font(.system(size: 11))
                        .foregroundColor(BackgroundAgentSideDockColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let lastConnectionError = composioConnectionManager.lastConnectionError {
                Text(lastConnectionError)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Button(action: {
                    Task {
                        await composioConnectionManager.connectActiveToolkit()
                    }
                }) {
                    HStack(spacing: 6) {
                        if composioConnectionManager.isConnectingToolkit {
                            ProgressView()
                                .scaleEffect(0.55)
                        }
                        Text(composioConnectionManager.isConnectingToolkit ? "Connecting..." : "Sync now")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(BackgroundAgentSideDockColors.accentBlue))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(composioConnectionManager.isConnectingToolkit)

                Button(action: {
                    composioConnectionManager.dismissActiveSyncPrompt()
                }) {
                    Text("Not now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(BackgroundAgentSideDockColors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(14)
        .frame(width: 268, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BackgroundAgentSideDockColors.panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BackgroundAgentSideDockColors.accentBlue.opacity(0.35), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: -4, y: 0)
        .padding(.trailing, 8)
        .onHover { isHovering in
            isHoveringOverDock = isHovering
        }
    }

    private func startMascotBobAnimationIfNeeded() {
        guard isAgentActivelyWorking else { return }

        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            mascotBobOffset = -3
        }
    }
}

private enum ComposioSyncAttentionFeedback {
    static func play() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        if let attentionSound = NSSound(named: "Tink") {
            attentionSound.play()
        }
    }
}

private enum BackgroundAgentMascotDockVisualState {
    case idle
    case working
    case completed
    case failed
}

private enum BackgroundAgentSideDockColors {
    static let panelBackground = Color(hex: "#0A0A0A").opacity(0.94)
    static let accentBlue = Color(hex: "#3380FF")
    static let successGreen = Color(hex: "#30D158")
    static let failureOrange = Color(hex: "#FF9F0A")
    static let textPrimary = Color(hex: "#F0F0F0")
    static let textSecondary = Color(hex: "#A0A0A0")
    static let textTertiary = Color(hex: "#666666")
}

private enum BackgroundAgentSideDockFormatting {
    static func formattedToolName(_ toolName: String) -> String {
        switch toolName {
        case "web_search", "openrouter:web_search":
            return "web search"
        case "web_fetch", "openrouter:web_fetch":
            return "web fetch"
        case "authenticated_fetch":
            return "authenticated fetch"
        case "list_browser_sessions":
            return "browser sessions"
        case "capture_screen":
            return "screen capture"
        case "run_applescript":
            return "applescript"
        case "ui_action":
            return "ui action"
        case "read_file":
            return "read file"
        case "write_file":
            return "write file"
        default:
            if toolName.contains("__") {
                let parts = toolName.split(separator: "__", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let connectorLabel = parts[0].replacingOccurrences(of: "_", with: " ")
                    let toolLabel = parts[1].replacingOccurrences(of: "_", with: " ")
                    return "\(connectorLabel): \(toolLabel)"
                }
            }
            return toolName.replacingOccurrences(of: "_", with: " ")
        }
    }
}
