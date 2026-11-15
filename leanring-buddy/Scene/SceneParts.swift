//
//  SceneParts.swift
//  leanring-buddy / Scene
//
//  Turns 3D scene commands into renderer-neutral parts. This is where the part
//  library lives: one short line like `gear g2 teeth=36 mesh=g1` or `dna d1`
//  expands here into placed, coloured, animated geometry, so the model never
//  spends tokens on vertices.
//
//  Pure (Foundation + simd). The SceneKit renderer only knows how to draw a
//  ScenePart and run a SceneAnimator.
//

import Foundation
import simd

// MARK: - Parts

enum SceneShape: Equatable {
    case group
    case box(size: SceneVec3, corner: Double)
    case sphere(radius: Double)
    case cylinder(radius: Double, height: Double)
    case cone(bottom: Double, top: Double, height: Double)
    case torus(ring: Double, pipe: Double)
    case capsule(radius: Double, height: Double)
    case tube(path: [SceneVec3], radius: Double, closed: Bool)
    /// (radius, y) profile revolved around the part's axis.
    case lathe(profile: [SceneVec2], sweep: Double)
    /// XY outline pushed along the part's axis, with an optional round hole.
    case extrude(outline: [SceneVec2], depth: Double, hole: Double)
    case text(String, size: Double)

    /// The direction a shape's own axis points before it is oriented.
    var naturalAxis: SceneVec3 {
        if case .extrude = self { return SceneVec3(0, 0, 1) }
        return SceneVec3(0, 1, 0)
    }
}

enum SceneMaterial: String, Equatable {
    case plastic, metal, glass, glow, matte, rubber
}

struct ScenePart: Equatable {
    var id: String
    var parent: String?
    var shape: SceneShape
    var position = SceneVec3.zero
    /// Direction the shape's own axis should point, in the parent's space.
    var axis: SceneVec3?
    /// Extra turn about that axis, radians (gear tooth phase).
    var twist = 0.0
    var eulerDegrees = SceneVec3.zero
    /// Set by macros that need an exact orientation; wins over axis and euler.
    var orientation: simd_quatd?
    var scale = SceneVec3(1, 1, 1)
    var color: SceneColor
    var opacity = 1.0
    var material = SceneMaterial.plastic
    /// Shown on a label chip with a leader line.
    var label: String?
    /// What a tap on this part reports when it has no label.
    var name: String?
    var number: Int?
    /// False for the pieces of a macro: a tap resolves to the macro's group.
    var isTappable = true

    var resolvedOrientation: simd_quatd {
        if let orientation { return orientation }
        var result = SceneOrientation.euler(degrees: eulerDegrees)
        if let axis {
            let aligned = SceneOrientation.aligning(shape.naturalAxis, to: axis)
            result = result * simd_quatd(angle: twist, axis: simd_normalize(axis)) * aligned
        } else if twist != 0 {
            result = result * simd_quatd(angle: twist, axis: shape.naturalAxis)
        }
        return result
    }

    var displayName: String { label ?? name ?? id }
}

enum SceneOrientation {
    /// Shortest rotation taking one direction onto another.
    static func aligning(_ from: SceneVec3, to: SceneVec3) -> simd_quatd {
        let a = simd_length(from) > 1e-9 ? simd_normalize(from) : SceneVec3(0, 1, 0)
        let b = simd_length(to) > 1e-9 ? simd_normalize(to) : a
        let cosine = simd_dot(a, b)
        if cosine > 1 - 1e-9 { return simd_quatd(angle: 0, axis: SceneVec3(0, 1, 0)) }
        if cosine < -1 + 1e-9 { return simd_quatd(angle: Double.pi, axis: SceneGeometry.perpendicularBasis(a).0) }
        return simd_quatd(from: a, to: b)
    }

    /// The turn that points a shape's own Y along `along` and its own Z along `facing` (as near as it can).
    static func frame(along: SceneVec3, facing: SceneVec3) -> simd_quatd {
        guard simd_length(along) > 1e-9 else { return simd_quatd(angle: 0, axis: SceneVec3(0, 1, 0)) }
        let y = simd_normalize(along)
        var x = simd_cross(y, facing)
        guard simd_length(x) > 1e-6 else { return aligning(SceneVec3(0, 1, 0), to: y) }
        x = simd_normalize(x)
        let z = simd_cross(x, y)
        return simd_quatd(simd_double3x3(columns: (x, y, z)))
    }

    /// Roughly where the camera starts, so cutaways open toward the viewer.
    static let viewerDirection = simd_normalize(SceneVec3(0.55, 0.45, 0.8))

    /// The turn about `axis` that points the missing wedge of a partly-swept lathe at the viewer.
    static func cutawayTwist(axis: SceneVec3, sweepDegrees: Double) -> Double {
        let sweep = min(max(abs(sweepDegrees), 1), 360)
        guard sweep < 359.5, simd_length(axis) > 1e-9 else { return 0 }
        let n = simd_normalize(axis)
        let gapCenter = (sweep + (360 - sweep) / 2) * Double.pi / 180
        let current = aligning(SceneVec3(0, 1, 0), to: n).act(SceneVec3(cos(gapCenter), 0, sin(gapCenter)))
        let flat = viewerDirection - n * simd_dot(viewerDirection, n)
        guard simd_length(flat) > 1e-6 else { return 0 }
        let wanted = simd_normalize(flat)
        return atan2(simd_dot(simd_cross(current, wanted), n), simd_dot(current, wanted))
    }

    /// Degrees about X, then Y, then Z (fixed axes).
    static func euler(degrees: SceneVec3) -> simd_quatd {
        let radians = degrees * (Double.pi / 180)
        let x = simd_quatd(angle: radians.x, axis: SceneVec3(1, 0, 0))
        let y = simd_quatd(angle: radians.y, axis: SceneVec3(0, 1, 0))
        let z = simd_quatd(angle: radians.z, axis: SceneVec3(0, 0, 1))
        return z * y * x
    }
}

