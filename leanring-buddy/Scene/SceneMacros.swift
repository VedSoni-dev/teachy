//
//  SceneMacros.swift
//  leanring-buddy / Scene
//
//  Whole objects in one line. `jet j`, `rocket r stages=2`, `heart h` or
//  `battery b` is rewritten here into the simpler commands the engine already
//  draws (lathes, fans, tubes, flows…), so a model thinking very little still
//  gets a convincing turbofan instead of three cylinders.
//
//  Every macro makes a group with the line's id. Its main pieces are children
//  named `id.piece` (listed in `pieces(of:)`), so a script can label, pulse or
//  move them:   label on=j.turbine text="Turbine" n=4
//
//  Pure (Foundation + simd): the expansions are checked by the scene tests.
//

import Foundation
import simd

enum SceneMacros {

    /// The simpler commands a macro line stands for, or nil when the line is not a macro.
    static func expand(_ c: SceneCommand) -> [SceneCommand]? {
        guard c.verb.isMacro else { return nil }
        var builder = Builder(c)
        switch c.verb {
        case .jet: jet(&builder)
        case .engine: engine(&builder)
        case .rocket: rocket(&builder)
        case .bridge: bridge(&builder)
        case .heart: heart(&builder)
        case .eye: eye(&builder)
        case .motor: motor(&builder)
        case .battery: battery(&builder)
        case .membrane: membrane(&builder)
        case .protein: protein(&builder)
        case .planet: planet(&builder)
        case .pendulum: pendulum(&builder)
        case .pins: pins(&builder)
        default: return nil
        }
        if c.flag("labels") || c.flag("labelled") || c.flag("labeled") {
            for (index, piece) in pieces(of: c.verb).prefix(7).enumerated() where builder.made.contains("\(c.id).\(piece.suffix)") {
                builder.line("label on=\(c.id).\(piece.suffix) text=\"\(piece.title)\" n=\(index + 1)")
            }
        }
        return builder.commands
    }

    /// The pieces of a macro that a script can address as `id.suffix`, in the order they are best explained.
    static func pieces(of verb: SceneVerb) -> [(suffix: String, title: String)] {
        switch verb {
        case .jet:
            return [("fan", "Fan"), ("compressor", "Compressor"), ("combustor", "Combustor"), ("turbine", "Turbine"),
                    ("nozzle", "Exhaust nozzle"), ("nacelle", "Nacelle"), ("bypass", "Bypass air")]
        case .engine:
            return [("p1", "Piston"), ("crankshaft", "Crankshaft"), ("block", "Engine block"), ("flywheel", "Flywheel")]
        case .rocket:
            return [("nose", "Nose cone"), ("stage2", "Second stage"), ("interstage", "Interstage"), ("stage1", "First stage"),
                    ("fins", "Fins"), ("engine", "Engine"), ("flame", "Exhaust")]
        case .bridge:
            return [("deck", "Deck"), ("cable", "Main cable"), ("hangers", "Hangers"), ("tower1", "Tower"), ("anchor1", "Anchorage")]
        case .heart:
            return [("ra", "Right atrium"), ("rv", "Right ventricle"), ("pulmonary", "Pulmonary artery"), ("la", "Left atrium"),
                    ("lv", "Left ventricle"), ("aorta", "Aorta"), ("venacava", "Vena cava")]
        case .eye:
            return [("cornea", "Cornea"), ("iris", "Iris"), ("lens", "Lens"), ("retina", "Retina"), ("nerve", "Optic nerve"), ("sclera", "Sclera")]
        case .motor:
            return [("north", "North magnet"), ("south", "South magnet"), ("rotor", "Rotor coil"), ("commutator", "Commutator"),
                    ("brushes", "Brushes"), ("shaft", "Shaft"), ("housing", "Housing")]
        case .battery:
            return [("positive", "Positive terminal"), ("cathode", "Cathode"), ("separator", "Separator"), ("anode", "Anode"),
                    ("collector", "Current collector"), ("case", "Steel case"), ("negative", "Negative terminal")]
        case .pendulum:
            return [("bob", "Bob"), ("pivot", "Pivot")]
        default:
            return []
        }
    }

    // MARK: - Builder

    struct Builder {
        let c: SceneCommand
        let id: String
        private(set) var commands: [SceneCommand] = []
        private(set) var made: Set<String> = []

        init(_ c: SceneCommand) {
            self.c = c
            self.id = c.id
        }

        /// Adds one or more script lines.
        mutating func line(_ text: String) {
            for var command in SceneScriptParser.parse(text) {
                command.cue = c.cue
                command.lineNumber = c.lineNumber
                made.insert(command.id)
                commands.append(command)
            }
        }

        /// Adds a command without going through text (for the hundreds of lipids in a membrane).
        mutating func add(_ verb: SceneVerb, _ id: String, _ args: [String: String]) {
            commands.append(SceneCommand(verb: verb, id: id, args: args, cue: c.cue, lineNumber: c.lineNumber))
            made.insert(id)
        }

        /// The group every piece hangs from. `scale` is the macro's own size factor.
        mutating func group(defaultAxis: String? = nil, scale: Double = 1, name: String) {
            var args: [String: String] = [:]
            for key in ["at", "rot", "parent", "label", "n", "num", "opacity"] {
                if let value = c.args[key] { args[key] = value }
            }
            if let axis = c.args["axis"] ?? defaultAxis { args["axis"] = axis }
            let size = scale * (c.number("scale") ?? 1)
            if abs(size - 1) > 1e-9 { args["scale"] = SceneMacros.n(size) }
            args["name"] = c.string("name", "title") ?? name
            add(.group, id, args)
        }

