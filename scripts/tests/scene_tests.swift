//
//  scene_tests.swift
//
//  Standalone tests for the pure half of the drawing engine: the TeachyScene
//  parser, the command model, the part-library maths and the replay log.
//  Run with scripts/tests/run_scene_tests.sh (exits non-zero on any failure).
//

import Foundation
import simd

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL (line \(line)): \(message())")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

func section(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

@main
enum SceneTests {
    static func main() {
        section("parser: basic line") {
            let commands = SceneScriptParser.parse(#"ring r1 at=500,300 r=60 color=red label="Click here" dash"#)
            expect(commands.count == 1, "one command")
            let c = commands[0]
            expect(c.verb == .ring && c.id == "r1" && c.hasExplicitID, "verb and id")
            expect(c.vec2("at") == SceneVec2(500, 300), "at")
            expect(c.number("r") == 60, "r")
            expect(c.string("label") == "Click here", "quoted value")
            expect(c.flag("dash") && !c.flag("fill"), "flags")
            expect(c.color() == SceneColor.named["red"], "colour")
        }

        section("parser: streaming in arbitrary chunks gives the same commands") {
            let script = SceneDemoScriptsForTests.mixed
            let whole = SceneScriptParser.parse(script)
            expect(whole.count >= 10, "whole script parses (\(whole.count))")
            for chunkSize in [1, 2, 3, 7, 16, 61] {
                let parser = SceneScriptParser()
                var streamed: [SceneCommand] = []
                var index = script.startIndex
                while index < script.endIndex {
                    let end = script.index(index, offsetBy: chunkSize, limitedBy: script.endIndex) ?? script.endIndex
                    streamed += parser.feed(String(script[index..<end]))
                    index = end
                }
                streamed += parser.finish()
                expect(streamed == whole, "chunk size \(chunkSize) matches")
            }
        }

        section("parser: a command is emitted the moment its line ends") {
            let parser = SceneScriptParser()
            expect(parser.feed("sphere a r=1\nbox b si").map(\.id) == ["a"], "first line out, second held")
            expect(parser.feed("ze=1,2,3").isEmpty, "still held without a newline")
            expect(parser.finish().map(\.id) == ["b"], "finish flushes the last line")
        }

        section("parser: fences, bullets, prose, comments, unknown verbs") {
            let script = """
            Here is the scene you asked for:
            ```teachyscene
            # a comment
            // another
            - sphere s1 r=1 color=blue
            * box b1 size=1,2,3
            2. cyl c1 r=0.5 h=2 axis=x
            `torus t1 r=2`
            wobble w1 at=1,2,3
            line up the parts carefully
            ring broken
            ```
            Hope that helps!
            """
            let parser = SceneScriptParser()
            let commands = parser.feed(script) + parser.finish()
            expect(commands.map(\.id) == ["s1", "b1", "c1", "t1"], "good lines kept: \(commands.map(\.id))")
            expect(parser.stats.commands == 4, "4 commands")
            expect(parser.stats.prose >= 4, "prose counted (\(parser.stats.prose))")
            expect(parser.stats.parseRate < 1 && parser.stats.parseRate > 0, "parse rate in between")
        }

        section("parser: cues from say and @") {
            let commands = SceneScriptParser.parse("""
            sphere before r=1
            say 1 "First sentence."
            box a
            @2
            box b
            @3 box c
            say "Fourth."
            box d
            """)
            let cues = Dictionary(uniqueKeysWithValues: commands.filter { $0.verb != .say }.map { ($0.id, $0.cue) })
            expect(cues["before"] == .some(nil), "no cue before the first say")
            expect(cues["a"] == 1 && cues["b"] == 2 && cues["c"] == 3 && cues["d"] == 4, "cues \(cues)")
            let says = commands.filter { $0.verb == .say }
            expect(says.count == 2 && says[0].freeText == "First sentence." && says[1].cue == 4, "say lines carry text and number")
        }

        section("parser: loose forms models write") {
            let commands = SceneScriptParser.parse("""
            box b at=1, 2, 3 size=(1,1,1)
            sphere s position=[4,5,6] radius=2 colour=#ff8800
            joint hinge j1 a=p b=q axis=z
            joint j2 type=ball a=p b=q
            slider len 0.5 3 1.5 label="Length" -> rope.length
            mesh g1 g2 ratio=3
            chart bar data=1,2,3 labels="a|b|c"
            text Hello there world
            text t1 "Quoted text"
            steps "A" "B" "C"
            steps items="Guess > Compare > Adjust"
            tube t pts=[[0,0,0],[1,1,1],[2,0,0]] r=0.1
            tube t2 pts=0,0,0;1,1,1 r=0.1
            cyl c r=30cm h=1.5m rot=0,45deg,0
            gravity 3.7
            image "a turbofan engine"
            say 1 “Curly quotes work.”
            """)
            func find(_ id: String) -> SceneCommand? { commands.first { $0.id == id } }
            expect(find("b")?.vec3("at") == SceneVec3(1, 2, 3), "spaces after commas")
            expect(find("s")?.vec3("at") == SceneVec3(4, 5, 6) && find("s")?.number("r") == 2, "synonyms")
            expect(find("s")?.color() == SceneColor(hex: 0xff8800), "hex colour")
            expect(find("j1")?.string("type") == "hinge" && find("j2")?.string("type") == "ball", "joint kinds")
            let slider = find("len")
            expect(slider?.number("min") == 0.5 && slider?.number("max") == 3 && slider?.number("value") == 1.5, "positional slider")
            expect(slider?.string("bind") == "rope.length", "arrow binding")
            let mesh = commands.first { $0.verb == .mesh }
            expect(mesh?.string("a") == "g1" && mesh?.string("b") == "g2" && mesh?.number("ratio") == 3, "mesh a b")
            let chart = commands.first { $0.verb == .chart }
            expect(chart?.string("type") == "bar" && chart?.numbers("data") == [1, 2, 3], "chart kind")
            let texts = commands.filter { $0.verb == .text }.compactMap(\.freeText)
            expect(texts == ["Hello there world", "Quoted text"], "free text \(texts)")
            let steps = commands.filter { $0.verb == .steps }.map { $0.textItems() }
            expect(steps == [["A", "B", "C"], ["Guess", "Compare", "Adjust"]], "steps \(steps)")
            expect(find("t")?.points3().count == 3 && find("t2")?.points3().count == 2, "point lists")
            expect(find("c")?.number("r") == 30 && find("c")?.vec3("rot") == SceneVec3(0, 45, 0), "units ignored")
            expect(commands.first { $0.verb == .gravity }?.number("g") == 3.7, "gravity value")
            expect(commands.first { $0.verb == .image }?.string("query") == "a turbofan engine", "image query")
            expect(commands.first { $0.verb == .say }?.freeText == "Curly quotes work.", "curly quotes")
        }

        section("numbers") {
            expect(SceneNumbers.scan("1.5,-2e1, 30deg") == [1.5, -20, 30], "scan")
            expect(SceneNumbers.scan("abc").isEmpty && SceneNumbers.scan("").isEmpty, "no numbers")
            expect(SceneNumbers.scan("1e999").allSatisfy { $0.isFinite }, "overflow stays finite")
            expect(SceneNumbers.scan("99999999999") == [SceneNumbers.limit], "clamped")
            expect(SceneNumbers.groups("1,2,3,4", size: 2) == [[1, 2], [3, 4]], "flat pairs")
            expect(SceneNumbers.groups("1,2;3,4;5", size: 3) == [[1, 2, 0], [3, 4, 0], [5, 0, 0]], "padded")
            expect(SceneNumbers.groups("1", size: 2).isEmpty, "too short")
        }

        section("prompt examples parse completely") {
            expect(SceneScriptPrompt.examples.count == 6, "six examples in the prompts (\(SceneScriptPrompt.examples.count))")
            for example in SceneScriptPrompt.examples {
                let parser = SceneScriptParser()
                _ = parser.feed(example) + parser.finish()
                expect(parser.stats.parseRate == 1, "example parses 100%: \(parser.rejections)")
            }
            // 16 Nov 2026: the draw-first guidance and the OS diagram example took it to ~8.5k.
            // The cap still catches runaway growth; the scene must start drawing within a second or two.
            expect(SceneScriptPrompt.system.count < 9_000, "prompt stays compact (\(SceneScriptPrompt.system.count) chars)")
        }

        section("fuzz: garbage and truncation never crash, good lines survive") {
            var rng = SceneRNG(seed: 20261114)
            let good = "sphere keep r=1 color=blue"
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 =\",;:.-_#@[](){}\\'`\n\r\t→“”é漢🙂%$*/<>|&^~")
            let seeds = SceneDemoScriptsForTests.mixed.split(separator: "\n").map(String.init)
            for round in 0..<600 {
                let parser = SceneScriptParser()
                var input = ""
                for _ in 0..<Int(rng.range(1, 12)) {
                    switch rng.next() % 4 {
                    case 0:
                        input += String((0..<Int(rng.range(0, 90))).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
                    case 1:
                        // A real line cut off at a random character.
                        let line = seeds[Int(rng.next() % UInt64(seeds.count))]
                        input += String(line.prefix(Int(rng.range(0, Double(line.count + 1)))))
                    case 2:
                        // A real line with random characters swapped in.
                        var characters = Array(seeds[Int(rng.next() % UInt64(seeds.count))])
                        for _ in 0..<3 where !characters.isEmpty {
                            characters[Int(rng.next() % UInt64(characters.count))] = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                        }
                        input += String(characters)
                    default:
                        input += "ring x at=\(String(repeating: "9", count: Int(rng.range(1, 400)))),1e400 r=-0 pts=;;;,,,"
                    }
                    input += "\n"
                }
                input += "\n" + good + "\n" + String(input.prefix(Int(rng.range(0, 40))))
                var commands: [SceneCommand] = []
                let characters = Array(input)
                var index = 0
                while index < characters.count {
                    let size = Int(rng.range(1, 30))
                    commands += parser.feed(String(characters[index..<min(index + size, characters.count)]))
                    index += size
                }
                commands += parser.finish()
                expect(commands.contains { $0.id == "keep" && $0.verb == .sphere }, "round \(round): good line survived")
                // Everything that parsed must also build and serialise without trapping.
                var builder = ScenePartBuilder()
                for command in commands {
                    var routed = command
                    routed.verb = SceneRouter.verbIn3D(command)
                    let build = builder.build(routed)
                    for part in build.parts {
                        expect(part.position.x.isFinite && part.resolvedOrientation.real.isFinite, "finite part")
                        switch part.shape {
                        case .tube(let path, let radius, let closed): _ = SceneGeometry.tubeMesh(path: path, radius: radius, closed: closed)
                        case .lathe(let profile, let sweep): _ = SceneGeometry.latheMesh(profile: profile, sweepDegrees: sweep)
                        default: break
                        }
                    }
                    _ = command.scriptLine
                    _ = SceneValidator.problem(with: command)
                }
                var rough = SceneRNG(id: "fuzz\(round)")
                for command in commands where command.verb.family == .overlay {
                    _ = SceneRough.polyline(command.points2(), closed: true, rng: &rough)
                }
            }
            // One enormous line with no newline must not grow without bound or crash.
            let parser = SceneScriptParser()
            _ = parser.feed(String(repeating: "x=1 ", count: 20_000))
            _ = parser.feed("\nsphere after r=1\n")
            expect(parser.stats.commands == 1, "recovers after a runaway line")
        }

        section("rough strokes: deterministic, hand-drawn, near the true shape") {
            var first = SceneRNG(id: "r1"), second = SceneRNG(id: "r1"), other = SceneRNG(id: "r2")
            let a = SceneRough.ellipse(center: SceneVec2(100, 100), rx: 50, ry: 30, rng: &first)
            let b = SceneRough.ellipse(center: SceneVec2(100, 100), rx: 50, ry: 30, rng: &second)
            let c = SceneRough.ellipse(center: SceneVec2(100, 100), rx: 50, ry: 30, rng: &other)
            expect(a == b, "same id, same wobble")
            expect(a != c, "different id, different wobble")
            expect(a.count == 2, "two passes")
            var worst = 0.0, imperfect = false
            for point in a.flatMap(\.points) {
                let dx = (point.x - 100) / 50, dy = (point.y - 100) / 30
                let radial = abs(sqrt(dx * dx + dy * dy) - 1)
                worst = max(worst, radial)
                if radial > 0.005 { imperfect = true }
            }
            expect(worst < 0.2, "stays close to the ellipse (\(worst))")
            expect(imperfect, "is not machine-perfect")
            var lineRNG = SceneRNG(id: "l")
            let strokes = SceneRough.line(SceneVec2(0, 0), SceneVec2(200, 0), rng: &lineRNG)
            expect(strokes.count == 2 && strokes.allSatisfy { $0.points.count == 4 }, "line passes")
            expect(strokes.flatMap(\.points).allSatisfy { abs($0.y) < 8 }, "line stays near its path")
            var zero = SceneRNG(id: "z")
            expect(SceneRough.line(SceneVec2(5, 5), SceneVec2(5, 5), rng: &zero).count == 1, "zero-length line is safe")
        }

        section("gear geometry") {
            let outline = SceneGeometry.gearOutline(teeth: 12, pitchRadius: 1)
            expect(outline.count == 48, "4 points per tooth")
            let radii = outline.map { simd_length($0) }
            let module = 2.0 / 12
            expect(near(radii.max()!, 1 + module, 1e-9) && near(radii.min()!, 1 - 1.25 * module, 1e-9), "tip and root radii")
            expect(near(atan2(outline[1].y, outline[1].x), -atan2(outline[2].y, outline[2].x), 1e-9), "tooth 0 centred on +X")
            expect(SceneGeometry.signedArea(outline) > 0, "counter-clockwise")
            expect(SceneGeometry.gearOutline(teeth: 0, pitchRadius: 1).count == 16, "tooth count clamped")

            // Meshing: where the driver has a tooth on the line of centres, the driven gear has a gap.
            for (driverTeeth, drivenTeeth, driverAngle, contact) in [(12, 36, 0.0, 0.0), (10, 25, 0.37, 1.1), (20, 20, -2.0, 3.0)] {
                let angle = SceneGeometry.meshedGearAngle(driverAngle: driverAngle, driverTeeth: driverTeeth, drivenTeeth: drivenTeeth, contactAngle: contact)
                let driverPhase = SceneGeometry.fraction((contact - driverAngle) * Double(driverTeeth) / (2 * .pi))
                let drivenPhase = SceneGeometry.fraction((contact + .pi - angle) * Double(drivenTeeth) / (2 * .pi))
                expect(near(SceneGeometry.fraction(driverPhase + drivenPhase), 0.5, 1e-9), "tooth meets gap (\(driverTeeth):\(drivenTeeth))")
            }
        }

        section("gear train: 3:1 from two lines of script") {
            var builder = ScenePartBuilder()
            let commands = SceneScriptParser.parse("gear g1 teeth=12 r=1 rpm=30\ngear g2 teeth=36 mesh=g1")
            let builds = commands.map { builder.build($0) }
            let small = builder.gears["g1"]!, large = builder.gears["g2"]!
            expect(near(large.radius, 3), "same module gives radius 3 (\(large.radius))")
            expect(near(simd_length(large.position - small.position), 4), "centres one pitch-sum apart")
            expect(builds[0].animators == [.spin(target: "g1", axis: nil, rpm: 30)], "rpm= becomes a spin")
            let rpm = builder.train.solve(drivers: ["g1": 30])
            expect(near(rpm["g2"]!, -10), "driven gear turns the other way at a third the speed")
            var train = SceneGearTrain()
            train.couple("a", "b", ratio: 2)
            train.couple("b", "c", ratio: 2)
            train.couple("c", "a", ratio: 1) // a loop must not hang
            let solved = train.solve(drivers: ["a": 100])
            expect(near(solved["b"]!, -50) && solved["c"] != nil, "chain and loop")
            expect(train.solve(drivers: ["c": 10])["a"] != nil, "drives backwards too")
        }

        section("helix, spring, dna") {
            let helix = SceneGeometry.helixPoints(radius: 2, height: 6, turns: 3)
            expect(helix.allSatisfy { near(sqrt($0.x * $0.x + $0.z * $0.z), 2, 1e-9) }, "constant radius")
            expect(near(helix.first!.y, -3) && near(helix.last!.y, 3), "spans the height")
            expect(near(helix.first!.x, helix.last!.x, 1e-9) && near(helix.first!.z, helix.last!.z, 1e-9), "whole turns end where they began")
            let spring = SceneGeometry.springPoints(from: SceneVec3(0, 0, 0), to: SceneVec3(0, 3, 0), coils: 6, radius: 0.4)
            expect(spring.first == SceneVec3(0, 0, 0) && spring.last == SceneVec3(0, 3, 0), "ends on its anchors")
            expect(SceneGeometry.springPoints(from: .zero, to: .zero, coils: 6, radius: 1).count == 2, "zero-length spring is safe")
            var builder = ScenePartBuilder()
            let dna = builder.build(SceneScriptParser.parse("dna d turns=2")[0])
            expect(dna.parts.count == 1 + 2 + 40, "group, two backbones, 20 base pairs in halves (\(dna.parts.count))")
            var again = ScenePartBuilder()
            expect(again.build(SceneScriptParser.parse("dna d turns=2")[0]) == dna, "same script, same model")
        }

        section("meshes") {
            let tube = SceneGeometry.tubeMesh(path: [SceneVec3(0, 0, 0), SceneVec3(0, 1, 0), SceneVec3(1, 2, 0)], radius: 0.1, sides: 8)
            expect(tube.positions.count == tube.normals.count && tube.triangleCount == 2 * 8 * 2 + 16, "tube triangles (\(tube.triangleCount))")
            expect(tube.indices.allSatisfy { Int($0) < tube.positions.count }, "indices in range")
            expect(tube.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-3 }, "unit normals")
            expect(SceneGeometry.tubeMesh(path: [.zero, .zero], radius: 1).positions.isEmpty, "degenerate tube is empty")
            let lathe = SceneGeometry.latheMesh(profile: [SceneVec2(1, 0), SceneVec2(1, 2)], segments: 24)
            expect(lathe.positions.allSatisfy { abs(sqrt($0.x * $0.x + $0.z * $0.z) - 1) < 1e-4 }, "cylinder of radius 1")
            expect(lathe.triangleCount == 48, "lathe triangles")
            let closedProfile = [SceneVec2(1, 0), SceneVec2(2, 0), SceneVec2(2, 1), SceneVec2(1, 1), SceneVec2(1, 0)]
            let cut = SceneGeometry.latheMesh(profile: closedProfile, segments: 24, sweepDegrees: 180)
            let whole = SceneGeometry.latheMesh(profile: closedProfile, segments: 24, sweepDegrees: 360)
            expect(cut.triangleCount == whole.triangleCount / 2 + 4, "a cutaway gets flat faces on the cut (\(cut.triangleCount) vs \(whole.triangleCount))")
            expect(SceneGeometry.triangulate([SceneVec2(0, 0), SceneVec2(2, 0), SceneVec2(2, 2), SceneVec2(1, 0.5), SceneVec2(0, 2)]).count == 9, "concave polygon")
            expect(SceneGeometry.latheMesh(profile: [SceneVec2(1, 0)]).positions.isEmpty, "one-point profile is empty")
        }

        section("kinematics") {
            expect(near(SceneGeometry.pistonHeight(angle: 0, crank: 1, rod: 3), 4), "top dead centre")
            expect(near(SceneGeometry.pistonHeight(angle: .pi, crank: 1, rod: 3), 2), "bottom dead centre")
            expect(SceneGeometry.pistonHeight(angle: 1, crank: 2, rod: 0.1).isFinite, "impossible rod is safe")
            let offsets = SceneGeometry.explodeOffsets(positions: [SceneVec3(-1, 0, 0), SceneVec3(0, 5, 0), SceneVec3(3, 0, 0)], axis: SceneVec3(1, 0, 0), distance: 2)
            expect(near(offsets[0].x, -2) && near(offsets[2].x, 2) && offsets[1].x < 0, "explode keeps order and spreads outward")
            expect(offsets.allSatisfy { $0.y == 0 && $0.z == 0 }, "only along the axis")
            let stacked = SceneGeometry.explodeOffsets(positions: [.zero, .zero, .zero], axis: SceneVec3(0, 1, 0), distance: 1)
            expect(near(stacked[0].y, -1) && near(stacked[1].y, 0) && near(stacked[2].y, 1), "coincident parts fan out")
            let orbit = SceneGeometry.orbitPosition(center: SceneVec3(1, 0, 0), radius: 2, angle: .pi / 2)
            expect(near(orbit.x, 1) && near(orbit.z, 2), "orbit")
            expect(near(SceneGeometry.pendulumAngle(pivot: SceneVec3(0, 3, 0), bob: SceneVec3(1, 2, 0)), 45), "pendulum angle")
            let along = SceneGeometry.pointAlong([SceneVec3(0, 0, 0), SceneVec3(2, 0, 0), SceneVec3(2, 2, 0)], t: 0.75)
            expect(near(along.position.x, 2) && near(along.position.y, 1) && near(along.direction.y, 1), "point along a path")
            let smooth = SceneGeometry.smooth([SceneVec2(0, 0), SceneVec2(1, 1), SceneVec2(2, 0)])
            expect(smooth.first == SceneVec2(0, 0) && smooth.last == SceneVec2(2, 0) && smooth.contains(SceneVec2(1, 1)), "curve passes through its points")
            let q = SceneOrientation.aligning(SceneVec3(0, 1, 0), to: SceneVec3(0, -1, 0))
            expect(near(q.act(SceneVec3(0, 1, 0)).y, -1), "opposite directions align")
        }

        section("part library") {
            var builder = ScenePartBuilder()
            func build(_ line: String) -> SceneBuild { builder.build(SceneScriptParser.parse(line)[0]) }
            let fan = build("fan f blades=18 r=1.2 axis=x rpm=40 label=\"Fan\" n=1")
            expect(fan.parts.count == 1 + 1 + 18, "group, hub, blades")
            expect(fan.parts[0].label == "Fan" && fan.parts[0].number == 1 && fan.parts[0].axis == SceneVec3(1, 0, 0), "attributes on the group")
            expect(fan.animators == [.spin(target: "f", axis: nil, rpm: 40)], "spins")
            expect(fan.parts.dropFirst().allSatisfy { $0.parent == "f" && !$0.isTappable }, "pieces belong to the group")
            let piston = build("piston p bore=1 stroke=1.2 rpm=90")
            if case .piston(_, let crank, _, _, let rpm, _)? = piston.animators.first {
                expect(near(crank, 0.6) && rpm == 90, "crank is half the stroke")
            } else {
                expect(false, "piston animator")
            }
            let flow = build("flow air pts=-3,0,0;0,1,0;3,0,0 color=sky")
            if case .flow(_, let markers, let path, let speed)? = flow.animators.first {
                expect(markers.count >= 2 && path.count > 3 && speed > 0, "flow markers on a smoothed path")
            } else {
                expect(false, "flow animator")
            }
            _ = build("board pi size=8.5,5.6")
            let chip = build("comp cpu on=pi at=1,0.5 size=1.5,1.5 label=\"CPU\"")
            expect(chip.parts[0].parent == "pi" && chip.parts[0].position.y > 0 && near(chip.parts[0].position.z, 0.5), "component sits on the board")
            let cylinder = build("cyl rod from=0,0,0 to=0,0,4 r=0.1")
            expect(cylinder.parts[0].position == SceneVec3(0, 0, 2) && cylinder.parts[0].axis == SceneVec3(0, 0, 1), "cylinder between two points")
            if case .cylinder(_, let height) = cylinder.parts[0].shape { expect(near(height, 4), "height from the span") }
            expect(build("wheel w spokes=5").parts.count == 1 + 3 + 5, "wheel pieces")
            expect(build("axes ax").parts.count == 7, "axes pieces")
            expect(build("sphere s color=glass").parts[0].material == .glass, "glass")
            expect(build("gear g teeth=10 color=gold").parts[0].material == .metal, "metal")
            let script = SceneScriptParser.parse("scene3d s\nfan f blades=6\nsphere a\ncard c title=x\ntext \"hi\"\nring r at=1,2")
            expect(SceneRouter.count3DParts(in: script) == 8, "3D part count ignores cards and overlay")
        }

        section("routing shared verbs") {
            func surface(_ line: String, _ current: SceneSurface?) -> SceneSurface? {
                SceneRouter.surface(for: SceneScriptParser.parse(line)[0], current: current)
            }
            expect(surface("label l at=10,20 text=\"x\"", .scene3d) == .overlay, "2D label")
            expect(surface("label l on=fan text=\"Fan\"", nil) == .scene3d, "3D label")
            expect(surface("chip \"Why?\"", .scene3d) == .scene3d && surface("chip \"Why?\"", nil) == .card, "follow-up chip follows the surface")
            expect(surface("chip cpu at=1,2 size=1,1", .card) == .scene3d, "chip with a place is a component")
            expect(surface("arrow a from=1,2,3 to=4,5,6", nil) == .scene3d && surface("arrow a from=1,2 to=4,5", .scene3d) == .overlay, "arrows by dimension")
            expect(surface("text \"hi\"", .scene3d) == .card, "text is a card line")
        }

        section("scheduler: speech timing") {
            var scheduler = SceneCueScheduler(timing: .speech, step: 0.1)
            let commands = SceneScriptParser.parse("box pre\nsay 1 \"one\"\nbox a\nbox b\nsay 2 \"two\"\nbox c")
            for command in commands { scheduler.enqueue(command, now: 0) }
            expect(scheduler.due(now: 0).map(\.id) == ["pre"], "uncued command is drawn at once")
            expect(scheduler.due(now: 1).isEmpty, "sentence 1 hasn't started")
            scheduler.sentenceStarted(1)
            var drawn = scheduler.due(now: 1).map(\.verb)
            expect(drawn == [.say, .box], "say is free, then one part per beat: \(drawn)")
            drawn = scheduler.due(now: 1.05).map(\.verb)
            expect(drawn.isEmpty, "beat not elapsed")
            expect(scheduler.due(now: 1.11).map(\.id) == ["b"], "next beat")
            expect(scheduler.due(now: 5).isEmpty, "sentence 2 held")
            expect(scheduler.due(now: 8.5).count == 2, "a sentence that never starts is released after the hold")
            expect(scheduler.isEmpty, "queue drained")

            var ending = SceneCueScheduler(timing: .speech, step: 0)
            for command in commands { ending.enqueue(command, now: 0) }
            ending.releaseAll()
            expect(ending.due(now: 0).count == commands.count, "releaseAll lets everything through in order")
        }

        section("scheduler: stagger timing") {
            var scheduler = SceneCueScheduler(timing: .stagger, step: 0.1, cuePause: 0.5)
            for command in SceneScriptParser.parse("say 1 \"one\"\nbox a\nbox b\nsay 2 \"two\"\nbox c") { scheduler.enqueue(command, now: 0) }
            var times: [String: Double] = [:]
            var now = 0.0
            while !scheduler.isEmpty && now < 10 {
                for command in scheduler.due(now: now) where command.verb == .box { times[command.id] = now }
                now += 0.01
            }
            expect(near(times["a"]!, 0, 0.02) && near(times["b"]!, 0.1, 0.02), "a beat apart: \(times)")
            expect(times["c"]! - times["b"]! > 0.55, "pause between sentences")
        }

        section("replay log") {
            var log = SceneReplayLog()
            let commands = SceneScriptParser.parse(SceneDemoScriptsForTests.mixed)
            for (index, command) in commands.enumerated() { log.record(command, at: Double(index) * 0.25) }
            log.record(commands[0], at: 0.1) // out of order: clamped forward
            expect(log.entries.last!.time == log.entries[log.entries.count - 2].time, "time never goes backwards")
            expect(log.title == "Mixed", "title picked up")
            let data = try! log.encoded()
            let restored = try! SceneReplayLog.decoded(from: data)
            expect(restored == log, "survives a round trip")
            expect(try! restored.encoded() == data, "encoding is stable")
            for tick in [0.016, 0.1, 0.33, 5.0] {
                var replayed: [SceneCommand] = []
                var clock = -1.0
                while clock < log.duration {
                    let next = clock < 0 ? 0 : clock + tick
                    replayed += log.entries(after: clock, upTo: next).map(\.command)
                    clock = next
                }
                expect(replayed == log.entries.map(\.command), "tick \(tick) replays every command once, in order")
            }
            let reparsed = SceneScriptParser.parse(log.script)
            expect(reparsed.count == log.entries.count, "exported script parses back (\(reparsed.count) of \(log.entries.count))")
            expect(zip(reparsed, log.entries).allSatisfy { $0.verb == $1.command.verb && $0.args == $1.command.args && $0.cue == $1.command.cue }, "and means the same")
        }

        print("\n\(checks) checks, \(failures) failure\(failures == 1 ? "" : "s")")
        exit(failures == 0 ? 0 : 1)
    }
}

enum SceneDemoScriptsForTests {
    static let mixed = """
    say 1 "Here is a little of everything."
    card c1 title="Mixed"
    text "A card line"
    bullet "A bullet"
    formula "E = mc²"
    steps "Guess" "Compare" "Adjust"
    chart ch type=bar data=1,4,9,16 labels="a|b|c|d" title="Squares"
    chip "What next?"
    say 2 "Now the screen."
    ring r1 at=500,300 r=60 color=red
    rect b1 from=100,100 to=300,200 dash
    arrow a1 from=320,150 to=440,280 bend=0.3 color=blue
    line l1 pts=10,10;200,40;300,10
    poly p1 pts=600,600;700,600;650,700 fill
    label t1 at=520,380 text="Click here"
    highlight h1 from=50,500 to=400,560
    say 3 "And a model."
    scene3d s1 title="Model"
    lathe shell axis=x pts=1.2,-2;1.4,0;1,2;0.9,2;1.3,0;1.1,-2;1.2,-2 sweep=250 color=silver
    fan f1 blades=12 r=1 axis=x at=-1.5,0,0 rpm=40 label="Fan" n=1
    gear g1 teeth=12 r=1 at=0,3,0 rpm=20
    gear g2 teeth=24 mesh=g1 angle=30
    flow air pts=-3,0.5,0;0,0.6,0;3,0.4,0 color=sky
    tube pipe pts=0,0,0;1,1,0;2,0,1 r=0.1 smooth
    fixed pivot at=0,5,0
    body bob shape=sphere r=0.3 mass=1 at=1.5,4,0
    joint ball rope a=pivot b=bob
    slider len min=0.5 max=3 value=2 label="Length" bind=rope.length
    plot swing of=bob.angle label="Angle"
    spin shell rpm=5 axis=x
    explode axis=x dist=1
    camera to=5,3,8 look=0,0,0
    """
}
