//
//  SceneCamera.swift
//  leanring-buddy / Scene
//
//  The maths and the rules behind the 3D camera that directs itself.
//
//    SceneCameraPose      where the camera is, as a turntable: a point it looks at, two angles and a distance
//    SceneFraming         how far back to stand so a box fills a given share of the picture, where a box
//                         lands in the picture, which side to look from when things are in the way,
//                         and zooming toward the cursor without passing through or losing the model
//    SceneCameraPolicy    calm movement: a minimum dwell, one move per sentence, no move when the
//                         subject is already well framed, none while the person is steering
//    SceneGesturePause    the person always wins: automatic moves wait until they have been idle
//    SceneSubjectMatcher  which parts a spoken sentence is about
//
//  Pure (Foundation + simd): everything here is unit-tested in scripts/tests/scene3.
//

import Foundation
import simd

// MARK: - Boxes

/// An axis-aligned box in world space.
struct SceneBox: Equatable {
    var low: SceneVec3
    var high: SceneVec3

    init(low: SceneVec3, high: SceneVec3) {
        self.low = simd_min(low, high)
        self.high = simd_max(low, high)
    }

    init(center: SceneVec3, size: SceneVec3) {
        self.init(low: center - size / 2, high: center + size / 2)
    }

    var center: SceneVec3 { (low + high) / 2 }
    var size: SceneVec3 { high - low }
    /// Half the diagonal: the radius of the sphere round the box.
    var radius: Double { simd_length(high - low) / 2 }

    var corners: [SceneVec3] {
        (0..<8).map { SceneVec3($0 & 1 == 0 ? low.x : high.x, $0 & 2 == 0 ? low.y : high.y, $0 & 4 == 0 ? low.z : high.z) }
    }

    func union(_ other: SceneBox) -> SceneBox {
        SceneBox(low: simd_min(low, other.low), high: simd_max(high, other.high))
    }

    func expanded(by factor: Double) -> SceneBox {
        SceneBox(center: center, size: size * factor)
    }

    func contains(_ point: SceneVec3) -> Bool {
        point.x >= low.x && point.x <= high.x && point.y >= low.y && point.y <= high.y && point.z >= low.z && point.z <= high.z
    }

    /// True when `other` sits inside this box. `tolerance` is a share of this box's size that
    /// `other` may poke out by (a turbine's blade tips reach the casing's skin).
    func contains(_ other: SceneBox, tolerance: Double = 0.06) -> Bool {
        let slack = size * tolerance
        let inside = other.low.x >= low.x - slack.x && other.low.y >= low.y - slack.y && other.low.z >= low.z - slack.z
            && other.high.x <= high.x + slack.x && other.high.y <= high.y + slack.y && other.high.z <= high.z + slack.z
        // A box is not "inside" one of nearly its own size.
        return inside && other.radius < radius * 0.92
    }

    func clamp(_ point: SceneVec3) -> SceneVec3 {
        simd_clamp(point, low, high)
    }

    /// Where a segment from `a` to `b` first enters the box, as a fraction 0...1 of the segment, or nil.
    func entry(ofSegmentFrom a: SceneVec3, to b: SceneVec3) -> Double? {
        let delta = b - a
        var near = 0.0, far = 1.0
        for axis in 0..<3 {
            if abs(delta[axis]) < 1e-12 {
                if a[axis] < low[axis] || a[axis] > high[axis] { return nil }
                continue
            }
            var t1 = (low[axis] - a[axis]) / delta[axis], t2 = (high[axis] - a[axis]) / delta[axis]
            if t1 > t2 { swap(&t1, &t2) }
            near = max(near, t1)
            far = min(far, t2)
            if near > far { return nil }
        }
        return near
    }
}

/// Something that may stand between the camera and its subject (for the pure direction chooser;
/// the app asks SceneKit which geometry a ray really hits).
struct SceneOccluder: Equatable {
    var box: SceneBox
    /// 1 hides what is behind it; a see-through part hides less.
    var weight = 1.0

    /// How much of the line of sight from `eye` to `target` is hidden, 0...1.
    static func blockage(from eye: SceneVec3, to target: SceneVec3, occluders: [SceneOccluder]) -> Double {
        var total = 0.0
        for occluder in occluders {
            // An occluder the target is inside (or touching) only counts when the eye is outside it.
            guard let entry = occluder.box.entry(ofSegmentFrom: eye, to: target), entry < 0.999 else { continue }
            if occluder.box.contains(eye) { continue }
            total += occluder.weight
        }
        return min(total, 1)
    }
}