        /// The group's axis in world space (ignoring `rot=`).
        func worldAxis(default fallback: SceneVec3) -> SceneVec3 { c.axis() ?? fallback }

        /// Degrees of twist that open a cutaway (a lathe swept less than 360°) toward the viewer.
        func cutTwist(axis: SceneVec3, sweep: Double) -> String {
            SceneMacros.n(SceneOrientation.cutawayTwist(axis: axis, sweepDegrees: sweep) * 180 / Double.pi)
        }

        /// A unit direction, in the group's own space, that points at the viewer and is square to the group's axis.
        func towardViewer(axis: SceneVec3) -> SceneVec3 {
            let local = SceneOrientation.aligning(SceneVec3(0, 1, 0), to: axis).inverse.act(SceneOrientation.viewerDirection)
            let flat = SceneVec3(local.x, 0, local.z)
            return simd_length(flat) > 1e-6 ? simd_normalize(flat) : SceneVec3(0, 0, 1)
        }

        func number(_ keys: String..., default fallback: Double) -> Double {
            for key in keys { if let value = c.number(key) { return value } }
            return fallback
        }

        var color: String? { c.args["color"] }
    }

    static func n(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
        return text.contains(".") ? text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : text
    }

    private static func point(_ v: SceneVec3) -> String { "\(n(v.x)),\(n(v.y)),\(n(v.z))" }

    private static func path(_ points: [SceneVec3]) -> String { points.map(point).joined(separator: ";") }

    /// (radius, y) points of a circle arc from `from` to `to` degrees (0° = +radius, 90° = +y), about (0, centerY).
    private static func arc(radius: Double, from: Double, to: Double, steps: Int, centerY: Double = 0) -> String {
        (0...steps).map { step -> String in
            let angle = (from + (to - from) * Double(step) / Double(steps)) * Double.pi / 180
            return "\(n(max(cos(angle) * radius, 0))),\(n(centerY + sin(angle) * radius))"
        }.joined(separator: ";")
    }

    // MARK: - Jet engine

    /// A cutaway turbofan lying along its axis: nacelle, fan, compressor stages, combustor, turbine, nozzle, and the two air streams.
    private static func jet(_ b: inout Builder) {
        let id = b.id
        let axis = b.worldAxis(default: SceneVec3(1, 0, 0))
        let rpm = n(b.number("rpm", default: 70))
        let stages = Int(min(max(b.number("stages", default: 4), 2), 7))
        let sweep = 215.0
        let twist = b.cutTwist(axis: axis, sweep: sweep)
        b.group(defaultAxis: "x", scale: b.number("r", "size", default: 1), name: "Jet engine")
        b.line("""
        lathe \(id).nacelle parent=\(id) pts=0.97,-1.85;1.08,-1.7;1.16,-1.1;1.14,-0.2;1.02,0.55;0.96,0.6;1.0,-0.2;1.02,-1.1;1.0,-1.6;0.97,-1.85 sweep=\(n(sweep)) twist=\(twist) color=\(b.color ?? "white") name="Nacelle"
        lathe \(id).casing parent=\(id) pts=0.56,-0.85;0.6,-0.8;0.52,0;0.56,0.55;0.46,1.2;0.42,1.2;0.52,0.55;0.48,0;0.56,-0.8;0.56,-0.85 sweep=\(n(sweep)) twist=\(twist) color=steel name="Core casing"
        fan \(id).fan parent=\(id) at=0,-1.3,0 axis=-y r=0.98 hub=0.3 blades=18 pitch=38 thick=0.2 rpm=\(rpm) color=steel name="Fan"
        cone \(id).fan.spinner parent=\(id).fan at=0,0.38,0 r=0.3 h=0.5 color=darkgray mat=metal
        group \(id).compressor parent=\(id) rpm=\(rpm) name="Compressor"
        lathe \(id).combustor parent=\(id) pts=0.2,0.1;0.44,0.14;0.46,0.42;0.2,0.5;0.2,0.1 sweep=\(n(sweep)) twist=\(twist) color=orange glow name="Combustor"
        group \(id).turbine parent=\(id) rpm=\(rpm) name="Turbine"
        fan \(id).turbine.s1 parent=\(id).turbine at=0,0.68,0 axis=y r=0.5 hub=0.24 blades=20 pitch=50 thick=0.09 color=copper
        fan \(id).turbine.s2 parent=\(id).turbine at=0,0.9,0 axis=y r=0.47 hub=0.24 blades=20 pitch=50 thick=0.09 color=copper
        cyl \(id).shaft parent=\(id) from=0,-1.2,0 to=0,1.15,0 r=0.07 color=silver
        cone \(id).nozzle parent=\(id) at=0,1.52,0 r=0.3 h=0.85 color=darkgray mat=metal name="Exhaust nozzle"
        """)
        for stage in 0..<stages {
            let t = Double(stage) / Double(max(stages - 1, 1))
            let radius = 0.5 - 0.09 * t
            b.line("fan \(id).compressor.s\(stage + 1) parent=\(id).compressor at=0,\(n(-0.7 + 0.62 * t)),0 axis=y r=\(n(radius)) hub=\(n(radius * 0.5)) blades=16 pitch=48 thick=0.07 color=sky")
        }
        if !b.c.flag("noflow") {
            let v = b.towardViewer(axis: axis)
            func along(_ entries: [(Double, Double)]) -> String { path(entries.map { SceneVec3(v.x * $0.0, $0.1, v.z * $0.0) }) }
            b.line("""
            flow \(id).bypass parent=\(id) pts=\(along([(0.8, -2.5), (0.8, -1.4), (0.78, 0.1), (0.82, 1.4)])) color=sky size=0.07 name="Bypass air"
            flow \(id).core parent=\(id) pts=\(along([(0.36, -1.15), (0.34, -0.3), (0.32, 0.1)])) color=blue size=0.055 name="Core air"
            flow \(id).exhaust parent=\(id) pts=\(along([(0.33, 0.52), (0.34, 1.2), (0.24, 1.9), (0.2, 2.5)])) color=orange size=0.07 name="Hot exhaust"
            """)
        }
    }