/// Motion the renderer runs every frame.
enum SceneAnimator: Equatable {
    /// Turn about an axis in the parent's space (nil = the part's own axis).
    case spin(target: String, axis: SceneVec3?, rpm: Double)
    /// Markers travelling along a path, looping.
    case flow(group: String, markers: [String], path: [SceneVec3], speed: Double)
    /// Links travelling round a closed path at the rim speed of a gear (a chain or belt).
    case belt(group: String, markers: [String], path: [SceneVec3], gear: String, radius: Double, axis: SceneVec3)
    /// Crank, rod and head of a piston macro.
    case piston(group: String, crank: Double, rod: Double, headHeight: Double, rpm: Double, phase: Double)
    /// Circular orbit around a point or another part.
    case orbit(target: String, around: String?, center: SceneVec3, radius: Double, period: Double, tilt: Double, phase: Double)
    /// A coil redrawn between two parts as they move.
    case spring(target: String, a: String, b: String, coils: Double, radius: Double, wire: Double)

    var target: String {
        switch self {
        case .spin(let target, _, _), .orbit(let target, _, _, _, _, _, _), .spring(let target, _, _, _, _, _): return target
        case .flow(let group, _, _, _), .piston(let group, _, _, _, _, _), .belt(let group, _, _, _, _, _): return group
        }
    }
}

struct SceneBuild: Equatable {
    var parts: [ScenePart] = []
    var animators: [SceneAnimator] = []
}

// MARK: - Builder

/// Stateful only where one part depends on another (gears that mesh, components on a board).
struct ScenePartBuilder {
    struct Gear: Equatable {
        var teeth: Int
        var radius: Double
        var position: SceneVec3
        var axis: SceneVec3
        var twist: Double
        var parent: String?
    }

    private(set) var gears: [String: Gear] = [:]
    private(set) var train = SceneGearTrain()
    private(set) var boardThickness: [String: Double] = [:]
    private(set) var boardSize: [String: SceneVec2] = [:]
    private(set) var positions: [String: SceneVec3] = [:]

    init() {}

    mutating func coupleGears(_ a: String, _ b: String, ratio: Double?) {
        let derived: Double? = {
            guard let first = gears[a], let second = gears[b], first.teeth > 0 else { return nil }
            return Double(second.teeth) / Double(first.teeth)
        }()
        train.couple(a, b, ratio: ratio ?? derived ?? 1)
    }

    mutating func build(_ c: SceneCommand) -> SceneBuild {
        var build = SceneBuild()
        if let expansion = SceneMacros.expand(c) {
            // A whole object: build each of the simpler commands it stands for.
            for command in expansion where command.verb.makes3DPart || command.verb == .group || command.verb == .fixed {
                let piece = self.build(command)
                build.parts += piece.parts
                build.animators += piece.animators
            }
            return build
        }
        switch c.verb {
        case .group, .scene3d:
            if c.verb == .group { build.parts = [basePart(c, shape: .group)] }
        case .box:
            let size = c.vec3("size", spread: true) ?? SceneVec3(c.number("w") ?? 1, c.number("h") ?? 1, c.number("d") ?? 1)
            build.parts = [basePart(c, shape: .box(size: positive(size), corner: c.number("round", "corner") ?? min(size.x, size.y, size.z) * 0.06))]
        case .sphere:
            let radius = c.number("r") ?? c.number("size").map { $0 / 2 } ?? 0.5
            build.parts = [basePart(c, shape: .sphere(radius: positive(radius)))]
        case .cyl, .capsule, .cone:
            build.parts = [axial(c)]
        case .torus:
            let ring = positive(c.number("r") ?? 1)
            let pipe = positive(c.number("r2", "pipe", "tube", "thick") ?? ring * 0.22)
            build.parts = [basePart(c, shape: .torus(ring: ring, pipe: min(pipe, ring)))]
        case .tube:
            var path = c.points3()
            if c.flag("smooth") || c.flag("curve") { path = SceneGeometry.smooth(path, closed: c.flag("closed")) }
            build.parts = [basePart(c, shape: .tube(path: path, radius: positive(c.number("r", "w") ?? 0.08), closed: c.flag("closed")))]
        case .lathe:
            var part = basePart(c, shape: .lathe(profile: c.points2(), sweep: c.number("sweep", "arc", "cut") ?? 360))
            if part.axis == nil { part.axis = SceneVec3(0, 1, 0) }
            if c.args["twist"] == nil, let axis = part.axis, case .lathe(_, let sweep) = part.shape {
                part.twist = SceneOrientation.cutawayTwist(axis: axis, sweepDegrees: sweep)
            }
            build.parts = [part]
        case .extrude:
            let depth = positive(c.number("depth", "h", "d", "thick") ?? 0.2)
            build.parts = [basePart(c, shape: .extrude(outline: c.points2(), depth: depth, hole: max(c.number("hole") ?? 0, 0)))]
        case .arrow, .arrow3:
            build.parts = [arrow(c)]
        case .text3, .label:
            var part = basePart(c, shape: .text(c.freeText ?? "", size: positive(c.number("size") ?? 0.3)))
            part.isTappable = false
            if c.color() == nil { part.color = .ink }
            build.parts = [part]
        case .gear: build = gear(c)
        case .helix: build = helix(c)
        case .dna: build = dna(c)
        case .spring: build = spring(c)
        case .piston: build = piston(c)
        case .wheel: build = wheel(c)
        case .fan: build = fan(c)
        case .flow: build = flow(c)
        case .board: build = board(c)
        case .comp, .chip: build = component(c)
        case .chain: build = chain(c)
        case .axes: build = axes(c)
        case .body, .fixed: build = body(c)
        case .ground:
            let size = positive(c.number("size") ?? 12)
            var part = basePart(c, shape: .box(size: SceneVec3(size, 0.06, size), corner: 0.02))
            part.position = SceneVec3(part.position.x, (c.number("y") ?? part.position.y) - 0.03, part.position.z)
            if c.color() == nil { part.color = SceneColor(hex: 0xE9E4D4) }
            part.material = .matte
            part.isTappable = false
            build.parts = [part]
        default:
            break
        }
        // `rpm=` on any part is shorthand for a spin about its own axis.
        if let rpm = c.number("rpm"), let first = build.parts.first, c.verb != .piston, c.verb != .spin,
           !build.animators.contains(where: { if case .spin = $0 { return true } else { return false } }) {
            build.animators.append(.spin(target: first.id, axis: c.axis("spin"), rpm: rpm))
        }
        for part in build.parts where part.parent == nil || part.id == c.id {
            positions[part.id] = part.position
        }
        return build
    }

    // MARK: Shared attributes

    private func positive(_ value: Double) -> Double { min(max(abs(value), 1e-4), 10_000) }
    private func positive(_ value: SceneVec3) -> SceneVec3 { SceneVec3(positive(value.x), positive(value.y), positive(value.z)) }

