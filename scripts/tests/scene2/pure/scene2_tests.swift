//
//  scene2_tests.swift
//
//  Tests for the second round of drawing-engine work: whole-object macros, label
//  layout, the explode and label-number fixes, narration sequencing, screenshot
//  coordinates, narration audio, follow-up summaries, the quality score, photo
//  picking and the drawing history store.
//
//  Run with scripts/tests/run_scene2_tests.sh (exits non-zero on any failure).
//  Nothing here touches the network, the screen or the real ~/.teachy.
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

func overlaps(_ a: (SceneVec2, SceneVec2), _ b: (SceneVec2, SceneVec2)) -> Bool {
    abs(a.0.x - b.0.x) < (a.1.x + b.1.x) / 2 - 1e-9 && abs(a.0.y - b.0.y) < (a.1.y + b.1.y) / 2 - 1e-9
}

@main
enum Scene2Tests {
    static func main() {
        macros()
        fixes()
        labelLayout()
        narration()
        screenMapping()
        audioAndSummary()
        promptsAndQuality()
        photosAndHistory()
        print("\n\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Macros

    static func macros() {
        section("macros: every whole object expands to commands the engine can draw") {
            let lines = ["jet j", "engine e cylinders=4 rpm=900", "rocket r stages=3", "bridge b", "heart h", "eye e", "motor m rpm=30",
                         "battery b", "membrane m size=3,2", "protein p on=m at=0.5,0", "planet earth r=0.2 dist=3 around=sun moons=1",
                         "pendulum p length=2 angle=30", "pins gpio on=pi at=0,1 count=40 rows=2"]
            for line in lines {
                guard let command = SceneScriptParser.parse(line).first else { expect(false, "\(line) parses"); continue }
                expect(command.verb.isMacro, "\(line) is a macro")
                let expansion = SceneMacros.expand(command) ?? []
                expect(!expansion.isEmpty, "\(line) expands")
                for sub in expansion {
                    expect(SceneValidator.problem(with: sub) == nil, "\(line): \(sub.scriptLine) is drawable (\(SceneValidator.problem(with: sub) ?? ""))")
                    expect(!sub.verb.isMacro, "\(line): expansions are not macros themselves")
                    expect(sub.cue == command.cue, "pieces keep the line's cue")
                }
                var builder = ScenePartBuilder()
                let parts = builder.build(command).parts
                expect(parts.count >= (command.verb == .protein ? 1 : 2), "\(line) builds parts (\(parts.count))")
                expect(parts.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }, "\(line): finite positions")
                expect(Set(parts.map(\.id)).count == parts.count, "\(line): part ids are unique")
            }
        }

        section("macros: the pieces a prompt may name all exist") {
            for (line, verb) in [("jet j", SceneVerb.jet), ("engine j", .engine), ("rocket j", .rocket), ("bridge j", .bridge), ("heart j", .heart),
                                 ("eye j", .eye), ("motor j", .motor), ("battery j", .battery), ("pendulum j", .pendulum)] {
                var builder = ScenePartBuilder()
                let ids = Set(builder.build(SceneScriptParser.parse(line)[0]).parts.map(\.id))
                for piece in SceneMacros.pieces(of: verb) {
                    expect(ids.contains("j.\(piece.suffix)"), "\(line) has piece \(piece.suffix)")
                }
            }
        }

        section("macros: labels flag, cue, engine speed cap, pendulum joint, planet orbit") {
            var command = SceneScriptParser.parse("say 2 \"x\"\nrocket r stages=2 labels").last!
            expect(command.cue == 2, "the line is cued to sentence 2")
            var expansion = SceneMacros.expand(command) ?? []
            let labels = expansion.filter { $0.verb == .label }
            expect(labels.count >= 5, "labels flag adds chips (\(labels.count))")
            expect(labels.first?.string("on") == "r.nose" && labels.first?.number("n") == 1, "first chip is the nose, numbered 1")
            expect(expansion.allSatisfy { $0.cue == 2 }, "every piece is cued to sentence 2")

            command = SceneScriptParser.parse("engine e cylinders=4 rpm=900")[0]
            expansion = SceneMacros.expand(command) ?? []
            let speeds = expansion.compactMap { $0.number("rpm") }
            expect(!speeds.isEmpty && speeds.allSatisfy { $0 <= 150 }, "engine speeds are capped at 150 rpm: \(speeds)")
            expect(expansion.filter { $0.verb == .piston }.count == 4, "four pistons")
            let phases = expansion.filter { $0.verb == .piston }.compactMap { $0.number("phase") }
            expect(phases == [0, 180, 180, 0], "inline-four firing phases: \(phases)")

            expansion = SceneMacros.expand(SceneScriptParser.parse("pendulum pen length=2 angle=30 at=0,3,0")[0]) ?? []
            let joint = expansion.first { $0.verb == .joint }
            expect(joint?.id == "pen" && joint?.string("a") == "pen.pivot" && joint?.string("b") == "pen.bob", "the joint carries the macro's id")
            let bob = expansion.first { $0.id == "pen.bob" }?.vec3("at") ?? .zero
            expect(near(simd_length(bob - SceneVec3(0, 3, 0)), 2, 1e-3), "the bob hangs `length` from the pivot")

            expansion = SceneMacros.expand(SceneScriptParser.parse("planet mars r=0.2 dist=3.5 around=sun period=9")[0]) ?? []
            let orbit = expansion.first { $0.verb == .orbit }
            expect(orbit?.id == "mars" && orbit?.string("around") == "sun" && orbit?.number("r") == 3.5 && orbit?.number("period") == 9, "planet makes an orbit")
            expect(expansion.first?.color() == SceneColor.named["red"], "mars is red without being told")
            let sun = SceneMacros.expand(SceneScriptParser.parse("planet sun r=1")[0]) ?? []
            expect(sun.count == 1 && sun[0].flag("glow"), "a planet with no orbit named sun glows and does not orbit")
        }

        section("macros: a macro counts its parts and is a library part") {
            let commands = SceneScriptParser.parse("scene3d s\njet j\nlabel a on=j.fan text=\"Fan\" n=1")
            expect(SceneRouter.count3DParts(in: commands) > 60, "a jet is many parts (\(SceneRouter.count3DParts(in: commands)))")
            expect(SceneVerb.jet.isLibraryPart && SceneVerb.chain.isLibraryPart && !SceneVerb.box.isLibraryPart, "library parts")
            expect(SceneVerb.lookup("turbofan") == .jet && SceneVerb.lookup("sprocket") == .gear && SceneVerb.lookup("belt") == .chain, "aliases")
        }

        section("chain: wraps both gears and makes them turn the same way") {
            var builder = ScenePartBuilder()
            _ = builder.build(SceneScriptParser.parse("gear front teeth=44 r=1")[0])
            _ = builder.build(SceneScriptParser.parse("gear rear teeth=22 r=0.5 at=-3,0,0")[0])
            let build = builder.build(SceneScriptParser.parse("chain c a=front b=rear")[0])
            expect(build.parts.count > 10, "chain has a loop and links (\(build.parts.count))")
            let rpm = builder.train.solve(drivers: ["front": 30])
            expect(near(rpm["rear"] ?? 0, 60), "rear turns the same way, twice as fast: \(rpm["rear"] ?? 0)")
            if case .belt(_, let markers, let path, let gear, let radius, _) = build.animators.first ?? .spin(target: "", axis: nil, rpm: 0) {
                expect(gear == "front" && radius > 1 && markers.count >= 6, "belt follows the front gear's rim")
                expect(simd_length(path.first! - path.last!) < 1e-9, "the path is closed")
                let xs = path.map(\.x)
                expect((xs.max() ?? 0) > 0.99 && (xs.min() ?? 0) < -3.49, "the loop reaches round both gears: \(xs.min() ?? 0)...\(xs.max() ?? 0)")
            } else {
                expect(false, "chain makes a belt animator")
            }
            let u = SceneVec3(1, 0, 0), v = SceneVec3(0, 1, 0)
            let belt = SceneGeometry.beltPath(centerA: .zero, radiusA: 1, centerB: SceneVec3(4, 0, 0), radiusB: 1, u: u, v: v)
            expect(belt.allSatisfy { p in near(simd_length(p), 1, 1e-6) || near(simd_length(p - SceneVec3(4, 0, 0)), 1, 1e-6) }, "equal gears: every point is on a circle")
            expect(SceneGeometry.beltPath(centerA: .zero, radiusA: 3, centerB: SceneVec3(1, 0, 0), radiusB: 1, u: u, v: v).isEmpty, "one gear inside the other has no belt")
        }

        section("board components are dressed by what they are") {
            func kind(_ line: String) -> String { ScenePartBuilder.componentKind(SceneScriptParser.parse(line)[0]) }
            expect(kind("comp usb1 on=pi at=1,0 size=0.5,0.5") == "usb", "usb from the id")
            expect(kind("comp c3 on=pi at=1,0 size=0.5,0.5 label=\"Ethernet port\"") == "ethernet", "ethernet from the label")
            expect(kind("comp c4 on=pi at=1,0 size=2,0.2 label=\"GPIO header\"") == "header", "header")
            expect(kind("comp soc on=pi at=0,0 size=0.6,0.6 label=\"CPU\"") == "chip", "chip")
            expect(kind("comp x on=pi at=0,0 size=0.6,0.6 kind=hdmi") == "hdmi", "kind= wins")
            expect(kind("comp thing on=pi at=0,0 size=0.6,0.6") == "block", "plain block")
            var builder = ScenePartBuilder()
            _ = builder.build(SceneScriptParser.parse("board pi size=4,2.7")[0])
            let usb = builder.build(SceneScriptParser.parse("comp usb on=pi at=1.7,0.5 size=0.6,0.5")[0]).parts
            expect(usb.count == 2 && usb[1].id == "usb.port" && usb[1].position.x > 0, "a usb port opens toward the nearest board edge")
            expect(usb[0].material == .metal, "a port is metal")
            let header = builder.build(SceneScriptParser.parse("comp gpio on=pi at=0,-1.1 size=2.4,0.24")[0]).parts
            expect(header.count > 20, "a header has pins (\(header.count))")
            expect(header.dropFirst().allSatisfy { !$0.isTappable && $0.parent == "gpio" }, "pins belong to the header")
        }
    }

    // MARK: Fixes

    static func fixes() {
        section("label numbers: a list number moves to the dot, a number in the name stays") {
            func split(_ text: String, _ n: Int? = nil) -> String { let r = SceneLabelText.split(text, number: n); return "\(r.text)|\(r.number.map(String.init) ?? "-")" }
            expect(split("3 Na⁺ out") == "3 Na⁺ out|-", "3 Na⁺ out keeps its 3: \(split("3 Na⁺ out"))")
            expect(split("2 K⁺ in", 5) == "2 K⁺ in|5", "a different n= leaves the name alone")
            expect(split("2 stroke engine") == "2 stroke engine|-", "2 stroke engine")
            expect(split("1 Fan", 1) == "Fan|1", "1 Fan with n=1")
            expect(split("1. Fan") == "Fan|1", "1. Fan")
            expect(split("2) Compressor") == "Compressor|2", "2) Compressor")
            expect(split("3 · Combustor") == "Combustor|3", "3 · Combustor")
            expect(split("4: Turbine", 4) == "Turbine|4", "4: Turbine")
            expect(split("4. Turbine", 2) == "4. Turbine|2", "a clashing n= wins and the text is kept")
            expect(split("Fan", 3) == "Fan|3", "no leading number")
            expect(split("100 rpm") == "100 rpm|-", "three digits are never a list number")
            expect(split("5") == "5|-", "a bare number stays")
            expect(split("7.") == "7.|-", "nothing left after the number")
        }

        section("explode: parts on a base lift off it, never through it") {
            let base = SceneVec3(0, 0, 0)
            let parts = [SceneVec3(-1, 0.11, 0), SceneVec3(1.5, 0.11, 0.5), SceneVec3(0, 0.2, -1)]
            let up = SceneGeometry.explodeOffsets(positions: parts, axis: SceneVec3(0, 1, 0), distance: 1, base: base)
            expect(up.allSatisfy { $0.y > 0.5 && $0.x == 0 && $0.z == 0 }, "all go up: \(up)")
            expect(near(up.map(\.y).max() ?? 0, 1), "the farthest moves by the distance")
            let down = SceneGeometry.explodeOffsets(positions: parts, axis: SceneVec3(0, -1, 0), distance: 1, base: base)
            expect(down.allSatisfy { $0.y > 0.5 }, "an axis pointing into the board still lifts parts off it: \(down)")
            let old = SceneGeometry.explodeOffsets(positions: parts, axis: SceneVec3(0, 1, 0), distance: 1)
            expect(old.contains { $0.y < 0 }, "the symmetric version pushes some parts down (why the base version exists)")
            let both = SceneGeometry.explodeOffsets(positions: [SceneVec3(0, 0.3, 0), SceneVec3(0, -0.3, 0)], axis: SceneVec3(0, 1, 0), distance: 2, base: base)
            expect(both[0].y > 0 && both[1].y < 0, "parts on both faces go their own ways")
            expect(SceneGeometry.explodeOffsets(positions: parts, axis: SceneVec3(0, 1, 0), distance: 0, base: base).allSatisfy { simd_length($0) == 0 }, "dist=0 puts them back")
            expect(SceneGeometry.explodeOffsets(positions: [], axis: SceneVec3(0, 1, 0), distance: 1, base: base).isEmpty, "empty")
        }

        section("explode: the axis is chosen from how the parts lie") {
            let stack = [SceneVec3(0, 0, 0), SceneVec3(0, 1.4, 0), SceneVec3(0, 2.9, 0)]
            let sizes = [SceneVec3(1, 1, 1), SceneVec3(1, 1, 1), SceneVec3(1, 1, 1)]
            expect(SceneGeometry.explodeAxis(positions: stack, extents: sizes) == SceneVec3(0, 1, 0), "a stack comes apart along the stack")
            let row = [SceneVec3(-2, 0, 0.1), SceneVec3(0, 0.1, 0), SceneVec3(2, 0, 0)]
            expect(SceneGeometry.explodeAxis(positions: row, extents: sizes) == SceneVec3(1, 0, 0), "a row comes apart along the row")
            let layers = [SceneVec3.zero, SceneVec3.zero, SceneVec3.zero]
            let flat = [SceneVec3(3, 0.05, 2), SceneVec3(3, 0.05, 2), SceneVec3(3, 0.05, 2)]
            expect(SceneGeometry.explodeAxis(positions: layers, extents: flat) == SceneVec3(0, 1, 0), "flat layers on one spot separate along their thin side")
            expect(SceneGeometry.explodeAxis(positions: [.zero], extents: [SceneVec3(1, 1, 1)]) == SceneVec3(1, 0, 0), "one part: any axis")
        }

        section("orientation frame keeps a link's face along the axle") {
            let q = SceneOrientation.frame(along: SceneVec3(1, 0, 0), facing: SceneVec3(0, 0, 1))
            expect(simd_length(q.act(SceneVec3(0, 1, 0)) - SceneVec3(1, 0, 0)) < 1e-9, "own Y lies along the path")
            expect(simd_length(q.act(SceneVec3(0, 0, 1)) - SceneVec3(0, 0, 1)) < 1e-9, "own Z faces along the axle")
            let degenerate = SceneOrientation.frame(along: SceneVec3(0, 0, 2), facing: SceneVec3(0, 0, 1))
            expect(simd_length(degenerate.act(SceneVec3(0, 1, 0)) - SceneVec3(0, 0, 1)) < 1e-9, "path along the axle still points the link along the path")
        }
    }

    // MARK: Label layout

    static func labelLayout() {
        typealias Item = SceneLabelLayout.Item
        func check(_ items: [Item], low: SceneVec2, high: SceneVec2, _ name: String) -> [String: SceneLabelLayout.Placement] {
            let placed = SceneLabelLayout.place(items, low: low, high: high, gap: 0.05, margin: 0.2)
            expect(placed.count == items.count, "\(name): every chip is placed")
            for (index, a) in items.enumerated() {
                guard let pa = placed[a.id] else { continue }
                // Outside the model's box.
                let outside = pa.center.x - a.size.x / 2 >= high.x - 1e-9 || pa.center.x + a.size.x / 2 <= low.x + 1e-9
                    || pa.center.y - a.size.y / 2 >= high.y - 1e-9 || pa.center.y + a.size.y / 2 <= low.y + 1e-9
                expect(outside, "\(name): chip \(a.id) is clear of the model")
                for b in items[(index + 1)...] {
                    guard let pb = placed[b.id] else { continue }
                    expect(!overlaps((pa.center, a.size), (pb.center, b.size)), "\(name): \(a.id) and \(b.id) do not overlap")
                }
            }
            return placed
        }

        section("label layout: close parts on a tall model get columns, not a tower") {
            // A rocket: six parts stacked close together on the centre line.
            let items = (0..<6).map { Item(id: "p\($0)", anchor: SceneVec2(0.02 * Double($0 % 2), 2.5 - Double($0) * 0.12), size: SceneVec2(1.2, 0.25), side: nil) }
            let placed = check(items, low: SceneVec2(-0.5, -3), high: SceneVec2(0.5, 3), "rocket")
            let sides = Set(placed.values.map(\.side))
            expect(sides.isSubset(of: [.left, .right]), "tall model uses the sides: \(sides)")
            let left = placed.values.filter { $0.side == .left }.count, right = placed.values.filter { $0.side == .right }.count
            expect(abs(left - right) <= 1, "the two columns are balanced (\(left) and \(right))")
            // In a column, a higher part gets a higher chip: leaders don't cross.
            for side in [SceneLabelLayout.Side.left, .right] {
                let column = items.filter { placed[$0.id]?.side == side }.sorted { $0.anchor.y > $1.anchor.y }
                let ys = column.compactMap { placed[$0.id]?.center.y }
                expect(ys == ys.sorted(by: >), "\(side) column keeps the parts' order")
            }
            let tallest = (placed.values.map(\.center.y).max() ?? 0) - (placed.values.map(\.center.y).min() ?? 0)
            expect(tallest < 1.2, "chips stay beside their parts instead of stacking far above (\(tallest))")
        }

        section("label layout: a wide model gets rows, in the parts' left-to-right order") {
            let items = [Item(id: "a", anchor: SceneVec2(-2, 0.2), size: SceneVec2(1.0, 0.3), side: nil),
                         Item(id: "b", anchor: SceneVec2(-1.8, 0.1), size: SceneVec2(1.4, 0.3), side: nil),
                         Item(id: "c", anchor: SceneVec2(0.1, 0), size: SceneVec2(0.9, 0.3), side: nil),
                         Item(id: "d", anchor: SceneVec2(2.2, -0.2), size: SceneVec2(1.1, 0.3), side: nil)]
            let placed = check(items, low: SceneVec2(-3, -1), high: SceneVec2(3, 1), "bridge")
            expect(placed.values.allSatisfy { $0.side == .up }, "few chips fit in one row above")
            let xs = ["a", "b", "c", "d"].compactMap { placed[$0]?.center.x }
            expect(xs == xs.sorted(), "row keeps left-to-right order: \(xs)")
            expect(near(placed["d"]?.center.x ?? 0, 2.2, 1e-6), "a chip with room sits right over its part")

            let many = (0..<9).map { Item(id: "m\($0)", anchor: SceneVec2(-2.4 + Double($0) * 0.6, $0 % 2 == 0 ? 0.5 : -0.5), size: SceneVec2(1.3, 0.3), side: nil) }
            let crowded = check(many, low: SceneVec2(-3, -1), high: SceneVec2(3, 1), "crowded")
            expect(Set(crowded.values.map(\.side)) == [.up, .down], "too many for one row: some go below")
            let below = many.filter { crowded[$0.id]?.side == .down }
            expect(below.allSatisfy { $0.anchor.y < 0 }, "the lower parts are the ones labelled below")
        }

        section("label layout: a script's side= is honoured, and spread() keeps order and gaps") {
            let items = [Item(id: "a", anchor: SceneVec2(0, 0), size: SceneVec2(1, 0.3), side: .down),
                         Item(id: "b", anchor: SceneVec2(0.1, 0.1), size: SceneVec2(1, 0.3), side: .left),
                         Item(id: "c", anchor: SceneVec2(0.2, 0.1), size: SceneVec2(1, 0.3), side: nil)]
            let placed = check(items, low: SceneVec2(-1, -1), high: SceneVec2(1, 1), "sides")
            expect(placed["a"]?.side == .down && placed["b"]?.side == .left, "asked-for sides")
            expect(SceneLabelLayout.Side(script: "below") == .down && SceneLabelLayout.Side(script: "Top") == .up && SceneLabelLayout.Side(script: nil) == nil, "side words")

            let spread = SceneLabelLayout.spread(wanted: [0, 0.1, 0.2, 5], sizes: [1, 1, 1, 1], gap: 0.2)
            expect(spread == spread.sorted(), "order kept")
            for index in 1..<spread.count { expect(spread[index] - spread[index - 1] >= 1.2 - 1e-9, "gap kept between \(index - 1) and \(index)") }
            expect(near(spread[3], 5), "a chip that is not crowded does not move")
            expect(near((spread[0] + spread[1] + spread[2]) / 3, 0.1, 1e-9), "a crowded group stays centred on where it wanted to be")
            expect(SceneLabelLayout.spread(wanted: [3], sizes: [1], gap: 1) == [3], "one chip")
            expect(SceneLabelLayout.place([], low: .zero, high: SceneVec2(1, 1), gap: 0.1, margin: 0.1).isEmpty, "no chips")

            let bounds = SceneLabelLayout.bounds(of: placed, items: items)
            expect(bounds != nil && bounds!.low.x < -1 && bounds!.low.y < -1, "bounds cover chips on the left and below")
            let end = SceneLabelLayout.leaderEnd(for: SceneLabelLayout.Placement(center: SceneVec2(3, 0), side: .right), size: SceneVec2(1, 0.4))
            expect(end == SceneVec2(2.5, 0), "a leader meets a right-hand chip at its left edge")
        }
    }

    // MARK: Narration

    static func narration() {
        typealias Action = SceneNarrationSequencer.Action

        section("narration: stream ahead of speech (the usual case)") {
            var s = SceneNarrationSequencer()
            expect(s.sentenceArrived(index: 1, text: "One.") == [.speak(index: 1, text: "One.")], "the first sentence is spoken at once")
            expect(s.sentenceArrived(index: 2, text: "Two.").isEmpty, "the second waits its turn")
            expect(s.sentenceArrived(index: 3, text: "Three.").isEmpty, "and the third")
            expect(s.streamDidEnd().isEmpty, "the stream ending does not end the narration while sentences wait")
            expect(s.pendingCount == 2 && s.isSpeaking, "two waiting")
            expect(s.speechFinished() == [.speak(index: 2, text: "Two.")], "then the second")
            expect(s.speechFinished() == [.speak(index: 3, text: "Three.")], "then the third")
            expect(s.speechFinished() == [.finished], "finished after the last sentence")
            expect(s.speechFinished().isEmpty && s.streamDidEnd().isEmpty, "finished is reported once")
            expect(s.spokenCount == 3, "three spoken")
        }

        section("narration: stream behind speech") {
            var s = SceneNarrationSequencer()
            _ = s.sentenceArrived(index: 1, text: "One.")
            expect(s.speechFinished().isEmpty, "nothing to say yet: wait for the stream")
            expect(!s.isSpeaking, "idle")
            expect(s.sentenceArrived(index: 2, text: "Two.") == [.speak(index: 2, text: "Two.")], "a late sentence is spoken the moment it arrives")
            expect(s.streamDidEnd().isEmpty, "still speaking")
            expect(s.speechFinished() == [.finished], "finished when the voice catches up")
        }

        section("narration: odd scripts") {
            var s = SceneNarrationSequencer()
            expect(s.streamDidEnd() == [.finished], "a script with no say lines finishes at once")
            expect(s.spokenCount == 0, "nothing was spoken")

            s = SceneNarrationSequencer()
            expect(s.sentenceArrived(index: 1, text: "   ").isEmpty, "blank text is skipped")
            _ = s.sentenceArrived(index: 1, text: "Hello.")
            expect(s.sentenceArrived(index: 1, text: "Hello.").isEmpty && s.pendingCount == 0, "a repeated line is not spoken twice")
            expect(s.sentenceArrived(index: 4, text: "Skipped ahead.").isEmpty && s.pendingCount == 1, "numbers may skip")
            expect(s.speechFinished() == [.speak(index: 4, text: "Skipped ahead.")], "it is spoken in arrival order")
        }

        section("narration: barge-in") {
            var s = SceneNarrationSequencer()
            _ = s.sentenceArrived(index: 1, text: "One.")
            _ = s.sentenceArrived(index: 2, text: "Two.")
            s.stop()
            expect(s.isStopped && !s.isSpeaking && s.pendingCount == 0, "stopped and emptied")
            expect(s.speechFinished().isEmpty, "the interrupted sentence returning does not start the next")
            expect(s.sentenceArrived(index: 3, text: "Three.").isEmpty, "late lines from the cancelled stream are ignored")
            expect(s.streamDidEnd().isEmpty, "no finished after a stop")
        }

        section("scheduler: lines wait for their sentence as long as the host says") {
            func command(_ id: String, cue: Int?) -> SceneCommand { SceneCommand(verb: .ring, id: id, args: ["at": "1,1"], cue: cue) }
            var short = SceneCueScheduler(timing: .speech)
            short.enqueue(command("a", cue: 2), now: 0)
            expect(short.due(now: 7.9).isEmpty && short.due(now: 8.1).count == 1, "by default a line is let through after 8 s")
            var long = SceneCueScheduler(timing: .speech, maximumHold: 120)
            long.enqueue(command("a", cue: 1), now: 0)
            long.enqueue(command("b", cue: 2), now: 0)
            long.enqueue(command("c", cue: nil), now: 0)
            expect(long.due(now: 30).isEmpty, "with a long hold a line still waits at 30 s")
            long.sentenceStarted(1)
            expect(long.due(now: 30.1).map(\.id) == ["a"], "sentence 1 releases its line, and only its line")
            long.sentenceStarted(2)
            var released: [String] = []
            var clock = 30.2
            while clock < 31 { released += long.due(now: clock).map(\.id); clock += 0.05 }
            expect(released == ["b", "c"], "sentence 2 releases the rest in order: \(released)")
        }
    }

    // MARK: Screenshot coordinates

    static func screenMapping() {
        section("screen mapping: 0–1000 lands on the right display, any arrangement") {
            // The main display, a display to its left set lower, and one above it.
            let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let left = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
            let above = CGRect(x: 200, y: 900, width: 1280, height: 800)
            expect(SceneScreenMapping.screenPoint(SceneVec2(0, 0), displayFrame: main) == CGPoint(x: 0, y: 900), "top left of the main display")
            expect(SceneScreenMapping.screenPoint(SceneVec2(1000, 1000), displayFrame: main) == CGPoint(x: 1440, y: 0), "bottom right of the main display")
            expect(SceneScreenMapping.screenPoint(SceneVec2(500, 500), displayFrame: left) == CGPoint(x: -960, y: 360), "middle of the left display")
            expect(SceneScreenMapping.screenPoint(SceneVec2(0, 0), displayFrame: left) == CGPoint(x: -1920, y: 900), "top left of the left display")
            expect(SceneScreenMapping.screenPoint(SceneVec2(250, 100), displayFrame: above) == CGPoint(x: 520, y: 1620), "a point on the display above")
            for frame in [main, left, above] {
                for point in [SceneVec2(0, 0), SceneVec2(123, 877), SceneVec2(1000, 1000), SceneVec2(640.5, 12.25)] {
                    let back = SceneScreenMapping.normalized(screenPoint: SceneScreenMapping.screenPoint(point, displayFrame: frame), displayFrame: frame)
                    expect(simd_length(back - point) < 1e-6, "round trip \(point) on \(frame)")
                    expect(frame.insetBy(dx: -0.001, dy: -0.001).contains(SceneScreenMapping.screenPoint(point, displayFrame: frame)), "\(point) stays on its display")
                }
            }
            let rect = SceneScreenMapping.screenRect(SceneVec2(800, 100), SceneVec2(600, 300), displayFrame: left)
            expect(rect == CGRect(x: -768, y: 576, width: 384, height: 216), "a rectangle given corner-to-corner in any order: \(rect)")
        }

        section("screen mapping: views, pixels and picking the display") {
            expect(SceneScreenMapping.viewPoint(SceneVec2(500, 250), viewSize: CGSize(width: 1920, height: 1080)) == CGPoint(x: 960, y: 270), "view point, y down")
            expect(SceneScreenMapping.normalized(pixel: CGPoint(x: 1440, y: 450), screenshotSize: CGSize(width: 2880, height: 1800)) == SceneVec2(500, 250), "retina pixels")
            expect(SceneScreenMapping.normalized(pixel: CGPoint(x: 5, y: 5), screenshotSize: .zero) == .zero, "no size")
            let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -180, width: 1920, height: 1080)]
            expect(SceneScreenMapping.displayFrame(containing: CGPoint(x: -5, y: 10), among: frames) == frames[1], "the mouse is on the left display")
            expect(SceneScreenMapping.displayFrame(containing: CGPoint(x: 700, y: 5000), among: frames) == frames[0], "off every display: the nearest one")
            expect(SceneScreenMapping.displayFrame(containing: .zero, among: []) == nil, "no displays")
            expect(SceneScreenMapping.clamped(SceneVec2(-20, 1040)) == SceneVec2(0, 1000), "clamped")
        }