    // MARK: - Piston engine

    private static func engine(_ b: inout Builder) {
        let id = b.id
        let count = Int(min(max(b.number("cylinders", "cyl", "pistons", "count", default: 4), 1), 8))
        let bore = b.number("bore", default: 0.8)
        let stroke = b.number("stroke", default: bore)
        // Pistons are capped at 150 rpm so the motion can be seen; the flywheel must match them.
        let rpm = n(min(max(b.number("rpm", default: 60), -150), 150))
        let spacing = bore * 1.38
        let phases: [Double]
        switch count {
        case 2: phases = [0, 180]
        case 3: phases = [0, 240, 120]
        case 4: phases = [0, 180, 180, 0]
        case 6: phases = [0, 120, 240, 240, 120, 0]
        default: phases = (0..<count).map { Double($0) * 360 / Double(count) }
        }
        let rod = stroke * 1.75
        let top = rod + stroke / 2 + bore * 0.75
        let span = spacing * Double(count - 1)
        b.group(scale: b.number("size", default: 1), name: "Engine")
        for index in 0..<count {
            let z = -span / 2 + spacing * Double(index)
            b.line("piston \(id).p\(index + 1) parent=\(id) at=0,0,\(n(z)) bore=\(n(bore)) stroke=\(n(stroke)) rpm=\(rpm) phase=\(n(phases[index])) name=\"Piston \(index + 1)\"")
        }
        b.line("""
        cyl \(id).crankshaft parent=\(id) from=0,0,\(n(-span / 2 - bore * 0.8)) to=0,0,\(n(span / 2 + bore * 0.9)) r=\(n(bore * 0.11)) color=steel name="Crankshaft"
        cyl \(id).flywheel parent=\(id) at=0,0,\(n(span / 2 + bore * 0.95)) axis=z r=\(n(stroke * 0.95)) h=\(n(bore * 0.22)) color=darkgray mat=metal rpm=\(rpm) name="Flywheel"
        box \(id).block parent=\(id) at=0,\(n(top / 2 + stroke * 0.3)),0 size=\(n(bore * 1.5)),\(n(top - stroke * 0.5)),\(n(span + bore * 1.5)) color=steel opacity=0.16 name="Engine block"
        box \(id).pan parent=\(id) at=0,\(n(-stroke * 0.95)),0 size=\(n(bore * 1.5)),\(n(stroke * 0.5)),\(n(span + bore * 1.5)) color=darkgray opacity=0.3 name="Oil pan"
        """)
    }

    // MARK: - Rocket

    private static func rocket(_ b: inout Builder) {
        let id = b.id
        let stages = Int(min(max(b.number("stages", default: 2), 1), 3))
        let radii = [0.5, 0.4, 0.32], heights = [2.4, 1.3, 0.9]
        let names = ["First stage", "Second stage", "Third stage"]
        let body = b.color ?? "white"
        var total = 0.0
        for stage in 0..<stages { total += heights[stage] + (stage < stages - 1 ? 0.4 : 0) }
        total += 1.3
        let scale = b.c.number("h").map { $0 / total } ?? b.c.number("r").map { $0 / 0.5 } ?? b.number("size", default: 1)
        b.group(scale: scale, name: "Rocket")
        b.line("""
        cone \(id).engine parent=\(id) at=0,-0.24,0 r=0.36 r2=0.15 h=0.5 color=darkgray mat=metal name="Engine"
        """)
        if !b.c.flag("noflame") {
            b.line("cone \(id).flame parent=\(id) at=0,-1.05,0 axis=-y r=0.27 h=1.15 color=orange glow opacity=0.8 name=\"Exhaust\"")
            b.line("cone \(id).flame.core parent=\(id).flame at=0,-0.12,0 r=0.14 h=0.75 color=yellow glow opacity=0.9")
        }
        for fin in 0..<4 {
            let angle = Double(fin) * 90 + 45
            let radians = angle * Double.pi / 180
            b.line("extrude \(id).fins\(fin == 0 ? "" : "\(fin)") parent=\(id) pts=0,0;0.62,-0.05;0.62,0.25;0,1.0 depth=0.05 at=\(n(cos(radians) * 0.47)),0,\(n(sin(radians) * 0.47)) rot=0,\(n(-angle)),0 color=red name=\"Fins\"")
        }
        var y = 0.0
        for stage in 0..<stages {
            let r = radii[stage], h = heights[stage]
            b.line("cyl \(id).stage\(stage + 1) parent=\(id) at=0,\(n(y + h / 2)),0 r=\(n(r)) h=\(n(h)) color=\(body) name=\"\(names[stage])\"")
            b.line("cyl \(id).stage\(stage + 1).band parent=\(id).stage\(stage + 1) at=0,\(n(h / 2 - 0.2)),0 r=\(n(r * 1.012)) h=0.1 color=black")
            y += h
            if stage < stages - 1 {
                b.line("cone \(id).interstage\(stage == 0 ? "" : "\(stage + 1)") parent=\(id) at=0,\(n(y + 0.2)),0 r=\(n(r)) r2=\(n(radii[stage + 1])) h=0.4 color=darkgray name=\"Interstage\"")
                y += 0.4
            }
        }
        let r = radii[stages - 1]
        b.line("lathe \(id).nose parent=\(id) at=0,\(n(y)),0 pts=0,0;\(n(r)),0;\(n(r)),0.3;\(n(r * 0.9)),0.62;\(n(r * 0.66)),0.95;\(n(r * 0.32)),1.2;0,1.3 color=\(b.c.args["nose"] ?? "red") name=\"Nose cone\"")
    }

