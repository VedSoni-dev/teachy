//
//  SceneQuality.swift
//  leanring-buddy / Scene
//
//  A crude, automatic score for a scene script, used by the model eval
//  (scripts/eval/scene_eval.swift) to compare prompts and part libraries without
//  a person looking at every picture. It is not a judge of beauty: it only
//  checks the things that are cheap to measure and that go wrong in practice.
//
//  Pure (Foundation + simd).
//

import Foundation
import simd

struct SceneQualityReport: Equatable {
    var surface = "-"
    var parseRate = 0.0
    /// 3D parts built, macro pieces included.
    var partCount = 0
    /// Lines that used a ready-made part (gear, fan, piston…).
    var macroLines = 0
    /// Label chips on a 3D model, or pills on an overlay.
    var labelCount = 0
    var sayCount = 0
    /// Sentences followed at once by a line that draws, labels or moves something.
    var tiedSays = 0
    var chipCount = 0
    /// Lines on a card (text, bullets, formulas, charts…).
    var cardItems = 0
    /// 1 = parts sit together sensibly; lower when parts are piled on one spot or flung far away.
    var boundsSanity = 1.0
    /// 0–100.
    var score = 0.0

    var usesMacros: Bool { macroLines > 0 }
}

enum SceneQuality {
    /// What counts as "reaching past plain boxes and cylinders": the part library, plus the
    /// verbs that take real thought to use (a revolved profile, an orbit, a jointed body).
    static func isMacro(_ verb: SceneVerb) -> Bool {
        verb.isLibraryPart || verb == .lathe || verb == .orbit || verb == .joint || verb == .body
    }

    static func report(commands: [SceneCommand], stats: SceneParseStats) -> SceneQualityReport {
        var report = SceneQualityReport()
        report.parseRate = stats.parseRate

        var builder = ScenePartBuilder()
        var current: SceneSurface?
        var surfaces: [String] = []
        var built: [ScenePart] = []
        for (index, command) in commands.enumerated() where command.verb == .say {
            if index + 1 < commands.count, commands[index + 1].verb != .say, commands[index + 1].verb != .chip { report.tiedSays += 1 }
        }
        for command in commands {
            if command.verb == .say { report.sayCount += 1; continue }
            guard let surface = SceneRouter.surface(for: command, current: current) else { continue }
            if command.verb.family != .control { current = surface }
            let name = surface == .scene3d ? "3D" : (surface == .card ? "card" : "overlay")
            if !surfaces.contains(name) { surfaces.append(name) }
            switch surface {
            case .scene3d:
                var routed = command
                routed.verb = SceneRouter.verbIn3D(command)
                if routed.verb == .chip { report.chipCount += 1; continue }
                if routed.verb == .label { report.labelCount += 1; continue }
                if isMacro(routed.verb) { report.macroLines += 1 }
                guard routed.verb.makes3DPart || routed.verb == .group else { continue }
                let parts = builder.build(routed).parts
                built += parts
                report.labelCount += parts.filter { ($0.label ?? "").isEmpty == false }.count
            case .card:
                if command.verb == .chip { report.chipCount += 1 } else if command.verb != .card { report.cardItems += 1 }
            case .overlay:
                if command.verb == .label || command.string("label") != nil { report.labelCount += 1 }
            }
        }
        report.surface = surfaces.isEmpty ? "-" : surfaces.joined(separator: "+")
        report.partCount = built.filter { if case .group = $0.shape { return false } else { return true } }.count
        report.boundsSanity = boundsSanity(of: built)
        report.score = score(report)
        return report
    }

    static func score(_ r: SceneQualityReport) -> Double {
        let narration = min(Double(r.sayCount) / 3, 1)
        if r.surface.contains("3D") {
            let parts = min(Double(r.partCount) / 12, 1)
            let labels: Double = (3...7).contains(r.labelCount) ? 1 : (r.labelCount == 0 ? 0 : 0.55)
            return 100 * (0.28 * r.parseRate + 0.18 * parts + 0.14 * (r.usesMacros ? 1 : 0) + 0.14 * labels + 0.18 * r.boundsSanity + 0.08 * narration)
        }
        if r.surface.contains("card") {
            let items = min(Double(r.cardItems) / 3, 1)
            let chips = min(Double(r.chipCount) / 2, 1)
            return 100 * (0.42 * r.parseRate + 0.30 * items + 0.14 * chips + 0.14 * narration)
        }
        if r.surface.contains("overlay") {
            return 100 * (0.6 * r.parseRate + 0.25 * (r.labelCount > 0 ? 1 : 0) + 0.15 * narration)
        }
        return 0
    }

