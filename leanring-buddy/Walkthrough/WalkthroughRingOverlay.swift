//
//  WalkthroughRingOverlay.swift
//  leanring-buddy / Walkthrough
//
//  The ring around the control a walkthrough step is about: a clean ring in the
//  pointer colour plus a small label tile, in a transparent panel that ignores
//  the mouse entirely. It follows its control when the window moves and fades
//  when the step is done.
//

import AppKit
import Combine
import simd
import SwiftUI

/// Where the panel goes and how the ring sits inside it. Pure geometry.
struct WalkthroughRingLayout: Equatable {
    static let pillAreaHeight: CGFloat = 34
    static let strokeRoom: CGFloat = 12
    static let minimumPanelWidth: CGFloat = 300
    static let pillHalfWidth: CGFloat = 140

    /// Size of the box the loop is drawn in.
    var ringSize: CGSize
    /// The panel's frame in AppKit screen coordinates (bottom-left origin).
    var panelFrame: CGRect
    var labelBelow: Bool
    /// Sideways nudge that keeps the pill on screen when the control hugs a screen edge.
    var pillOffsetX: CGFloat

    /// - Parameters:
    ///   - target: the control's frame in global CG coordinates (top-left origin).
    ///   - screenCG: the frame of the display the control is on, in global CG coordinates.
    ///   - primaryHeight: the primary display's height (flips CG y to AppKit y).
    static func make(target: CGRect, screenCG: CGRect, primaryHeight: CGFloat, isApproximate: Bool) -> WalkthroughRingLayout {
        // The loop passes a little outside the control's corners, like a circle drawn around a word.
        let ringWidth = max(target.width * 1.22 + 18, 44) + strokeRoom * 2
        let ringHeight = max(target.height * 1.34 + 14, isApproximate ? 44 : 34) + strokeRoom * 2

        let ringTop = target.midY - ringHeight / 2
        let roomAbove = ringTop - screenCG.minY
        let labelBelow = roomAbove < pillAreaHeight + 26

        var pillOffset: CGFloat = 0
        if screenCG.width > pillHalfWidth * 2 + 16 {
            let wanted = min(max(target.midX, screenCG.minX + pillHalfWidth + 8), screenCG.maxX - pillHalfWidth - 8)
            pillOffset = wanted - target.midX
        }

        let width = max(ringWidth, minimumPanelWidth + abs(pillOffset) * 2)
        let height = ringHeight + pillAreaHeight
        let topCG = labelBelow ? ringTop : ringTop - pillAreaHeight
        let frame = CGRect(x: target.midX - width / 2, y: primaryHeight - topCG - height, width: width, height: height)
        return WalkthroughRingLayout(ringSize: CGSize(width: ringWidth, height: ringHeight), panelFrame: frame, labelBelow: labelBelow, pillOffsetX: pillOffset)
    }
}

@MainActor
final class WalkthroughRingModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case shown
        case completed
    }

    @Published var label = ""
    @Published var stepNumber = 1
    @Published var stepCount = 1
    @Published var ringSize = CGSize(width: 120, height: 60)
    @Published var labelBelow = false
    @Published var pillOffsetX: CGFloat = 0
    @Published var isApproximate = false
    @Published var phase: Phase = .hidden
    /// Changes with each step so the ring is drawn on again from the start.
    @Published var seed = "ring"
}

/// The ring itself: a clean ellipse. `progress` 0→1 draws it on, starting at the
/// upper left and going once round.
struct WalkthroughRingShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // A unit circle that starts at the upper left, stretched to fill the box.
        var unitCircle = Path()
        unitCircle.addArc(center: .zero, radius: 1, startAngle: .degrees(-135), endAngle: .degrees(225), clockwise: false)
        let ellipse = unitCircle.applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: rect.width / 2, y: rect.height / 2)
        )
        return ellipse.trimmedPath(from: 0, to: min(max(progress, 0), 1))
    }
}

struct WalkthroughRingView: View {
    @ObservedObject var model: WalkthroughRingModel
    /// For still renders: show the finished ring without animating.
    var frozen = false

    @State private var drawn: Double = 0