    // MARK: - Suspension bridge

    private static func bridge(_ b: inout Builder) {
        let id = b.id
        let scale = b.c.number("span").map { $0 / 6 } ?? b.number("size", default: 1)
        b.group(scale: scale, name: "Suspension bridge")
        let towerX = 3.0, end = 5.2, top = 2.7, low = 0.7, railZ = 0.5
        func cableHeight(_ x: Double) -> Double {
            let ax = abs(x)
            if ax <= towerX { return low + (top - low) * (ax / towerX) * (ax / towerX) }
            let t = (ax - towerX) / (end - towerX)
            return top + (0.12 - top) * (t * 0.75 + t * t * 0.25)
        }
        b.line("""
        box \(id).deck parent=\(id) at=0,0,0 size=\(n(end * 2)),0.16,1.15 color=steel name="Deck"
        box \(id).deck.road parent=\(id).deck at=0,0.085,0 size=\(n(end * 2)),0.012,0.86 color=darkgray
        box \(id).water parent=\(id) at=0,-1.0,0 size=\(n(end * 2 + 0.6)),0.04,3.6 color=sky opacity=0.45
        """)
        for (index, x) in [-towerX, towerX].enumerated() {
            let tower = "\(id).tower\(index + 1)"
            b.line("""
            group \(tower) parent=\(id) at=\(n(x)),0,0 name="Tower"
            box \(tower).a parent=\(tower) at=0,0.9,\(n(railZ + 0.1)) size=0.24,3.8,0.2 color=\(b.color ?? "red")
            box \(tower).b parent=\(tower) at=0,0.9,\(n(-railZ - 0.1)) size=0.24,3.8,0.2 color=\(b.color ?? "red")
            box \(tower).c parent=\(tower) at=0,2.62,0 size=0.22,0.2,1.2 color=\(b.color ?? "red")
            box \(tower).d parent=\(tower) at=0,1.5,0 size=0.2,0.16,1.2 color=\(b.color ?? "red")
            box \(id).anchor\(index + 1) parent=\(id) at=\(n(x < 0 ? -end - 0.2 : end + 0.2)),-0.05,0 size=0.8,0.7,1.7 color=gray name="Anchorage"
            """)
        }
        let xs = stride(from: -end, through: end + 0.001, by: 0.4).map { $0 }
        for (index, z) in [railZ + 0.1, -railZ - 0.1].enumerated() {
            let points = xs.map { SceneVec3($0, cableHeight($0), z) }
            b.line("tube \(id).cable\(index == 0 ? "" : "2") parent=\(id) pts=\(path(points)) r=0.045 color=gold name=\"Main cable\"")
        }
        b.line("group \(id).hangers parent=\(id) name=\"Hangers\"")
        var hanger = 0
        for x in stride(from: -end + 0.6, through: end - 0.59, by: 0.5) where abs(abs(x) - towerX) > 0.2 {
            for z in [railZ + 0.1, -railZ - 0.1] {
                hanger += 1
                b.line("cyl \(id).hangers.h\(hanger) parent=\(id).hangers from=\(n(x)),0.08,\(n(z)) to=\(n(x)),\(n(cableHeight(x))),\(n(z)) r=0.014 color=gray")
            }
        }
    }

    // MARK: - Heart

