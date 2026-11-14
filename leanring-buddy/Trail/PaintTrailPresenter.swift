//
//  PaintTrailPresenter.swift
//  leanring-buddy
//
//  The paint trail: while the talk key is held, the pointer leaves a stroke in
//  the cursor colour so the person can circle the thing they mean. It fades
//  away after the key is released. Display only: it never changes what
//  `MouseOutlineTracker` records or what is sent to the model.
//
//  Call `begin()` when the key goes down and `end()` when it comes up. By
//  default the presenter follows the pointer itself; pass `followsPointer:
//  false` and call `addPoint(_:)` to feed it points from somewhere else.
//
//  Drawn in a transparent, click-through panel per display, created the first
//  time the stroke reaches that display.
//

import AppKit

@MainActor
final class PaintTrailPresenter {
    static let shared = PaintTrailPresenter()

    var configuration = PaintTrailConfiguration()

    /// Global AppKit coordinates (origin bottom-left of the main display).
    private(set) var points: [PaintTrailPoint] = []
    private var releasedAt: TimeInterval?
    private var isHeld = false
    private var followsPointer = true
    private var color: NSColor = .systemBlue
    private var frameTimer: Timer?
    private var panels: [PaintTrailPanel] = []

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The talk key went down: start a fresh stroke.
    func begin(followsPointer: Bool = true) {
        points.removeAll(keepingCapacity: true)
        releasedAt = nil
        isHeld = true
        self.followsPointer = followsPointer
        color = TeachySettings.currentCursorNSColor
        panels.forEach { $0.trailView.needsDisplay = true }
        startFrameTimer()
        if followsPointer { addPoint(NSEvent.mouseLocation) }
    }

    /// Adds one pointer position (global AppKit coordinates). Ignored unless a stroke is in progress.
    func addPoint(_ globalPoint: CGPoint) {
        guard isHeld else { return }
        let point = PaintTrailPoint(x: Double(globalPoint.x), y: Double(globalPoint.y), time: now)
        guard PaintTrailMath.append(point, to: &points, configuration: configuration) else { return }
        showPanel(containing: globalPoint)
    }

    /// The talk key came up: the stroke stays for a moment and fades out.
    func end() {
        guard isHeld else { return }
        isHeld = false
        releasedAt = now
        // A press with no real movement leaves nothing worth fading.
        if PaintTrailMath.length(of: points) < 4 { clear() }
    }

    /// Removes the stroke immediately.
    func clear() {
        isHeld = false
        releasedAt = nil
        points.removeAll(keepingCapacity: true)
        frameTimer?.invalidate()
        frameTimer = nil
        panels.forEach { $0.orderOut(nil) }
    }

    // MARK: Frames

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this is the main thread.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func tick() {
        let time = now
        if isHeld {
            if followsPointer { addPoint(NSEvent.mouseLocation) }
            points = PaintTrailMath.pruned(points, now: time, releasedAt: nil, configuration: configuration)
        } else if PaintTrailMath.isFinished(now: time, releasedAt: releasedAt, configuration: configuration) {
            clear()
            return
        }
        let snapshot = makeSnapshot(at: time)
        for panel in panels where panel.isVisible {
            panel.trailView.update(snapshot)
        }
    }

    private func makeSnapshot(at time: TimeInterval) -> PaintTrailSnapshot {
        PaintTrailSnapshot(
            points: points,
            widths: PaintTrailMath.widths(for: points, now: time, releasedAt: releasedAt, configuration: configuration),
            opacity: PaintTrailMath.releaseOpacity(now: time, releasedAt: releasedAt, configuration: configuration),
            color: color
        )
    }

    // MARK: Panels

    private func showPanel(containing globalPoint: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(globalPoint) }) else { return }
        if let existing = panels.first(where: { $0.frame == screen.frame }) {
            if !existing.isVisible { existing.orderFrontRegardless() }
            return
        }
        // Displays were rearranged: drop panels that no longer match one.
        panels.removeAll { panel in
            let isStale = !NSScreen.screens.contains { $0.frame == panel.frame }
            if isStale { panel.orderOut(nil) }
            return isStale
        }
        let panel = PaintTrailPanel(screenFrame: screen.frame)
        panels.append(panel)
        panel.orderFrontRegardless()
    }
}