    static let metalColours: Set<String> = ["silver", "steel", "metal", "gold", "copper", "bronze", "chrome", "iron"]

    private func basePart(_ c: SceneCommand, shape: SceneShape) -> ScenePart {
        var part = ScenePart(id: c.id, shape: shape, color: c.color() ?? SceneColor.automatic(for: c.id))
        part.parent = c.string("parent", "in", "group")
        if c.verb != .comp, c.verb != .chip, c.verb != .label, part.parent == nil, let on = c.string("on") { part.parent = on }
        part.position = c.vec3("at") ?? .zero
        part.axis = c.axis()
        part.twist = (c.number("twist") ?? 0) * Double.pi / 180
        part.eulerDegrees = c.vec3("rot") ?? .zero
        if let scale = c.vec3("scale", spread: true) { part.scale = scale }
        part.opacity = min(max(c.number("opacity") ?? part.color.a, 0.02), 1)
        part.label = c.string("label")
        part.name = c.string("name", "title")
        part.number = c.number("n", "num").map { Int($0) }
        let colourName = c.string("color")?.lowercased() ?? ""
        if let material = c.string("mat", "material").flatMap({ SceneMaterial(rawValue: $0.lowercased()) }) {
            part.material = material
        } else if c.flag("glow") {
            part.material = .glow
        } else if colourName == "glass" || part.opacity < 0.6 {
            // See-through wins over metal: a translucent steel casing is a window, not a mirror.
            part.material = .glass
        } else if Self.metalColours.contains(colourName) {
            part.material = .metal
        }
        return part
    }

    /// Cylinder, capsule or cone: `r= h= axis=` or stretched between `from=` and `to=`.
    private func axial(_ c: SceneCommand) -> ScenePart {
        var radius = c.number("r") ?? 0.5
        var height = c.number("h") ?? 1
        let size = c.numbers("size")
        if c.args["r"] == nil, size.count >= 1 { radius = size[0] / 2 }
        if c.args["h"] == nil, size.count >= 2 { height = size[1] }
        if c.args["r"] == nil, let diameter = c.number("d", "diameter") { radius = diameter / 2 }
        var between: (SceneVec3, SceneVec3)?
        if let from = c.vec3("from"), let to = c.vec3("to"), simd_length(to - from) > 1e-9 {
            between = (from, to)
            height = simd_length(to - from)
        }
        let shape: SceneShape
        switch c.verb {
        case .capsule: shape = .capsule(radius: positive(radius), height: max(positive(height), positive(radius) * 2))
        case .cone: shape = .cone(bottom: positive(radius), top: max(c.number("r2", "top") ?? 0, 0), height: positive(height))
        default: shape = .cylinder(radius: positive(radius), height: positive(height))
        }
        var part = basePart(c, shape: shape)
        if let (from, to) = between {
            part.position = (from + to) / 2
            part.axis = simd_normalize(to - from)
        }
        return part
    }

    private func segment(id: String, parent: String?, from: SceneVec3, to: SceneVec3, radius: Double, color: SceneColor, material: SceneMaterial = .plastic) -> ScenePart {
        var part = ScenePart(id: id, shape: .cylinder(radius: radius, height: max(simd_length(to - from), 1e-4)), color: color)
        part.parent = parent
        part.position = (from + to) / 2
        part.axis = simd_length(to - from) > 1e-9 ? simd_normalize(to - from) : SceneVec3(0, 1, 0)
        part.material = material
        part.isTappable = false
        return part
    }

    /// One solid arrow: a shaft and a head revolved as a single profile.
    private func arrow(_ c: SceneCommand) -> ScenePart {
        let from = c.vec3("from") ?? .zero
        let to = c.vec3("to") ?? SceneVec3(1, 0, 0)
        return arrowPart(c, id: c.id, from: from, to: to, thickness: c.number("r", "w"))
    }

    private func arrowPart(_ c: SceneCommand?, id: String, from: SceneVec3, to: SceneVec3, thickness: Double?, color: SceneColor? = nil) -> ScenePart {
        let length = max(simd_length(to - from), 1e-4)
        let shaft = positive(thickness ?? min(max(length * 0.03, 0.02), 0.12))
        let head = min(length * 0.35, shaft * 6)
        let profile = [SceneVec2(0, 0), SceneVec2(shaft, 0), SceneVec2(shaft, length - head), SceneVec2(shaft * 2.6, length - head), SceneVec2(0, length)]
        var part: ScenePart
        if let c {
            part = basePart(c, shape: .lathe(profile: profile, sweep: 360))
            if c.color() == nil { part.color = SceneColor.named["orange"] ?? .marker }
        } else {
            part = ScenePart(id: id, shape: .lathe(profile: profile, sweep: 360), color: color ?? .marker)
        }
        part.id = id
        part.position = from
        part.axis = simd_normalize(to - from)
        if let color { part.color = color }
        return part
    }

    // MARK: Part library

    private mutating func gear(_ c: SceneCommand) -> SceneBuild {
        let teeth = Int(min(max(c.number("teeth", "n") ?? 12, 4), 240).rounded())
        var radius = positive(c.number("r") ?? 1)
        var part = basePart(c, shape: .group)
        part.number = c.number("num").map { Int($0) } ?? (c.args["teeth"] != nil ? c.number("n").map { Int($0) } : nil)
        var axis = part.axis ?? SceneVec3(0, 0, 1)
        var twist = part.twist
        var position = part.position

        if let partnerID = c.string("mesh", "with", "meshes"), let partner = gears[partnerID] {
            // Same tooth size as the partner, so the pair actually meshes.
            axis = partner.axis
            let module = SceneGeometry.gearModule(teeth: partner.teeth, pitchRadius: partner.radius)
            radius = module * Double(teeth) / 2
            let alignment = SceneOrientation.aligning(SceneVec3(0, 0, 1), to: axis)
            let u = alignment.act(SceneVec3(1, 0, 0)), v = alignment.act(SceneVec3(0, 1, 0))
            var contact = (c.number("angle", "side") ?? 0) * Double.pi / 180
            if c.args["at"] == nil {
                position = partner.position + (u * cos(contact) + v * sin(contact)) * (partner.radius + radius)
                if part.parent == nil { part.parent = partner.parent }
            } else {
                let delta = position - partner.position
                contact = atan2(simd_dot(delta, v), simd_dot(delta, u))
            }
            twist = SceneGeometry.meshedGearAngle(driverAngle: partner.twist, driverTeeth: partner.teeth, drivenTeeth: teeth, contactAngle: contact)
            train.couple(partnerID, c.id, ratio: Double(teeth) / Double(partner.teeth))
        }

        let module = SceneGeometry.gearModule(teeth: teeth, pitchRadius: radius)
        let depth = positive(c.number("thick", "depth", "h", "w") ?? max(radius * 0.18, module * 1.2))
        let hole = c.number("hole") ?? radius * 0.18
        part.shape = .extrude(outline: SceneGeometry.gearOutline(teeth: teeth, pitchRadius: radius), depth: depth, hole: min(max(hole, 0), radius * 0.6))
        part.axis = axis
        part.twist = twist
        part.position = position
        if c.string("mat", "material") == nil { part.material = .metal }
        gears[c.id] = Gear(teeth: teeth, radius: radius, position: position, axis: axis, twist: twist, parent: part.parent)
        return SceneBuild(parts: [part])
    }