    /// A diagram heart: oxygen-poor side blue, oxygen-rich side red, beating, with the blood's path.
    private static func heart(_ b: inout Builder) {
        let id = b.id
        let bpm = n(b.number("bpm", "beat", "rate", default: 60))
        b.group(scale: b.number("size", "r", default: 1), name: "Heart")
        b.line("""
        sphere \(id).rv parent=\(id) at=-0.36,-0.32,0.14 r=0.56 scale=0.95,1.3,0.9 rot=0,0,-14 color=#3F6FD8 name="Right ventricle"
        sphere \(id).lv parent=\(id) at=0.3,-0.36,-0.04 r=0.62 scale=0.95,1.38,0.95 rot=0,0,-14 color=#D8433F name="Left ventricle"
        sphere \(id).ra parent=\(id) at=-0.62,0.52,0.08 r=0.42 scale=1,0.92,0.95 color=#6C93E8 name="Right atrium"
        sphere \(id).la parent=\(id) at=0.5,0.58,-0.14 r=0.4 scale=1,0.9,0.95 color=#E86C68 name="Left atrium"
        tube \(id).aorta parent=\(id) pts=0.12,0.3,0.02;0.1,1.05,0.02;-0.02,1.5,-0.02;-0.3,1.66,-0.1;-0.58,1.5,-0.2;-0.66,1.0,-0.28;-0.66,0.2,-0.32 r=0.17 smooth color=#D8433F name="Aorta"
        tube \(id).aorta.b1 parent=\(id).aorta pts=-0.02,1.52,-0.02;0.02,2.0,-0.02 r=0.07 color=#D8433F
        tube \(id).aorta.b2 parent=\(id).aorta pts=-0.28,1.66,-0.1;-0.3,2.05,-0.1 r=0.07 color=#D8433F
        tube \(id).pulmonary parent=\(id) pts=-0.2,0.25,0.34;-0.12,0.85,0.36;0.14,1.18,0.3;0.55,1.26,0.2;0.95,1.2,0.12 r=0.15 smooth color=#3F6FD8 name="Pulmonary artery"
        tube \(id).venacava parent=\(id) pts=-0.72,1.95,0.02;-0.7,1.2,0.04;-0.68,0.6,0.06 r=0.14 color=#3F6FD8 name="Vena cava"
        tube \(id).venacava.lower parent=\(id).venacava pts=-0.7,0.3,0.04;-0.74,-0.5,-0.2;-0.76,-1.35,-0.24 r=0.13 smooth color=#3F6FD8
        tube \(id).veins parent=\(id) pts=0.72,0.68,-0.2;1.2,0.82,-0.28 r=0.085 color=#E86C68 name="Pulmonary veins"
        tube \(id).veins.b parent=\(id).veins pts=0.74,0.46,-0.22;1.2,0.44,-0.3 r=0.085 color=#E86C68
        beat \(id).rv bpm=\(bpm) amount=0.07
        beat \(id).lv bpm=\(bpm) amount=0.07
        beat \(id).ra bpm=\(bpm) amount=0.06 phase=0.35
        beat \(id).la bpm=\(bpm) amount=0.06 phase=0.35
        """)
        if !b.c.flag("noflow") {
            b.line("""
            flow \(id).inflow parent=\(id) pts=-0.72,2.5,0.3;-0.7,1.4,0.3;-0.66,0.7,0.52 color=sky size=0.07 n=4 name="Blood from the body"
            flow \(id).tolungs parent=\(id) pts=-0.3,0.2,0.62;-0.14,0.9,0.6;0.3,1.3,0.52;1.5,1.25,0.3 color=sky size=0.07 n=4 name="Blood to the lungs"
            flow \(id).fromlungs parent=\(id) pts=1.75,0.66,-0.05;1.0,0.62,0.12;0.6,0.56,0.3 color=pink size=0.07 n=3 name="Blood from the lungs"
            flow \(id).tobody parent=\(id) pts=0.24,0.2,0.36;0.14,1.1,0.26;-0.3,1.9,0.12;-1.05,1.75,-0.1 color=red size=0.07 n=4 name="Blood to the body"
            """)
        }
    }

    // MARK: - Eye

    /// An eyeball cut open along its optical axis.
    private static func eye(_ b: inout Builder) {
        let id = b.id
        let axis = b.worldAxis(default: SceneVec3(1, 0, 0))
        let sweep = 230.0
        let twist = b.cutTwist(axis: axis, sweep: sweep)
        b.group(defaultAxis: "x", scale: b.number("r", "size", default: 1), name: "Eye")
        // Outer arc from the back of the eye round to the edge of the cornea, then back along the inside.
        let sclera = arc(radius: 1, from: -90, to: 62, steps: 14) + ";" + arc(radius: 0.93, from: 62, to: -90, steps: 14)
        let retina = arc(radius: 0.925, from: -90, to: 18, steps: 10) + ";" + arc(radius: 0.88, from: 18, to: -90, steps: 10)
        let cornea = arc(radius: 0.56, from: 33, to: 90, steps: 8, centerY: 0.64) + ";" + arc(radius: 0.51, from: 90, to: 33, steps: 8, centerY: 0.64)
        b.line("""
        lathe \(id).sclera parent=\(id) pts=\(sclera) sweep=\(n(sweep)) twist=\(twist) color=white name="Sclera"
        lathe \(id).retina parent=\(id) pts=\(retina) sweep=\(n(sweep)) twist=\(twist) color=#C4533F name="Retina"
        lathe \(id).cornea parent=\(id) pts=\(cornea) sweep=\(n(sweep)) twist=\(twist) color=sky opacity=0.45 name="Cornea"
        lathe \(id).iris parent=\(id) pts=0.19,0.86;0.48,0.85;0.48,0.8;0.19,0.81;0.19,0.86 sweep=\(n(sweep)) twist=\(twist) color=\(b.color ?? "#2E86C1") name="Iris"
        sphere \(id).lens parent=\(id) at=0,0.66,0 r=0.3 scale=1,0.5,1 color=lightblue opacity=0.55 name="Lens"
        tube \(id).nerve parent=\(id) pts=0.16,-0.9,0;0.24,-1.25,0;0.4,-1.7,0 r=0.15 smooth color=gold name="Optic nerve"
        """)
        if !b.c.flag("noflow") {
            let v = b.towardViewer(axis: axis)
            func ray(_ entries: [(Double, Double)]) -> String { path(entries.map { SceneVec3(v.x * $0.0, $0.1, v.z * $0.0) }) }
            b.line("""
            flow \(id).light parent=\(id) pts=\(ray([(0.34, 2.0), (0.33, 1.25), (0.22, 0.7), (0.0, -0.86)])) color=yellow size=0.06 n=5 name="Light"
            flow \(id).light2 parent=\(id) pts=\(ray([(-0.22, 2.0), (-0.21, 1.25), (-0.14, 0.7), (0.0, -0.86)])) color=yellow size=0.06 n=5 name="Light"
            """)
        }
    }

