//
//  SceneOverlayView.swift
//  leanring-buddy / Scene
//
//  The 2D half of the drawing engine: hand-drawn rings, boxes, arrows, lines,
//  polygons, label pills and highlighter swipes over the live screen.
//
//  Coordinates in the script are 0–1000 across and down a screenshot. The host
//  gives the view the rectangle (in view points) that screenshot covers, so the
//  same script lands correctly on any display.
//

import AppKit
import Combine
import simd
import SwiftUI

// MARK: - Shared look

enum SceneStyle {
    private static func firstAvailable(_ names: [String], size: CGFloat) -> NSFont {
        for name in names { if let font = NSFont(name: name, size: size) { return font } }
        return NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// Marker-like handwriting for the marks drawn on the screen and on a model.
    static func markerNSFont(_ size: CGFloat) -> NSFont {
        firstAvailable(["BradleyHandITCTT-Bold", "Noteworthy-Bold", "ChalkboardSE-Bold", "MarkerFelt-Thin"], size: size)
    }

    static func marker(_ size: CGFloat) -> Font { Font(markerNSFont(size)) }
}

extension SceneColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension SceneVec2 {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum SceneRoughPath {
    /// One smooth path per stroke.
    static func paths(_ strokes: [SceneRough.Stroke]) -> [Path] {
        strokes.map { stroke in
            let points = SceneGeometry.smooth(stroke.points, closed: stroke.closed, samplesPerSegment: 6)
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: first.cgPoint)
            for point in points.dropFirst() { path.addLine(to: point.cgPoint) }
            if stroke.closed { path.closeSubpath() }
            return path
        }
    }

    /// A wobbly rectangle outline for SwiftUI views (card boxes, chips).
    static func rect(in rect: CGRect, seed: String, roughness: Double = 0.8) -> Path {
        var rng = SceneRNG(id: seed)
        let strokes = SceneRough.rect(from: SceneVec2(rect.minX, rect.minY), to: SceneVec2(rect.maxX, rect.maxY), rng: &rng, roughness: roughness)
        var combined = Path()
        for path in paths(strokes) { combined.addPath(path) }
        return combined
    }
}

/// A hand-drawn box as a SwiftUI shape.
struct SceneRoughBox: Shape {
    var seed: String
    var roughness = 0.8

    func path(in rect: CGRect) -> Path {
        SceneRoughPath.rect(in: rect.insetBy(dx: 2, dy: 2), seed: seed, roughness: roughness)
    }
}

// MARK: - Model

@MainActor
final class SceneOverlayModel: ObservableObject {
    struct Item: Identifiable {
        let id: String
        var command: SceneCommand
        var createdAt: Date
        /// When set, the item fades out starting at this moment and is then dropped.
        var fadeStart: Date?
    }

    @Published private(set) var items: [Item] = []

    /// Seconds a highlight stays before it fades.
    var highlightLifetime: TimeInterval = 2
    /// The time items are stamped with. A headless scene supplies its own clock so a replay
    /// rendered to video fades and draws on at the same moments every time.
    var clock: () -> Date = { Date() }
    static let drawDuration: TimeInterval = 0.45
    static let fadeDuration: TimeInterval = 0.45

    private var sweepTimer: Timer?

    var isEmpty: Bool { items.isEmpty }

    func apply(_ command: SceneCommand) {
        let now = clock()
        var item = Item(id: command.id, command: command, createdAt: now, fadeStart: nil)
        if command.verb == .highlight {
            item.fadeStart = now.addingTimeInterval(command.number("for", "dur") ?? highlightLifetime)
        } else if let lifetime = command.number("for", "dur") {
            item.fadeStart = now.addingTimeInterval(lifetime)
        }
        if let existing = items.firstIndex(where: { $0.id == command.id }) {
            items[existing] = item
        } else {
            items.append(item)
        }
        scheduleSweep()
    }

    func remove(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].fadeStart = clock()
        scheduleSweep()
    }

    /// Fades everything out (speech ended) or drops it at once.
    func clearAll(animated: Bool = true) {
        if animated {
            let now = clock()
            for index in items.indices where items[index].fadeStart == nil || items[index].fadeStart! > now {
                items[index].fadeStart = now
            }
            scheduleSweep()
        } else {
            items.removeAll()
        }
    }

    /// Animation windows include their final frame. A future fade does not need frames
    /// throughout its hold time, and a permanent mark stops scheduling after its reveal.
    var animationIntervals: [DateInterval] {
        items.flatMap { item -> [DateInterval] in
            let revealEnd = item.createdAt.addingTimeInterval(Self.drawDuration)
            var intervals = [DateInterval(start: item.createdAt, end: revealEnd)]
            if let fadeStart = item.fadeStart {
                intervals.append(DateInterval(start: fadeStart, duration: Self.fadeDuration))
            }
            return intervals
        }
    }