        section("screen mapping: where a mark points") {
            func focus(_ line: String) -> SceneVec2? { SceneScreenMapping.focus(of: SceneScriptParser.parse(line)[0]) }
            expect(focus("ring a at=300,400 r=20") == SceneVec2(300, 400), "ring: its centre")
            expect(focus("rect a from=100,200 to=300,260") == SceneVec2(200, 230), "rect: its middle")
            expect(focus("highlight a from=300,260 to=100,200") == SceneVec2(200, 230), "highlight, corners reversed")
            expect(focus("arrow a from=10,10 to=400,500") == SceneVec2(400, 500), "arrow: its tip")
            expect(focus("line a pts=319,310;611,689") == SceneVec2(465, 499.5), "line: its middle")
            expect(focus("poly a pts=0,0;100,0;100,50") == SceneVec2(50, 25), "poly: middle of its box")
            expect(focus("label a at=50,60 text=\"hi\"") == SceneVec2(50, 60), "pill")
            let bounds = SceneScreenMapping.bounds(of: SceneScriptParser.parse("ring a at=300,400 rx=50 ry=10")[0])
            expect(bounds?.low == SceneVec2(250, 390) && bounds?.high == SceneVec2(350, 410), "an oval's box")
            expect(SceneScreenMapping.bounds(of: SceneCommand(verb: .say, id: "_")) == nil, "say has no place")
        }
    }

    // MARK: Audio and summary

    static func audioAndSummary() {
        func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBufferPointer { Data(buffer: $0) } }

        section("narration audio: stretches are laid on the scene's clock") {
            var audio = SceneNarrationAudio()
            expect(audio.isEmpty && audio.duration == 0 && audio.mixed().isEmpty, "empty")
            audio.append(pcm([Int16](repeating: 100, count: 1000)), sampleRate: 1000, at: 0.5)
            // A voice streams faster than real time: the next chunk arrives "early" and continues the stretch.
            audio.append(pcm([Int16](repeating: 200, count: 500)), sampleRate: 1000, at: 0.6)
            expect(audio.segments.count == 1 && audio.segments[0].samples.count == 1500, "chunks of one sentence join up")
            expect(near(audio.duration, 2.0), "ends at 2.0 s: \(audio.duration)")
            // The next sentence starts after a pause.
            audio.append(pcm([Int16](repeating: 300, count: 500)), sampleRate: 1000, at: 3.0)
            expect(audio.segments.count == 2 && near(audio.segments[1].start, 3.0), "a pause starts a new stretch")
            let track = audio.mixed()
            expect(track.count == 3500, "one track from time zero: \(track.count)")
            expect(track[0] == 0 && track[499] == 0 && track[500] == 100 && track[1500] == 200 && track[2500] == 0 && track[3000] == 300, "silence where nothing was said")
            // Saved and loaded again.
            let reloaded = SceneNarrationAudio(track: audio.data(), sampleRate: 1000)
            expect(reloaded.mixed() == track, "survives being saved as PCM")
            audio.append(Data([1]), sampleRate: 1000, at: 9)
            audio.append(pcm([1, 2]), sampleRate: 0, at: 9)
            expect(audio.segments.count == 2, "odd input is ignored")
            var mixedRates = SceneNarrationAudio()
            mixedRates.append(pcm([Int16](repeating: 5, count: 100)), sampleRate: 1000, at: 0)
            mixedRates.append(pcm([Int16](repeating: 7, count: 200)), sampleRate: 2000, at: 0.05)
            expect(mixedRates.sampleRate == 1000 && mixedRates.mixed().count == 200, "a second rate is brought to the first")
        }

        section("summary: what a follow-up is told about the drawing on screen") {
            let script = """
            say 1 "A turbofan pulls air in with a big fan."
            scene3d t title="How a turbofan works"
            jet j
            label a on=j.fan text="Fan" n=1
            say 2 "The turbine drives the fan."
            label d on=j.turbine text="Turbine" n=4
            sphere extra r=0.2 label="Spinner"
            chip "Why is the fan so big?"
            """
            var log = SceneReplayLog()
            for (index, command) in SceneScriptParser.parse(script).enumerated() { log.record(command, at: Double(index) * 0.1) }
            let summary = log.summary
            for needle in ["How a turbofan works", "3D model", "jet j", "Fan (j.fan)", "Turbine (j.turbine)", "Spinner (extra)", "The turbine drives the fan."] {
                expect(summary.contains(needle), "summary mentions \(needle): \(summary)")
            }
            expect(summary.count <= 1400, "summary is short")
            expect(SceneReplayLog().summary.isEmpty, "nothing drawn, nothing to say")
            let body = SceneScriptPrompt.requestBody(question: "what does the turbine do", context: summary)
            let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            expect(user.contains("Turbine (j.turbine)") && user.hasSuffix("what does the turbine do"), "the follow-up request carries the summary and ends with the question")
            let plain = SceneScriptPrompt.requestBody(question: "draw a cat")
            expect(((plain["messages"] as? [[String: Any]])?.last?["content"] as? String) == "draw a cat", "no context, no preamble")
            expect(plain["model"] == nil && body["model"] == nil, "the router picks the model")
        }
    }

    // MARK: Prompts and quality

    static func promptsAndQuality() {
        section("prompts: examples parse, annotation is overlay-only") {
            for example in SceneScriptPrompt.examples {
                let parser = SceneScriptParser()
                let commands = parser.feed(example) + parser.finish()
                expect(parser.stats.parseRate == 1, "example parses fully: \(parser.rejections)")
                // The rule the prompt teaches: every say is followed by something drawn.
                for (index, command) in commands.enumerated() where command.verb == .say {
                    expect(index + 1 < commands.count && commands[index + 1].verb != .say, "example: say \(command.cue ?? 0) is followed by a drawing line")
                }
            }
            let osExample = SceneScriptPrompt.examples.first { $0.contains("How an operating system works") } ?? ""
            let osParser = SceneScriptParser()
            let osCommands = osParser.feed(osExample) + osParser.finish()
            let osQuality = SceneQuality.report(commands: osCommands, stats: osParser.stats, expected: .drawing)
            expect(!osExample.isEmpty && osQuality.parseRate == 1 && osQuality.presentationMatches && !osQuality.surface.contains("card"), "the OS teaching example is a real drawing, never a text card: \(osQuality)")
            let annotate = SceneScriptPrompt.examples.last.map { SceneScriptParser.parse($0) } ?? []
            expect(!annotate.isEmpty && annotate.allSatisfy { $0.verb.family == .overlay || $0.verb.family == .control }, "the annotation example only marks the screen")
            let body = SceneScriptPrompt.annotateRequestBody(question: "circle the bug", screenshotJPEG: Data([0xFF, 0xD8, 0xFF]))
            let content = (body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]] ?? []
            let url = (content.first?["image_url"] as? [String: Any])?["url"] as? String ?? ""
            expect(url.hasPrefix("data:image/jpeg;base64,/9j/"), "the screenshot is sent as a JPEG data URL")
            expect((content.last?["text"] as? String) == "circle the bug" && body["model"] == nil, "question after the image, no model key")
            for verb in ["jet", "rocket", "heart", "eye", "motor", "battery", "bridge", "engine", "membrane", "planet", "pendulum", "chain"] {
                expect(SceneScriptPrompt.system.contains("\(verb) id"), "the prompt teaches \(verb)")
            }
            expect(!SceneScriptPrompt.annotateSystem.contains("scene3d id") && !SceneScriptPrompt.annotateSystem.contains("card id"), "the annotation prompt offers no cards or 3D")
        }

        section("quality score: rewards macros, labels and sane placement") {
            func report(_ script: String, expected: ScenePresentationExpectation = .any) -> SceneQualityReport {
                let parser = SceneScriptParser()
                let commands = parser.feed(script) + parser.finish()
                return SceneQuality.report(commands: commands, stats: parser.stats, expected: expected)
            }
            let good = report("say 1 \"a\"\nscene3d s\nrocket r\nlabel a on=r.nose text=\"Nose\" n=1\nsay 2 \"b\"\nlabel b on=r.stage1 text=\"Stage\" n=2\nsay 3 \"c\"\nlabel c on=r.engine text=\"Engine\" n=3")
            expect(good.surface == "3D" && good.usesMacros && good.labelCount == 3 && good.sayCount == 3 && good.partCount > 8, "a labelled rocket: \(good)")
            let plain = report("scene3d s\ncyl a r=0.3 h=1\ncyl b r=0.3 h=1\ncyl c r=0.3 h=1")
            expect(!plain.usesMacros && plain.boundsSanity < 0.5, "three cylinders on one spot: no macros, piled up (\(plain.boundsSanity))")
            expect(good.score > plain.score + 25, "and it scores much lower (\(good.score) vs \(plain.score))")
            let flung = report("scene3d s\nbox a at=0,0,0\nbox b at=1,0,0\nbox c at=0,1,0\nbox d at=1,1,0\nbox e at=900,0,0")
            expect(flung.boundsSanity < 1, "a part flung far away is noticed (\(flung.boundsSanity))")
            let card = report("say 1 \"a\"\ncard c title=\"T\"\ntext \"one\"\nbullet \"two\"\nformula \"x\"\nchip \"q\"\nchip \"r\"")
            expect(card.surface == "card" && card.cardItems == 3 && card.chipCount == 2 && card.score > 80, "a card: \(card)")
            let osCard = "card os title=\"Operating system layers\"\nsteps \"Apps\" \"Kernel\" \"Hardware\"\nbullet \"Apps request files and memory from the kernel.\"\nbullet \"Drivers communicate with hardware.\""
            let wrongCard = report(osCard, expected: .drawing)
            expect(wrongCard.parseRate == 1 && !wrongCard.presentationMatches && wrongCard.score <= 40 && wrongCard.presentationMismatch != nil, "a valid OS steps/bullets card fails a drawing expectation: \(wrongCard)")
            let textOnly = report("scene3d s\ntext3 apps at=0,2,0 text=\"Apps\"\ntext3 kernel at=0,0,0 text=\"Kernel\"\ntext3 hardware at=0,-2,0 text=\"Hardware\"", expected: .drawing)
            expect(textOnly.parseRate == 1 && textOnly.partCount == 3 && textOnly.geometryPartCount == 0 && !textOnly.presentationMatches && textOnly.score <= 40, "moving three text labels into 3D does not make a diagram: \(textOnly)")
            let diagram = report("scene3d os\nbox apps at=0,2,0 label=\"Apps\"\nbox kernel at=0,0,0 label=\"Kernel\"\nbox hardware at=0,-2,0 label=\"Hardware\"\narrow3 request from=0,1.5,0 to=0,0.5,0", expected: .drawing)
            expect(diagram.parseRate == 1 && diagram.geometryPartCount >= 3 && diagram.presentationMatches && diagram.presentationMismatch == nil, "boxes and an arrow form a real diagram: \(diagram)")
            let overlay = report("rect apps at=0.2,0.2 size=0.2,0.1\narrow request from=0.3,0.3 to=0.3,0.5", expected: .drawing)
            expect(overlay.parseRate == 1 && overlay.overlayGeometryCount == 2 && overlay.presentationMatches, "screen-space geometry also satisfies a drawing: \(overlay)")
            let reference = report(osCard, expected: .referenceCard)
            let textReference = report("card summary\ntext \"The kernel manages memory and devices.\"", expected: .referenceCard)
            let chartReference = report("card requests\nchart traffic type=bar data=20,35,25", expected: .referenceCard)
            expect(reference.presentationMatches && textReference.presentationMatches && chartReference.presentationMatches && chartReference.parseRate == 1, "explicit summaries and charts remain valid reference cards")
            let wrongReference = report("scene3d s\nbox a\nbox b at=2,0,0", expected: .referenceCard)
            expect(!wrongReference.presentationMatches && wrongReference.score <= 40, "a drawing cannot silently replace an explicitly requested card")
            let repeatedPart = report("scene3d s\nbox a\nbox a at=2,0,0", expected: .drawing)
            expect(repeatedPart.geometryPartCount == 1 && !repeatedPart.presentationMatches, "repeated upserts do not inflate the geometry count")
            let garbage = report("this is prose\nso is this")
            expect(garbage.score == 0 && garbage.parseRate == 0, "prose scores nothing")
        }
    }

    // MARK: Photos and history

    static func photosAndHistory() {
        section("photos: choosing a picture from search and Wikipedia responses") {
            // The shape publik's /search returned on 14 Nov 2026: no image fields.
            let results: [[String: Any]] = [
                ["title": "GE9X Engine | GE Aerospace", "url": "https://www.geaerospace.com/commercial/aircraft-engines/ge9x", "site": "geaerospace.com", "snippet": "…"],
                ["title": "General Electric GE9X - Wikipedia", "url": "https://en.wikipedia.org/wiki/General_Electric_GE9X", "site": "en.wikipedia.org", "snippet": "…"],
            ]
            expect(ScenePhotoPicker.imageInSearchResults(results) == nil, "today's search results carry no image")
            expect(ScenePhotoPicker.wikipediaTitle(inSearchResults: results) == "General_Electric_GE9X", "but they name the article")
            let withImage: [[String: Any]] = [["url": "https://example.org/page", "site": "example.org", "thumbnail": ["url": "https://example.org/a.jpg"]]]
            let direct = ScenePhotoPicker.imageInSearchResults(withImage)
            expect(direct?.imageURL.absoluteString == "https://example.org/a.jpg" && direct?.sourceURL?.absoluteString == "https://example.org/page" && direct?.sourceName == "example.org",
                   "an image field is used if the search ever returns one")
            expect(ScenePhotoPicker.imageInSearchResults([["url": "https://e.org", "image": "http://e.org/a.jpg"]]) == nil, "plain http is refused")
            expect(ScenePhotoPicker.wikipediaTitle(fromPage: "https://en.wikipedia.org/wiki/File:Engine.jpg") == nil, "a file page is not an article")
            expect(ScenePhotoPicker.wikipediaTitle(fromPage: "https://en.wikipedia.org/wiki/Caf%C3%A9") == "Café", "percent-encoding is undone")
            expect(ScenePhotoPicker.wikipediaTitle(fromPage: "https://evil.example/wiki/Thing") == nil, "only Wikipedia")
            expect(ScenePhotoPicker.summaryURL(forTitle: "Golden Gate Bridge")?.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/Golden_Gate_Bridge", "summary URL")
            expect(ScenePhotoPicker.summaryURL(forTitle: "AC/DC?")?.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC%3F", "a slash or question mark cannot change the path")
            expect(ScenePhotoPicker.summaryURL(forTitle: "  ") == nil, "empty title")

            let summary = """
            {"type":"standard","title":"Golden Gate Bridge","thumbnail":{"source":"https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/GGB.jpg/320px-GGB.jpg","width":320,"height":213},
             "originalimage":{"source":"https://upload.wikimedia.org/wikipedia/commons/0/0c/GGB.jpg","width":4000,"height":2667},
             "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Golden_Gate_Bridge"}}}
            """
            let candidate = ScenePhotoPicker.candidate(fromSummary: Data(summary.utf8))
            expect(candidate?.imageURL.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/GGB.jpg/960px-GGB.jpg", "asks for a 960 px thumbnail, a width Wikimedia serves: \(candidate?.imageURL.absoluteString ?? "nil")")
            expect(candidate?.fallbackImageURL?.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/GGB.jpg/320px-GGB.jpg", "and keeps the thumbnail it was given to fall back on")
            expect(candidate?.sourceURL?.absoluteString == "https://en.wikipedia.org/wiki/Golden_Gate_Bridge" && candidate?.sourceName == "Wikipedia", "the source page is kept for the caption")
            expect(ScenePhotoPicker.candidate(fromSummary: Data(#"{"type":"disambiguation","thumbnail":{"source":"https://x.org/320px-a.jpg"}}"#.utf8)) == nil, "a disambiguation page is refused")
            expect(ScenePhotoPicker.candidate(fromSummary: Data(#"{"type":"standard","title":"No picture"}"#.utf8)) == nil, "no picture")
            expect(ScenePhotoPicker.candidate(fromSummary: Data("not json".utf8)) == nil, "bad JSON")
            expect(ScenePhotoPicker.resized(thumbnail: "https://u.org/thumb/a.jpg/320px-a.jpg", to: 960, originalWidth: 500) == "https://u.org/thumb/a.jpg/500px-a.jpg", "never wider than the original")
            expect(ScenePhotoPicker.resized(thumbnail: "https://u.org/thumb/a.jpg/330px-a.jpg", to: 960, originalWidth: 700) == "https://u.org/thumb/a.jpg/500px-a.jpg", "only widths Wikimedia serves (500, not 700)")
            expect(ScenePhotoPicker.resized(thumbnail: "https://u.org/thumb/a.jpg/330px-a.jpg", to: 960, originalWidth: 300) == "https://u.org/thumb/a.jpg/330px-a.jpg", "a small original: keep what we were given")
            expect(ScenePhotoPicker.resized(thumbnail: "https://t.org/a.jpg/330px-a.jpg?utm=x", to: 960, originalWidth: 4032) == "https://t.org/a.jpg/960px-a.jpg?utm=x", "the query string survives")
            expect(ScenePhotoPicker.resized(thumbnail: "https://u.org/a.jpg", to: 800, originalWidth: 500) == "https://u.org/a.jpg", "not a sized thumbnail: left alone")
            let search = #"{"pages":[{"key":"Turbofan_(band)","thumbnail":null},{"key":"Turbofan","thumbnail":{"url":"//u.org/t.jpg"}}]}"#
            expect(ScenePhotoPicker.titles(fromTitleSearch: Data(search.utf8)) == ["Turbofan", "Turbofan_(band)"], "title search prefers articles with a picture")

            expect(ScenePhotoPicker.accepts(contentType: "image/jpeg", byteCount: 50_000), "a JPEG")
            expect(ScenePhotoPicker.accepts(contentType: "IMAGE/PNG; charset=binary", byteCount: 50_000), "type is read loosely")
            expect(!ScenePhotoPicker.accepts(contentType: "text/html", byteCount: 50_000), "not a web page")
            expect(!ScenePhotoPicker.accepts(contentType: "image/svg+xml", byteCount: 50_000), "not an SVG")
            expect(!ScenePhotoPicker.accepts(contentType: "image/jpeg", byteCount: 7_000_000), "not over 6 MB")
            expect(!ScenePhotoPicker.accepts(contentType: nil, byteCount: 50_000) && !ScenePhotoPicker.accepts(contentType: "image/png", byteCount: 10), "no type, or too small to be a picture")
            expect(ScenePhotoPicker.cacheKey(for: "GE9X  Turbofan") == ScenePhotoPicker.cacheKey(for: "ge9x turbofan"), "the cache ignores case and spacing")
            expect(ScenePhotoPicker.cacheKey(for: "a") != ScenePhotoPicker.cacheKey(for: "b"), "different queries, different files")
            expect(ScenePhotoPicker.cacheKey(for: "../../etc").allSatisfy { $0.isHexDigit }, "a cache name is only hex digits")
        }

        section("history: drawings are saved, listed, loaded, pruned and removed") {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-scene2/history-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var store = SceneHistoryStore(root: root)
            expect(store.entries().isEmpty, "a new store is empty")

            var log = SceneReplayLog()
            for (index, command) in SceneScriptParser.parse("say 1 \"Hi\"\nscene3d s title=\"A rocket\"\nrocket r").enumerated() { log.record(command, at: Double(index) * 0.5) }
            var audio = SceneNarrationAudio()
            audio.append([Int16](repeating: 9, count: 480).withUnsafeBufferPointer { Data(buffer: $0) }, sampleRate: 24000, at: 0.25)
            let day = Date(timeIntervalSince1970: 1_794_000_000)
            let first = store.save(log: log, question: "draw a rocket", thumbnailPNG: Data([0x89, 0x50, 0x4E, 0x47]), narration: audio, date: day)
            expect(first != nil, "saved")
            guard let first else { return }
            expect(SceneHistoryStore.isValidID(first.id) && first.id.count == 19, "id is <date>-<8 hex>: \(first.id)")
            expect(first.title == "A rocket" && first.question == "draw a rocket" && first.kind == "3D model" && first.hasNarration && near(first.duration, 1.0), "entry: \(first)")
            let folder = store.folder(for: first.id)
            for file in ["meta.json", "scene.json", "thumb.png", "narration.pcm"] {
                expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), "\(file) is written")
            }
            expect(store.entries() == [first], "listed")
            expect(store.log(for: first.id) == log, "the log comes back exactly")
            let narration = store.narration(for: first)
            expect(narration.sampleRate == 24000 && narration.mixed().count == 6000 + 480, "the voice track comes back with its lead-in silence")

            var cardLog = SceneReplayLog()
            for command in SceneScriptParser.parse("card c\ntext \"hello\"") { cardLog.record(command, at: 0) }
            let second = store.save(log: cardLog, question: "explain the chain rule on a card please, slowly and with every step shown", thumbnailPNG: nil, date: day.addingTimeInterval(60))
            expect(second?.kind == "card" && second?.hasNarration == false, "a card without a voice")
            expect(second?.title.hasSuffix("…") == true && (second?.title.count ?? 99) <= 48, "an untitled drawing is named from the question: \(second?.title ?? "")")
            expect(store.entries().map(\.id) == [second?.id ?? "", first.id], "newest first")

            var sayOnly = SceneReplayLog()
            sayOnly.record(SceneScriptParser.parse("say 1 \"just talk\"")[0], at: 0)
            expect(store.save(log: sayOnly, question: "x", thumbnailPNG: nil) == nil && store.save(log: SceneReplayLog(), question: "x", thumbnailPNG: nil) == nil, "nothing drawn, nothing saved")

            expect(store.log(for: "../../etc/passwd") == nil && !SceneHistoryStore.isValidID("2026-11-14-zzzzzzzz") && !SceneHistoryStore.isValidID(".."), "ids that are not ours are refused")
            store.delete("..")
            expect(FileManager.default.fileExists(atPath: root.path), "a bad id cannot delete the folder above")
            // A stray folder is not listed.
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
            expect(store.entries().count == 2, "other folders are ignored")

            store.limit = 3
            for index in 0..<4 { _ = store.save(log: log, question: "q\(index)", thumbnailPNG: nil, date: day.addingTimeInterval(120 + Double(index))) }
            let kept = store.entries()
            expect(kept.count == 3 && kept.first?.question == "q3" && !kept.contains(first), "only the newest three are kept")
            store.delete(kept[0].id)
            expect(store.entries().count == 2 && !FileManager.default.fileExists(atPath: store.folder(for: kept[0].id).path), "removed")

            expect(SceneHistoryStore.makeID(date: Date(timeIntervalSince1970: 0), random: 0xABCD, timeZone: TimeZone(identifier: "UTC")!) == "1970-01-01-0000abcd", "id format")
            expect(SceneHistoryStore.titleFromQuestion("  ") == "Drawing" && SceneHistoryStore.titleFromQuestion("show me a gear") == "Show me a gear", "titles")
        }
    }
}