    // MARK: - Electric motor

    /// A brushed DC motor: two magnets, a spinning coil on a shaft, commutator and brushes, in a cut-open can.
    private static func motor(_ b: inout Builder) {
        let id = b.id
        let axis = b.worldAxis(default: SceneVec3(1, 0, 0))
        let rpm = n(b.number("rpm", default: 45))
        let sweep = 200.0
        let v = b.towardViewer(axis: axis)
        // Lathe angles run from +x toward +z; a positive twist turns them the other way.
        let viewerAngle = atan2(v.z, v.x) * 180 / Double.pi
        func twistCentering(_ partSweep: Double, at angle: Double) -> String { n(partSweep / 2 - angle) }
        b.group(defaultAxis: "x", scale: b.number("r", "size", default: 1), name: "Electric motor")
        b.line("""
        lathe \(id).housing parent=\(id) pts=1.04,-0.95;1.12,-0.95;1.12,0.95;1.04,0.95;1.04,-0.95 sweep=\(n(sweep)) twist=\(b.cutTwist(axis: axis, sweep: sweep)) color=steel name="Housing"
        lathe \(id).north parent=\(id) pts=0.8,-0.7;1.02,-0.7;1.02,0.7;0.8,0.7;0.8,-0.7 sweep=100 twist=\(twistCentering(100, at: viewerAngle + 115)) color=red name="North magnet"
        lathe \(id).south parent=\(id) pts=0.8,-0.7;1.02,-0.7;1.02,0.7;0.8,0.7;0.8,-0.7 sweep=100 twist=\(twistCentering(100, at: viewerAngle - 115)) color=blue name="South magnet"
        group \(id).rotor parent=\(id) rpm=\(rpm) name="Rotor coil"
        cyl \(id).rotor.core parent=\(id).rotor r=0.36 h=1.15 color=darkgray mat=metal
        cyl \(id).shaft parent=\(id).rotor from=0,-1.5,0 to=0,1.75,0 r=0.075 color=silver name="Shaft"
        cyl \(id).commutator parent=\(id).rotor at=0,1.15,0 r=0.2 h=0.3 color=gold name="Commutator"
        box \(id).commutator.gap parent=\(id).commutator size=0.42,0.31,0.03 color=black
        group \(id).brushes parent=\(id) name="Brushes"
        """)
        for coil in 0..<3 {
            b.line("tube \(id).rotor.coil\(coil) parent=\(id).rotor pts=0.62,-0.62,0;0.62,0.62,0;-0.62,0.62,0;-0.62,-0.62,0 closed r=0.07 rot=0,\(coil * 60),0 color=copper")
        }
        // Brushes sit on the side the cutaway shows.
        let side = SceneVec3(-v.z, 0, v.x)
        for (index, sign) in [1.0, -1.0].enumerated() {
            let at = SceneVec3(side.x * 0.33 * sign, 1.15, side.z * 0.33 * sign)
            let angle = atan2(side.z, side.x) * 180 / Double.pi
            b.line("box \(id).brushes.b\(index) parent=\(id).brushes at=\(point(at)) size=0.26,0.2,0.16 rot=0,\(n(-angle)),0 color=#3A3A3A")
        }
    }

    // MARK: - Battery

