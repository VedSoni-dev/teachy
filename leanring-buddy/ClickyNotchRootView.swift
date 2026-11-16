//
//  ClickyNotchRootView.swift
//  leanring-buddy
//
//  Root notch UI — mirrors boring.notch ContentView:
//  system glass in the NotchShape (lightly dimmed closed, more so open),
//  closed live-activity wings, spring open height, hover chin.
//

import AppKit
import SwiftUI

struct ClickyNotchRootView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var notchNamespace
    @State private var gestureProgress: CGFloat = 0

    private var geometry: NotchScreenGeometry {
        notchManager.currentNotchGeometry()
    }

    private var closedNotchWidth: CGFloat {
        geometry.hasNotch ? max(geometry.notchWidth, 160) : 0
    }

    private var closedNotchHeight: CGFloat {
        if geometry.hasNotch {
            return max(geometry.notchHeight, 32)
        }
        return 36
    }

    private var wingSize: CGFloat {
        max(0, closedNotchHeight - 12)
    }

    private var isLiveActivityActive: Bool {
        companionManager.voiceState != .idle
            || companionManager.backgroundAgentManager.status.isActivelyRunning
    }

    private var topCornerRadius: CGFloat {
        notchManager.isExpanded
            ? ClickyNotchSizing.cornerRadiusInsets.opened.top
            : ClickyNotchSizing.cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        notchManager.isExpanded
            ? ClickyNotchSizing.cornerRadiusInsets.opened.bottom
            : ClickyNotchSizing.cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: ClickyNotchShape {
        ClickyNotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    private var closedHorizontalPadding: CGFloat { isLiveActivityActive ? 14 : 8 }
    private var idleWingWidth: CGFloat { geometry.hasNotch ? 24 : 32 }

    private var chinWidth: CGFloat {
        if isLiveActivityActive { return closedNotchWidth + 2 * wingSize + 2 * closedHorizontalPadding }
        return (geometry.hasNotch ? closedNotchWidth + 2 * idleWingWidth : idleWingWidth)
            + 2 * closedHorizontalPadding
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                notchLayout
                    .frame(width: notchManager.isExpanded ? notchManager.expandedSize.width : chinWidth,
                           height: notchManager.isExpanded ? notchManager.expandedSize.height : closedNotchHeight,
                           alignment: .top)
                    .background(DS.Colors.notchBlack)
                    .clipShape(currentNotchShape)
                    .animation(reduceMotion ? nil : (notchManager.isExpanded
                        ? ClickyNotchSizing.openSpring : ClickyNotchSizing.closeSpring),
                        value: notchManager.isExpanded)
                    // Limit file-drop handling to the visible shell, not its animation canvas.
                    .attachmentDropTarget(cornerRadius: 24, showsHighlight: notchManager.isExpanded) { isOver in
                        notchManager.setAttachmentDragTargeted(isOver)
                        if isOver {
                            notchManager.selectedTab = .chat
                            if !notchManager.isExpanded { notchManager.expand() }
                        }
                    }
                    .contentShape(currentNotchShape)
                    .onTapGesture {
                        if !notchManager.isExpanded {
                            notchManager.expand()
                        }
                    }
                    .contextMenu {
                        Button("Collapse") {
                            notchManager.collapse()
                        }
                        .disabled(!notchManager.isExpanded)

                        Divider()

                        Button("Quit Teachy") {
                            NSApp.terminate(nil)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 16)
                            .onChanged { value in
                                guard !notchManager.isExpanded else { return }
                                gestureProgress = min(max(value.translation.height / 8, 0), 20)
                            }
                            .onEnded { value in
                                defer {
                                    withAnimation(ClickyNotchSizing.interactiveSpring) {
                                        gestureProgress = 0
                                    }
                                }
                                guard !notchManager.isExpanded else { return }
                                if value.translation.height > 36 {
                                    notchManager.expand()
                                }
                            }
                    )

                // Nearly-invisible hover chin under the closed notch.
                if !notchManager.isExpanded {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: chinWidth, height: ClickyNotchSizing.chinHeight)
                }
            }
            .onHover { notchManager.handleNotchHover($0) }
        }
        .padding(.bottom, 8)
        .frame(
            maxWidth: notchManager.hostingSize.width,
            maxHeight: notchManager.hostingSize.height,
            alignment: .top
        )
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .preferredColorScheme(.dark)

    }

    private var gestureScale: CGFloat {
        guard gestureProgress != 0 else { return 1 }
        return max(0.85, 1 + gestureProgress * 0.01)
    }

    // MARK: - Layout

    @ViewBuilder
    private var notchLayout: some View {
        ZStack(alignment: .top) {
            if notchManager.isExpanded {
                // Lay out once at the destination size. The surrounding silhouette
                // reveals it from the camera, instead of scaling or reflowing text.
                VStack(spacing: 0) {
                    clickyNotchHeader
                        .frame(height: notchManager.selectedTab == .home || notchManager.selectedTab == .chat ? 44 : 50)
                        .background(DS.Colors.notchBlack)
                    NotchPanelView(companionManager: companionManager, notchManager: notchManager)
                }
                // The notch shoulders occupy real horizontal space; keep all
                // content inside their straight edges before applying page gutters.
                .padding(.horizontal, ClickyNotchSizing.cornerRadiusInsets.opened.top)
                .frame(width: notchManager.expandedSize.width, height: notchManager.expandedSize.height, alignment: .top)
                .transition(.opacity)
            } else {
                Group {
                    if isLiveActivityActive { liveActivityRow }
                    else { idleClosedRow }
                }
                .padding(.horizontal, closedHorizontalPadding)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Closed: idle

    private var idleClosedRow: some View {
        HStack(spacing: 0) {
            if geometry.hasNotch {
                // Equal wings keep the hardware camera exactly centered.
                Color.clear.frame(width: idleWingWidth, height: closedNotchHeight)
                Color.clear.frame(width: closedNotchWidth)
            }
            idleClickyIcon
                .frame(width: idleWingWidth, height: closedNotchHeight)
        }
        .frame(height: closedNotchHeight, alignment: .center)
    }

    /// Teachy's pointer past the camera: one crisp triangle in the person's colour.
    /// It sits still. Nothing in the notch moves until something is happening.
    private var idleClickyIcon: some View {
        Triangle()
            .fill(companionManager.selectedCursorColor.displayColor)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(-35))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .matchedGeometryEffect(id: "clickyCursor", in: notchNamespace)
    }

    // MARK: - Closed: live activity (listening / thinking / speaking / agent job)

    private var liveActivityRow: some View {
        HStack(spacing: 0) {
            closedCursorBadge
                .frame(width: wingSize, height: wingSize)
                .matchedGeometryEffect(id: "clickyCursor", in: notchNamespace)

            Color.clear
                .overlay {
                    if companionManager.voiceState != .idle {
                        Text(liveStatusLabel)
                            .font(DS.Fonts.data)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .opacity(0) // reserved for sneak-peek style later
                    }
                }
                .frame(width: max(0, closedNotchWidth))

            HStack {
                ClickyAudioSpectrumView(
                    isAnimating: companionManager.voiceState == .listening
                        || companionManager.voiceState == .processing
                        || companionManager.voiceState == .responding
                        || companionManager.backgroundAgentManager.status.isActivelyRunning,
                    color: companionManager.selectedCursorColor.displayColor
                )
                .frame(width: 16, height: 12)
            }
            .frame(width: wingSize, height: wingSize, alignment: .center)
            .matchedGeometryEffect(id: "clickySpectrum", in: notchNamespace)
        }
        .frame(height: closedNotchHeight, alignment: .center)
    }

    private var closedCursorBadge: some View {
        Triangle()
            .fill(companionManager.selectedCursorColor.displayColor)
            .frame(width: max(10, wingSize * 0.55), height: max(10, wingSize * 0.55))
            .rotationEffect(.degrees(-35))
    }

    private var liveStatusLabel: String {
        switch companionManager.voiceState {
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        case .idle: return "Ready"
        }
    }

    // MARK: - Open header (boring.notch BoringHeader style)

    private func headerTab(_ tab: NotchPanelTab) -> some View {
        Button { notchManager.selectedTab = tab } label: {
            Image(systemName: tab.symbol)
                .font(DS.Fonts.controlCompact)
                .foregroundColor(notchManager.selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: 34, height: 26)
                .background(notchManager.selectedTab == tab ? DS.Colors.fillPrimary : .clear, in: Capsule())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(notchManager.selectedTab == tab ? .isSelected : [])
    }

    private var clickyNotchHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                headerTab(.home)
                headerTab(.chat)
            }
            .padding(2)
            .background(DS.Colors.fillTertiary, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.black.frame(width: closedNotchWidth)

            HStack(spacing: 8) {
                Button("Account") { notchManager.openSettings(.account) }
                    .font(DS.Fonts.controlCompact)
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(LinearGradient(colors: [.white, DS.Colors.pointer.opacity(0.6)], startPoint: .top, endPoint: .bottom), in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Colors.pointer.opacity(0.6), lineWidth: 1))
                    .buttonStyle(.plain).pointerCursor()
                ClickyNotchHoverIconButton(systemName: "gearshape.fill") {
                    notchManager.openSettings(.general)
                }
                .accessibilityLabel("Teachy settings")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(DS.Colors.textSecondary)
    }

}

// MARK: - Header icon button

private struct ClickyNotchHoverIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .teachyIconButton(sideLength: 28)
    }
}

private extension AgentStatus {
    var isActivelyRunning: Bool {
        switch self {
        case .reasoning, .running: return true
        case .idle, .completed, .failed: return false
        }
    }
}