    /// True while something is still drawing itself on or fading out.
    func isAnimating(at date: Date) -> Bool {
        animationIntervals.contains { date >= $0.start && date < $0.end }
    }

    private func scheduleSweep() {
        guard sweepTimer == nil else { return }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    private func sweep() {
        let now = clock()
        let alive = items.filter { item in
            guard let fadeStart = item.fadeStart else { return true }
            return now.timeIntervalSince(fadeStart) < Self.fadeDuration
        }
        if alive.count != items.count { items = alive }
        if !items.contains(where: { $0.fadeStart != nil }) {
            sweepTimer?.invalidate()
            sweepTimer = nil
        }
    }
}

// MARK: - Scheduling

/// A finite schedule rather than a paused animation schedule: SwiftUI must receive the
/// completed reveal/fade frame before it can sleep, then wake at the next fade's start.
struct SceneOverlayTimelineSchedule: TimelineSchedule, Hashable {
    let intervals: [DateInterval]

    init(intervals: [DateInterval]) {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let previous = merged.last, interval.start <= previous.end {
                merged[merged.count - 1] = DateInterval(start: previous.start, end: max(previous.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        self.intervals = merged
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(intervals: intervals, firstDate: startDate, frameInterval: mode == .lowFrequency ? 1.0 / 30 : 1.0 / 60)
    }

    struct Entries: Sequence, IteratorProtocol {
        let intervals: [DateInterval]
        let firstDate: Date
        let frameInterval: TimeInterval
        private var previousDate: Date?
        private var intervalIndex = 0

        init(intervals: [DateInterval], firstDate: Date, frameInterval: TimeInterval) {
            self.intervals = intervals
            self.firstDate = firstDate
            self.frameInterval = frameInterval
        }

        mutating func next() -> Date? {
            guard let previousDate else {
                self.previousDate = firstDate
                return firstDate
            }
            while intervalIndex < intervals.count {
                let interval = intervals[intervalIndex]
                if previousDate >= interval.end {
                    intervalIndex += 1
                    continue
                }
                let nextDate = previousDate < interval.start
                    ? interval.start
                    : Swift.min(previousDate.addingTimeInterval(frameInterval), interval.end)
                self.previousDate = nextDate
                return nextDate
            }
            return nil
        }
    }
}

// MARK: - View

struct SceneOverlayView: View {
    @ObservedObject var model: SceneOverlayModel
    /// The rectangle, in this view's points, that the 0–1000 space maps onto. Nil = the whole view.
    var mapping: CGRect?
    /// Fixed clock for snapshots; nil draws live.
    var frozenAt: Date?

    var body: some View {
        let schedule = SceneOverlayTimelineSchedule(intervals: frozenAt == nil ? model.animationIntervals : [])
        TimelineView(schedule) { timeline in
            Canvas { context, size in
                let now = frozenAt ?? timeline.date
                let rect = mapping ?? CGRect(origin: .zero, size: size)
                for item in model.items {
                    SceneOverlayPainter.draw(item, at: now, in: rect, context: &context)
                }
            }
        }
        // New marks and explicit removals restart a completed schedule immediately.
        .id(schedule)
        .allowsHitTesting(false)
    }
}

enum SceneOverlayPainter {
    static func draw(_ item: SceneOverlayModel.Item, at now: Date, in rect: CGRect, context: inout GraphicsContext) {
        let c = item.command
        let age = now.timeIntervalSince(item.createdAt)
        let progress = min(max(age / SceneOverlayModel.drawDuration, 0), 1)
        var opacity = 1.0
        if let fadeStart = item.fadeStart {
            opacity = 1 - min(max(now.timeIntervalSince(fadeStart) / SceneOverlayModel.fadeDuration, 0), 1)
        }
        guard opacity > 0.01 else { return }

        func point(_ p: SceneVec2) -> SceneVec2 {
            SceneVec2(Double(rect.minX) + p.x / 1000 * Double(rect.width), Double(rect.minY) + p.y / 1000 * Double(rect.height))
        }
        let scaleX = Double(rect.width) / 1000, scaleY = Double(rect.height) / 1000
        let uniformScale = (scaleX * scaleY).squareRoot()

        let color = c.color() ?? (c.verb == .highlight ? SceneColor.named["yellow"]! : .marker)
        let width = CGFloat(min(max(c.number("w", "width", "stroke") ?? 3.6, 1), 14))
        let roughness = min(max(c.number("rough") ?? 1, 0), 3)
        var rng = SceneRNG(id: c.id)
        var layer = context
        layer.opacity = opacity

        var strokes: [SceneRough.Stroke] = []
        var fillOutline: [SceneVec2] = []
        var labelAnchor: SceneVec2?

        switch c.verb {
        case .ring:
            guard let at = c.vec2("at") else { return }
            let center = point(at)
            let r = c.number("r") ?? 40
            let rx = (c.number("rx").map { $0 * scaleX }) ?? r * uniformScale
            let ry = (c.number("ry").map { $0 * scaleY }) ?? r * uniformScale
            strokes = SceneRough.ellipse(center: center, rx: rx, ry: ry, rng: &rng, roughness: roughness)
            fillOutline = (0..<36).map { step in
                let angle = Double(step) / 36 * 2 * Double.pi
                return center + SceneVec2(cos(angle) * rx, sin(angle) * ry)
            }
            labelAnchor = center + SceneVec2(0, -ry - 20)
        case .rect, .highlight:
            guard let corners = rectCorners(c) else { return }
            let a = point(corners.0), b = point(corners.1)
            let low = simd_min(a, b), high = simd_max(a, b)
            fillOutline = [low, SceneVec2(high.x, low.y), high, SceneVec2(low.x, high.y)]
            if c.verb == .highlight {
                drawHighlight(low: low, high: high, color: color, progress: progress, rng: &rng, context: &layer)
                return
            }
            strokes = SceneRough.rect(from: a, to: b, rng: &rng, roughness: roughness)
            labelAnchor = SceneVec2((low.x + high.x) / 2, low.y - 20)
        case .arrow:
            guard let from = c.vec2("from"), let to = c.vec2("to") else { return }
            let shaft = SceneRough.curve(from: point(from), to: point(to), bend: c.number("bend", "curve") ?? 0, rng: &rng, roughness: roughness)
            strokes = shaft.strokes
            let length = simd_length(point(to) - point(from))
            strokes += SceneRough.arrowHead(tip: shaft.tip, direction: shaft.direction, size: min(max(length * 0.16, 12), 26), rng: &rng)
            let tail = point(from)
            let away = simd_length(tail - shaft.tip) > 1 ? simd_normalize(tail - shaft.tip) : SceneVec2(0, -1)
            labelAnchor = tail + away * 22
        case .line:
            var points = c.points2().map(point)
            if points.count < 2, let from = c.vec2("from"), let to = c.vec2("to") { points = [point(from), point(to)] }
            guard points.count >= 2 else { return }
            if c.flag("smooth"), points.count > 2 {
                var jittered = points
                for index in jittered.indices { jittered[index] += SceneVec2(rng.signed(), rng.signed()) * 1.6 * roughness }
                strokes = [SceneRough.Stroke(points: points), SceneRough.Stroke(points: jittered)]
            } else {
                strokes = SceneRough.polyline(points, closed: c.flag("closed"), rng: &rng, roughness: roughness)
            }
            labelAnchor = points[0] + SceneVec2(0, -20)
        case .poly:
            let points = c.points2().map(point)
            guard points.count >= 3 else { return }
            strokes = SceneRough.polyline(points, closed: true, rng: &rng, roughness: roughness)
            fillOutline = points
            let top = points.min { $0.y < $1.y } ?? points[0]
            labelAnchor = top + SceneVec2(0, -20)
        case .label:
            guard let at = c.vec2("at"), let text = c.freeText else { return }
            drawPill(text, at: point(at), color: color, seed: c.id, progress: progress, bounds: rect, context: &layer)
            return
        default:
            return
        }

        // Fill: hachure lines clipped to the shape, like a marker shading it in.
        if !fillOutline.isEmpty, c.flag("fill") || c.args["fill"] != nil {
            let fillColor = c.color("fill") ?? color
            var outline = Path()
            outline.move(to: fillOutline[0].cgPoint)
            for p in fillOutline.dropFirst() { outline.addLine(to: p.cgPoint) }
            outline.closeSubpath()
            var clipped = layer
            clipped.clip(to: outline)
            clipped.opacity = opacity * progress
            clipped.fill(outline, with: .color(fillColor.color.opacity(0.10)))
            let bounds = outline.boundingRect
            var hatch = SceneRNG(id: c.id + "#fill")
            var offset = -Double(bounds.height)
            while offset < Double(bounds.width) {
                let start = SceneVec2(Double(bounds.minX) + offset, Double(bounds.maxY))
                let end = SceneVec2(Double(bounds.minX) + offset + Double(bounds.height), Double(bounds.minY))
                for path in SceneRoughPath.paths(SceneRough.line(start, end, rng: &hatch, roughness: 0.7, passes: 1)) {
                    clipped.stroke(path, with: .color(fillColor.color.opacity(0.42)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                offset += 9
            }
        }

        // The outline draws itself on, stroke after stroke.
        let paths = SceneRoughPath.paths(strokes)
        let dash: [CGFloat] = c.flag("dash") || c.flag("dashed") ? [width * 2.6, width * 2.2] : []
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
        let shading = GraphicsContext.Shading.color(color.color.opacity(0.92))
        for (index, path) in paths.enumerated() {
            let start = Double(index) / Double(paths.count), end = Double(index + 1) / Double(paths.count)
            let local = min(max((progress - start) / (end - start), 0), 1)
            guard local > 0 else { continue }
            layer.stroke(local >= 1 ? path : path.trimmedPath(from: 0, to: local), with: shading, style: style)
        }

        if let text = c.string("label"), let anchor = labelAnchor, progress > 0.5 {
            drawPill(text, at: anchor, color: color, seed: c.id + "#label", progress: (progress - 0.5) * 2, bounds: rect, context: &layer)
        }
    }

    static func rectCorners(_ c: SceneCommand) -> (SceneVec2, SceneVec2)? {
        if let from = c.vec2("from"), let to = c.vec2("to") { return (from, to) }
        let box = c.numbers("box")
        if box.count >= 4 { return (SceneVec2(box[0], box[1]), SceneVec2(box[2], box[3])) }
        if let at = c.vec2("at"), let size = c.vec2("size") { return (at - size / 2, at + size / 2) }
        return nil
    }

    /// A highlighter swipe: a few fat translucent strokes left to right.
    private static func drawHighlight(low: SceneVec2, high: SceneVec2, color: SceneColor, progress: Double, rng: inout SceneRNG, context: inout GraphicsContext) {
        let height = max(high.y - low.y, 6)
        let rows = max(1, Int((height / 22).rounded(.up)))
        let rowHeight = height / Double(rows)
        for row in 0..<rows {
            let y = low.y + rowHeight * (Double(row) + 0.5)
            let start = SceneVec2(low.x + rng.signed() * 3, y + rng.signed() * 1.5)
            let end = SceneVec2(low.x + (high.x - low.x) * progress + rng.signed() * 3, y + rng.signed() * 1.5)
            for path in SceneRoughPath.paths(SceneRough.line(start, end, rng: &rng, roughness: 0.6, passes: 1)) {
                context.stroke(path, with: .color(color.color.opacity(0.36)), style: StrokeStyle(lineWidth: rowHeight * 1.05, lineCap: .round))
            }
        }
    }

    /// A small handwritten pill, slightly askew.
    static func drawPill(_ text: String, at requested: SceneVec2, color: SceneColor, seed: String, progress: Double, bounds: CGRect, context: inout GraphicsContext) {
        var rng = SceneRNG(id: seed)
        let resolved = context.resolve(Text(text).font(SceneStyle.marker(17)).foregroundColor(.white))
        let textSize = resolved.measure(in: CGSize(width: 420, height: 200))
        let pill = CGRect(x: -textSize.width / 2 - 12, y: -textSize.height / 2 - 5, width: textSize.width + 24, height: textSize.height + 10)
        // Keep the whole pill on the display.
        var center = requested
        if bounds.width > pill.width + 12, bounds.height > pill.height + 12 {
            center.x = min(max(center.x, Double(bounds.minX + pill.width / 2 + 6)), Double(bounds.maxX - pill.width / 2 - 6))
            center.y = min(max(center.y, Double(bounds.minY + pill.height / 2 + 6)), Double(bounds.maxY - pill.height / 2 - 6))
        }
        var layer = context
        layer.opacity *= min(progress * 1.5, 1)
        layer.translateBy(x: center.x, y: center.y)
        layer.rotate(by: .degrees(rng.signed() * 2.2))
        let scale = 0.85 + 0.15 * min(progress * 1.5, 1)
        layer.scaleBy(x: scale, y: scale)
        let shape = Path(roundedRect: pill, cornerRadius: pill.height / 2)
        layer.fill(shape.offsetBy(dx: 0, dy: 2), with: .color(.black.opacity(0.18)))
        layer.fill(shape, with: .color(color.color))
        layer.draw(resolved, at: .zero, anchor: .center)
    }
}

// MARK: - Window

/// A click-through, transparent window covering one display, for hosts that
/// don't already have an overlay to put SceneOverlayView in.
@MainActor
final class SceneOverlayWindow {
    private var window: NSWindow?
    let model: SceneOverlayModel

    init(model: SceneOverlayModel) { self.model = model }

    /// `screenFrame` is the display's frame in AppKit screen coordinates.
    func show(on screenFrame: CGRect) {
        if let window, window.frame == screenFrame {
            window.orderFrontRegardless()
            return
        }
        close()
        let window = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SceneOverlayView(model: model))
        window.setFrame(screenFrame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    /// The overlay drawn over a plain backdrop, for checking it without screen-recording permission.
    func snapshot(size: CGSize, backdrop: Color = Color(white: 0.93)) -> NSImage? {
        let view = ZStack {
            backdrop
            SceneOverlayView(model: model, frozenAt: model.clock())
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }
}