    private func helix(_ c: SceneCommand) -> SceneBuild {
        let radius = positive(c.number("r") ?? 1)
        let height = positive(c.number("h") ?? 4)
        let turns = min(max(c.number("turns", "coils") ?? 3, 0.1), 60)
        let strands = Int(min(max(c.number("strands") ?? 1, 1), 6))
        let wire = positive(c.number("wire", "r2", "w") ?? radius * 0.08)
        var group = basePart(c, shape: .group)
        if group.axis == nil { group.axis = SceneVec3(0, 1, 0) }
        var parts = [group]
        for strand in 0..<strands {
            let phase = Double(strand) / Double(strands) * 2 * Double.pi
            var part = ScenePart(id: "\(c.id).s\(strand + 1)",
                                 shape: .tube(path: SceneGeometry.helixPoints(radius: radius, height: height, turns: turns, phase: phase), radius: wire, closed: false),
                                 color: strand == 0 ? group.color : SceneColor.palette[(strand + 1) % SceneColor.palette.count])
            part.parent = c.id
            part.material = group.material
            part.isTappable = false
            parts.append(part)
        }
        return SceneBuild(parts: parts)
    }

    private func dna(_ c: SceneCommand) -> SceneBuild {
        let radius = positive(c.number("r") ?? 1)
        let turns = min(max(c.number("turns") ?? 2, 0.25), 20)
        let height = positive(c.number("h") ?? turns * radius * 3.4)
        let pairCount = Int(min(max(c.number("pairs") ?? (turns * 10).rounded(), 2), 160))
        let wire = radius * 0.11
        var group = basePart(c, shape: .group)
        if group.axis == nil { group.axis = SceneVec3(0, 1, 0) }
        var parts = [group]

        let backboneColours = [SceneColor.named["blue"]!, SceneColor.named["orange"]!]
        for (strand, phase) in [0.0, Double.pi].enumerated() {
            var part = ScenePart(id: "\(c.id).strand\(strand + 1)",
                                 shape: .tube(path: SceneGeometry.helixPoints(radius: radius, height: height, turns: turns, phase: phase, samplesPerTurn: 28), radius: wire, closed: false),
                                 color: backboneColours[strand])
            part.parent = c.id
            part.name = strand == 0 ? "Sugar-phosphate backbone" : "Second backbone"
            part.isTappable = false
            parts.append(part)
        }

        // A–T and G–C in a fixed, seeded order so replays match.
        let bases: [(SceneColor, SceneColor)] = [
            (SceneColor.named["green"]!, SceneColor.named["red"]!),
            (SceneColor.named["red"]!, SceneColor.named["green"]!),
            (SceneColor.named["yellow"]!, SceneColor.named["purple"]!),
            (SceneColor.named["purple"]!, SceneColor.named["yellow"]!),
        ]
        var rng = SceneRNG(id: c.id)
        for pair in 0..<pairCount {
            let t = (Double(pair) + 0.5) / Double(pairCount)
            let angle = t * turns * 2 * Double.pi
            let y = (t - 0.5) * height
            let first = SceneVec3(cos(angle) * radius, y, sin(angle) * radius)
            let second = SceneVec3(-first.x, y, -first.z)
            let middle = SceneVec3(0, y, 0)
            let colours = bases[Int(rng.next() % UInt64(bases.count))]
            parts.append(segment(id: "\(c.id).b\(pair)a", parent: c.id, from: first, to: middle, radius: wire * 0.62, color: colours.0))
            parts.append(segment(id: "\(c.id).b\(pair)b", parent: c.id, from: middle, to: second, radius: wire * 0.62, color: colours.1))
        }
        return SceneBuild(parts: parts)
    }

    private func spring(_ c: SceneCommand) -> SceneBuild {
        let coils = min(max(c.number("coils", "turns") ?? 8, 1), 80)
        let radius = positive(c.number("r") ?? 0.3)
        let wire = positive(c.number("wire", "r2") ?? radius * 0.14)
        var part = basePart(c, shape: .group)
        if c.string("mat", "material") == nil { part.material = .metal }
        if c.color() == nil { part.color = SceneColor.named["steel"]! }

        // Between two parts: redrawn every frame as they move.
        if let a = c.string("a"), let b = c.string("b"), c.numbers("a").count < 2 {
            let start = positions[a] ?? .zero, end = positions[b] ?? SceneVec3(0, -1, 0)
            part.shape = .tube(path: SceneGeometry.springPoints(from: start, to: end, coils: coils, radius: radius), radius: wire, closed: false)
            part.position = .zero
            part.axis = nil
            return SceneBuild(parts: [part], animators: [.spring(target: c.id, a: a, b: b, coils: coils, radius: radius, wire: wire)])
        }
        var from = c.vec3("from"), to = c.vec3("to")
        if from == nil || to == nil {
            let axis = part.axis ?? SceneVec3(0, 1, 0)
            let height = positive(c.number("h") ?? 2)
            from = part.position - axis * height / 2
            to = part.position + axis * height / 2
        }
        part.shape = .tube(path: SceneGeometry.springPoints(from: from!, to: to!, coils: coils, radius: radius), radius: wire, closed: false)
        part.position = .zero
        part.axis = nil
        return SceneBuild(parts: [part])
    }