    /// A rough radius for a part, good enough to tell "inside the model" from "flung away".
    static func approximateRadius(of part: ScenePart) -> Double {
        let scale = max(abs(part.scale.x), abs(part.scale.y), abs(part.scale.z))
        let radius: Double
        switch part.shape {
        case .group: radius = 0
        case .box(let size, _): radius = simd_length(size) / 2
        case .sphere(let r): radius = r
        case .cylinder(let r, let h), .capsule(let r, let h): radius = max(r, h / 2)
        case .cone(let bottom, let top, let h): radius = max(bottom, top, h / 2)
        case .torus(let ring, let pipe): radius = ring + pipe
        case .tube(let path, let r, _): radius = (path.map { simd_length($0) }.max() ?? 0) + r
        case .lathe(let profile, _): radius = profile.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
        case .extrude(let outline, let depth, _): radius = max(outline.map { simd_length($0) }.max() ?? 0, depth / 2)
        case .text(_, let size): radius = size
        }
        return radius * scale
    }

    /// Positions in world space, following `parent=` chains (rotation of parents is ignored: this is a sanity check).
    static func worldCenters(of parts: [ScenePart]) -> [String: SceneVec3] {
        var byID: [String: ScenePart] = [:]
        for part in parts { byID[part.id] = part }
        var result: [String: SceneVec3] = [:]
        for part in parts {
            var position = part.position
            var parent = part.parent
            var hops = 0
            while let id = parent, let node = byID[id], hops < 16 {
                position += node.position
                parent = node.parent
                hops += 1
            }
            result[part.id] = position
        }
        return result
    }

    static func boundsSanity(of parts: [ScenePart]) -> Double {
        // Judge the pieces a script placed itself. A scene that is one ready-made object
        // (a single `rocket r` line) is judged by that object's own main pieces instead.
        var placed = parts.filter { $0.parent == nil }
        if placed.count < 3 {
            let top = Set(placed.map(\.id))
            let children = parts.filter { part in part.parent.map { top.contains($0) } ?? false }
            if children.count >= 2 { placed = children }
        }
        let solid = placed.filter { if case .group = $0.shape { return false }; if case .text = $0.shape { return false }; return true }
        let centers = worldCenters(of: parts)
        let entries: [(center: SceneVec3, radius: Double)] = placed.compactMap { part in
            guard let center = centers[part.id] else { return nil }
            var radius = approximateRadius(of: part)
            if case .group = part.shape {
                radius = parts.filter { $0.parent == part.id }.map { approximateRadius(of: $0) + simd_length($0.position) }.max() ?? 0
            }
            return radius > 0 ? (center, radius) : nil
        }
        guard entries.count >= 2 else { return entries.isEmpty ? 0 : 0.6 }
        guard entries.allSatisfy({ $0.center.x.isFinite && $0.center.y.isFinite && $0.center.z.isFinite && $0.radius.isFinite }) else { return 0 }

        // Flung away: far from the middle compared with how big the rest of the model is.
        let weight = entries.map(\.radius).reduce(0, +)
        let centroid = entries.reduce(SceneVec3.zero) { $0 + $1.center * $1.radius } / max(weight, 1e-9)
        let reach = entries.map { simd_length($0.center - centroid) + $0.radius }.sorted()
        let typical = max(reach[reach.count * 3 / 4], 1e-6)
        let stray = entries.filter { simd_length($0.center - centroid) - $0.radius > typical * 3 }.count

        // Piled up: several solid parts of about the same size on the very same spot.
        var piled = 0
        let solidEntries: [(center: SceneVec3, radius: Double)] = solid.compactMap { part in
            centers[part.id].map { ($0, approximateRadius(of: part)) }
        }
        for (index, entry) in solidEntries.enumerated() {
            let twins = solidEntries.enumerated().filter { other in
                other.offset != index && simd_length(other.element.center - entry.center) < entry.radius * 0.05
                    && abs(other.element.radius - entry.radius) < entry.radius * 0.15
            }.count
            if twins >= 1 { piled += 1 }
        }
        // One part dwarfing everything (a wrong unit): the rest become specks.
        let radii = entries.map(\.radius).sorted()
        let dwarfed = radii.last! > radii[radii.count / 2] * 60 ? 0.3 : 0

        let strayShare = Double(stray) / Double(entries.count)
        let piledShare = solidEntries.isEmpty ? 0 : Double(piled) / Double(solidEntries.count)
        return min(max(1 - strayShare * 1.5 - piledShare - dwarfed, 0), 1)
    }
}
