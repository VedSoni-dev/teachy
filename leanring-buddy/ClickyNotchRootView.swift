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

    @Namespace private var notchNamespace
    @State private var gestureProgress: CGFloat = 0

    private var geometry: NotchScreenGeometry {
        notchManager.currentNotchGeometry()
    }

    private var closedNotchWidth: CGFloat {
        geometry.hasNotch ? max(geometry.notchWidth, 160) : 185
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

    private var chinWidth: CGFloat {
        var width = closedNotchWidth
        if !notchManager.isExpanded && isLiveActivityActive {
            width += 2 * wingSize + 20
        } else if !notchManager.isExpanded {
            // Symmetric wings keep the center aligned with the camera;
            // without a left spacer, centering slides the icon under the housing.
            width += 2 * idleRightWingWidth + idleIconGapFromNotch
        }
        return width
    }

    /// Right wing wide enough for the pointer triangle.
    private var idleRightWingWidth: CGFloat {
        max(wingSize + 14, 40)
    }

    /// Clear gap between the physical camera edge and the idle icon.
    private var idleIconGapFromNotch: CGFloat { 12 }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = notchLayout
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        notchManager.isExpanded
                            ? ClickyNotchSizing.cornerRadiusInsets.opened.top
                            : ClickyNotchSizing.cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], notchManager.isExpanded ? 12 : 0)
                    .clipShape(currentNotchShape)
                    // No drawn shadow and no black hairline: glass brings its own
                    // depth, and either would show through it as a smudge.
                    .background { notchSurface }

                mainLayout
                    .frame(height: notchManager.isExpanded ? ClickyNotchSizing.openNotchSize.height : nil)
                    .animation(
                        notchManager.isExpanded
                            ? ClickyNotchSizing.openSpring
                            : ClickyNotchSizing.closeSpring,
                        value: notchManager.isExpanded
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        notchManager.handleNotchHover(hovering)
                    }
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
        }
        .padding(.bottom, 8)
        .frame(
            maxWidth: ClickyNotchSizing.windowSize.width,
            maxHeight: ClickyNotchSizing.windowSize.height,
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
        // Drop a file on the notch to attach it to the conversation.
        .attachmentDropTarget(cornerRadius: 24, showsHighlight: notchManager.isExpanded) { isOver in
            if isOver, !notchManager.isExpanded { notchManager.expand() }
        }
    }

    /// What the notch is made of: system glass in the notch's silhouette, closed
    /// and open (solid black with Reduce Transparency). The same layer stays
    /// put and its shape grows, so opening reads as one pane unfolding. Closed it
    /// is dimmed lightly so it looks clear at rest, and a little lighter still
    /// under the pointer; open it is dimmed more so small text stays readable.
    private var notchSurface: some View {
        TeachyGlassSurface(shape: currentNotchShape, dimming: notchSurfaceDimming, isClear: !notchManager.isExpanded)
    }

    private var notchSurfaceDimming: Double {
        if notchManager.isExpanded { return TeachyGlass.panelDimming }
        return notchManager.isHoveringNotch ? TeachyGlass.restingDimming * 0.5 : TeachyGlass.restingDimming
    }

    private var gestureScale: CGFloat {
        guard gestureProgress != 0 else { return 1 }
        return max(0.85, 1 + gestureProgress * 0.01)
    }

    // MARK: - Layout

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            closedOrHeaderRow
                .zIndex(2)

            if notchManager.isExpanded {
                NotchPanelView(
                    companionManager: companionManager,
                    notchManager: notchManager
                )
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                        .combined(with: .opacity)
                        .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .opacity(gestureProgress != 0 ? 1 - min(abs(gestureProgress) * 0.1, 0.3) : 1)
            }
        }
    }

    @ViewBuilder
    private var closedOrHeaderRow: some View {
        if notchManager.isExpanded {
            clickyNotchHeader
                .frame(height: max(24, closedNotchHeight))
        } else if isLiveActivityActive {
            liveActivityRow
        } else {
            idleClosedRow
        }
    }

    // MARK: - Closed: idle

    private var idleClosedRow: some View {
        HStack(spacing: 0) {
            // Matching left spacer — keeps the clear center locked to the camera
            // so the Clicky icon on the right sits fully past the housing.
            Color.clear
                .frame(width: idleRightWingWidth, height: wingSize)

            Color.clear
                .frame(width: max(0, closedNotchWidth))

            Color.clear
                .frame(width: idleIconGapFromNotch)

            idleClickyIcon
                .frame(width: idleRightWingWidth, height: closedNotchHeight)
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
                .frame(width: max(0, closedNotchWidth - ClickyNotchSizing.cornerRadiusInsets.closed.top))

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

    private var clickyNotchHeader: some View {
        HStack(spacing: 0) {
            // Home is the only tab, so the left side of the header has no tab buttons.
            Color.clear
                .frame(maxWidth: .infinity)

            // Physical camera bay — black mask matching closed notch width.
            Rectangle()
                .fill(geometry.hasNotch ? Color.black : Color.clear)
                .frame(width: closedNotchWidth)
                .mask { ClickyNotchShape() }

            HStack(spacing: 4) {
                closedCursorBadge
                    .frame(width: 28, height: 28)
                    .matchedGeometryEffect(id: "clickyCursor", in: notchNamespace)

                ClickyNotchHoverIconButton(systemName: "gearshape") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }

                ClickyNotchHoverIconButton(systemName: "chevron.compact.up") {
                    notchManager.collapse()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(notchManager.isExpanded ? 1 : 0)
            .blur(radius: notchManager.isExpanded ? 0 : 20)
        }
        .foregroundStyle(.gray)
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