enum SceneContainment {
    /// Ids of the boxes that `subject` sits inside, smallest first. A part's own ancestors and
    /// descendants (ids related by a dot path) are never its containers.
    static func containers(of subjectID: String, subject: SceneBox, among others: [(id: String, box: SceneBox)], tolerance: Double = 0.06) -> [String] {
        others.filter { other in
            other.id != subjectID && !isRelated(other.id, subjectID) && other.box.contains(subject, tolerance: tolerance)
        }
        .sorted { $0.box.radius < $1.box.radius }
        .map(\.id)
    }

    /// `a.b` and `a.b.c` are the same thing at two levels.
    static func isRelated(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }
}

// MARK: - Pose

/// The camera as a turntable: it looks at `center` from `distance` away, turned `azimuth`
/// round the vertical (0 looks from +z) and raised `elevation` above the horizon. Radians.
struct SceneCameraPose: Equatable {
    var center: SceneVec3
    var azimuth: Double
    var elevation: Double
    var distance: Double

    static let maximumElevation = 1.45

    init(center: SceneVec3, azimuth: Double, elevation: Double, distance: Double) {
        self.center = center
        self.azimuth = azimuth
        self.elevation = elevation
        self.distance = distance
    }

    /// From a unit direction pointing from the subject to the camera.
    init(center: SceneVec3, direction: SceneVec3, distance: Double) {
        let d = simd_length(direction) > 1e-9 ? simd_normalize(direction) : SceneVec3(0, 0, 1)
        self.init(center: center, azimuth: atan2(d.x, d.z), elevation: asin(min(max(d.y, -1), 1)), distance: distance)
    }

    /// Unit vector from the subject to the camera.
    var direction: SceneVec3 { Self.direction(azimuth: azimuth, elevation: elevation) }
    var position: SceneVec3 { center + direction * distance }

    static func direction(azimuth: Double, elevation: Double) -> SceneVec3 {
        SceneVec3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
    }

    /// The camera's right and up, for a camera looking back along `direction`.
    static func basis(direction: SceneVec3) -> (right: SceneVec3, up: SceneVec3) {
        var right = simd_cross(SceneVec3(0, 1, 0), direction)
        right = simd_length(right) > 1e-6 ? simd_normalize(right) : SceneVec3(1, 0, 0)
        return (right, simd_normalize(simd_cross(direction, right)))
    }

    var basis: (right: SceneVec3, up: SceneVec3) { Self.basis(direction: direction) }

    /// Part of the way from one pose to another. The turn goes the short way round.
    static func interpolate(_ a: SceneCameraPose, _ b: SceneCameraPose, _ t: Double) -> SceneCameraPose {
        let turn = shortestTurn(from: a.azimuth, to: b.azimuth)
        return SceneCameraPose(center: a.center + (b.center - a.center) * t,
                               azimuth: a.azimuth + turn * t,
                               elevation: a.elevation + (b.elevation - a.elevation) * t,
                               distance: a.distance + (b.distance - a.distance) * t)
    }

    static func shortestTurn(from: Double, to: Double) -> Double {
        var turn = (to - from).truncatingRemainder(dividingBy: 2 * Double.pi)
        if turn > Double.pi { turn -= 2 * Double.pi }
        if turn < -Double.pi { turn += 2 * Double.pi }
        return turn
    }

    /// How different two views are: 0 for the same view, about 1 for a clearly different one.
    func difference(from other: SceneCameraPose, scale: Double) -> Double {
        let shift = simd_length(center - other.center) / max(scale, 1e-9)
        let zoom = abs(log(max(distance, 1e-9) / max(other.distance, 1e-9)))
        let turn = abs(Self.shortestTurn(from: azimuth, to: other.azimuth)) + abs(elevation - other.elevation)
        return shift + zoom + turn
    }
}

