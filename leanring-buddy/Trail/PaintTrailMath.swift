//
//  PaintTrailMath.swift
//  leanring-buddy
//
//  Pure maths for the paint trail drawn while the talk key is held: which mouse
//  samples to keep, how wide the stroke is at each point (a little uneven, like a
//  marker), and how it dries up and fades. No AppKit and no clock: callers pass
//  the time in.
//

import Foundation

nonisolated struct PaintTrailPoint: Equatable, Sendable {
    var x: Double
    var y: Double
    /// When the point was recorded (seconds, any monotonic clock).
    var time: TimeInterval

    init(x: Double, y: Double, time: TimeInterval) {
        self.x = x
        self.y = y
        self.time = time
    }
}

nonisolated struct PaintTrailConfiguration: Equatable, Sendable {
    /// A new sample closer than this to the last kept point is dropped.
    var minimumPointDistance: Double = 3
    /// The oldest points are dropped beyond this many.
    var maximumPointCount: Int = 1500
    var baseWidth: Double = 7
    /// While the key is held, paint stays full for this long, then thins away
    /// over `heldThinDuration` so an old scribble doesn't pile up.
    var heldFullDuration: TimeInterval = 6
    var heldThinDuration: TimeInterval = 2
    /// After release the whole stroke fades over this long.
    var releaseFadeDuration: TimeInterval = 1.2

    init() {}
}

nonisolated enum PaintTrailMath {
    typealias Configuration = PaintTrailConfiguration

    // MARK: Keeping points

    static func shouldAppend(_ point: PaintTrailPoint, after last: PaintTrailPoint?, configuration: Configuration = Configuration()) -> Bool {
        guard let last else { return true }
        return distance(point, last) >= configuration.minimumPointDistance
    }

    /// Appends the sample if it moved far enough, and trims the oldest points
    /// beyond the cap. Returns true if the point was kept.
    @discardableResult
    static func append(_ point: PaintTrailPoint, to points: inout [PaintTrailPoint], configuration: Configuration = Configuration()) -> Bool {
        guard shouldAppend(point, after: points.last, configuration: configuration) else { return false }
        points.append(point)
        if points.count > configuration.maximumPointCount {
            points.removeFirst(points.count - configuration.maximumPointCount)
        }
        return true
    }

    static func distance(_ a: PaintTrailPoint, _ b: PaintTrailPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    static func length(of points: [PaintTrailPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    // MARK: Fading

    /// 1 while the key is held, then eases from 1 to 0 over the fade after release.
    static func releaseOpacity(now: TimeInterval, releasedAt: TimeInterval?, configuration: Configuration = Configuration()) -> Double {
        guard let releasedAt else { return 1 }
        guard configuration.releaseFadeDuration > 0 else { return 0 }
        let progress = min(max((now - releasedAt) / configuration.releaseFadeDuration, 0), 1)
        // Ease-out: drops quickly at first, then lingers faintly.
        return (1 - progress) * (1 - progress)
    }

    /// True once the release fade has run its course and the panel can go away.
    static func isFinished(now: TimeInterval, releasedAt: TimeInterval?, configuration: Configuration = Configuration()) -> Bool {
        guard let releasedAt else { return false }
        return now - releasedAt >= configuration.releaseFadeDuration
    }

    /// How much of its width a point still has, by age: 1, then thinning to 0.
    /// After release the age is frozen at the release time so the stroke fades
    /// as a whole instead of also shrinking.
    static func ageFactor(pointTime: TimeInterval, now: TimeInterval, releasedAt: TimeInterval?, configuration: Configuration = Configuration()) -> Double {
        let age = (releasedAt ?? now) - pointTime
        guard age > configuration.heldFullDuration else { return 1 }
        guard configuration.heldThinDuration > 0 else { return 0 }
        return max(0, 1 - (age - configuration.heldFullDuration) / configuration.heldThinDuration)
    }

    /// Drops points that have thinned to nothing (only happens while held).
    static func pruned(_ points: [PaintTrailPoint], now: TimeInterval, releasedAt: TimeInterval?, configuration: Configuration = Configuration()) -> [PaintTrailPoint] {
        guard releasedAt == nil else { return points }
        guard let firstAlive = points.firstIndex(where: {
            ageFactor(pointTime: $0.time, now: now, releasedAt: nil, configuration: configuration) > 0
        }) else { return [] }
        return firstAlive == 0 ? points : Array(points[firstAlive...])
    }

    // MARK: Width

    /// A steady wobble between -1 and 1 that depends only on the point's place
    /// in the stroke, so the line doesn't shimmer from frame to frame.
    static func wobble(index: Int) -> Double {
        let i = Double(index)
        return (sin(i * 0.37) + 0.6 * sin(i * 0.11 + 1.7) + 0.4 * sin(i * 0.83 + 0.4)) / 2.0
    }

    /// Stroke width at one point: thinner when the hand moves fast, thicker when
    /// slow, plus a small wobble. `speed` is in points per second.
    static func width(index: Int, speed: Double, configuration: Configuration = Configuration()) -> Double {
        let base = configuration.baseWidth
        // 0 at rest, 1 at about 2,500 pt/s and beyond.
        let fastness = min(max(speed, 0) / 2500, 1)
        let speedFactor = 1.2 - 0.5 * fastness
        let wobbleFactor = 1 + 0.12 * wobble(index: index)
        return min(max(base * speedFactor * wobbleFactor, base * 0.55), base * 1.4)
    }

    /// The width of every point, lightly smoothed so it changes gradually.
    static func widths(for points: [PaintTrailPoint], now: TimeInterval, releasedAt: TimeInterval?, configuration: Configuration = Configuration()) -> [Double] {
        guard !points.isEmpty else { return [] }
        var raw: [Double] = []
        raw.reserveCapacity(points.count)
        for index in points.indices {
            var speed = 0.0
            if index > 0 {
                let elapsed = points[index].time - points[index - 1].time
                if elapsed > 0 { speed = distance(points[index], points[index - 1]) / elapsed }
            }
            raw.append(width(index: index, speed: speed, configuration: configuration))
        }
        return points.indices.map { index in
            let lower = max(0, index - 2), upper = min(points.count - 1, index + 2)
            let average = raw[lower...upper].reduce(0, +) / Double(upper - lower + 1)
            return average * ageFactor(pointTime: points[index].time, now: now, releasedAt: releasedAt, configuration: configuration)
        }
    }
}
