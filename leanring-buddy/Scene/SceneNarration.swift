//
//  SceneNarration.swift
//  leanring-buddy / Scene
//
//  Two small pure pieces the director leans on.
//
//  SceneNarrationSequencer decides what is spoken when. The model's stream and
//  the voice run at different speeds: usually the whole script has arrived
//  while the first sentence is still being spoken, but a slow stream can also
//  fall behind the voice. The sequencer speaks one sentence at a time in the
//  order they arrive, waits when the next one is not here yet, and says when
//  the narration is over. The scene's own scheduler holds each drawing line
//  until its sentence starts.
//
//  SceneScreenMapping turns the 0–1000 coordinates of a screenshot into places
//  on the display that screenshot came from.
//
//  Pure (Foundation + simd).
//

import CoreGraphics
import Foundation
import simd

struct SceneNarrationSequencer: Equatable {
    enum Action: Equatable {
        /// Start speaking this sentence now; drawing lines cued to `index` appear with it.
        case speak(index: Int, text: String)
        /// Every sentence has been spoken and no more are coming.
        case finished
    }

    private var waiting: [(index: Int, text: String)] = []
    private(set) var isSpeaking = false
    private(set) var streamEnded = false
    private(set) var isStopped = false
    /// Sentences handed out to be spoken so far.
    private(set) var spokenCount = 0
    private var reportedFinished = false
    private var seen: Set<String> = []

    init() {}

    static func == (lhs: SceneNarrationSequencer, rhs: SceneNarrationSequencer) -> Bool {
        lhs.isSpeaking == rhs.isSpeaking && lhs.streamEnded == rhs.streamEnded && lhs.isStopped == rhs.isStopped
            && lhs.spokenCount == rhs.spokenCount && lhs.waiting.map(\.index) == rhs.waiting.map(\.index) && lhs.waiting.map(\.text) == rhs.waiting.map(\.text)
    }

    var pendingCount: Int { waiting.count }

    /// A `say N "…"` line arrived from the model.
    mutating func sentenceArrived(index: Int, text: String) -> [Action] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStopped, !trimmed.isEmpty else { return [] }
        // A model that repeats a line (same number, same words) is not asked to say it twice.
        guard seen.insert("\(index)|\(trimmed)").inserted else { return [] }
        waiting.append((index, trimmed))
        return next()
    }

    /// The voice finished (or gave up on) the sentence it was speaking.
    mutating func speechFinished() -> [Action] {
        guard !isStopped else { return [] }
        isSpeaking = false
        return next()
    }

    /// The model's stream is over: nothing more will arrive.
    mutating func streamDidEnd() -> [Action] {
        guard !isStopped else { return [] }
        streamEnded = true
        return next()
    }

    /// The person interrupted. Nothing more is spoken and no further actions are produced.
    mutating func stop() {
        isStopped = true
        waiting.removeAll()
        isSpeaking = false
    }

    private mutating func next() -> [Action] {
        guard !isStopped, !isSpeaking else { return [] }
        if !waiting.isEmpty {
            let sentence = waiting.removeFirst()
            isSpeaking = true
            spokenCount += 1
            return [.speak(index: sentence.index, text: sentence.text)]
        }
        if streamEnded, !reportedFinished {
            reportedFinished = true
            return [.finished]
        }
        return []
    }
}

// MARK: - Screenshot coordinates

/// A screenshot is addressed 0–1000 across and 0–1000 down, whatever its pixel size. These
/// functions place such a point on the display the screenshot was taken of.
///
/// AppKit's screen space has its origin at the bottom left of the main display with y up, and
/// other displays sit around it (their frames can start at negative x or y). A screenshot has
/// its origin at the top left with y down. So x maps straight across the display's frame and
/// y is measured down from the frame's top edge.
enum SceneScreenMapping {
    static let extent = 1000.0

    /// A screenshot point as a global AppKit screen point on the display with `displayFrame`.
    static func screenPoint(_ point: SceneVec2, displayFrame: CGRect) -> CGPoint {
        CGPoint(x: displayFrame.minX + CGFloat(point.x / extent) * displayFrame.width,
                y: displayFrame.maxY - CGFloat(point.y / extent) * displayFrame.height)
    }