    private func piston(_ c: SceneCommand) -> SceneBuild {
        let bore = positive(c.number("bore", "r").map { c.args["bore"] != nil ? $0 : $0 * 2 } ?? 1)
        let stroke = positive(c.number("stroke") ?? bore)
        let crank = stroke / 2
        let rod = max(positive(c.number("rod") ?? stroke * 1.75), crank * 1.3)
        let rpm = c.number("rpm") ?? 50
        let phase = (c.number("phase") ?? 0) * Double.pi / 180
        let headHeight = bore * 0.55
        var group = basePart(c, shape: .group)
        group.color = c.color() ?? SceneColor.named["steel"]!
        var parts = [group]

        let wall = bore * 0.07
        let inner = bore / 2 + bore * 0.015
        let bottom = rod - crank - headHeight * 0.4
        let top = rod + crank + headHeight * 0.55 + bore * 0.25
        var sleeve = ScenePart(id: "\(c.id).cylinder",
                               shape: .lathe(profile: [SceneVec2(inner, bottom), SceneVec2(inner + wall, bottom), SceneVec2(inner + wall, top + wall),
                                                       SceneVec2(0, top + wall), SceneVec2(0, top), SceneVec2(inner, top), SceneVec2(inner, bottom)], sweep: 250),
                               color: SceneColor.named["silver"]!)
        sleeve.parent = c.id
        sleeve.axis = SceneVec3(0, 1, 0)
        sleeve.twist = SceneOrientation.cutawayTwist(axis: SceneVec3(0, 1, 0), sweepDegrees: 250)
        sleeve.material = .metal
        sleeve.name = "Cylinder"
        sleeve.isTappable = false
        parts.append(sleeve)

        var head = ScenePart(id: "\(c.id).head", shape: .cylinder(radius: bore / 2, height: headHeight), color: group.color)
        head.parent = c.id
        head.material = .metal
        head.isTappable = false
        parts.append(head)

        var rodPart = segment(id: "\(c.id).rod", parent: c.id, from: SceneVec3(0, crank, 0), to: SceneVec3(0, crank + rod, 0),
                              radius: bore * 0.07, color: SceneColor.named["gray"]!, material: .metal)
        rodPart.name = "Connecting rod"
        parts.append(rodPart)

        var crankDisc = ScenePart(id: "\(c.id).crank", shape: .cylinder(radius: crank * 1.25, height: bore * 0.14), color: SceneColor.named["orange"]!)
        crankDisc.parent = c.id
        crankDisc.axis = SceneVec3(0, 0, 1)
        crankDisc.position = SceneVec3(0, 0, -bore * 0.16)
        crankDisc.isTappable = false
        parts.append(crankDisc)

        var pin = ScenePart(id: "\(c.id).pin", shape: .cylinder(radius: bore * 0.08, height: bore * 0.36), color: SceneColor.named["darkgray"]!)
        pin.parent = c.id
        pin.axis = SceneVec3(0, 0, 1)
        pin.material = .metal
        pin.isTappable = false
        parts.append(pin)

        return SceneBuild(parts: parts, animators: [.piston(group: c.id, crank: crank, rod: rod, headHeight: headHeight, rpm: rpm, phase: phase)])
    }

    private func wheel(_ c: SceneCommand) -> SceneBuild {
        let radius = positive(c.number("r") ?? 1)
        let width = positive(c.number("w", "width", "thick") ?? radius * 0.35)
        let spokes = Int(min(max(c.number("spokes") ?? 6, 0), 48))
        var group = basePart(c, shape: .group)
        if group.axis == nil { group.axis = SceneVec3(1, 0, 0) }
        var parts = [group]
        let pipe = min(width / 2, radius * 0.24)
        var tire = ScenePart(id: "\(c.id).tire", shape: .torus(ring: radius - pipe, pipe: pipe), color: c.color() ?? SceneColor.named["black"]!)
        tire.parent = c.id
        tire.material = .rubber
        tire.isTappable = false
        parts.append(tire)
        let rimRadius = radius - pipe * 1.7
        var rim = ScenePart(id: "\(c.id).rim",
                            shape: .lathe(profile: [SceneVec2(rimRadius * 0.9, -width * 0.3), SceneVec2(rimRadius, -width * 0.3), SceneVec2(rimRadius, width * 0.3),
                                                    SceneVec2(rimRadius * 0.9, width * 0.3), SceneVec2(rimRadius * 0.9, -width * 0.3)], sweep: 360),
                            color: SceneColor.named["silver"]!)
        rim.parent = c.id
        rim.axis = SceneVec3(0, 1, 0)
        rim.material = .metal
        rim.isTappable = false
        parts.append(rim)
        var hub = ScenePart(id: "\(c.id).hub", shape: .cylinder(radius: radius * 0.16, height: width * 0.8), color: SceneColor.named["steel"]!)
        hub.parent = c.id
        hub.material = .metal
        hub.isTappable = false
        parts.append(hub)
        for spoke in 0..<spokes {
            let angle = Double(spoke) / Double(spokes) * 2 * Double.pi
            let direction = SceneVec3(cos(angle), 0, sin(angle))
            parts.append(segment(id: "\(c.id).spoke\(spoke)", parent: c.id, from: direction * radius * 0.14, to: direction * rimRadius * 0.93,
                                 radius: radius * 0.035, color: SceneColor.named["silver"]!, material: .metal))
        }
        return SceneBuild(parts: parts)
    }

    private func fan(_ c: SceneCommand) -> SceneBuild {
        let radius = positive(c.number("r") ?? 1)
        let blades = Int(min(max(c.number("blades", "n", "count") ?? 8, 2), 64))
        let hub = min(positive(c.number("hub") ?? radius * 0.25), radius * 0.9)
        let pitch = (c.number("pitch") ?? 32) * Double.pi / 180
        var group = basePart(c, shape: .group)
        group.number = c.number("num").map { Int($0) } ?? (c.args["blades"] != nil ? c.number("n").map { Int($0) } : nil)
        if group.axis == nil { group.axis = SceneVec3(0, 0, 1) }
        let bladeColour = c.color() ?? SceneColor.named["steel"]!
        var parts = [group]

        let depth = positive(c.number("thick", "depth", "w") ?? radius * 0.22)
        var hubPart = ScenePart(id: "\(c.id).hub",
                                shape: .lathe(profile: [SceneVec2(0, -depth * 0.55), SceneVec2(hub, -depth * 0.55), SceneVec2(hub, depth * 0.3),
                                                        SceneVec2(hub * 0.8, depth * 0.75), SceneVec2(hub * 0.45, depth * 1.1), SceneVec2(0, depth * 1.25)], sweep: 360),
                                color: bladeColour.mixed(with: SceneColor(0, 0, 0), amount: 0.25))
        hubPart.parent = c.id
        hubPart.axis = SceneVec3(0, 1, 0)
        hubPart.material = .metal
        hubPart.isTappable = false
        parts.append(hubPart)

        let span = radius - hub * 0.85
        let middle = hub * 0.85 + span / 2
        let chord = min(2 * Double.pi * middle / Double(blades) * 1.05, radius * 0.55)
        for blade in 0..<blades {
            let angle = Double(blade) / Double(blades) * 2 * Double.pi
            var part = ScenePart(id: "\(c.id).blade\(blade)", shape: .box(size: SceneVec3(span, radius * 0.025, chord), corner: radius * 0.01), color: bladeColour)
            part.parent = c.id
            part.position = SceneVec3(cos(angle) * middle, 0, sin(angle) * middle)
            // Long side along the radius, then pitched about it.
            part.orientation = simd_quatd(angle: -angle, axis: SceneVec3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SceneVec3(1, 0, 0))
            part.material = group.material == .plastic ? .metal : group.material
            part.isTappable = false
            parts.append(part)
        }
        return SceneBuild(parts: parts)
    }

