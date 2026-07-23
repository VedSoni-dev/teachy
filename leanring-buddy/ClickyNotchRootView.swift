//
//  ClickyNotchRootView.swift
//  leanring-buddy
//
//  Root notch UI — mirrors boring.notch ContentView:
//  black NotchShape, closed live-activity wings, spring open height, hover chin.
//

import AppKit
import SwiftUI

struct ClickyNotchRootView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager

    @Namespace private var notchNamespace
    @State private var gestureProgress: CGFloat = 0
    @State private var idleIconPulseScale: CGFloat = 1.0

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
            || companionManager.coursesManager.isCourseActive
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
            // Symmetric wings keep the black center aligned with the camera;
            // without a left spacer, centering slides the icon under the housing.
            width += 2 * idleRightWingWidth + idleIconGapFromNotch
        }
        return width
    }

    /// Right wing wide enough for the glowing Clicky triangle.
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
                    .background(Color.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        // Seals the top edge against the bezel (boring.notch hairline).
                        Rectangle()
                            .fill(Color.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (notchManager.isExpanded || notchManager.isHoveringNotch)
                            ? Color.black.opacity(0.7)
                            : .clear,
                        radius: 6
                    )

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
        .onChange(of: companionManager.coursesManager.isCourseActive) { isActive in
            if isActive {
                notchManager.selectedTab = .courses
            }
        }
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
            // Matching left spacer — keeps the black center locked to the camera
            // so the Clicky icon on the right sits fully past the housing.
            Color.clear
                .frame(width: idleRightWingWidth, height: wingSize)

            Rectangle()
                .fill(Color.black)
                .frame(width: max(0, closedNotchWidth))

            Color.clear
                .frame(width: idleIconGapFromNotch)

            idleClickyIcon
                .frame(width: idleRightWingWidth, height: closedNotchHeight)
        }
        .frame(height: closedNotchHeight, alignment: .center)
    }

    /// Clicky triangle past the camera — glowing so idle is obvious.
    private var idleClickyIcon: some View {
        ZStack {
            Triangle()
                .fill(companionManager.selectedCursorColor.displayColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-35))
                .blur(radius: 7)
                .opacity(0.55)
                .scaleEffect(idleIconPulseScale * 1.35)

            Triangle()
                .fill(companionManager.selectedCursorColor.displayColor)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(-35))
                .shadow(
                    color: companionManager.selectedCursorColor.displayColor.opacity(0.7),
                    radius: 4
                )
                .scaleEffect(idleIconPulseScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .matchedGeometryEffect(id: "clickyCursor", in: notchNamespace)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                idleIconPulseScale = 1.12
            }
        }
    }

    // MARK: - Closed: live activity (listening / course / processing)

    private var liveActivityRow: some View {
        HStack(spacing: 0) {
            closedCursorBadge
                .frame(width: wingSize, height: wingSize)
                .matchedGeometryEffect(id: "clickyCursor", in: notchNamespace)

            Rectangle()
                .fill(Color.black)
                .overlay {
                    if companionManager.voiceState != .idle {
                        Text(liveStatusLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
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
        ZStack {
            Triangle()
                .fill(companionManager.selectedCursorColor.displayColor)
                .frame(width: wingSize * 0.85, height: wingSize * 0.85)
                .rotationEffect(.degrees(-35))
                .blur(radius: 8)
                .opacity(companionManager.voiceState == .listening ? 0.55 : 0.25)
                .scaleEffect(1.35)

            Triangle()
                .fill(companionManager.selectedCursorColor.displayColor)
                .frame(width: max(10, wingSize * 0.55), height: max(10, wingSize * 0.55))
                .rotationEffect(.degrees(-35))
        }
    }

    private var liveStatusLabel: String {
        switch companionManager.voiceState {
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        case .idle:
            if companionManager.coursesManager.isCourseActive { return "Course" }
            return "Ready"
        }
    }

    // MARK: - Open header (boring.notch BoringHeader style)

    private var clickyNotchHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if companionManager.allPermissionsGranted && companionManager.hasCompletedOnboarding {
                    headerTab(.courses, title: "Learn", systemImage: "book.fill")
                    headerTab(.progress, title: "Progress", systemImage: "chart.line.uptrend.xyaxis")
                    headerTab(.portfolio, title: "Portfolio", systemImage: "folder.fill")
                    headerTab(.skills, title: "Skills", systemImage: "chart.bar.xaxis")
                    headerTab(.home, title: "Settings", systemImage: "slider.horizontal.3")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(notchManager.isExpanded ? 1 : 0)
            .blur(radius: notchManager.isExpanded ? 0 : 20)

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

    private func headerTab(_ tab: NotchPanelTab, title: String, systemImage: String) -> some View {
        let isSelected = notchManager.selectedTab == tab
        let tint = tabAccent(tab)
        return Button {
            withAnimation(.smooth(duration: 0.28)) { notchManager.selectedTab = tab }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? tint : Color.gray)
                .frame(width: 28, height: 22)
                .background(Capsule().fill(isSelected ? tint.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(title)
    }

    private func tabAccent(_ tab: NotchPanelTab) -> Color {
        switch tab {
        case .courses: return DS.Colors.learnAccent       // teal
        case .progress: return DS.Colors.success          // green
        case .portfolio: return DS.Colors.portfolioAccent // orange
        case .skills: return DS.Colors.skillsAccent       // purple
        default: return .white                             // Settings/home stays neutral
        }
    }
}

// MARK: - Hover icon (boring.notch HoverButton)

private struct ClickyNotchHoverIconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Capsule()
                        .fill(isHovering ? Color.gray.opacity(0.25) : Color.black)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.25)) {
                isHovering = hovering
            }
        }
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