enum SceneEasing {
    /// Ease in, ease out (smootherstep): no velocity or acceleration at either end.
    static func easeInOut(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

// MARK: - Framing

/// How close `focus` stands: the share of the picture's shorter side the subject fills.
enum SceneZoom: String, Equatable, CaseIterable {
    case tight, medium, wide

    var fill: Double {
        switch self {
        case .tight: return 0.66
        case .medium: return 0.50
        case .wide: return 0.34
        }
    }

    init(script: String?) {
        switch script?.lowercased() {
        case "tight", "close", "closeup", "near", "in": self = .tight
        case "wide", "far", "loose", "out": self = .wide
        default: self = .medium
        }
    }
}

struct SceneLens: Equatable {
    /// Vertical field of view, degrees.
    var fieldOfView: Double
    /// Picture width ÷ height.
    var aspect: Double

    var tanVertical: Double { tan(fieldOfView * Double.pi / 360) }
    var tanHorizontal: Double { tanVertical * aspect }
    /// Half-angle tangent along the picture's shorter side.
    var tanShort: Double { min(tanVertical, tanHorizontal) }
}

/// Where a box lands in the picture.
struct SceneProjection: Equatable {
    /// Corners of the box's outline in the picture: −1…1 across and up (the edges of the view are ±1).
    var low: SceneVec2
    var high: SceneVec2
    /// Part of the box is behind the camera.
    var behindCamera: Bool
    /// The larger of the outline's width and height, as a share of the picture's shorter side.
    var fill: Double

    /// The whole outline is in the picture.
    var isInside: Bool { isInside(margin: 0) }

    func isInside(margin: Double) -> Bool {
        !behindCamera && low.x >= -1 + margin && low.y >= -1 + margin && high.x <= 1 - margin && high.y <= 1 - margin
    }

    var center: SceneVec2 { (low + high) / 2 }
}

enum SceneFraming {
    /// Acceptable share of the shorter side for a focused subject.
    static let sensibleFill = 0.20...0.75

    /// The distance from the middle of `box` at which the box's outline fills `fill` of the
    /// picture's shorter side, seen from `direction` (unit, subject → camera).
    static func distance(for box: SceneBox, direction: SceneVec3, lens: SceneLens, fill: Double) -> Double {
        let share = min(max(fill, 0.05), 1)
        let (right, up) = SceneCameraPose.basis(direction: direction)
        let center = box.center
        var needed = 0.0, nearest = 0.0
        for corner in box.corners {
            let p = corner - center
            let depth = simd_dot(p, direction)
            let across = abs(simd_dot(p, right)), along = abs(simd_dot(p, up))
            // The outline is as wide as its widest corner; a corner nearer the camera looks bigger.
            needed = max(needed, max(across, along) / (lens.tanShort * share) + depth)
            // On the long side the box only has to fit.
            needed = max(needed, across / lens.tanHorizontal + depth, along / lens.tanVertical + depth)
            nearest = max(nearest, depth)
        }
        // Never inside the box itself.
        return max(needed, nearest + box.radius * 0.15, 1e-4)
    }

    /// A pose that frames `box` from `direction`.
    static func pose(framing box: SceneBox, direction: SceneVec3, lens: SceneLens, fill: Double) -> SceneCameraPose {
        SceneCameraPose(center: box.center, direction: direction, distance: distance(for: box, direction: direction, lens: lens, fill: fill))
    }

    /// A world point in the picture (−1…1), and how far in front of the camera it is.
    static func project(_ point: SceneVec3, pose: SceneCameraPose, lens: SceneLens) -> (ndc: SceneVec2, depth: Double) {
        let direction = pose.direction
        let (right, up) = SceneCameraPose.basis(direction: direction)
        let p = point - pose.position
        let depth = -simd_dot(p, direction)
        let safe = max(depth, 1e-9)
        return (SceneVec2(simd_dot(p, right) / (safe * lens.tanHorizontal), simd_dot(p, up) / (safe * lens.tanVertical)), depth)
    }

    static func project(_ box: SceneBox, pose: SceneCameraPose, lens: SceneLens) -> SceneProjection {
        var low = SceneVec2(repeating: .greatestFiniteMagnitude), high = SceneVec2(repeating: -.greatestFiniteMagnitude)
        var behind = false
        for corner in box.corners {
            let (ndc, depth) = project(corner, pose: pose, lens: lens)
            if depth <= 1e-6 { behind = true }
            low = simd_min(low, ndc)
            high = simd_max(high, ndc)
        }
        // Width and height in units of the shorter side.
        let widthShare = (high.x - low.x) / 2 * (lens.aspect >= 1 ? lens.aspect : 1)
        let heightShare = (high.y - low.y) / 2 * (lens.aspect >= 1 ? 1 : 1 / lens.aspect)
        return SceneProjection(low: low, high: high, behindCamera: behind, fill: max(widthShare, heightShare))
    }

    /// True when the subject is already shown well enough that moving the camera would only fidget:
    /// all of it in the picture, near the middle, and about the size the zoom asks for.
    static func isWellFramed(_ box: SceneBox, pose: SceneCameraPose, lens: SceneLens, zoom: SceneZoom) -> Bool {
        let projection = project(box, pose: pose, lens: lens)
        guard projection.isInside(margin: 0.04) else { return false }
        let wanted = zoom.fill
        guard projection.fill >= max(wanted * 0.72, sensibleFill.lowerBound), projection.fill <= min(wanted * 1.35, sensibleFill.upperBound) else { return false }
        return abs(projection.center.x) < 0.36 && abs(projection.center.y) < 0.36
    }

    // MARK: Which side to look from

    /// Views to try, best first: the preferred 3/4 view, then a little to either side, higher, further round.
    static func candidateDirections(azimuth: Double, elevation: Double) -> [(azimuth: Double, elevation: Double)] {
        let high = min(elevation + 0.38, 1.1)
        return [
            (azimuth, elevation),
            (azimuth - 0.55, elevation), (azimuth + 0.55, elevation),
            (azimuth, high),
            (azimuth - 1.1, elevation), (azimuth + 1.1, elevation),
            (azimuth - 0.55, high), (azimuth + 0.55, high),
            (azimuth - 1.75, elevation), (azimuth + 1.75, elevation),
            (azimuth, 1.2),
            (azimuth + Double.pi, elevation),
        ]
    }

    /// Blockage at or below this hardly counts when choosing a side.
    static let clearEnough = 0.2

    /// The index of the candidate to use. `blocked[i]` is how hidden the subject is from candidate
    /// `i` (0 clear … 1 hidden). The clearest view wins; among views about as clear, the earlier
    /// (more natural) one wins, so the camera does not swing round for a sliver of a gain.
    /// How badly `direction` shows a flat subject: 0 when it is seen face on (or is not flat), up to
    /// about 0.3 when a disc or a board is seen edge on, as a line.
    static func edgeOnPenalty(for box: SceneBox, direction: SceneVec3) -> Double {
        let size = [box.size.x, box.size.y, box.size.z]
        guard let thin = size.indices.min(by: { size[$0] < size[$1] }) else { return 0 }
        let others = size.indices.filter { $0 != thin }.map { size[$0] }
        guard let smallerOther = others.min(), size[thin] < smallerOther * 0.4 else { return 0 }
        let facing = abs(simd_normalize(direction)[thin])
        return 0.3 * max(0, 1 - facing / 0.45)
    }

    /// How much a view looks at a part from behind: 0 when the camera is on the side of the part that
    /// faces out of the model (or the part is near the middle, where no side is "out"), up to 0.4 when
    /// it looks at the part from straight across the model.
    static func facingPenalty(direction: SceneVec3, part: SceneVec3, model: SceneBox) -> Double {
        let outward = part - model.center
        let offCentre = simd_length(outward) / max(model.radius, 1e-9)
        guard offCentre > 0.15, simd_length(direction) > 1e-9 else { return 0 }
        let facing = simd_dot(simd_normalize(direction), simd_normalize(outward))
        return 0.4 * min(offCentre / 0.6, 1) * max(0, 0.25 - facing) / 1.25
    }

    static func chooseDirection(blocked: [Double], extra: [Double] = [], preference: Double = 0.035) -> Int {
        var best = 0
        var bestCost = Double.greatestFiniteMagnitude
        for (index, value) in blocked.enumerated() {
            // A little in the way (a see-through casing, a stray edge) is nearly as good as clear:
            // not worth a swing round, but a truly clear view next door still wins.
            // The last candidates (far round the side, straight overhead, from behind) are odd views:
            // they are only worth taking when nearly everything else is hidden.
            let odd = index >= 10 ? 0.5 : (index >= 8 ? 0.15 : 0)
            let cost = (value <= clearEnough ? value * 0.2 : min(value, 1)) + Double(index) * preference + odd + (index < extra.count ? extra[index] : 0)
            if cost < bestCost - 1e-12 {
                bestCost = cost
                best = index
            }
        }
        return best
    }

    /// The pure version of the whole choice, with boxes standing in for the geometry in the way.
    static func chooseDirection(target: SceneBox, occluders: [SceneOccluder], azimuth: Double, elevation: Double,
                                lens: SceneLens, fill: Double) -> (pose: SceneCameraPose, blocked: Double) {
        let candidates = candidateDirections(azimuth: azimuth, elevation: elevation)
        let poses = candidates.map { pose(framing: target, direction: SceneCameraPose.direction(azimuth: $0.azimuth, elevation: $0.elevation), lens: lens, fill: fill) }
        let blocked = poses.map { SceneOccluder.blockage(from: $0.position, to: target.center, occluders: occluders) }
        let index = chooseDirection(blocked: blocked)
        return (poses[index], blocked[index])
    }

    // MARK: The person's hands on the camera

    struct ZoomLimits: Equatable {
        /// The camera never comes closer to its look-at point than this.
        var minimumDistance: Double
        var maximumDistance: Double
        /// The model's box.
        var model: SceneBox
        /// How far outside the model's box the look-at point may go, per unit of camera distance:
        /// most of half the picture, so the model can be slid to the edge of the view but never out of it.
        var slack: Double

        /// The nearest allowed look-at point to `center` for a camera `distance` away.
        func allowed(_ center: SceneVec3, distance: Double) -> SceneVec3 {
            let pad = SceneVec3(repeating: max(distance, 0) * slack)
            return simd_clamp(center, model.low - pad, model.high + pad)
        }
    }

    /// Limits for a model with this box. `wholeDistance` is how far back the whole model is framed from;
    /// `surfaceAhead` is how far in front of the camera the first solid thing is (nil: nothing ahead).
    static func zoomLimits(model: SceneBox, wholeDistance: Double, pose: SceneCameraPose, lens: SceneLens, surfaceAhead: Double?) -> ZoomLimits {
        let radius = max(model.radius, 1e-6)
        var minimum = radius * 0.12
        if let surfaceAhead {
            // Stop a little short of the surface in front: the camera does not pass through it.
            let margin = radius * 0.06
            let travel = max(surfaceAhead - margin, 0)
            minimum = max(minimum, pose.distance - travel)
        }
        let maximum = max(wholeDistance * 3, minimum * 1.5)
        return ZoomLimits(minimumDistance: min(minimum, maximum), maximumDistance: maximum, model: model, slack: lens.tanShort * 0.8)
    }

    /// Zooms by `factor` (above 1 moves in) keeping the world point under the cursor still.
    /// `cursor` is in the picture's −1…1 space.
    static func zoom(_ pose: SceneCameraPose, by factor: Double, toward cursor: SceneVec2, lens: SceneLens, limits: ZoomLimits) -> SceneCameraPose {
        guard factor > 0, factor.isFinite else { return pose }
        var result = pose
        let wanted = pose.distance / factor
        result.distance = min(max(wanted, limits.minimumDistance), limits.maximumDistance)
        // The point under the cursor, on the plane through the look-at point, must stay under the cursor.
        let (right, up) = pose.basis
        let scale = pose.distance - result.distance
        result.center = pose.center + right * (cursor.x * lens.tanHorizontal * scale) + up * (cursor.y * lens.tanVertical * scale)
        result.center = limits.allowed(result.center, distance: result.distance)
        return result
    }

    /// Slides the view by a drag of `delta` (in −1…1 picture units): the model follows the hand.
    static func pan(_ pose: SceneCameraPose, by delta: SceneVec2, lens: SceneLens, limits: ZoomLimits) -> SceneCameraPose {
        var result = pose
        let (right, up) = pose.basis
        result.center = pose.center - right * (delta.x * lens.tanHorizontal * pose.distance) - up * (delta.y * lens.tanVertical * pose.distance)
        result.center = limits.allowed(result.center, distance: result.distance)
        return result
    }

    /// Turns the view by a drag in radians.
    static func turn(_ pose: SceneCameraPose, azimuth: Double, elevation: Double) -> SceneCameraPose {
        var result = pose
        result.azimuth += azimuth
        result.elevation = min(max(pose.elevation + elevation, -SceneCameraPose.maximumElevation), SceneCameraPose.maximumElevation)
        return result
    }
}

enum SceneProjectionFill {
    /// The share of the shorter side `box` fills from `pose`, kept within what `focus` can ask for
    /// (so following a subject that moved keeps the zoom it had).
    static func current(_ box: SceneBox, pose: SceneCameraPose, lens: SceneLens) -> Double {
        min(max(SceneFraming.project(box, pose: pose, lens: lens).fill, SceneZoom.wide.fill), SceneZoom.tight.fill)
    }
}

// MARK: - Calm movement

/// Decides whether an automatic camera move may happen now.
struct SceneCameraPolicy: Equatable {
    enum Decision: Equatable {
        case move
        /// The camera moved too recently; try again at this time.
        case wait(until: Double)
        /// This sentence already had its move.
        case skipSentence
        /// The subject is already well framed: moving would only fidget.
        case skipFramed
        /// The person is steering.
        case skipPaused
    }

    /// Seconds the camera rests after a move starts before the next one may start.
    var minimumDwell = 1.2
    private(set) var lastMoveAt: Double?
    private(set) var lastMoveSentence: Int?

    init(minimumDwell: Double = 1.2) { self.minimumDwell = minimumDwell }

    func decide(now: Double, sentence: Int?, alreadyFramed: Bool, paused: Bool) -> Decision {
        if paused { return .skipPaused }
        if let sentence, sentence == lastMoveSentence { return .skipSentence }
        if alreadyFramed { return .skipFramed }
        if let last = lastMoveAt, now - last < minimumDwell { return .wait(until: last + minimumDwell) }
        return .move
    }

    /// Any move that starts (automatic or written by the model) counts toward the dwell.
    mutating func noteMove(now: Double, sentence: Int?) {
        lastMoveAt = now
        if let sentence { lastMoveSentence = sentence }
    }

    mutating func reset() {
        lastMoveAt = nil
        lastMoveSentence = nil
    }
}

/// The person always wins. While they drag, scroll or pinch, and for `idleResume` seconds after,
/// automatic camera moves are held back.
struct SceneGesturePause: Equatable {
    var idleResume = 5.0
    private(set) var isGestureActive = false
    private(set) var lastTouchedAt: Double?

    init(idleResume: Double = 5) { self.idleResume = idleResume }

    /// A drag began.
    mutating func began(now: Double) {
        isGestureActive = true
        lastTouchedAt = now
    }

    /// A drag moved, or a scroll, pinch or click happened.
    mutating func touched(now: Double) {
        lastTouchedAt = now
    }

    /// The drag ended.
    mutating func ended(now: Double) {
        isGestureActive = false
        lastTouchedAt = now
    }

    /// Recenter (or a request the person made): automatic moves may run again at once.
    mutating func resume() {
        isGestureActive = false
        lastTouchedAt = nil
    }

    func isPaused(now: Double) -> Bool {
        if isGestureActive { return true }
        guard let lastTouchedAt else { return false }
        return now - lastTouchedAt < idleResume
    }

    /// The person has steered and automatic moves have not been resumed since.
    var hasTouched: Bool { lastTouchedAt != nil || isGestureActive }
}

// MARK: - What a sentence is about

/// A part a sentence could be about.
struct SceneSubjectCandidate: Equatable {
    var id: String
    /// Its label chip, if it has one.
    var label: String?
    /// Its built-in name ("Right ventricle" for `h.rv`).
    var name: String?

    init(id: String, label: String? = nil, name: String? = nil) {
        self.id = id
        self.label = label
        self.name = name
    }
}

enum SceneSubjectMatcher {
    /// Words that carry no subject.
    static let stopWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "it", "its", "of", "in", "on", "at", "to", "into", "onto", "from", "by", "with", "and", "or",
        "is", "are", "was", "be", "as", "for", "then", "so", "out", "up", "down", "here", "there", "which", "what", "how", "why", "when", "where",
        "you", "your", "we", "our", "i", "me", "my", "can", "do", "does", "see", "show", "look", "tell", "about", "more", "now", "let", "lets",
        "zoom", "focus", "please", "just", "all", "each", "every", "some", "one", "two", "three", "first", "second", "third", "next", "last",
        "big", "small", "little", "main", "whole", "other", "same",
    ]

    /// Words too general to pick a part by themselves ("the air", "this part", "the inside").
    static let genericWords: Set<String> = [
        "air", "part", "piece", "thing", "bit", "side", "top", "bottom", "front", "back", "inside", "outside", "middle", "center", "centre", "end",
        "way", "path", "flow", "line", "body", "base", "group", "model", "shape", "object", "item", "label", "arrow", "text", "point", "area", "section",
        "stage", "left", "right", "upper", "lower", "inner", "outer", "hot", "cold", "gas", "energy", "force", "light",
    ]

    /// Lower-case words of a text, plurals folded to singular, punctuation dropped.
    static func words(_ text: String) -> [String] {
        // "engine's" → "engine"
        let plain = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'s", with: "")
        return plain.unicodeScalars
            .split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
            .map { stem(String(String.UnicodeScalarView($0))) }
            .filter { !$0.isEmpty }
    }

    /// Folds a plural to its singular, roughly: "blades" → "blade", "boxes" → "box", "arteries" → "artery".
    static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("zes") { return String(word.dropLast(2)) }
        if word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("is") { return word }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    /// The words of an id that mean something: `j.turbine` → ["turbine"], `leftVentricle` → ["left", "ventricle"],
    /// `usb_port2` → ["usb", "port"]. Only the last dotted piece counts (the rest names the object it belongs to).
    static func idWords(_ id: String) -> [String] {
        guard let last = id.split(separator: ".").last else { return [] }
        var spaced = ""
        var previousLower = false
        for character in String(last) {
            if character == "_" || character == "-" || character.isNumber {
                spaced.append(" ")
                previousLower = false
                continue
            }
            if character.isUppercase, previousLower { spaced.append(" ") }
            spaced.append(character)
            previousLower = character.isLowercase
        }
        return words(spaced).filter { $0.count >= 3 }
    }

    private struct Match {
        var id: String
        var range: Range<Int>
        var score: Double
    }

    /// The parts a sentence is about, in the order the sentence names them. A part matches when its
    /// label, name or id words appear in the sentence (case and plurals ignored, little words skipped).
    /// When two labels match the same words the longer label wins ("fan blade" over "fan").
    static func match(sentence: String, parts: [SceneSubjectCandidate], limit: Int = 3) -> [String] {
        let tokens = words(sentence)
        guard !tokens.isEmpty else { return [] }
        var matches: [Match] = []

        func find(_ phrase: [String]) -> Range<Int>? {
            guard !phrase.isEmpty, phrase.count <= tokens.count else { return nil }
            for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase { return start..<(start + phrase.count) }
            return nil
        }

        for part in parts {
            var best: Match?
            func consider(_ phrase: [String], weight: Double) {
                let meaningful = phrase.filter { !stopWords.contains($0) }
                guard !meaningful.isEmpty else { return }
                // A single general word never picks a part.
                if meaningful.count == 1, genericWords.contains(meaningful[0]) || meaningful[0].count < 3 { return }
                var range = find(phrase)
                if range == nil, meaningful != phrase { range = find(meaningful) }
                var score = Double(meaningful.count) * 10 * weight
                if range == nil, meaningful.count > 1, let head = meaningful.last, !genericWords.contains(head), head.count >= 4, let found = find([head]) {
                    // "Exhaust nozzle" is "the nozzle" in speech: the head noun alone is a weaker match.
                    // But "a piston engine" is not the "Jet engine": a different word in front of the noun means a different thing.
                    let before = found.lowerBound > 0 ? tokens[found.lowerBound - 1] : ""
                    if before.isEmpty || stopWords.contains(before) || meaningful.contains(before) {
                        range = found
                        score = 6 * weight
                    }
                }
                guard let range else { return }
                if best == nil || score > best!.score { best = Match(id: part.id, range: range, score: score) }
            }
            if let label = part.label { consider(words(label), weight: 1.0) }
            if let name = part.name { consider(words(name), weight: 0.95) }
            consider(idWords(part.id), weight: 0.9)
            if let best { matches.append(best) }
        }

        // Longest (highest-scoring) first; a weaker match over the same words is dropped.
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.range.lowerBound < $1.range.lowerBound }
        var accepted: [Match] = []
        for match in matches where !accepted.contains(where: { $0.range.overlaps(match.range) }) {
            accepted.append(match)
        }
        // A part named in full beats one only hinted at by its head noun, and a part beats the
        // object it belongs to ("the turbine in a jet engine" is about the turbine).
        if accepted.contains(where: { $0.score >= 8 }) { accepted.removeAll { $0.score < 8 } }
        let ids = accepted.map(\.id)
        accepted.removeAll { whole in ids.contains { $0 != whole.id && $0.hasPrefix(whole.id + ".") } }
        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }.prefix(limit).map(\.id)
    }
}