    /// An alkaline cell cut open: case, cathode, separator, zinc anode, collector pin and the two terminals.
    private static func battery(_ b: inout Builder) {
        let id = b.id
        let axis = b.worldAxis(default: SceneVec3(0, 1, 0))
        let sweep = 235.0
        let twist = b.cutTwist(axis: axis, sweep: sweep)
        b.group(scale: b.c.number("h").map { $0 / 2.1 } ?? b.number("r", "size", default: 0.5) / 0.5, name: "Battery")
        b.line("""
        lathe \(id).case parent=\(id) pts=0,-1;0.5,-1;0.5,1;0.2,1;0.2,0.96;0.465,0.96;0.465,-0.96;0,-0.96 sweep=\(n(sweep)) twist=\(twist) color=steel name="Steel case"
        lathe \(id).jacket parent=\(id) pts=0.502,-0.88;0.515,-0.88;0.515,0.88;0.502,0.88;0.502,-0.88 sweep=\(n(sweep)) twist=\(twist) color=\(b.color ?? "orange") mat=plastic name="Label"
        lathe \(id).cathode parent=\(id) pts=0.335,-0.9;0.46,-0.9;0.46,0.86;0.335,0.86;0.335,-0.9 sweep=\(n(sweep)) twist=\(twist) color=#2B2B30 mat=matte name="Cathode"
        lathe \(id).separator parent=\(id) pts=0.3,-0.9;0.335,-0.9;0.335,0.88;0.3,0.88;0.3,-0.9 sweep=\(n(sweep)) twist=\(twist) color=white name="Separator"
        lathe \(id).anode parent=\(id) pts=0.045,-0.86;0.3,-0.86;0.3,0.8;0.045,0.8;0.045,-0.86 sweep=\(n(sweep)) twist=\(twist) color=#9AA3AE mat=matte name="Anode"
        cyl \(id).collector parent=\(id) from=0,-0.98,0 to=0,0.72,0 r=0.04 color=gold name="Current collector"
        cyl \(id).positive parent=\(id) at=0,1.06,0 r=0.17 h=0.13 color=silver name="Positive terminal"
        cyl \(id).negative parent=\(id) at=0,-1.02,0 r=0.42 h=0.05 color=silver name="Negative terminal"
        """)
    }

    // MARK: - Cell membrane

    /// A patch of lipid bilayer lying flat: two sheets of heads with their tails pointing inward.
    private static func membrane(_ b: inout Builder) {
        let id = b.id
        let size = b.c.numbers("size")
        let width = min(max(size.first ?? 4, 0.6), 12), depth = min(max(size.count > 1 ? size[1] : 2.2, 0.6), 8)
        let pitch = max(0.27, max(width / 20, depth / 12))
        let columns = max(Int(width / pitch), 2), rows = max(Int(depth / pitch), 2)
        let head = b.color ?? "gold"
        b.group(name: "Cell membrane")
        for column in 0..<columns {
            for row in 0..<rows {
                let x = (Double(column) + 0.5) * pitch - Double(columns) * pitch / 2
                let z = (Double(row) + 0.5) * pitch - Double(rows) * pitch / 2
                for (side, sign) in [("t", 1.0), ("b", -1.0)] {
                    b.add(.sphere, "\(id).\(side)h\(column)_\(row)", ["parent": id, "at": "\(n(x)),\(n(0.36 * sign)),\(n(z))", "r": n(pitch * 0.42), "color": head])
                    b.add(.cyl, "\(id).\(side)t\(column)_\(row)", ["parent": id, "at": "\(n(x)),\(n(0.16 * sign)),\(n(z))", "r": n(pitch * 0.09), "h": "0.3", "color": "cream"])
                }
            }
        }
    }

    /// A protein through a membrane (a pump or channel), cut open to show its pore.
    private static func protein(_ b: inout Builder) {
        let id = b.id
        let r = b.number("r", default: 0.5), h = b.number("h", default: 1.5)
        let at = b.c.numbers("at")
        let position = at.count >= 3 ? "\(n(at[0])),\(n(at[1])),\(n(at[2]))" : (at.count == 2 ? "\(n(at[0])),0,\(n(at[1]))" : "0,0,0")
        var line = "lathe \(id) at=\(position) pts=\(n(r * 0.26)),\(n(-h / 2));\(n(r * 0.8)),\(n(-h * 0.53));\(n(r)),\(n(-h * 0.22));\(n(r * 0.84)),0;\(n(r)),\(n(h * 0.22));\(n(r * 0.8)),\(n(h * 0.53));\(n(r * 0.26)),\(n(h / 2));\(n(r * 0.36)),0;\(n(r * 0.26)),\(n(-h / 2)) sweep=250 color=\(b.color ?? "purple")"
        if let parent = b.c.string("on", "parent", "in") { line += " parent=\(parent)" }
        if let label = b.c.string("label") { line += " label=\"\(label)\"" } else { line += " name=\"\(b.c.string("name", "title") ?? "Pump protein")\"" }
        if let number = b.c.args["n"] ?? b.c.args["num"] { line += " n=\(number)" }
        b.line(line)
    }

    // MARK: - Planets

    static let planetColours: [String: String] = [
        "sun": "yellow", "mercury": "gray", "venus": "cream", "earth": "blue", "mars": "red", "jupiter": "tan",
        "saturn": "gold", "uranus": "cyan", "neptune": "navy", "moon": "lightgray", "pluto": "tan",
    ]