    /// The reverse: where a global AppKit screen point falls in the screenshot of that display.
    static func normalized(screenPoint: CGPoint, displayFrame: CGRect) -> SceneVec2 {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return .zero }
        return SceneVec2(Double((screenPoint.x - displayFrame.minX) / displayFrame.width) * extent,
                         Double((displayFrame.maxY - screenPoint.y) / displayFrame.height) * extent)
    }

    /// A screenshot rectangle (two corners, any order) as a global AppKit screen rectangle.
    static func screenRect(_ a: SceneVec2, _ b: SceneVec2, displayFrame: CGRect) -> CGRect {
        let first = screenPoint(a, displayFrame: displayFrame), second = screenPoint(b, displayFrame: displayFrame)
        return CGRect(x: min(first.x, second.x), y: min(first.y, second.y), width: abs(first.x - second.x), height: abs(first.y - second.y))
    }

    /// A screenshot point in a view that covers the display and has its origin at the top left
    /// (a SwiftUI canvas in a window whose frame is the display's frame).
    static func viewPoint(_ point: SceneVec2, viewSize: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(point.x / extent) * viewSize.width, y: CGFloat(point.y / extent) * viewSize.height)
    }

    /// A pixel of the screenshot image (origin top left) in 0–1000 space.
    static func normalized(pixel: CGPoint, screenshotSize: CGSize) -> SceneVec2 {
        guard screenshotSize.width > 0, screenshotSize.height > 0 else { return .zero }
        return SceneVec2(Double(pixel.x / screenshotSize.width) * extent, Double(pixel.y / screenshotSize.height) * extent)
    }

    /// The display a global point is on: the frame containing it, else the nearest one.
    static func displayFrame(containing point: CGPoint, among frames: [CGRect]) -> CGRect? {
        if let hit = frames.first(where: { $0.contains(point) }) { return hit }
        return frames.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The box, in 0–1000 space, that an overlay command covers. Nil for commands with no place.
    static func bounds(of command: SceneCommand) -> (low: SceneVec2, high: SceneVec2)? {
        let c = command
        switch c.verb {
        case .ring:
            guard let at = c.vec2("at") else { return nil }
            let r = c.number("r") ?? 40
            let radius = SceneVec2(c.number("rx") ?? r, c.number("ry") ?? r)
            return (at - radius, at + radius)
        case .rect, .highlight:
            var corners: (SceneVec2, SceneVec2)?
            if let from = c.vec2("from"), let to = c.vec2("to") {
                corners = (from, to)
            } else if c.numbers("box").count >= 4 {
                let box = c.numbers("box")
                corners = (SceneVec2(box[0], box[1]), SceneVec2(box[2], box[3]))
            } else if let at = c.vec2("at"), let size = c.vec2("size") {
                corners = (at - size / 2, at + size / 2)
            }
            guard let corners else { return nil }
            return (simd_min(corners.0, corners.1), simd_max(corners.0, corners.1))
        case .arrow:
            guard let from = c.vec2("from"), let to = c.vec2("to") else { return nil }
            return (simd_min(from, to), simd_max(from, to))
        case .line, .poly:
            var points = c.points2()
            if points.count < 2, let from = c.vec2("from"), let to = c.vec2("to") { points = [from, to] }
            guard let first = points.first else { return nil }
            return points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        case .label:
            guard let at = c.vec2("at") else { return nil }
            return (at, at)
        default:
            return nil
        }
    }

    /// The single spot a mark draws the eye to: an arrow's tip, otherwise the middle of the shape.
    static func focus(of command: SceneCommand) -> SceneVec2? {
        if command.verb == .arrow, let to = command.vec2("to") { return to }
        guard let (low, high) = bounds(of: command) else { return nil }
        return (low + high) / 2
    }

    /// Keeps a mark on the screenshot: coordinates a little outside 0–1000 are pulled back in.
    static func clamped(_ point: SceneVec2) -> SceneVec2 {
        simd_clamp(point, SceneVec2(0, 0), SceneVec2(extent, extent))
    }
}
