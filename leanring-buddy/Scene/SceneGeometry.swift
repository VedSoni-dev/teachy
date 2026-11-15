//
//  SceneGeometry.swift
//  leanring-buddy / Scene
//
//  The maths behind the drawing engine: hand-drawn stroke jitter, curve smoothing,
//  gear teeth, helices, springs, tube and lathe meshes, gear-train and piston
//  kinematics. Pure (Foundation + simd) and unit-tested by scripts/tests/scene_tests.swift.
//

import Foundation
import simd

// MARK: - Hand-drawn strokes

/// Rough.js-style strokes: every shape is a few wobbly passes of a marker.
/// All randomness comes from a SceneRNG seeded by the item's id, so a scene
/// draws identically every time it is replayed.
enum SceneRough {
    /// A run of points the renderer draws as one smooth curve.
    struct Stroke: Equatable {
        var points: [SceneVec2]
        var closed = false
    }

    /// How far a stroke of this length may stray, in points.
    static func wobble(forLength length: Double) -> Double {
        min(max(length * 0.014, 0.9), 3.4)
    }

    static func line(_ a: SceneVec2, _ b: SceneVec2, rng: inout SceneRNG, roughness: Double = 1, passes: Int = 2) -> [Stroke] {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 1e-6 else { return [Stroke(points: [a, b])] }
        let amplitude = wobble(forLength: length) * roughness
        let perpendicular = SceneVec2(-delta.y, delta.x) / length
        var strokes: [Stroke] = []
        for _ in 0..<max(1, passes) {
            let start = a + SceneVec2(rng.signed(), rng.signed()) * amplitude * 0.8
            let end = b + SceneVec2(rng.signed(), rng.signed()) * amplitude * 0.8
            let bow = rng.signed() * amplitude * 1.5
            let firstT = 0.33 + rng.signed() * 0.08
            let secondT = 0.67 + rng.signed() * 0.08
            let first = a + delta * firstT + perpendicular * (bow * 0.8 + rng.signed() * amplitude * 0.3)
            let second = a + delta * secondT + perpendicular * (bow + rng.signed() * amplitude * 0.3)
            strokes.append(Stroke(points: [start, first, second, end]))
        }
        return strokes
    }

    static func polyline(_ points: [SceneVec2], closed: Bool, rng: inout SceneRNG, roughness: Double = 1) -> [Stroke] {
        guard points.count >= 2 else { return [] }
        var strokes: [Stroke] = []
        let count = closed ? points.count : points.count - 1
        for index in 0..<count {
            strokes += line(points[index], points[(index + 1) % points.count], rng: &rng, roughness: roughness)
        }
        return strokes
    }

    static func rect(from a: SceneVec2, to b: SceneVec2, rng: inout SceneRNG, roughness: Double = 1) -> [Stroke] {
        let low = simd_min(a, b), high = simd_max(a, b)
        return polyline([low, SceneVec2(high.x, low.y), high, SceneVec2(low.x, high.y)], closed: true, rng: &rng, roughness: roughness)
    }