    /// A body and its orbit in one line. Without `around=` it is the thing in the middle.
    private static func planet(_ b: inout Builder) {
        let id = b.id
        let lowered = id.lowercased()
        let r = b.number("r", "size", default: 0.3)
        let around = b.c.string("around", "about", "orbits")
        let distance = b.c.number("dist", "distance", "orbit", "a")
        let colour = b.color ?? planetColours.first { lowered.contains($0.key) }?.value
        var line = "sphere \(id) r=\(n(r))"
        if let colour { line += " color=\(colour)" }
        let isStar = around == nil && distance == nil
        if b.c.flag("glow") || (isStar && (lowered.contains("sun") || lowered.contains("star"))) { line += " glow" }
        if let label = b.c.string("label") { line += " label=\"\(label)\"" } else { line += " name=\"\(b.c.string("name") ?? id.capitalized)\"" }
        if let number = b.c.args["n"] ?? b.c.args["num"] { line += " n=\(number)" }
        if let distance { line += " at=\(n(distance)),0,0" } else if let at = b.c.args["at"] { line += " at=\(at)" }
        b.line(line)
        if around != nil || distance != nil {
            let radius = distance ?? 2
            // Planets start spread round the star instead of in a row.
            let phase = Double(SceneRNG.hash(id) % 360)
            var orbit = "orbit \(id) r=\(n(radius)) period=\(n(b.number("period", "t", "year", default: 4 + radius * 1.5))) phase=\(n(phase))"
            if let around { orbit += " around=\(around)" }
            if let tilt = b.c.args["tilt"] { orbit += " tilt=\(tilt)" }
            b.line(orbit)
        }
        if b.c.flag("ring") || b.c.flag("rings") || lowered.contains("saturn") {
            b.line("torus \(id).ring parent=\(id) r=\(n(r * 1.75)) r2=\(n(r * 0.32)) scale=1,0.04,1 rot=18,0,8 color=tan name=\"Rings\"")
        }
        let moons = Int(min(max(b.c.number("moons", "moon") ?? (b.c.flag("moon") ? 1 : 0), 0), 4))
        for moon in 0..<moons {
            let moonID = "\(id).moon\(moon == 0 ? "" : "\(moon + 1)")"
            b.line("sphere \(moonID) r=\(n(r * 0.28)) color=lightgray name=\"Moon\"")
            b.line("orbit \(moonID) around=\(id) r=\(n(r * (2.2 + Double(moon) * 0.9))) period=\(n(1.6 + Double(moon))) nopath")
        }
    }

    // MARK: - Pendulum

    /// A bob on a rod under gravity. The joint has the macro's id, so `bind=id.length` and `of=id.angle` work.
    private static func pendulum(_ b: inout Builder) {
        let id = b.id
        let length = max(b.number("length", "len", "l", "h", default: 2), 0.1)
        let angle = b.number("angle", "start", default: 35) * Double.pi / 180
        let pivot = b.c.vec3("at") ?? SceneVec3(0, length + 0.6, 0)
        let bob = pivot + SceneVec3(sin(angle), -cos(angle), 0) * length
        let radius = b.number("r", default: 0.24)
        var body = "body \(id).bob shape=sphere r=\(n(radius)) mass=\(n(b.number("mass", "m", default: 1))) at=\(point(bob)) color=\(b.color ?? "red")"
        body += " label=\"\(b.c.string("label") ?? "Bob")\""
        if let number = b.c.args["n"] ?? b.c.args["num"] { body += " n=\(number)" }
        b.line("""
        fixed \(id).pivot at=\(point(pivot)) name="Pivot"
        box \(id).beam at=\(n(pivot.x)),\(n(pivot.y + 0.1)),\(n(pivot.z)) size=\(n(max(length * 0.7, 1))),0.12,0.4 color=brown name="Support"
        \(body)
        joint \(id) type=ball a=\(id).pivot b=\(id).bob
        """)
    }

    // MARK: - Pin header

    /// Rows of gold pins on a black strip (a GPIO header). `count=` pins in `rows=` rows.
    private static func pins(_ b: inout Builder) {
        let id = b.id
        let rows = Int(min(max(b.number("rows", default: 2), 1), 4))
        let labelNumber = b.c.number("num") ?? b.c.number("n").flatMap { $0 <= 9 ? $0 : nil }
        let count = Int(min(max(b.c.number("count", "pins") ?? b.c.number("n").flatMap { $0 > 9 ? $0 : nil } ?? 40, Double(rows)), 80))
        let perRow = max(count / rows, 1)
        let alongZ = (b.c.args["axis"] ?? "x").lowercased().contains("z")
        let sizes = b.c.numbers("size")
        let pitch = b.c.number("pitch") ?? sizes.first.map { $0 / Double(perRow) } ?? 0.1
        let length = pitch * Double(perRow) + pitch * 0.3, width = pitch * Double(rows) + pitch * 0.3, base = pitch * 0.5
        // kind=block: the pins are added here, so the builder must not add its own for a "gpio" id.
        var comp = "comp \(id) size=\(n(alongZ ? width : length)),\(n(alongZ ? length : width)),\(n(base)) color=black kind=block"
        if let on = b.c.string("on", "parent", "board") { comp += " on=\(on)" }
        if let at = b.c.args["at"] { comp += " at=\(at)" }
        if let label = b.c.string("label") { comp += " label=\"\(label)\"" } else { comp += " name=\"\(b.c.string("name") ?? "Pin header")\"" }
        if let labelNumber { comp += " n=\(n(labelNumber))" }
        b.line(comp)
        for row in 0..<rows {
            for pin in 0..<perRow {
                let along = (Double(pin) + 0.5) * pitch - Double(perRow) * pitch / 2
                let across = (Double(row) + 0.5) * pitch - Double(rows) * pitch / 2
                b.add(.box, "\(id).p\(row)_\(pin)", ["parent": id, "at": alongZ ? "\(n(across)),\(n(base / 2 + pitch * 0.7)),\(n(along))" : "\(n(along)),\(n(base / 2 + pitch * 0.7)),\(n(across))",
                                                    "size": "\(n(pitch * 0.28)),\(n(pitch * 1.4)),\(n(pitch * 0.28))", "color": "gold", "round": "0"])
            }
        }
    }
}