    /// The pointer colour (Teachy's tint) while the step is waiting; green once it is done.
    private var ringColor: Color {
        model.phase == .completed ? DS.Colors.success : DS.Colors.pointer
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.labelBelow { pill }
            ring
            if model.labelBelow { pill }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.phase == .shown || frozen ? 1 : 0)
        .scaleEffect(model.phase == .completed ? 1.06 : 1)
        .animation(.easeOut(duration: model.phase == .completed ? 0.4 : 0.18), value: model.phase)
        .onAppear { redraw() }
        .onChange(of: model.seed) { _, _ in redraw() }
        .allowsHitTesting(false)
    }

    private var ring: some View {
        let inset = WalkthroughRingLayout.strokeRoom
        let progress = frozen ? 1 : drawn
        // Dashed for a guessed spot, solid for a real control.
        let dash: [CGFloat] = model.isApproximate ? [10, 8] : []
        return ZStack {
            // A soft dark edge under the stroke keeps it readable on any background.
            WalkthroughRingShape(progress: progress)
                .stroke(DS.Colors.notchBlack.opacity(0.28), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round, dash: dash))
                .blur(radius: 1.5)
            WalkthroughRingShape(progress: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round, dash: dash))
        }
        .padding(inset)
        .frame(width: model.ringSize.width, height: model.ringSize.height)
    }

    /// The step label: a small floating tile with the step count and what to do.
    private var pill: some View {
        HStack(spacing: DS.Spacing.sm) {
            if model.phase == .completed {
                TeachyStatusMark(kind: .done)
            } else {
                Text("\(model.stepNumber) of \(model.stepCount)")
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize()
            }
            if !model.label.isEmpty {
                Text(model.label)
                    .font(DS.Fonts.bodyEmphasized)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 5)
        .teachyTile(cornerRadius: DS.CornerRadius.pill)
        .frame(maxWidth: WalkthroughRingLayout.pillHalfWidth * 2)
        .frame(height: WalkthroughRingLayout.pillAreaHeight)
        .offset(x: model.pillOffsetX)
    }

    private func redraw() {
        guard !frozen else { return }
        drawn = 0
        withAnimation(.easeOut(duration: 0.5)) { drawn = 1 }
    }
}

@MainActor
final class WalkthroughRingOverlay {
    let model = WalkthroughRingModel()
    private var panel: NSPanel?
    private var hideGeneration = 0
    private var currentTarget: CGRect = .zero

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// The display (in global CG coordinates) that holds most of `target`.
    private static func screenCG(containing target: CGRect) -> CGRect {
        let primary = primaryHeight
        let center = CGPoint(x: target.midX, y: target.midY)
        let frames = NSScreen.screens.map { DriveCoordinates.globalCGRect(fromAppKit: $0.frame, primaryDisplayHeight: primary) }
        return frames.first { $0.contains(center) } ?? frames.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func show(_ ring: WalkthroughRing) {
        hideGeneration += 1
        let isNewStep = model.phase != .shown || model.stepNumber != ring.stepNumber || model.label != ring.label
        model.label = ring.label
        model.stepNumber = ring.stepNumber
        model.stepCount = ring.stepCount
        model.isApproximate = ring.isApproximate
        place(target: ring.frame)
        if isNewStep { model.seed = "walk-\(ring.stepNumber)-\(ring.label)-\(hideGeneration)" }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        model.phase = .shown
    }

    /// Keeps the ring on its control when the window is dragged or the page scrolls.
    func move(to target: CGRect) {
        guard model.phase == .shown, target != currentTarget else { return }
        place(target: target)
    }

    func hide(completed: Bool) {
        guard model.phase == .shown else { return }
        hideGeneration += 1
        let generation = hideGeneration
        model.phase = completed ? .completed : .hidden
        let delay: TimeInterval = completed ? 0.45 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.model.phase = .hidden
            self.panel?.orderOut(nil)
        }
    }

    func close() {
        hideGeneration += 1
        model.phase = .hidden
        panel?.orderOut(nil)
        panel = nil
    }

    private func place(target: CGRect) {
        currentTarget = target
        let layout = WalkthroughRingLayout.make(
            target: target,
            screenCG: Self.screenCG(containing: target),
            primaryHeight: Self.primaryHeight,
            isApproximate: model.isApproximate
        )
        model.ringSize = layout.ringSize
        model.labelBelow = layout.labelBelow
        model.pillOffsetX = layout.pillOffsetX
        (panel ?? { let made = makePanel(); panel = made; return made }()).setFrame(layout.panelFrame, display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        // Click-through: the ring can never get between the person and the thing they are clicking.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: WalkthroughRingView(model: model))
        return panel
    }
}
