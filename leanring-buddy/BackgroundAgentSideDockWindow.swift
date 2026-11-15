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

    /// The mascot is Teachy's pointer, so it is the pointer colour until the job
    /// ends: green when it is done, red when it failed.
    private var mascotDockAccentColor: Color {
        switch mascotDockVisualState {
        case .idle, .working:
            return cursorAccentColor
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructive
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
                        .stroke(mascotDockAccentColor.opacity(completionGlowPulseOpacity), lineWidth: 2)
                        .frame(width: 38, height: 38)
                }

                if mascotDockVisualState == .failed {
                    Circle()
                        .stroke(mascotDockAccentColor.opacity(0.55), lineWidth: 2)
                        .frame(width: 38, height: 38)
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
                    .offset(y: mascotBobOffset)

                if mascotDockVisualState == .completed {
                    TeachyStatusMark(kind: .done)
                        .offset(x: 14, y: -17)
                }

                if mascotDockVisualState == .failed {
                    TeachyStatusMark(kind: .failed)
                        .offset(x: 14, y: -17)
                }
            }
            .scaleEffect(completionBounceScale)
            .frame(width: 44, height: 52)
            .teachyTile(cornerRadius: DS.CornerRadius.group)
        }
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.45, dampingFraction: 0.68), value: mascotDockVisualState)
        .onHover { isHovering in
            isHoveringOverDock = isHovering
        }
        .pointerCursor()
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
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync \(syncPrompt.displayName) with Teachy")
                    .font(DS.Fonts.itemTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Connect once so Teachy can help in the background.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastConnectionError = composioConnectionManager.lastConnectionError {
                Text(lastConnectionError)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Button(action: {
                    Task {
                        await composioConnectionManager.connectActiveToolkit()
                    }
                }) {
                    Text(composioConnectionManager.isConnectingToolkit ? "Connecting..." : "Sync now")
                }
                .teachyButton(.primary, size: .compact)
                .disabled(composioConnectionManager.isConnectingToolkit)

                Button(action: {
                    composioConnectionManager.dismissActiveSyncPrompt()
                }) {
                    Text("Not now")
                }
                .teachyButton(.quiet, size: .compact)
            }
        }
        .padding(14)
        .frame(width: 268, alignment: .leading)
        .teachyTile()
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