struct PaintTrailSnapshot {
    var points: [PaintTrailPoint] = []
    var widths: [Double] = []
    var opacity: Double = 1
    var color: NSColor = .systemBlue
}

/// Transparent, click-through, covers one display.
final class PaintTrailPanel: NSPanel {
    let trailView: PaintTrailView

    init(screenFrame: NSRect) {
        trailView = PaintTrailView(frame: NSRect(origin: .zero, size: screenFrame.size))
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Same level as the companion overlay, so the stroke is above menus too.
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        trailView.autoresizingMask = [.width, .height]
        contentView = trailView
        setFrame(screenFrame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PaintTrailView: NSView {
    private var snapshot = PaintTrailSnapshot()
    private var lastDrawnBounds: CGRect = .null

    override var isOpaque: Bool { false }

    /// Takes the latest stroke and redraws only the part of the screen it touches.
    func update(_ newSnapshot: PaintTrailSnapshot) {
        snapshot = newSnapshot
        let strokeBounds = localBounds(of: newSnapshot)
        let dirty = strokeBounds.union(lastDrawnBounds)
        lastDrawnBounds = strokeBounds
        if !dirty.isNull { setNeedsDisplay(dirty.intersection(bounds)) }
    }

    /// Renders a snapshot whose points are already in this view's coordinates
    /// (used for offscreen previews).
    func setLocalSnapshot(_ localSnapshot: PaintTrailSnapshot) {
        snapshot = localSnapshot
        localOrigin = .zero
        needsDisplay = true
    }

    /// Where this view's bottom-left corner is in global coordinates.
    private var localOrigin: CGPoint?

    private var originInGlobalCoordinates: CGPoint {
        localOrigin ?? window?.frame.origin ?? .zero
    }

    private func localPoint(_ point: PaintTrailPoint) -> CGPoint {
        let origin = originInGlobalCoordinates
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    private func localBounds(of snapshot: PaintTrailSnapshot) -> CGRect {
        guard let first = snapshot.points.first else { return .null }
        var rect = CGRect(origin: localPoint(first), size: .zero)
        for point in snapshot.points.dropFirst() {
            rect = rect.union(CGRect(origin: localPoint(point), size: .zero))
        }
        // Room for the stroke width and its glow.
        return rect.insetBy(dx: -28, dy: -28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let points = snapshot.points.map(localPoint)
        let widths = snapshot.widths
        guard points.count >= 2, widths.count == points.count, snapshot.opacity > 0.003 else { return }

        context.saveGState()
        context.setAlpha(CGFloat(snapshot.opacity))
        // One soft glow under the whole stroke. Drawing inside a transparency
        // layer keeps overlapping segments from showing as darker beads.
        context.setShadow(offset: .zero, blur: 7, color: snapshot.color.withAlphaComponent(0.55).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(snapshot.color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        func stroke(width: Double, _ build: (CGContext) -> Void) {
            guard width > 0.35 else { return }
            context.setLineWidth(CGFloat(width))
            context.beginPath()
            build(context)
            context.strokePath()
        }

        if points.count == 2 {
            stroke(width: (widths[0] + widths[1]) / 2) {
                $0.move(to: points[0])
                $0.addLine(to: points[1])
            }
        } else {
            // Each piece is a curve through one recorded point, from the midpoint
            // before it to the midpoint after it, at that point's width.
            stroke(width: widths[0]) {
                $0.move(to: points[0])
                $0.addLine(to: midpoint(points[0], points[1]))
            }
            for index in 1..<(points.count - 1) {
                stroke(width: widths[index]) {
                    $0.move(to: midpoint(points[index - 1], points[index]))
                    $0.addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
                }
            }
            let last = points.count - 1
            stroke(width: widths[last]) {
                $0.move(to: midpoint(points[last - 1], points[last]))
                $0.addLine(to: points[last])
            }
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }
}