    /// A loop that overshoots its start, like a circle drawn by hand.
    static func ellipse(center: SceneVec2, rx: Double, ry: Double, rng: inout SceneRNG, roughness: Double = 1, passes: Int = 2) -> [Stroke] {
        let radiusX = max(abs(rx), 0.5), radiusY = max(abs(ry), 0.5)
        let amplitude = wobble(forLength: (radiusX + radiusY) * 2) * roughness
        var strokes: [Stroke] = []
        for pass in 0..<max(1, passes) {
            let startAngle = rng.range(-Double.pi, Double.pi)
            let overshoot = pass == 0 ? rng.range(0.25, 0.55) : rng.range(0.05, 0.2)
            let sweep = 2 * Double.pi + overshoot
            let squashPhase = rng.range(0, 2 * Double.pi)
            let squash = rng.range(0.015, 0.045) * roughness
            let drift = SceneVec2(rng.signed(), rng.signed()) * amplitude * 0.9
            let steps = 30
            var points: [SceneVec2] = []
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let angle = startAngle + sweep * t
                let scale = 1 + squash * sin(2 * angle + squashPhase) + rng.signed() * 0.006 * roughness
                // The end of the loop drifts off the start, so the two ends don't meet exactly.
                points.append(center + drift * t + SceneVec2(cos(angle) * radiusX, sin(angle) * radiusY) * scale)
            }
            strokes.append(Stroke(points: points))
        }
        return strokes
    }

    /// A straight or bent shaft. Returns the strokes plus the tip and its direction for the head.
    static func curve(from a: SceneVec2, to b: SceneVec2, bend: Double, rng: inout SceneRNG, roughness: Double = 1)
        -> (strokes: [Stroke], tip: SceneVec2, direction: SceneVec2) {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 1e-6 else { return ([Stroke(points: [a, b])], b, SceneVec2(1, 0)) }
        if abs(bend) < 0.01 {
            return (line(a, b, rng: &rng, roughness: roughness), b, delta / length)
        }
        let perpendicular = SceneVec2(-delta.y, delta.x) / length
        let control = (a + b) / 2 + perpendicular * (bend * length)
        let amplitude = wobble(forLength: length) * roughness
        var strokes: [Stroke] = []
        for _ in 0..<2 {
            var points: [SceneVec2] = []
            let steps = 14
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let point = a * ((1 - t) * (1 - t)) + control * (2 * t * (1 - t)) + b * (t * t)
                points.append(point + SceneVec2(rng.signed(), rng.signed()) * amplitude * 0.45)
            }
            strokes.append(Stroke(points: points))
        }
        let tangent = b - control
        return (strokes, b, tangent / max(simd_length(tangent), 1e-9))
    }

    static func arrowHead(tip: SceneVec2, direction: SceneVec2, size: Double, rng: inout SceneRNG) -> [Stroke] {
        let angle = atan2(direction.y, direction.x)
        var strokes: [Stroke] = []
        for side in [-1.0, 1.0] {
            let wingAngle = angle + Double.pi + side * (0.45 + rng.signed() * 0.07)
            let wing = tip + SceneVec2(cos(wingAngle), sin(wingAngle)) * size * (1 + rng.signed() * 0.1)
            strokes += line(wing, tip, rng: &rng, roughness: 0.6, passes: 2)
        }
        return strokes
    }
}

// MARK: - Meshes

struct SceneMesh: Equatable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    /// Makes each triangle wind the way its normals point, so two-sided lighting is right.
    mutating func alignWindingWithNormals() {
        var index = 0
        while index + 2 < indices.count {
            let a = Int(indices[index]), b = Int(indices[index + 1]), c = Int(indices[index + 2])
            let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            if simd_dot(face, normals[a] + normals[b] + normals[c]) < 0 {
                indices.swapAt(index + 1, index + 2)
            }
            index += 3
        }
    }
}

enum SceneGeometry {

    // MARK: Curves