    private func flow(_ c: SceneCommand) -> SceneBuild {
        var path = c.points3()
        if path.count > 2 { path = SceneGeometry.smooth(path, samplesPerSegment: 6) }
        let length = SceneGeometry.pathLength(path)
        let size = positive(c.number("size", "r", "w") ?? min(max(length * 0.035, 0.05), 0.16))
        let count = Int(min(max(c.number("n", "count") ?? (length / (size * 7)).rounded(), 2), 40))
        let speed = c.number("speed") ?? max(length / 3.5, 0.2)
        var group = basePart(c, shape: .group)
        group.position = .zero
        group.axis = nil
        if c.color() == nil { group.color = SceneColor.named["sky"]! }
        var parts = [group]

        var trail = ScenePart(id: "\(c.id).trail", shape: .tube(path: path, radius: size * 0.22, closed: false), color: group.color)
        trail.parent = c.id
        trail.opacity = 0.28
        trail.material = .glow
        trail.isTappable = false
        parts.append(trail)

        var markers: [String] = []
        for index in 0..<count {
            var marker = ScenePart(id: "\(c.id).m\(index)", shape: .cone(bottom: size, top: 0, height: size * 2.6), color: group.color)
            marker.parent = c.id
            marker.material = .glow
            marker.isTappable = false
            let placement = SceneGeometry.pointAlong(path, t: Double(index) / Double(count))
            marker.position = placement.position
            marker.axis = placement.direction
            markers.append(marker.id)
            parts.append(marker)
        }
        return SceneBuild(parts: parts, animators: [.flow(group: c.id, markers: markers, path: path, speed: speed)])
    }

    private mutating func board(_ c: SceneCommand) -> SceneBuild {
        let size = c.numbers("size")
        let width = positive(size.first ?? 4), depth = positive(size.count > 1 ? size[1] : (size.first ?? 4) * 0.66)
        let thickness = positive(size.count > 2 ? size[2] : (c.number("thick", "h") ?? 0.08))
        var part = basePart(c, shape: .box(size: SceneVec3(width, thickness, depth), corner: min(width, depth) * 0.03))
        if c.color() == nil { part.color = SceneColor.named["pcb"]! }
        boardThickness[c.id] = thickness
        boardSize[c.id] = SceneVec2(width, depth)
        return SceneBuild(parts: [part])
    }

    /// What a block on a board is, from `kind=` or from words in its id and label.
    static func componentKind(_ c: SceneCommand) -> String {
        if let kind = c.string("kind", "type")?.lowercased() { return kind }
        let text = (c.id + " " + (c.string("label", "name") ?? "") + " " + (c.words.first(where: \.quoted)?.text ?? "")).lowercased()
        let table: [(String, [String])] = [
            ("header", ["gpio", "header", "pins"]),
            ("ethernet", ["ethernet", "rj45", "lan"]),
            ("hdmi", ["hdmi", "displayport"]),
            ("usb", ["usb", "power in"]),
            ("sd", ["sd", "sim"]),
            ("connector", ["camera", "csi", "dsi", "ribbon", "connector", "fpc", "pcie"]),
            ("chip", ["cpu", "soc", "processor", "chip", "ram", "memory", "wifi", "wi-fi", "bluetooth", "controller", "pmic", "flash", "gpu", "rp1"]),
        ]
        for (kind, words) in table where words.contains(where: { text.contains($0) }) { return kind }
        return "block"
    }