    /// Catmull-Rom through the points (centripetal enough for our use: uniform, clamped ends).
    static func smooth<V: SIMD>(_ points: [V], closed: Bool = false, samplesPerSegment: Int = 8) -> [V] where V.Scalar == Double {
        guard points.count >= 3, samplesPerSegment > 1 else { return points }
        let count = points.count
        func point(_ index: Int) -> V {
            if closed { return points[((index % count) + count) % count] }
            return points[min(max(index, 0), count - 1)]
        }
        var result: [V] = []
        let segments = closed ? count : count - 1
        for segment in 0..<segments {
            let p0 = point(segment - 1), p1 = point(segment), p2 = point(segment + 1), p3 = point(segment + 2)
            for sample in 0..<samplesPerSegment {
                let t = Double(sample) / Double(samplesPerSegment)
                let t2 = t * t, t3 = t2 * t
                let a = p1 * 2.0
                let b = (p2 - p0) * t
                let c = (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
                let d = (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3
                result.append((a + b + c + d) * 0.5)
            }
        }
        if !closed { result.append(points[count - 1]) }
        return result
    }

    /// The point a fraction `t` (0...1) of the way along a polyline, and the direction there.
    static func pointAlong(_ path: [SceneVec3], t: Double) -> (position: SceneVec3, direction: SceneVec3) {
        guard path.count >= 2 else { return (path.first ?? .zero, SceneVec3(1, 0, 0)) }
        var lengths: [Double] = []
        var total = 0.0
        for index in 1..<path.count {
            let length = simd_length(path[index] - path[index - 1])
            lengths.append(length)
            total += length
        }
        guard total > 1e-9 else { return (path[0], SceneVec3(1, 0, 0)) }
        var remaining = min(max(t, 0), 1) * total
        for (index, length) in lengths.enumerated() {
            if remaining <= length || index == lengths.count - 1 {
                let direction = length > 1e-9 ? (path[index + 1] - path[index]) / length : SceneVec3(1, 0, 0)
                return (path[index] + direction * min(remaining, length), direction)
            }
            remaining -= length
        }
        return (path[path.count - 1], SceneVec3(1, 0, 0))
    }

    static func pathLength(_ path: [SceneVec3]) -> Double {
        guard path.count >= 2 else { return 0 }
        return (1..<path.count).reduce(0) { $0 + simd_length(path[$1] - path[$1 - 1]) }
    }

    // MARK: Part outlines

    /// Outline of a spur gear in the XY plane, tooth 0 centred on +X.
    /// Module m = 2r/N; teeth rise m above the pitch circle and 1.25 m below it.
    static func gearOutline(teeth: Int, pitchRadius: Double) -> [SceneVec2] {
        let count = min(max(teeth, 4), 240)
        let radius = max(pitchRadius, 1e-4)
        let module = 2 * radius / Double(count)
        let root = max(radius - 1.25 * module, radius * 0.2)
        let tip = radius + module
        let pitch = 2 * Double.pi / Double(count)
        var outline: [SceneVec2] = []
        outline.reserveCapacity(count * 4)
        for tooth in 0..<count {
            let center = Double(tooth) * pitch
            for (r, offset) in [(root, -0.31), (tip, -0.17), (tip, 0.17), (root, 0.31)] {
                let angle = center + offset * pitch
                outline.append(SceneVec2(cos(angle) * r, sin(angle) * r))
            }
        }
        return outline
    }

    /// Module (tooth size) of a gear.
    static func gearModule(teeth: Int, pitchRadius: Double) -> Double {
        2 * pitchRadius / Double(max(teeth, 1))
    }

    /// The rotation of a driven gear that makes its teeth sit in the driver's gaps.
    /// `contactAngle` is the direction from the driver's centre to the driven gear's
    /// centre, measured in the gear plane. Angles in radians.
    static func meshedGearAngle(driverAngle: Double, driverTeeth: Int, drivenTeeth: Int, contactAngle: Double) -> Double {
        let driverPhase = fraction((contactAngle - driverAngle) * Double(driverTeeth) / (2 * Double.pi))
        return contactAngle + Double.pi - 2 * Double.pi * (0.5 - driverPhase) / Double(max(drivenTeeth, 1))
    }

    static func fraction(_ value: Double) -> Double { value - floor(value) }

    /// Points of a helix around +Y, centred on the origin.
    static func helixPoints(radius: Double, height: Double, turns: Double, phase: Double = 0, samplesPerTurn: Int = 24) -> [SceneVec3] {
        let samples = min(max(Int((abs(turns) * Double(samplesPerTurn)).rounded(.up)), 2), 4_000)
        return (0...samples).map { index in
            let t = Double(index) / Double(samples)
            let angle = phase + t * turns * 2 * Double.pi
            return SceneVec3(cos(angle) * radius, (t - 0.5) * height, sin(angle) * radius)
        }
    }

    /// A coil spring between two points with short straight ends.
    static func springPoints(from a: SceneVec3, to b: SceneVec3, coils: Double, radius: Double, samplesPerCoil: Int = 16) -> [SceneVec3] {
        let axis = b - a
        let length = simd_length(axis)
        guard length > 1e-9 else { return [a, b] }
        let direction = axis / length
        let (u, v) = perpendicularBasis(direction)
        let lead = min(length * 0.08, radius)
        let samples = min(max(Int(coils * Double(samplesPerCoil)), 4), 4_000)
        var points: [SceneVec3] = [a]
        for index in 0...samples {
            let t = Double(index) / Double(samples)
            let angle = t * coils * 2 * Double.pi
            let along = lead + t * (length - 2 * lead)
            points.append(a + direction * along + (u * cos(angle) + v * sin(angle)) * radius)
        }
        points.append(b)
        return points
    }

    /// Two unit vectors perpendicular to `direction` and to each other.
    static func perpendicularBasis(_ direction: SceneVec3) -> (SceneVec3, SceneVec3) {
        let d = simd_length(direction) > 1e-9 ? simd_normalize(direction) : SceneVec3(0, 1, 0)
        let helper = abs(d.y) < 0.9 ? SceneVec3(0, 1, 0) : SceneVec3(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, d))
        return (u, simd_cross(d, u))
    }

    // MARK: Meshes

    /// A round tube swept along a path (parallel-transport frames, capped ends).
    static func tubeMesh(path rawPath: [SceneVec3], radius: Double, sides: Int = 12, closed: Bool = false) -> SceneMesh {
        var path: [SceneVec3] = []
        for point in rawPath where path.last.map({ simd_length($0 - point) > 1e-7 }) ?? true { path.append(point) }
        if closed, path.count > 2, simd_length(path[0] - path[path.count - 1]) < 1e-7 { path.removeLast() }
        guard path.count >= 2, radius > 0 else { return SceneMesh() }
        let sideCount = min(max(sides, 3), 48)
        let count = path.count

        func tangent(_ index: Int) -> SceneVec3 {
            let previous = closed ? path[(index - 1 + count) % count] : path[max(index - 1, 0)]
            let next = closed ? path[(index + 1) % count] : path[min(index + 1, count - 1)]
            let delta = next - previous
            return simd_length(delta) > 1e-9 ? simd_normalize(delta) : SceneVec3(0, 1, 0)
        }

        var mesh = SceneMesh()
        var normal = perpendicularBasis(tangent(0)).0
        for index in 0..<count {
            let t = tangent(index)
            let projected = normal - t * simd_dot(normal, t)
            normal = simd_length(projected) > 1e-6 ? simd_normalize(projected) : perpendicularBasis(t).0
            let binormal = simd_cross(t, normal)
            for side in 0..<sideCount {
                let angle = Double(side) / Double(sideCount) * 2 * Double.pi
                let radial = normal * cos(angle) + binormal * sin(angle)
                mesh.positions.append(SIMD3<Float>(path[index] + radial * radius))
                mesh.normals.append(SIMD3<Float>(radial))
            }
        }
        let rings = closed ? count : count - 1
        for ring in 0..<rings {
            let nextRing = (ring + 1) % count
            for side in 0..<sideCount {
                let nextSide = (side + 1) % sideCount
                let a = UInt32(ring * sideCount + side), b = UInt32(ring * sideCount + nextSide)
                let c = UInt32(nextRing * sideCount + side), d = UInt32(nextRing * sideCount + nextSide)
                mesh.indices += [a, c, b, b, c, d]
            }
        }
        if !closed {
            for (ringIndex, sign) in [(0, -1.0), (count - 1, 1.0)] {
                let capNormal = SIMD3<Float>(tangent(ringIndex) * sign)
                let centerIndex = UInt32(mesh.positions.count)
                mesh.positions.append(SIMD3<Float>(path[ringIndex]))
                mesh.normals.append(capNormal)
                let firstRim = UInt32(mesh.positions.count)
                for side in 0..<sideCount {
                    mesh.positions.append(mesh.positions[ringIndex * sideCount + side])
                    mesh.normals.append(capNormal)
                }
                for side in 0..<sideCount {
                    mesh.indices += [centerIndex, firstRim + UInt32(side), firstRim + UInt32((side + 1) % sideCount)]
                }
            }
        }
        mesh.alignWindingWithNormals()
        return mesh
    }

    /// A profile of (radius, y) points revolved around +Y. A sweep under 360° leaves
    /// the solid cut open, and a closed profile gets flat faces on the cut so it
    /// reads as a cutaway rather than a shell.
    static func latheMesh(profile rawProfile: [SceneVec2], segments: Int = 48, sweepDegrees: Double = 360) -> SceneMesh {
        var profile: [SceneVec2] = []
        for point in rawProfile {
            let clamped = SceneVec2(max(point.x, 0), point.y)
            if profile.last.map({ simd_length($0 - clamped) > 1e-7 }) ?? true { profile.append(clamped) }
        }
        guard profile.count >= 2 else { return SceneMesh() }
        let sweep = min(max(abs(sweepDegrees), 1), 360) * Double.pi / 180
        let full = sweep >= 2 * Double.pi - 1e-6
        let steps = max(3, Int((Double(min(max(segments, 6), 128)) * sweep / (2 * Double.pi)).rounded(.up)))

        let segmentCount = profile.count - 1
        var segmentNormals: [SceneVec2] = []
        for index in 0..<segmentCount {
            let delta = profile[index + 1] - profile[index]
            segmentNormals.append(simd_normalize(SceneVec2(delta.y, -delta.x)))
        }
        func blended(_ a: SceneVec2, _ b: SceneVec2) -> SceneVec2? {
            // Smooth across gentle bends only; keep machined edges crisp.
            guard simd_dot(a, b) > 0.82 else { return nil }
            return simd_normalize(a + b)
        }
        let profileIsClosed = profile.count > 3 && simd_length(profile[0] - profile[profile.count - 1]) < 1e-6

        var mesh = SceneMesh()
        for index in 0..<segmentCount {
            var startNormal = segmentNormals[index], endNormal = segmentNormals[index]
            if index > 0, let smooth = blended(segmentNormals[index - 1], segmentNormals[index]) { startNormal = smooth }
            else if index == 0, profileIsClosed, let smooth = blended(segmentNormals[segmentCount - 1], segmentNormals[0]) { startNormal = smooth }
            if index < segmentCount - 1, let smooth = blended(segmentNormals[index], segmentNormals[index + 1]) { endNormal = smooth }
            else if index == segmentCount - 1, profileIsClosed, let smooth = blended(segmentNormals[index], segmentNormals[0]) { endNormal = smooth }

            let base = UInt32(mesh.positions.count)
            for step in 0...steps {
                let angle = sweep * Double(step) / Double(steps)
                let cosine = cos(angle), sine = sin(angle)
                for (point, normal) in [(profile[index], startNormal), (profile[index + 1], endNormal)] {
                    mesh.positions.append(SIMD3<Float>(Float(point.x * cosine), Float(point.y), Float(point.x * sine)))
                    mesh.normals.append(SIMD3<Float>(Float(normal.x * cosine), Float(normal.y), Float(normal.x * sine)))
                }
            }
            for step in 0..<steps {
                let a = base + UInt32(step * 2), b = a + 1, c = a + 2, d = a + 3
                mesh.indices += [a, b, c, b, d, c]
            }
        }

        if !full, profileIsClosed {
            let polygon = Array(profile.dropLast())
            let triangles = triangulate(polygon)
            for (angle, sign) in [(0.0, -1.0), (sweep, 1.0)] {
                let cosine = cos(angle), sine = sin(angle)
                let normal = SIMD3<Float>(Float(-sine * sign), 0, Float(cosine * sign))
                let base = UInt32(mesh.positions.count)
                for point in polygon {
                    mesh.positions.append(SIMD3<Float>(Float(point.x * cosine), Float(point.y), Float(point.x * sine)))
                    mesh.normals.append(normal)
                }
                mesh.indices += triangles.map { base + UInt32($0) }
            }
        }
        mesh.alignWindingWithNormals()
        return mesh
    }

    /// Ear-clipping triangulation of a simple polygon. Returns vertex indices, three per triangle.
    static func triangulate(_ polygon: [SceneVec2]) -> [Int] {
        guard polygon.count >= 3 else { return [] }
        var remaining = Array(polygon.indices)
        let area = signedArea(polygon)
        if area < 0 { remaining.reverse() }
        func cross(_ o: SceneVec2, _ a: SceneVec2, _ b: SceneVec2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func contains(_ a: SceneVec2, _ b: SceneVec2, _ c: SceneVec2, _ p: SceneVec2) -> Bool {
            cross(a, b, p) > 1e-12 && cross(b, c, p) > 1e-12 && cross(c, a, p) > 1e-12
        }
        var triangles: [Int] = []
        var guardCounter = 0
        while remaining.count > 3 && guardCounter < polygon.count * polygon.count + 16 {
            guardCounter += 1
            var clipped = false
            for index in remaining.indices {
                let previous = remaining[(index - 1 + remaining.count) % remaining.count]
                let current = remaining[index]
                let next = remaining[(index + 1) % remaining.count]
                let a = polygon[previous], b = polygon[current], c = polygon[next]
                guard cross(a, b, c) > 1e-12 else { continue }
                let blocked = remaining.contains { other in
                    other != previous && other != current && other != next && contains(a, b, c, polygon[other])
                }
                if blocked { continue }
                triangles += [previous, current, next]
                remaining.remove(at: index)
                clipped = true
                break
            }
            if !clipped {
                // Degenerate input: drop a vertex rather than loop forever.
                remaining.removeLast()
            }
        }
        if remaining.count == 3 { triangles += remaining }
        return triangles
    }

    static func signedArea(_ polygon: [SceneVec2]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    // MARK: Kinematics

    /// Height of a piston pin above the crank centre for a crank angle (0 = top dead centre).
    static func pistonHeight(angle: Double, crank: Double, rod: Double) -> Double {
        let safeRod = max(rod, crank * 1.05)
        let side = crank * sin(angle)
        return crank * cos(angle) + sqrt(max(safeRod * safeRod - side * side, 0))
    }

    /// Where each part goes when a model is pulled apart along an axis: parts keep
    /// their order along the axis and the outermost ones move by `distance`.
    static func explodeOffsets(positions: [SceneVec3], axis: SceneVec3, distance: Double) -> [SceneVec3] {
        guard !positions.isEmpty else { return [] }
        let direction = simd_length(axis) > 1e-9 ? simd_normalize(axis) : SceneVec3(1, 0, 0)
        let projections = positions.map { simd_dot($0, direction) }
        let low = projections.min() ?? 0, high = projections.max() ?? 0
        let middle = (low + high) / 2
        let halfSpan = (high - low) / 2
        if halfSpan < 1e-6 {
            // Everything sits at the same place along the axis: fan out by order.
            let count = positions.count
            return positions.indices.map { index in
                let spread = count > 1 ? (Double(index) / Double(count - 1)) * 2 - 1 : 0
                return direction * spread * distance
            }
        }
        return projections.map { direction * (($0 - middle) / halfSpan) * distance }
    }

    /// The axis a model comes apart along when a script does not name one: the direction
    /// its parts are spread along most. Parts stacked on one spot (flat layers) come apart
    /// along the direction they are thinnest.
    static func explodeAxis(positions: [SceneVec3], extents: [SceneVec3]) -> SceneVec3 {
        let axes = [SceneVec3(1, 0, 0), SceneVec3(0, 1, 0), SceneVec3(0, 0, 1)]
        guard positions.count >= 2 else { return axes[0] }
        let spreads = axes.map { axis -> Double in
            let values = positions.map { simd_dot($0, axis) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        let size = extents.reduce(SceneVec3.zero) { simd_max($0, $1) }
        let largest = max(simd_reduce_max(size), 1e-9)
        if let widest = spreads.max(), widest > largest * 0.05 {
            return axes[spreads.firstIndex(of: widest) ?? 0]
        }
        let thickness = [size.x, size.y, size.z]
        return axes[thickness.firstIndex(of: thickness.min() ?? 0) ?? 1]
    }

    /// Like `explodeOffsets`, for parts that sit on a base (components on a board): every
    /// part moves away from the base, never through it, and the farthest moves by `distance`.
    static func explodeOffsets(positions: [SceneVec3], axis: SceneVec3, distance: Double, base: SceneVec3) -> [SceneVec3] {
        guard !positions.isEmpty else { return [] }
        let direction = simd_length(axis) > 1e-9 ? simd_normalize(axis) : SceneVec3(0, 1, 0)
        let heights = positions.map { simd_dot($0 - base, direction) }
        let reach = max(heights.map { abs($0) }.max() ?? 0, 1e-9)
        // Parts all on one side keep that side even if a script's axis points the other way.
        let above = heights.filter { $0 >= 0 }.count
        let side: Double = above * 2 >= heights.count ? 1 : -1
        return heights.map { height in
            let sign: Double = abs(height) < reach * 1e-3 ? side : (height >= 0 ? 1 : -1)
            return direction * sign * abs(distance) * (0.6 + 0.4 * abs(height) / reach)
        }
    }

    /// A closed belt round two circles in the plane spanned by `u` and `v`: the far arc of
    /// each circle joined by the two outer tangents. Points run with the angle increasing.
    static func beltPath(centerA: SceneVec3, radiusA: Double, centerB: SceneVec3, radiusB: Double, u: SceneVec3, v: SceneVec3, step: Double = 12) -> [SceneVec3] {
        let delta = centerB - centerA
        let dx = simd_dot(delta, u), dy = simd_dot(delta, v)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > abs(radiusA - radiusB) + 1e-9 else { return [] }
        let facing = atan2(dy, dx)
        let alpha = acos(min(max((radiusA - radiusB) / distance, -1), 1))
        func point(_ center: SceneVec3, _ radius: Double, _ angle: Double) -> SceneVec3 {
            center + (u * cos(angle) + v * sin(angle)) * radius
        }
        var points: [SceneVec3] = []
        let stepRadians = max(step, 1) * Double.pi / 180
        // Round the far side of A, from one tangent point to the other.
        let spanA = 2 * Double.pi - 2 * alpha
        let countA = max(Int((spanA / stepRadians).rounded(.up)), 1)
        for index in 0...countA { points.append(point(centerA, radiusA, facing + alpha + spanA * Double(index) / Double(countA))) }
        // Then the far side of B.
        let spanB = 2 * alpha
        let countB = max(Int((spanB / stepRadians).rounded(.up)), 1)
        for index in 0...countB { points.append(point(centerB, radiusB, facing - alpha + spanB * Double(index) / Double(countB))) }
        return points
    }

    /// A point on a circular orbit in the XZ plane, tilted about X.
    static func orbitPosition(center: SceneVec3, radius: Double, angle: Double, tiltDegrees: Double = 0) -> SceneVec3 {
        let tilt = tiltDegrees * Double.pi / 180
        let flat = SceneVec3(cos(angle) * radius, 0, sin(angle) * radius)
        return center + SceneVec3(flat.x, -flat.z * sin(tilt), flat.z * cos(tilt))
    }

    /// Angle from straight down (degrees) of a bob hanging from a pivot, in the XY plane.
    static func pendulumAngle(pivot: SceneVec3, bob: SceneVec3) -> Double {
        let delta = bob - pivot
        return atan2(delta.x, -delta.y) * 180 / Double.pi
    }
}

// MARK: - Gear trains

/// Gears are coupled kinematically: a driven gear turns the other way at
/// driver rpm ÷ ratio, where ratio = driven teeth ÷ driver teeth.
struct SceneGearTrain: Equatable {
    struct Coupling: Equatable {
        var a: String
        var b: String
        /// How many turns of `a` make one turn of `b`.
        var ratio: Double
    }

    var couplings: [Coupling] = []

    mutating func couple(_ a: String, _ b: String, ratio: Double) {
        guard a != b, ratio.isFinite, abs(ratio) > 1e-9 else { return }
        couplings.removeAll { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
        couplings.append(Coupling(a: a, b: b, ratio: ratio))
    }

    /// Spreads the drivers' rpm through the train. A gear reached twice keeps the first value.
    func solve(drivers: [String: Double]) -> [String: Double] {
        var rpm = drivers
        var queue = drivers.keys.sorted()
        var visited = 0
        while visited < queue.count {
            let current = queue[visited]
            visited += 1
            guard let speed = rpm[current] else { continue }
            for coupling in couplings {
                if coupling.a == current, rpm[coupling.b] == nil {
                    rpm[coupling.b] = -speed / coupling.ratio
                    queue.append(coupling.b)
                } else if coupling.b == current, rpm[coupling.a] == nil {
                    rpm[coupling.a] = -speed * coupling.ratio
                    queue.append(coupling.a)
                }
            }
        }
        return rpm
    }
}