    /// A flat labelled block. `on=board at=x,z` sits it on top of the board.
    private func component(_ c: SceneCommand) -> SceneBuild {
        let size = c.numbers("size")
        let width = positive(size.first ?? 0.6), depth = positive(size.count > 1 ? size[1] : size.first ?? 0.6)
        let height = positive(size.count > 2 ? size[2] : (c.number("h", "thick") ?? 0.14))
        var part = basePart(c, shape: .box(size: SceneVec3(width, height, depth), corner: min(width, depth, height) * 0.12))
        if c.color() == nil { part.color = SceneColor.named["darkgray"]! }
        let board = c.string("on", "parent", "board") ?? (boardThickness.count == 1 ? boardThickness.keys.first : nil)
        let at = c.numbers("at")
        if let board, let thickness = boardThickness[board] {
            part.parent = board
            if at.count == 2 {
                part.position = SceneVec3(at[0], thickness / 2 + height / 2, at[1])
            } else if at.count >= 3 {
                part.position = SceneVec3(at[0], max(at[1], thickness / 2 + height / 2), at[2])
            } else {
                part.position = SceneVec3(0, thickness / 2 + height / 2, 0)
            }
        } else if at.count == 2 {
            part.position = SceneVec3(at[0], height / 2, at[1])
        }
        if part.label == nil, part.name == nil, let text = c.words.first(where: \.quoted)?.text { part.label = text }

        // Dress the block as what it is: a port gets a metal shell and a dark opening, a chip a lid, a header its pins.
        let kind = Self.componentKind(c)
        var extras: [ScenePart] = []
        func child(_ name: String, _ shape: SceneShape, at: SceneVec3, color: SceneColor, material: SceneMaterial = .plastic) -> ScenePart {
            var piece = ScenePart(id: "\(c.id).\(name)", shape: shape, color: color)
            piece.parent = c.id
            piece.position = at
            piece.material = material
            piece.isTappable = false
            return piece
        }
        let explicitHeight = size.count > 2 || c.number("h", "thick") != nil
        func resize(height newHeight: Double) {
            guard !explicitHeight else { return }
            part.shape = .box(size: SceneVec3(width, newHeight, depth), corner: min(width, depth, newHeight) * 0.08)
            part.position.y += (newHeight - height) / 2
        }
        var bodyHeight = height
        let small = min(width, depth)
        switch kind {
        case "usb", "ethernet", "hdmi":
            bodyHeight = explicitHeight ? height : small * (kind == "ethernet" ? 0.85 : (kind == "usb" ? 0.7 : 0.4))
            resize(height: bodyHeight)
            if c.color() == nil { part.color = SceneColor.named["silver"]!; part.material = .metal }
            // The opening faces the nearest edge of the board.
            let half = board.flatMap { boardSize[$0] }.map { $0 / 2 } ?? SceneVec2(1, 1)
            let x = part.position.x, z = part.position.z
            let facesX = abs(x) / max(half.x, 1e-6) >= abs(z) / max(half.y, 1e-6)
            let sign: Double = (facesX ? x : z) >= 0 ? 1 : -1
            let slab = facesX ? SceneVec3(width * 0.04, bodyHeight * 0.62, depth * 0.78) : SceneVec3(width * 0.78, bodyHeight * 0.62, depth * 0.04)
            let at = facesX ? SceneVec3(sign * width * 0.49, 0, 0) : SceneVec3(0, 0, sign * depth * 0.49)
            extras.append(child("port", .box(size: slab, corner: 0), at: at, color: SceneColor(hex: 0x15161A), material: .matte))
        case "chip":
            if c.color() == nil { part.color = SceneColor(hex: 0x1E1F24) }
            extras.append(child("lid", .box(size: SceneVec3(width * 0.74, height * 0.3, depth * 0.74), corner: small * 0.03), at: SceneVec3(0, height * 0.5, 0),
                                color: SceneColor.named["silver"]!, material: .metal))
        case "sd":
            if c.color() == nil { part.color = SceneColor.named["silver"]!; part.material = .metal }
        case "connector":
            if c.color() == nil { part.color = SceneColor.named["cream"]! }
            extras.append(child("latch", .box(size: SceneVec3(width * 0.94, height * 0.4, depth * 0.3), corner: 0), at: SceneVec3(0, height * 0.5, depth * 0.3),
                                color: SceneColor(hex: 0x33363D), material: .matte))
        case "header":
            if c.color() == nil { part.color = SceneColor(hex: 0x17181C) }
            let alongX = width >= depth
            let long = max(width, depth), short = min(width, depth)
            let rows = 2
            let pitch = short / Double(rows)
            let perRow = min(max(Int(long / pitch), 2), 24)
            let gold = SceneColor.named["gold"]!
            for row in 0..<rows {
                for pin in 0..<perRow {
                    let along = (Double(pin) + 0.5) * long / Double(perRow) - long / 2
                    let across = (Double(row) + 0.5) * pitch - short / 2
                    extras.append(child("p\(row)_\(pin)", .box(size: SceneVec3(pitch * 0.26, pitch * 1.3, pitch * 0.26), corner: 0),
                                        at: alongX ? SceneVec3(along, height / 2 + pitch * 0.6, across) : SceneVec3(across, height / 2 + pitch * 0.6, along),
                                        color: gold, material: .metal))
                }
            }
        default:
            break
        }
        return SceneBuild(parts: [part] + extras)
    }

    /// A chain or belt round two gears. They then turn the same way, at the ratio of their teeth.
    private mutating func chain(_ c: SceneCommand) -> SceneBuild {
        guard let aID = c.string("a", "from"), let bID = c.string("b", "to") else { return SceneBuild() }
        let first = gears[aID], second = gears[bID]
        let axis = first?.axis ?? second?.axis ?? c.axis() ?? SceneVec3(0, 0, 1)
        let centerA = first?.position ?? positions[aID] ?? .zero
        let centerB = second?.position ?? positions[bID] ?? SceneVec3(2, 0, 0)
        // The chain rides on the teeth, a little outside each gear's pitch circle.
        func rim(_ gear: Gear?) -> Double? { gear.map { $0.radius + SceneGeometry.gearModule(teeth: $0.teeth, pitchRadius: $0.radius) * 0.6 } }
        let radiusA = positive(c.number("ra") ?? rim(first) ?? 0.5), radiusB = positive(c.number("rb") ?? rim(second) ?? 0.5)
        let alignment = SceneOrientation.aligning(SceneVec3(0, 0, 1), to: axis)
        let u = alignment.act(SceneVec3(1, 0, 0)), v = alignment.act(SceneVec3(0, 1, 0))
        let path = SceneGeometry.beltPath(centerA: centerA, radiusA: radiusA, centerB: centerB, radiusB: radiusB, u: u, v: v)
        guard path.count >= 4 else { return SceneBuild() }
        let wire = positive(c.number("r", "w", "wire") ?? min(radiusA, radiusB) * 0.09)
        let across = positive(c.number("width") ?? min(radiusA, radiusB) * 0.34)
        var group = basePart(c, shape: .group)
        group.position = .zero
        group.axis = nil
        group.parent = first?.parent ?? c.string("parent")
        if c.color() == nil { group.color = SceneColor(hex: 0x3B3F48) }
        if group.name == nil, group.label == nil { group.name = "Chain" }
        var parts = [group]
        var loop = ScenePart(id: "\(c.id).loop", shape: .tube(path: path, radius: wire * 0.5, closed: true), color: group.color)
        loop.parent = c.id
        loop.material = .metal
        loop.isTappable = false
        parts.append(loop)
        let closed = path + [path[0]]
        let length = SceneGeometry.pathLength(closed)
        let count = Int(min(max((length / (wire * 4.4)).rounded(), 6), 110))
        var markers: [String] = []
        for index in 0..<count {
            var link = ScenePart(id: "\(c.id).l\(index)", shape: .box(size: SceneVec3(wire * 1.5, wire * 3.2, across), corner: wire * 0.4), color: SceneColor.named["silver"]!)
            link.parent = c.id
            link.material = .metal
            link.isTappable = false
            let placement = SceneGeometry.pointAlong(closed, t: Double(index) / Double(count))
            link.position = placement.position
            link.orientation = SceneOrientation.frame(along: placement.direction, facing: axis)
            markers.append(link.id)
            parts.append(link)
        }
        if let first, let second, first.teeth > 0 {
            train.couple(aID, bID, ratio: -Double(second.teeth) / Double(first.teeth))
        } else {
            train.couple(aID, bID, ratio: -radiusB / radiusA)
        }
        return SceneBuild(parts: parts, animators: [.belt(group: c.id, markers: markers, path: closed, gear: aID, radius: radiusA, axis: axis)])
    }

    private func axes(_ c: SceneCommand) -> SceneBuild {
        let size = positive(c.number("size", "len", "h") ?? 2)
        var group = basePart(c, shape: .group)
        group.isTappable = false
        var parts = [group]
        let entries: [(String, SceneVec3, String)] = [("x", SceneVec3(1, 0, 0), "red"), ("y", SceneVec3(0, 1, 0), "green"), ("z", SceneVec3(0, 0, 1), "blue")]
        for (name, direction, colour) in entries {
            var shaft = arrowPart(nil, id: "\(c.id).\(name)", from: .zero, to: direction * size, thickness: size * 0.012, color: SceneColor.named[colour])
            shaft.parent = c.id
            shaft.isTappable = false
            parts.append(shaft)
            var text = ScenePart(id: "\(c.id).\(name)label", shape: .text(c.string(name) ?? name, size: size * 0.11), color: SceneColor.named[colour]!)
            text.parent = c.id
            text.position = direction * size * 1.08
            text.isTappable = false
            parts.append(text)
        }
        return SceneBuild(parts: parts)
    }

    /// The visible part of a physics body (the renderer adds the physics).
    private func body(_ c: SceneCommand) -> SceneBuild {
        let kind = (c.string("shape") ?? (c.verb == .fixed ? "anchor" : "sphere")).lowercased()
        let shape: SceneShape
        switch kind {
        case "box", "cube", "block":
            shape = .box(size: positive(c.vec3("size", spread: true) ?? SceneVec3(repeating: (c.number("r") ?? 0.3) * 2)), corner: 0.02)
        case "cyl", "cylinder", "disc", "disk":
            shape = .cylinder(radius: positive(c.number("r") ?? 0.3), height: positive(c.number("h") ?? 0.6))
        case "capsule":
            shape = .capsule(radius: positive(c.number("r") ?? 0.2), height: positive(c.number("h") ?? 0.8))
        case "anchor":
            shape = .sphere(radius: positive(c.number("r") ?? 0.09))
        default:
            shape = .sphere(radius: positive(c.number("r") ?? c.number("size").map { $0 / 2 } ?? 0.3))
        }
        var part = basePart(c, shape: shape)
        if c.verb == .fixed, c.color() == nil { part.color = SceneColor.named["darkgray"]! }
        return SceneBuild(parts: [part])
    }
}

// MARK: - Label text

enum SceneLabelText {
    /// Separates a leading list number from a label: "1. Fan" → ("Fan", 1), and "1 Fan" with n=1 → ("Fan", 1).
    /// A number that is part of the name stays: "3 Na⁺ out" and "2 stroke engine" are left alone,
    /// because a bare number followed by a space is only a list number when `n=` says the same.
    static func split(_ text: String, number: Int?) -> (text: String, number: Int?) {
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 2, let leading = Int(digits) else { return (text, number) }
        let rest = text.dropFirst(digits.count)
        guard let separator = rest.first else { return (text, number) }
        let isListMark = ".:)·".contains(separator) || rest.hasPrefix(" ·") || rest.hasPrefix(" - ") || rest.hasPrefix(" – ")
        if isListMark {
            guard number == nil || number == leading else { return (text, number) }
        } else if separator == " " {
            guard number == leading else { return (text, number) }
        } else {
            return (text, number)
        }
        let stripped = rest.drop(while: { " .:)·-–".contains($0) })
        guard !stripped.isEmpty else { return (text, number) }
        return (String(stripped), leading)
    }
}

// MARK: - Routing

/// Which renderer a command goes to. Some verbs are shared (`label`, `chip`,
/// `arrow`, `line`, `text`), so the surface most recently opened decides.
enum SceneSurface: Equatable {
    case overlay
    case card
    case scene3d
}

enum SceneRouter {
    static func surface(for c: SceneCommand, current: SceneSurface?) -> SceneSurface? {
        switch c.verb {
        case .say, .clear, .set, .remove, .hide, .show:
            return current
        case .card: return .card
        case .scene3d: return .scene3d
        case .label:
            if c.string("on") != nil { return .scene3d }
            if c.numbers("at").count >= 3 && current == .scene3d { return .scene3d }
            return .overlay
        case .chip:
            if c.args["at"] != nil || c.args["size"] != nil || c.args["on"] != nil { return .scene3d }
            return current == .scene3d ? .scene3d : .card
        case .arrow:
            return c.numbers("from").count >= 3 || c.numbers("to").count >= 3 ? .scene3d : .overlay
        case .line:
            return current == .scene3d && c.numbers("pts").count % 3 == 0 && !c.args.keys.contains("from") ? .scene3d : .overlay
        case .text:
            return current == .scene3d && c.args["at"] != nil ? .scene3d : .card
        case .slider, .plot:
            return .scene3d
        default:
            switch c.verb.family {
            case .overlay: return .overlay
            case .card: return .card
            case .scene3d: return .scene3d
            case .control: return current
            }
        }
    }

    /// The 3D verb a shared verb stands for once it is routed to the 3D scene.
    static func verbIn3D(_ c: SceneCommand) -> SceneVerb {
        switch c.verb {
        case .arrow: return .arrow3
        case .line: return .tube
        case .text: return .text3
        case .chip where c.args["at"] != nil || c.args["size"] != nil || c.args["on"] != nil: return .comp
        default: return c.verb
        }
    }

    /// Number of 3D parts a script builds (macro pieces included).
    static func count3DParts(in commands: [SceneCommand]) -> Int {
        var builder = ScenePartBuilder()
        var current: SceneSurface?
        var total = 0
        for command in commands {
            guard let surface = surface(for: command, current: current) else { continue }
            if command.verb.family != .control { current = surface }
            guard surface == .scene3d else { continue }
            var routed = command
            routed.verb = verbIn3D(command)
            guard routed.verb.makes3DPart || routed.verb == .group else { continue }
            total += builder.build(routed).parts.filter { if case .group = $0.shape { return false } else { return true } }.count
        }
        return total
    }
}
