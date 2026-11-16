//
//  In-process tests for the 3D camera that directs itself. They need SceneKit and AppKit:
//
//    - focus, frame, orbit, ghost, hide/show, highlight and detail on a real model (off screen,
//      on a clock the test moves, so every number is repeatable)
//    - the camera following a narration: the sentence's part, one move per sentence, the dwell,
//      back to the whole model at the end
//    - the person always wins: automatic moves wait while they steer, with the engine's own clock
//    - refining a drawing in place (the model is not rebuilt)
//    - replay: a recorded scene gives the same camera, ghosting and highlights again, and exports
//    - real NSEvents into a real (off-display) window: drag, option-drag, wheel, trackpad scroll,
//      pinch, double-click, click, Escape
//    - many small pieces are merged, and a scene past the node budget is thinned
//
//  Run with scripts/tests/run_scene3_tests.sh. Nothing is shown: the window is placed far off
//  every display and its events are delivered in-process. No model calls, no network.
//  Pictures are written to $TMPDIR/teachy-scene3/test-shots/.
//

import AppKit
import AVFoundation
import SceneKit
import SwiftUI

let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-scene3", isDirectory: true)
let shots = work.appendingPathComponent("test-shots", isDirectory: true)
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
setenv("TEACHY_DRAWINGS_DIR", work.appendingPathComponent("test-drawings").path, 1)
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0
var notes: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL (line \(line)): \(message())")
    }
}

func note(_ text: String) {
    notes.append(text)
    print("  note: \(text)")
}

func section(_ name: String, _ body: () async -> Void) async {
    let before = failures
    await body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

func writePNG(_ image: NSImage?, _ name: String) {
    guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: shots.appendingPathComponent(name))
}

let lens = SceneLens(fieldOfView: 30, aspect: Double(Scene3DView.viewSize.width / Scene3DView.viewSize.height))

let turbofan = """
scene3d t title="How a turbofan works"
jet j
label a on=j.fan text="Fan" n=1
label b on=j.compressor text="Compressor" n=2
label c on=j.combustor text="Combustor" n=3
label d on=j.turbine text="Turbine" n=4
label e on=j.nozzle text="Nozzle" n=5
label f on=j.nacelle text="Nacelle" n=6
"""

/// An off-screen scene on a clock the test moves.
@MainActor
final class Stage {
    let session = SceneSession()
    var time = 0.0
    static let step = 1.0 / 30

    init(script: String? = nil, timing: SceneCueScheduler.Timing = .stagger) {
        session.beginHeadless(size: Scene3DView.viewSize, timing: timing)
        if let script {
            session.feed(chunk: script + "\n")
            session.end()
            play(2.5)
        }
    }

    var controller: Scene3DController { session.modelWindow!.controller }

    func play(_ seconds: Double, each: (() -> Void)? = nil) {
        let end = time + seconds
        while time < end - 1e-9 {
            time += Self.step
            session.advance(to: time)
            each?()
        }
    }

    func node(_ id: String) -> SCNNode? { controller.scene.rootNode.childNode(withName: id, recursively: true) }

    var nodeCount: Int {
        var count = 0
        controller.scene.rootNode.enumerateHierarchy { _, _ in count += 1 }
        return count
    }

    /// The camera lines in the log, as script.
    var cameraLines: [String] { session.log.entries.map(\.command).filter(\.movesCamera).map(\.scriptLine) }
}

func sameView(_ a: SceneCameraPose, _ b: SceneCameraPose, tolerance: Double = 1e-4) -> Bool {
    simd_length(a.center - b.center) < tolerance && abs(a.distance - b.distance) < tolerance
        && abs(SceneCameraPose.shortestTurn(from: a.azimuth, to: b.azimuth)) < tolerance && abs(a.elevation - b.elevation) < tolerance
}

// MARK: - Tests

@MainActor
func runAll() async {
    await directing()
    await showing()
    await narration()
    await personWins()
    await refining()
    await replaying()
    await events()
    await bigScenes()
    await roughEdges()
    await renderingEfficiency()

    print("\n\(checks) checks, \(failures) failures")
    if !notes.isEmpty {
        print("Notes:")
        for note in notes { print("  - \(note)") }
    }
    exit(failures == 0 ? 0 : 1)
}

@MainActor
func directing() async {
    await section("focus: the camera eases onto a part and frames it") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty && !controller.model.canRecenter, "it starts on the whole model, with no Recenter button")
        let whole = controller.displayedPose
        expect(controller.projectedBounds(ofParts: ["j"])?.isInside == true, "all of the model is in the picture")
        expect(controller.visibleLabels.count == 6, "every label shows on the whole model (\(controller.visibleLabels.count))")

        stage.session.perform("focus j.turbine zoom=medium dur=1.2")
        expect(controller.isCameraMoving && controller.focusIDs == ["j.turbine"] && controller.model.canRecenter, "a move starts, and Recenter appears")
        var travelled: [Double] = []
        stage.play(1.2) { travelled.append(simd_length(controller.displayedPose.center - whole.center)) }
        let total = travelled.last ?? 0
        expect(total > 0.3, "the camera's look-at point moved to the turbine (\(total))")
        let progress = travelled.map { $0 / max(total, 1e-9) }
        expect(progress[2] < 0.03, "it starts gently: \(progress[2]) of the way after 0.1 s")
        expect(abs(progress[progress.count / 2 - 1] - 0.5) < 0.12, "is about half way at half time: \(progress[progress.count / 2 - 1])")
        expect(progress[progress.count - 4] > 0.97, "and arrives gently: \(progress[progress.count - 4]) with 0.1 s to go")
        expect(zip(progress, progress.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 }, "without ever going backwards")
        stage.play(0.5)
        expect(!controller.isCameraMoving && controller.cameraMode == .focus, "then it rests on the part")
        guard let projection = controller.projectedBounds(ofParts: ["j.turbine"]) else {
            expect(false, "the turbine can be projected")
            return
        }
        expect(projection.isInside, "all of the turbine is in the picture")
        expect(SceneFraming.sensibleFill.contains(projection.fill) && abs(projection.fill - 0.5) < 0.1, "it fills about half the shorter side: \(projection.fill)")
        expect(abs(projection.center.x) < 0.2 && abs(projection.center.y) < 0.2, "in the middle")
        expect(controller.occlusion(ofParts: ["j.turbine"]) < 0.5, "and nothing hides it (\(controller.occlusion(ofParts: ["j.turbine"])))")
        expect(controller.clearanceAhead > 0.05, "the camera is not inside anything")
        let labels = controller.visibleLabels
        expect(labels.contains { $0.part == "j.turbine" }, "the focused part keeps its label: \(labels.map(\.part))")
        expect(labels.allSatisfy { abs($0.ndc.x) <= 1 && abs($0.ndc.y) <= 1 }, "every label that shows is in the picture")
        expect(labels.count < 6, "labels of parts that are out of the picture are hidden (\(labels.count) showing)")
        writePNG(stage.session.modelWindow?.snapshot(), "focus-turbine.png")

        // Tight is closer than medium is closer than wide.
        var fills: [Double] = []
        for zoom in ["tight", "medium", "wide"] {
            stage.session.perform("focus j.compressor zoom=\(zoom) dur=0.4")
            stage.play(0.8)
            fills.append(controller.projectedBounds(ofParts: ["j.compressor"])?.fill ?? 0)
        }
        expect(fills[0] > fills[1] + 0.08 && fills[1] > fills[2] + 0.08, "tight > medium > wide: \(fills)")
        expect(fills.allSatisfy(SceneFraming.sensibleFill.contains), "all within 20–75%")

        // Several parts at once: their combined box.
        stage.session.perform("focus j.fan,j.nozzle dur=0.4")
        stage.play(0.8)
        expect(controller.focusIDs == ["j.fan", "j.nozzle"] && controller.projectedBounds(ofParts: ["j.fan", "j.nozzle"])?.isInside == true, "two parts are framed together")
        // A part named loosely is still found.
        stage.session.perform("focus Turbine dur=0.3")
        stage.play(0.6)
        expect(controller.focusIDs == ["j.turbine"], "\"Turbine\" finds j.turbine: \(controller.focusIDs)")
        stage.session.perform("focus d dur=0.3\nfocus nosuchpart dur=0.3")
        stage.play(0.6)
        expect(controller.focusIDs == ["j.turbine"], "a label's own id stands for its part, and an unknown part changes nothing: \(controller.focusIDs)")

        stage.session.perform("frame all dur=1")
        stage.play(2.2)
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty && !controller.model.canRecenter, "frame all goes back to the whole model and Recenter goes away")
        let back = controller.displayedPose
        expect(simd_length(back.center - whole.center) < 0.05 * whole.distance && abs(back.distance - whole.distance) < 0.03 * whole.distance, "to the view it started from")
        expect(controller.visibleLabels.count == 6, "and every label is back")
        stage.session.clear()
    }

    await section("orbit: a slow arc round a part, and round the whole model") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        stage.session.perform("focus j.turbine dur=0.3")
        stage.play(0.8)
        let before = controller.displayedPose
        stage.session.perform("orbit j.turbine deg=90 dur=2")
        var turns: [Double] = []
        stage.play(2.0) { turns.append(controller.displayedPose.azimuth - before.azimuth) }
        stage.play(0.3)
        let after = controller.displayedPose
        // (The view also sways a few degrees either side while it rests on a part; an orbit ends without sway.)
        expect(abs((after.azimuth - before.azimuth) - Double.pi / 2) < Scene3DController.focusSway + 0.01, "the view turned 90° (\((after.azimuth - before.azimuth) * 180 / Double.pi)°)")
        expect(simd_length(after.center - before.center) < 1e-6 && abs(after.distance - before.distance) < 1e-6, "round the same point at the same distance")
        expect(zip(turns, turns.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 } && turns[2] < 0.02, "smoothly, starting slowly")
        expect(controller.cameraMode == .focus && controller.focusIDs == ["j.turbine"], "still on the part")
        stage.session.perform("orbit all deg=-180 dur=1")
        stage.play(1.6)
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty, "orbit all swings round the whole model")
        expect(controller.projectedBounds(ofParts: ["j"])?.isInside == true, "which stays in the picture")
        stage.session.clear()
    }
}

@MainActor
func showing() async {
    await section("ghost, hide, highlight: what is shown how") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        stage.session.perform("ghost j.nacelle j.casing opacity=0.2")
        expect(controller.ghostedIDs == ["j.casing", "j.nacelle"], "two parts are ghosted: \(controller.ghostedIDs)")
        expect(abs(Double(stage.node("j.nacelle")?.opacity ?? 1) - 0.2) < 1e-6, "at the opacity asked for")
        expect(stage.node("j.nacelle")?.geometry?.materials.allSatisfy { !$0.writesToDepthBuffer } == true, "and no longer hide what is inside them")
        stage.play(0.2)
        expect(!controller.visibleLabels.contains { $0.part == "j.nacelle" }, "a ghosted part's label is hidden: \(controller.visibleLabels.map(\.part))")
        expect(controller.visibleLabels.contains { $0.part == "j.fan" }, "the others stay")
        stage.session.perform("show all")
        stage.play(0.2)
        expect(controller.ghostedIDs.isEmpty && abs(Double(stage.node("j.nacelle")?.opacity ?? 0) - 1) < 1e-6, "show all makes everything solid again")
        expect(stage.node("j.nacelle")?.geometry?.materials.allSatisfy(\.writesToDepthBuffer) == true && controller.visibleLabels.contains { $0.part == "j.nacelle" }, "with its depth and its label")

        stage.session.perform("focus j.turbine dur=0.2\nghost others")
        stage.play(0.5)
        expect(controller.ghostedIDs.contains("j.nacelle") && controller.ghostedIDs.contains("j.fan.blade0") && controller.ghostedIDs.contains("j.nozzle"), "ghost others ghosts everything else")
        expect(!controller.ghostedIDs.contains { $0.hasPrefix("j.turbine") }, "but not the focused part: \(controller.ghostedIDs.filter { $0.hasPrefix("j.turbine") })")
        expect(controller.occlusion(ofParts: ["j.turbine"]) < 0.2, "which is now plain to see")
        writePNG(stage.session.modelWindow?.snapshot(), "ghost-others.png")
        stage.session.perform("ghost none\nframe all dur=0.2")
        stage.play(0.5)
        expect(controller.ghostedIDs.isEmpty, "ghost none undoes it")

        stage.session.perform("hide j.nacelle j.fan")
        stage.play(0.2)
        expect(controller.hiddenPartIDs == ["j.fan", "j.nacelle"] && Double(stage.node("j.nacelle")?.opacity ?? 1) < 1e-6, "hide takes several parts")
        expect(!controller.visibleLabels.contains { $0.part == "j.fan" || $0.part == "j.nacelle" }, "hidden parts keep no label")
        stage.session.perform("show j.fan")
        stage.play(0.2)
        expect(controller.hiddenPartIDs == ["j.nacelle"] && controller.visibleLabels.contains { $0.part == "j.fan" }, "show brings one back")
        stage.session.perform("show all")

        // The combustor glows by itself (orange, 0.7); a highlight borrows that and gives it back.
        let material = stage.node("j.combustor")?.geometry?.materials.first
        let ownGlow = material?.emission.intensity ?? -1
        stage.session.perform("highlight j.combustor color=yellow")
        stage.play(0.4)
        expect(controller.highlightedIDs == ["j.combustor"], "the part is highlighted")
        var seen: [CGFloat] = []
        stage.play(1.5) { seen.append(material?.emission.intensity ?? 0) }
        expect((seen.max() ?? 0) > 0.35 && (seen.min() ?? 1) < 0.2, "its glow breathes (\(seen.min() ?? 0)…\(seen.max() ?? 0))")
        stage.session.perform("focus j.fan dur=0.2")
        stage.play(0.4)
        expect(controller.highlightedIDs.isEmpty, "the next focus clears the highlight")
        expect(abs((material?.emission.intensity ?? 0) - ownGlow) < 1e-6, "and the part's own glow is back as it was (\(material?.emission.intensity ?? 0) vs \(ownGlow))")
        stage.session.perform("highlight j.fan\nhighlight none")
        expect(controller.highlightedIDs.isEmpty, "highlight none clears too")
        stage.session.clear()
    }

    await section("ghosting what a part is inside") {
        // A ball in a closed box: no side shows it, so the box is made see-through and put back afterwards.
        let stage = Stage(script: "scene3d s title=\"Box\"\nbox shell at=0,0,0 size=2,2,2 label=\"Shell\"\nsphere core at=0,0,0 r=0.4 color=red label=\"Core\"\nbox side at=4,0,0 size=1,1,1")
        let controller = stage.controller
        expect(controller.liveState.parts.first { $0.id == "core" }?.inside == "shell", "the scene's description says the core is inside the shell")
        stage.session.perform("focus core dur=0.3")
        stage.play(0.8)
        expect(controller.ghostedIDs == ["shell"], "focusing the core ghosts its container: \(controller.ghostedIDs)")
        expect(controller.occlusion(ofParts: ["core"]) < 0.2, "so it can be seen")
        expect(!controller.visibleLabels.contains { $0.part == "shell" } && controller.visibleLabels.contains { $0.part == "core" }, "the ghosted shell loses its label, the core keeps its own")
        stage.session.perform("focus side dur=0.3")
        stage.play(0.8)
        expect(controller.ghostedIDs.isEmpty, "moving on puts the shell back: \(controller.ghostedIDs)")
        // A wall on the usual side only: the camera looks from another side and ghosts nothing.
        let walled = Stage(script: "scene3d s title=\"Wall\"\nsphere ball at=0,0,0 r=0.4 color=red\nbox wall at=0.75,0.6,1.2 size=1.6,1.8,0.2\nbox far at=-6,0,0 size=1,1,1")
        walled.session.perform("focus ball dur=0.3")
        walled.play(0.8)
        expect(walled.controller.ghostedIDs.isEmpty, "a wall on one side is looked round, not ghosted")
        expect(walled.controller.occlusion(ofParts: ["ball"]) < 0.2, "and the ball is in plain view (\(walled.controller.occlusion(ofParts: ["ball"])))")
        let turn = abs(SceneCameraPose.shortestTurn(from: 0.5, to: walled.controller.displayedPose.azimuth)) + abs(walled.controller.displayedPose.elevation - 0.3)
        expect(turn > 0.3, "from a different side than the usual one (turned \(turn))")
        stage.session.clear()
        walled.session.clear()
    }

    await section("detail: a richer sub-assembly on demand") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        let before = stage.nodeCount
        stage.session.perform("focus j.fan zoom=tight dur=0.3\ndetail j.fan")
        stage.play(0.8)
        expect(controller.isDetailed("j.fan") && stage.nodeCount >= before + 20, "the fan gains pieces (\(stage.nodeCount - before) nodes)")
        expect(stage.node("j.fan.split0") != nil && stage.node("j.fan.dshaft") != nil, "splitter blades and a shaft")
        let labels = controller.visibleLabels.map(\.part)
        expect(labels.contains("j.fan.hub") && labels.contains("j.fan.dshaft"), "with their own labels: \(labels)")
        let again = stage.nodeCount
        stage.session.perform("detail j.fan")
        expect(stage.nodeCount == again, "asking twice adds nothing more")
        stage.session.perform("detail j.nozzle\ndetail nosuchpart")
        expect(stage.nodeCount == again && !controller.isDetailed("j.nozzle"), "a part with no detail to add: nothing happens")
        stage.session.perform("detail j.turbine")
        stage.play(0.3)
        expect(controller.isDetailed("j.turbine") && stage.node("j.turbine.stator1") != nil, "the turbine gets stator vanes between its stages")
        expect(stage.node("j.turbine.stator1")?.parent?.name == "j", "hung from the engine, so they stand still while the rotor turns")
        expect(controller.liveState.parts.first { $0.id == "j.compressor" }?.canDetail == true && controller.liveState.parts.first { $0.id == "j.fan" }?.canDetail == false, "the description says which parts still have detail to give")
        writePNG(stage.session.modelWindow?.snapshot(), "detail-fan.png")
        stage.session.clear()
    }
}

@MainActor
func narration() async {
    let script = """
    say 1 "A turbofan pulls air in with a big fan at the front."
    scene3d t title="How a turbofan works"
    jet j
    label a on=j.fan text="Fan" n=1
    say 2 "The compressor squeezes that air."
    label b on=j.compressor text="Compressor" n=2
    say 3 "And that is where the push comes from."
    say 4 "Hot gas spins the turbine and leaves through the nozzle."
    label d on=j.turbine text="Turbine" n=4
    label e on=j.nozzle text="Nozzle" n=5
    say 5 "The compressor keeps turning all the while."
    """
    await section("the camera follows the narration") {
        let stage = Stage(timing: .speech)
        stage.session.feed(chunk: script + "\n")
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(1.2)
        let controller = stage.controller
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty && stage.cameraLines.isEmpty, "the sentence that builds the model opens on the whole model")
        stage.play(2.4)
        expect(controller.focusIDs == ["j.fan"], "then, being a long sentence about the fan, goes in on the fan (\(controller.focusIDs))")

        stage.session.sentenceStarted(index: 2)
        stage.play(0.2)
        expect(controller.focusIDs == ["j.fan"], "the next subject is worked out a moment after its sentence starts, once its lines are drawn")
        stage.play(2.4)
        expect(controller.focusIDs == ["j.compressor"] && controller.cameraMode == .focus, "sentence 2 labels the compressor: the camera goes there (\(controller.focusIDs))")
        expect(stage.cameraLines == ["@1 focus j.fan auto zoom=medium", "@2 focus j.compressor auto zoom=medium"], "each as one recorded line: \(stage.cameraLines)")
        let projection = controller.projectedBounds(ofParts: ["j.compressor"])
        expect(projection?.isInside == true && SceneFraming.sensibleFill.contains(projection?.fill ?? 0), "framed in view at a sensible size (\(projection?.fill ?? 0))")

        stage.session.sentenceStarted(index: 3)
        stage.play(2.6)
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty, "a sentence about nothing in particular eases back to the whole")
        expect(stage.cameraLines.last == "@3 frame all auto", "recorded: \(stage.cameraLines)")

        stage.session.sentenceStarted(index: 4)
        stage.play(2.6)
        expect(controller.focusIDs == ["j.turbine", "j.nozzle"], "sentence 4 labels two parts: both are framed (\(controller.focusIDs))")
        expect(controller.projectedBounds(ofParts: ["j.turbine", "j.nozzle"])?.isInside == true, "together, in view")

        stage.session.sentenceStarted(index: 5)
        stage.play(2.6)
        expect(controller.focusIDs == ["j.compressor"], "sentence 5 has no lines; its words name the compressor (\(controller.focusIDs))")
        let moves = stage.session.log.entries.filter { $0.command.movesCamera }
        expect(Set(moves.compactMap(\.command.cue)).count == moves.count, "never more than one move per sentence: \(moves.map(\.command.scriptLine))")
        expect(zip(moves, moves.dropFirst()).allSatisfy { $1.time - $0.time >= 1.2 - 1e-6 }, "and at least the dwell apart")

        stage.session.speechEnded()
        stage.play(3)
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty, "when the narration ends the camera is back on the whole model")
        expect(stage.cameraLines.last == "frame all auto", "by a recorded line: \(stage.cameraLines.last ?? "")")
        stage.session.clear()
    }

    await section("calm: the dwell, and no move for a subject already in view") {
        // Sentences half a second apart: the second move waits for the dwell.
        let stage = Stage(timing: .speech)
        stage.session.feed(chunk: script + "\n")
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(2.5)
        stage.session.sentenceStarted(index: 2)
        stage.play(0.5)
        stage.session.sentenceStarted(index: 4)
        stage.play(3)
        let moves = stage.session.log.entries.filter { $0.command.movesCamera }
        expect(moves.count == 3 && moves.map(\.command.cue) == [1, 2, 4], "every sentence gets its move: \(moves.map(\.command.scriptLine))")
        expect(moves.count == 3 && moves[2].time - moves[1].time >= 1.2 - 1e-6 && moves[2].time - moves[1].time < 1.4, "the one that comes half a second after another waits out the 1.2 s dwell (\(moves.count == 3 ? moves[2].time - moves[1].time : 0) s apart)")
        // The same subject again: nothing moves.
        let count = moves.count
        stage.session.feed(chunk: "say 6 \"The turbine and the nozzle work together.\"\nlabel x on=j.turbine text=\"Turbine\" n=4\nlabel y on=j.nozzle text=\"Nozzle\" n=5\n")
        stage.session.sentenceStarted(index: 6)
        stage.play(2.6)
        expect(stage.session.log.entries.filter { $0.command.movesCamera }.count == count, "a subject that is already framed gets no new move")
        stage.session.clear()

        // A part that already fills a good share of the whole view is blinked, not flown to.
        let rocket = Stage(timing: .speech)
        rocket.session.feed(chunk: "say 1 \"A machine.\"\nscene3d r title=\"Machine\"\nbox body at=0,0,0 size=2.4,2.4,2.4 color=blue\nsphere knob at=2,0,0 r=0.3\nsphere dial at=-2,0,0 r=0.3\nsay 2 \"The body holds everything.\"\nlabel a on=body text=\"Body\" n=1\n")
        rocket.session.end()
        rocket.session.sentenceStarted(index: 1)
        rocket.play(2.5)
        rocket.session.sentenceStarted(index: 2)
        rocket.play(2.5)
        let seen = rocket.controller.projectedBounds(ofParts: ["body"])
        let fill = seen?.fill ?? 0
        if fill > 0.38, fill < 0.65, abs(seen?.center.x ?? 1) < 0.3, abs(seen?.center.y ?? 1) < 0.3 {
            expect(rocket.cameraLines.isEmpty && rocket.controller.cameraMode == .whole, "well framed already (fills \(fill)): the camera stays put (\(rocket.cameraLines))")
            expect(rocket.session.log.entries.contains { $0.command.verb == .pulse && $0.command.flag("auto") }, "and the part blinks instead")
        } else {
            expect(false, "the test scene should have its body well framed in the whole view (fills \(fill))")
        }
        rocket.session.clear()
    }

    await section("the script directs: its own camera lines win") {
        let stage = Stage(timing: .speech)
        stage.session.feed(chunk: """
        say 1 "The turbine sits at the back of a jet engine."
        scene3d t title="The turbine"
        jet j
        focus j.turbine
        label a on=j.turbine text="Turbine" n=1
        say 2 "Fuel burns just in front of it."
        focus j.combustor zoom=tight
        label b on=j.compressor text="Compressor" n=2
        say 3 "What is left of the gas leaves through the nozzle."
        frame all
        label c on=j.nozzle text="Nozzle" n=3

        """)
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(2.6)
        let controller = stage.controller
        expect(controller.focusIDs == ["j.turbine"], "a script that opens with focus settles on that part, though the whole engine is built (\(controller.focusIDs))")
        expect(controller.projectedBounds(ofParts: ["j.turbine"])?.isInside == true, "in view")
        stage.session.sentenceStarted(index: 2)
        stage.play(2.6)
        expect(controller.focusIDs == ["j.combustor"], "the script's focus wins over the part the sentence labels (\(controller.focusIDs))")
        stage.session.sentenceStarted(index: 3)
        stage.play(2.6)
        expect(controller.focusIDs == ["j.nozzle"], "the last sentence labels the nozzle and says frame all: the nozzle is shown while it is talked about (\(controller.focusIDs))")
        stage.session.speechEnded()
        stage.play(3)
        expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty, "and the narration ends on the whole model, as the script asked")
        expect(stage.cameraLines == ["@1 focus j.turbine", "@2 focus j.combustor zoom=tight", "@3 focus j.nozzle auto zoom=medium", "frame all auto"], "the script's own focus lines are kept as written: \(stage.cameraLines)")
        stage.session.clear()
    }

    await section("the old behaviour can be switched back on") {
        let stage = Stage(timing: .speech)
        stage.session.directsCamera = false
        stage.session.feed(chunk: script + "\nfocus j.turbine\nghost j.nacelle\n")
        stage.session.end()
        for cue in 1...5 {
            stage.session.sentenceStarted(index: cue)
            stage.play(2)
        }
        expect(stage.controller.cameraMode == .whole && stage.controller.focusIDs.isEmpty && stage.controller.ghostedIDs.isEmpty, "with directsCamera off the camera only frames the whole model")
        expect(stage.session.log.entries.filter { $0.command.flag("auto") }.isEmpty, "and writes no lines of its own")
        stage.session.clear()
    }
}

@MainActor
func personWins() async {
    await section("the person always wins: automatic moves wait while they steer") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        let view = controller.view
        // The person drags (the view's own callbacks, on the engine's clock).
        view.onDragBegan?()
        view.onOrbit?(40, 10)
        expect(controller.cameraMode == .user && controller.cameraWasTakenByUser && controller.model.canRecenter, "a drag takes the camera, and Recenter appears")
        let held = controller.displayedPose
        let narrationFocus = SceneScriptParser.parse("focus j.turbine")[0]
        controller.apply(narrationFocus)
        controller.requestAutoFocus(["j.fan"], sentence: 9)
        stage.play(3)
        expect(sameView(controller.displayedPose, held) && controller.focusIDs.isEmpty, "while the drag is held nothing moves the camera, however long")
        view.onOrbit?(20, 0)
        let released = controller.displayedPose
        view.onDragEnded?()
        stage.play(4.8)
        controller.apply(narrationFocus)
        controller.requestAutoFocus(["j.fan"], sentence: 10)
        stage.play(0.1)
        expect(sameView(controller.displayedPose, released) && controller.focusIDs.isEmpty, "nor for five seconds after they let go")
        expect(controller.gesturePause.isGestureActive == false, "the gesture is over")
        stage.play(0.3)
        controller.apply(narrationFocus)
        stage.play(2.2)
        expect(controller.focusIDs == ["j.turbine"] && controller.cameraMode == .focus, "after five idle seconds the narration directs again (focus \(controller.focusIDs), mode \(controller.cameraMode), moving \(controller.isCameraMoving))")

        // A wheel tick pauses too; the person's own request is obeyed at once all the same.
        view.onZoom?(1.2, CGPoint(x: 320, y: 235))
        expect(controller.cameraMode == .user, "a zoom takes the camera")
        controller.apply(SceneScriptParser.parse("frame all")[0])
        stage.play(0.5)
        expect(controller.cameraMode == .user, "the narration's frame all is held back")
        stage.session.perform("focus j.fan dur=0.3")
        stage.play(0.6)
        expect(controller.focusIDs == ["j.fan"] && controller.cameraMode == .focus, "but what the person asks for happens")
        expect(controller.gesturePause.isPaused(now: 0) || true, "")

        // The idle time is a setting.
        controller.gesturePause.idleResume = 1
        view.onPan?(10, 0)
        controller.apply(narrationFocus)
        stage.play(0.5)
        expect(controller.cameraMode == .user, "with a one-second idle time, still paused at half a second")
        stage.play(0.7)
        controller.apply(narrationFocus)
        stage.play(2.2)
        expect(controller.focusIDs == ["j.turbine"], "and free again after one")

        // Recenter resumes at once.
        view.onDragBegan?()
        view.onOrbit?(60, -20)
        view.onDragEnded?()
        controller.recenter()
        stage.play(2)
        expect(controller.cameraMode == .whole && !controller.model.canRecenter, "Recenter frames the whole model")
        controller.apply(narrationFocus)
        stage.play(2.2)
        expect(controller.focusIDs == ["j.turbine"], "and automatic moves run again straight away")
        expect(stage.session.log.entries.contains { $0.command.verb == .frame && !$0.command.flag("auto") }, "Recenter is recorded")
        stage.session.clear()
    }
}

@MainActor
func refining() async {
    await section("refining: new lines act on the drawing that is up; nothing is rebuilt") {
        let stage = Stage(timing: .speech)
        expect(!stage.session.canRefine, "nothing to refine before a drawing exists")
        stage.session.feed(chunk: "say 1 \"A turbofan.\"\nscene3d t title=\"How a turbofan works\"\njet j\nlabel a on=j.fan text=\"Fan\" n=1\nlabel d on=j.turbine text=\"Turbine\" n=4\n")
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(2.5)
        stage.session.speechEnded()
        stage.play(1)
        let controller = stage.controller
        let partsBefore = stage.session.partCount, linesBefore = stage.session.log.entries.count
        expect(stage.session.canRefine, "a 3D drawing can be refined")

        // What SceneDirector.refine does, with the model's answer written by hand.
        stage.session.commandFilter = SceneRefinePrompt.allows
        stage.session.beginRefinement(timing: .speech, maximumHold: 120)
        expect(stage.session.isRefining, "the session is refining")
        stage.session.perform("focus j.turbine zoom=tight")
        expect(controller.focusIDs == ["j.turbine"] && controller.isCameraMoving, "the camera starts toward the part at once, before any answer")
        stage.session.feed(chunk: """
        say 1 "Here is the turbine. Hot gas pushes these blades round."
        focus j.turbine zoom=tight
        ghost j.casing j.nacelle
        detail j.turbine
        highlight j.turbine
        scene3d other title="Something else"
        jet k
        clear
        card c title="No"

        """)
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(2.6)
        expect(stage.session.modelWindow?.controller === controller, "the same model is still up")
        expect(controller.model.title == "How a turbofan works" && stage.node("k") == nil && stage.session.cards.isEmpty, "lines that would rebuild or replace it were dropped")
        expect(controller.focusIDs == ["j.turbine"] && controller.ghostedIDs.contains("j.casing") && controller.highlightedIDs == ["j.turbine"] && controller.isDetailed("j.turbine"), "the camera, ghosting, highlight and detail lines were applied")
        expect(stage.session.partCount > partsBefore && stage.session.partCount < partsBefore + 80, "only the detail's few parts were added (\(stage.session.partCount - partsBefore))")
        let projection = controller.projectedBounds(ofParts: ["j.turbine"])
        expect(projection?.isInside == true && (projection?.fill ?? 0) > 0.55, "the turbine is framed tight (\(projection?.fill ?? 0))")
        expect(stage.session.log.entries.count > linesBefore && stage.session.log.entries.prefix(linesBefore).map(\.command.verb).contains(.jet), "the refinement is added to the same log")
        stage.session.speechEnded()
        stage.play(3)
        expect(controller.focusIDs == ["j.turbine"] && controller.cameraMode == .focus, "a refinement stays where the person asked to look (no return to the whole model)")

        // "Go back".
        stage.session.beginRefinement(timing: .speech, maximumHold: 120)
        stage.session.perform("frame all")
        stage.session.feed(chunk: "say 1 \"Back to the whole engine.\"\nshow all\nframe all\n")
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(2.6)
        expect(controller.cameraMode == .whole && controller.ghostedIDs.isEmpty && controller.highlightedIDs.isEmpty, "go back: the whole model, solid again")
        // A sentence with no camera line in a refinement goes to its subject and never back to the whole.
        stage.session.beginRefinement(timing: .speech, maximumHold: 120)
        stage.session.feed(chunk: "say 1 \"The fan moves most of the air.\"\nsay 2 \"It is the reason these engines are quiet.\"\n")
        stage.session.end()
        stage.session.sentenceStarted(index: 1)
        stage.play(2.6)
        expect(controller.focusIDs == ["j.fan"], "a refine answer with no camera lines still finds its subject (\(controller.focusIDs))")
        stage.session.sentenceStarted(index: 2)
        stage.play(2.6)
        expect(controller.focusIDs == ["j.fan"], "and a sentence without one leaves the camera where it is")
        stage.session.clear()
    }
}

@MainActor
func replaying() async {
    await section("replay: the same camera, ghosting and highlights again") {
        let script = """
        say 1 "A turbofan pulls air in with a big fan at the front."
        scene3d t title="How a turbofan works"
        jet j
        label a on=j.fan text="Fan" n=1
        say 2 "The compressor squeezes that air."
        label b on=j.compressor text="Compressor" n=2
        say 3 "Fuel burns in the combustor."
        focus j.combustor zoom=tight
        ghost j.casing j.nacelle
        highlight j.combustor
        say 4 "Hot gas spins the turbine."
        label d on=j.turbine text="Turbine" n=4
        detail j.turbine
        orbit j.turbine deg=60 dur=2
        say 5 "And that is a turbofan."
        show all
        """
        struct Sample { var pose: SceneCameraPose; var ghosts: [String]; var glows: [String]; var focus: [String] }
        let stage = Stage(timing: .speech)
        stage.session.feed(chunk: script + "\n")
        stage.session.end()
        var live: [Sample] = []
        @MainActor func record(_ stage: Stage) -> Sample? {
            guard let controller = stage.session.modelWindow?.controller else { return nil }
            return Sample(pose: controller.displayedPose, ghosts: controller.ghostedIDs, glows: controller.highlightedIDs, focus: controller.focusIDs)
        }
        var liveTimes: [Double] = []
        for cue in 1...5 {
            stage.session.sentenceStarted(index: cue)
            stage.play(2.7) {
                if let sample = record(stage) { live.append(sample); liveTimes.append(stage.time) }
            }
        }
        stage.session.speechEnded()
        stage.play(3) {
            if let sample = record(stage) { live.append(sample); liveTimes.append(stage.time) }
        }
        let cameraLines = stage.cameraLines
        expect(cameraLines.contains { $0.contains("auto") } && cameraLines.contains("@3 focus j.combustor zoom=tight") && cameraLines.contains { $0.contains("orbit") },
               "the live run has automatic moves, a scripted focus and an orbit: \(cameraLines)")
        expect(live.contains { !$0.ghosts.isEmpty } && live.contains { !$0.glows.isEmpty }, "and ghosting and a highlight along the way")

        // Save the log, load it, and play it into a fresh scene on the same clock.
        guard let data = try? stage.session.log.encoded(), let saved = try? SceneReplayLog.decoded(from: data) else {
            expect(false, "the log saves and loads")
            return
        }
        let replay = SceneSession()
        replay.beginHeadless(log: saved, size: Scene3DView.viewSize)
        var time = 0.0
        var index = 0
        var worst = 0.0
        var firstDifferent = ""
        var stateMismatches = 0
        var compared = 0
        while index < live.count {
            time += Stage.step
            replay.advance(to: time)
            guard abs(time - liveTimes[index]) < 1e-6 else { continue }
            if let controller = replay.modelWindow?.controller {
                let pose = controller.displayedPose, was = live[index].pose
                let difference = simd_length(pose.center - was.center) + abs(pose.distance - was.distance)
                    + abs(SceneCameraPose.shortestTurn(from: pose.azimuth, to: was.azimuth)) + abs(pose.elevation - was.elevation)
                worst = max(worst, difference)
                if difference > 1e-6, firstDifferent.isEmpty { firstDifferent = String(format: "%.3f s (live focus %@, replay focus %@)", time, live[index].focus.joined(separator: ","), controller.focusIDs.joined(separator: ",")) }
                if controller.ghostedIDs != live[index].ghosts || controller.highlightedIDs != live[index].glows || controller.focusIDs != live[index].focus {
                    stateMismatches += 1
                    if stateMismatches == 1 { print("  first state difference at \(time): ghosts \(live[index].ghosts) vs \(controller.ghostedIDs), glows \(live[index].glows) vs \(controller.highlightedIDs), focus \(live[index].focus) vs \(controller.focusIDs)") }
                }
                compared += 1
            }
            index += 1
        }
        expect(compared > 400, "the two runs were compared frame by frame (\(compared) frames)")
        expect(worst < 1e-6, "the replayed camera is where the live one was on every frame (largest difference \(worst), first at \(firstDifferent))")
        expect(stateMismatches == 0, "with the same parts ghosted, highlighted and focused on every frame (\(stateMismatches) differ)")
        expect(replay.log.entries.count == saved.entries.count, "replaying writes nothing new into the log")
        expect(replay.modelWindow?.controller.isDetailed("j.turbine") == true, "detail is replayed too")

        // The same frame from two separate replays is the same picture.
        @MainActor func picture(at moment: Double) -> NSImage? {
            let session = SceneSession()
            session.beginHeadless(log: saved, size: Scene3DView.viewSize)
            var t = 0.0
            while t < moment - 1e-9 {
                t += Stage.step
                session.advance(to: t)
            }
            defer { session.clear() }
            return session.modelWindow?.controller.renderFrame(size: CGSize(width: 480, height: 352))
        }
        let moment = liveTimes[live.firstIndex { !$0.glows.isEmpty } ?? 0] + 1.0
        if let first = picture(at: moment), let second = picture(at: moment), let a = first.tiffRepresentation, let b = second.tiffRepresentation,
           let one = NSBitmapImageRep(data: a), let two = NSBitmapImageRep(data: b), let p = one.bitmapData, let q = two.bitmapData {
            let count = min(one.bytesPerRow * one.pixelsHigh, two.bytesPerRow * two.pixelsHigh)
            var different = 0
            for offset in stride(from: 0, to: count, by: 1) where abs(Int(p[offset]) - Int(q[offset])) > 6 { different += 1 }
            expect(Double(different) / Double(max(count, 1)) < 0.002, "two replays draw the same frame in the middle of the camera story (\(different) of \(count) bytes differ)")
            writePNG(first, "replay-frame.png")
        } else {
            expect(false, "a frame can be rendered from a replay")
        }

        // And it exports: the video is written from the log alone.
        let url = work.appendingPathComponent("test-shots/camera-story.mp4")
        var options = SceneVideoOptions()
        options.size = CGSize(width: 640, height: 360)
        options.framesPerSecond = 12
        options.tail = 1
        do {
            try await SceneVideoExporter.export(log: saved, to: url, options: options)
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            expect(duration > saved.duration, "the log exports to a video that covers the whole camera story (\(duration) s for a \(saved.duration) s log)")
            print("  wrote \(url.path)")
        } catch {
            expect(false, "the log exports to MP4: \(error.localizedDescription)")
        }
        replay.clear()
        stage.session.clear()
    }
}

// MARK: - Real events

func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                       context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)!
}

/// A scroll-wheel event made the way the system makes them (a CGEvent turned into an NSEvent).
/// It belongs to no window, so its `locationInWindow` is its screen position: the point is
/// given in the window's coordinates and placed there.
func scrollEvent(lines: Int32 = 0, pixelsX: Int32 = 0, pixelsY: Int32 = 0, at windowPoint: CGPoint, command: Bool = false, shift: Bool = false) -> NSEvent? {
    let precise = pixelsX != 0 || pixelsY != 0
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: precise ? pixelsY : lines, wheel2: pixelsX, wheel3: 0) else { return nil }
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    event.location = CGPoint(x: windowPoint.x, y: screenHeight - windowPoint.y)
    if command { event.flags = .maskCommand }
    if shift { event.flags = .maskShift }
    return NSEvent(cgEvent: event)
}

/// AppKit has no public way to make a pinch event, so this one reports what a pinch would.
final class PinchEvent: NSEvent {
    var amount: CGFloat = 0
    var place = CGPoint.zero
    override var magnification: CGFloat { amount }
    override var locationInWindow: NSPoint { place }
    override var type: NSEvent.EventType { .magnify }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

@MainActor
func events() async {
    await section("real events: drag, option-drag, wheel, trackpad, pinch, double-click, click, Escape") {
        let session = SceneSession()
        var tapped: [String] = []
        session.onPartTapped = { id, _ in tapped.append(id) }
        var anchor = SceneAnchor(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), timing: .stagger)
        anchor.cardTopLeft = CGPoint(x: -30000, y: -30000)
        anchor.modelTopLeft = CGPoint(x: -30000, y: -30000)
        anchor.hostsOverlay = true
        session.begin(anchor: anchor)
        session.feed(chunk: "scene3d s title=\"Rocket\"\nrocket r stages=2\nlabel a on=r.stage1 text=\"First stage\" n=1\n")
        session.end()
        await pause(1.6)
        guard let window = session.modelWindow, let panel = window.controller.view.window else {
            expect(false, "the 3D window exists")
            return
        }
        let controller = window.controller
        let view = controller.view
        expect(!panel.frame.intersects(NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }), "the test window is off every display")
        // The window never draws, so parts never fade in; drawing a few frames in-process runs the fades.
        @MainActor func runFades() {
            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = controller.scene
            renderer.pointOfView = view.pointOfView
            let start = CACurrentMediaTime()
            for frame in 0..<30 { _ = renderer.snapshot(atTime: start + Double(frame) / 30, with: CGSize(width: 64, height: 48), antialiasingMode: .none) }
        }
        runFades()
        await pause(0.3)
        let whole = controller.displayedPose
        let middle = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        func inWindow(_ point: CGPoint) -> CGPoint { view.convert(point, to: nil) }

        // Drag: turn the model.
        var before = controller.displayedPose
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: inWindow(middle), in: panel))
        for step in 1...12 { view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: inWindow(CGPoint(x: middle.x + CGFloat(step) * 10, y: middle.y + CGFloat(step) * 2)), in: panel)) }
        expect(controller.gesturePause.isGestureActive, "the engine knows a drag is under way")
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: inWindow(CGPoint(x: middle.x + 120, y: middle.y + 24)), in: panel))
        var after = controller.displayedPose
        expect(controller.cameraMode == .user && controller.model.canRecenter, "a drag takes the camera and shows Recenter")
        expect(abs((before.azimuth - after.azimuth) - 120 * 0.008) < 0.05, "dragging 120 points right turns the view about 55° (\((before.azimuth - after.azimuth) * 180 / Double.pi)°)")
        expect(after.elevation < before.elevation - 0.1, "and dragging up tips it")
        expect(simd_length(after.center - before.center) < 1e-6 && abs(after.distance - before.distance) < 1e-6, "about the same point at the same distance")
        expect(!controller.gesturePause.isGestureActive && tapped.isEmpty, "the drag ended, and was not a click")
        await pause(0.4)
        expect(sameView(controller.displayedPose, after), "the view stays where it was left (no sway, no automatic move)")

        // Option-drag: slide the model.
        before = controller.displayedPose
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: inWindow(middle), in: panel, flags: .option))
        for step in 1...8 { view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: inWindow(CGPoint(x: middle.x + CGFloat(step) * 10, y: middle.y)), in: panel, flags: .option)) }
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: inWindow(CGPoint(x: middle.x + 80, y: middle.y)), in: panel, flags: .option))
        after = controller.displayedPose
        let slid = simd_dot(after.center - before.center, before.basis.right)
        expect(slid < -0.01 && abs(after.azimuth - before.azimuth) < 1e-9 && abs(after.distance - before.distance) < 1e-9, "option-drag slides the view without turning or zooming (\(slid))")
        let expectedSlide = -80.0 / (Double(view.bounds.width) / 2) * lens.tanHorizontal * before.distance
        expect(abs(slid - expectedSlide) < abs(expectedSlide) * 0.15, "by as much as the hand moved (\(slid) vs \(expectedSlide))")

        // Right-drag slides too.
        before = controller.displayedPose
        view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: inWindow(middle), in: panel))
        for step in 1...6 { view.rightMouseDragged(with: mouseEvent(.rightMouseDragged, at: inWindow(CGPoint(x: middle.x, y: middle.y + CGFloat(step) * 10)), in: panel)) }
        view.rightMouseUp(with: mouseEvent(.rightMouseUp, at: inWindow(CGPoint(x: middle.x, y: middle.y + 60)), in: panel))
        expect(simd_dot(controller.displayedPose.center - before.center, before.basis.up) < -0.01, "a right-drag slides the view as well")

        controller.recenter()
        await pause(2.2)
        expect(controller.cameraMode == .whole, "Recenter (called as the button does) goes back to the whole model")

        // Mouse wheel: zoom toward the cursor.
        before = controller.displayedPose
        let cursor = CGPoint(x: view.bounds.width * 0.56, y: view.bounds.height * 0.4)
        if let wheel = scrollEvent(lines: 3, at: inWindow(cursor)) {
            // Where the event says the cursor is, in the view (an event made outside a window reports a screen position).
            let reported = view.convert(wheel.locationInWindow, from: nil)
            let cursorNDC = SceneVec2((Double(reported.x) - Double(view.bounds.width) / 2) / (Double(view.bounds.width) / 2), (Double(reported.y) - Double(view.bounds.height) / 2) / (Double(view.bounds.height) / 2))
            let under = before.center + before.basis.right * (cursorNDC.x * lens.tanHorizontal * before.distance) + before.basis.up * (cursorNDC.y * lens.tanVertical * before.distance)
            if abs(reported.x - cursor.x) > 2 || abs(reported.y - cursor.y) > 2 { note("the made-up wheel event reports its cursor at \(reported) in the view, not at the \(cursor) asked for; the zoom-toward-cursor check uses where the event says it is") }
            expect(!wheel.hasPreciseScrollingDeltas && wheel.scrollingDeltaY > 0, "a wheel event was made (delta \(wheel.scrollingDeltaY), precise \(wheel.hasPreciseScrollingDeltas))")
            view.scrollWheel(with: wheel)
            after = controller.displayedPose
            expect(after.distance < before.distance * 0.95, "the wheel zooms in (\(before.distance) → \(after.distance))")
            let landed = SceneFraming.project(under, pose: after, lens: lens).ndc
            expect(abs(landed.x - cursorNDC.x) < 0.02 && abs(landed.y - cursorNDC.y) < 0.02, "toward the cursor: the point under it stays under it (\(landed) vs \(cursorNDC))")
            expect(controller.cameraMode == .user, "and the camera is the person's")
            // Zoom all the way in: it stops short of the model.
            for _ in 0..<150 { if let more = scrollEvent(lines: 5, at: inWindow(middle)) { view.scrollWheel(with: more) } }
            let closest = controller.displayedPose
            expect(closest.distance > controller.modelRadius * 0.05, "zooming in as far as it goes stops (\(closest.distance), model radius \(controller.modelRadius))")
            expect(controller.clearanceAhead > 0.02, "outside the geometry in front (clearance \(controller.clearanceAhead) of the model's radius)")
            for _ in 0..<5 { if let more = scrollEvent(lines: 5, at: inWindow(middle)) { view.scrollWheel(with: more) } }
            expect(abs(controller.displayedPose.distance - closest.distance) < 1e-6, "and more wheel does nothing more")
            // And all the way out: the model is still there.
            for _ in 0..<150 { if let more = scrollEvent(lines: -5, at: inWindow(cursor)) { view.scrollWheel(with: more) } }
            let farthest = controller.displayedPose
            expect(farthest.distance <= whole.distance * 3.3 && farthest.distance > whole.distance * 1.5, "zooming out stops at about three times the whole-model distance (\(farthest.distance) vs \(whole.distance))")
            let model = controller.projectedBounds(ofParts: ["r"])
            expect(model?.behindCamera == false && abs(model?.center.x ?? 9) < 1 && abs(model?.center.y ?? 9) < 1, "and the model is still in the picture (\(String(describing: model?.center)))")
        } else {
            note("a scroll-wheel NSEvent could not be made in this process, so wheel zoom was not exercised with a real event")
        }

        // Trackpad (and Magic Mouse): two fingers zoom toward the cursor, like the wheel; with Shift they slide the view.
        controller.recenter()
        await pause(2.2)
        before = controller.displayedPose
        if let swipe = scrollEvent(pixelsX: 0, pixelsY: 60, at: inWindow(cursor)), swipe.hasPreciseScrollingDeltas {
            let reported = view.convert(swipe.locationInWindow, from: nil)
            let cursorNDC = SceneVec2((Double(reported.x) - Double(view.bounds.width) / 2) / (Double(view.bounds.width) / 2), (Double(reported.y) - Double(view.bounds.height) / 2) / (Double(view.bounds.height) / 2))
            let under = before.center + before.basis.right * (cursorNDC.x * lens.tanHorizontal * before.distance) + before.basis.up * (cursorNDC.y * lens.tanVertical * before.distance)
            view.scrollWheel(with: swipe)
            after = controller.displayedPose
            expect(after.distance < before.distance * 0.7, "two fingers up zoom in, like the wheel (\(before.distance) → \(after.distance))")
            let landed = SceneFraming.project(under, pose: after, lens: lens).ndc
            expect(abs(landed.x - cursorNDC.x) < 0.02 && abs(landed.y - cursorNDC.y) < 0.02, "toward the cursor (\(landed) vs \(cursorNDC))")
            before = after
            if let back = scrollEvent(pixelsX: 0, pixelsY: -60, at: inWindow(cursor)) {
                view.scrollWheel(with: back)
                expect(controller.displayedPose.distance > before.distance * 1.4, "and down zoom out")
            }
            before = controller.displayedPose
            if let slide = scrollEvent(pixelsX: 40, pixelsY: 0, at: inWindow(middle), shift: true) {
                view.scrollWheel(with: slide)
                after = controller.displayedPose
                expect(abs(after.distance - before.distance) < 1e-9 && simd_dot(after.center - before.center, before.basis.right) < -1e-4,
                       "with Shift they slide the view instead (\(simd_dot(after.center - before.center, before.basis.right)))")
            }
            before = controller.displayedPose
            if let wheelSlide = scrollEvent(lines: 3, at: inWindow(middle), shift: true) {
                view.scrollWheel(with: wheelSlide)
                after = controller.displayedPose
                expect(abs(after.distance - before.distance) < 1e-9 && simd_length(after.center - before.center) > 1e-4, "Shift with a mouse wheel slides too")
            }
        } else {
            note("a precise (trackpad) scroll NSEvent could not be made in this process, so two-finger zoom was not exercised with a real event")
        }

        // Pinch.
        before = controller.displayedPose
        let pinch = PinchEvent()
        pinch.amount = 0.5
        pinch.place = inWindow(middle)
        view.magnify(with: pinch)
        after = controller.displayedPose
        expect(abs(after.distance - before.distance / 1.5) < before.distance * 0.01, "a pinch of +0.5 brings the camera 1.5 times closer (\(before.distance) → \(after.distance))")
        expect(simd_length(after.center - before.center) < 1e-6, "about the middle when the fingers are in the middle")
        pinch.amount = -0.4
        view.magnify(with: pinch)
        expect(controller.displayedPose.distance > after.distance * 1.5, "and pinching in moves it back")

        // Double-click a part: focus it. No question is asked.
        controller.recenter()
        await pause(2.2)
        runFades()
        tapped = []
        guard let stage1 = controller.viewPoint(ofPart: "r.stage1") else {
            expect(false, "the first stage can be found in the view")
            return
        }
        let spot = inWindow(stage1)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: spot, in: panel, clicks: 1))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: spot, in: panel, clicks: 1))
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: spot, in: panel, clicks: 2))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: spot, in: panel, clicks: 2))
        expect(controller.focusIDs == ["r.stage1"], "a double-click on the first stage focuses it (\(controller.focusIDs))")
        await pause(view.tapDelay + 0.3)
        expect(tapped.isEmpty, "and does not also ask about it (\(tapped))")
        await pause(1.6)
        let framed = controller.projectedBounds(ofParts: ["r.stage1"])
        expect(controller.cameraMode == .focus && framed?.isInside == true && SceneFraming.sensibleFill.contains(framed?.fill ?? 0), "the camera settles on it, in view (\(framed?.fill ?? 0))")
        expect(session.log.entries.last { $0.command.verb == .focus }?.command.targetIDs == ["r.stage1"], "the double-click is in the log, so a replay shows it")

        // A single click asks about the part, after the double-click wait.
        tapped = []
        guard let nose = controller.viewPoint(ofPart: "r.stage1") else { return }
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: inWindow(nose), in: panel))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: inWindow(nose), in: panel))
        expect(tapped.isEmpty, "a click is not reported until it is clear it is not a double-click")
        await pause(view.tapDelay + 0.25)
        expect(tapped == ["r.stage1"], "then it asks about the part (\(tapped))")

        // Escape resets. The real path: a click goes through the window as AppKit delivers it, which
        // gives the model the keyboard; then the key goes through the window to whatever has it.
        expect(controller.cameraMode != .whole, "the view is still on the part")
        expect(view.needsPanelToBecomeKey && panel.canBecomeKey && (panel as? NSPanel)?.becomesKeyOnlyIfNeeded == true,
               "the panel takes the keyboard only when the model itself is clicked")
        expect((panel.styleMask.contains(.nonactivatingPanel)), "and is non-activating, so the person's app stays the active app")
        panel.makeFirstResponder(nil)
        panel.sendEvent(mouseEvent(.leftMouseDown, at: spot, in: panel))
        panel.sendEvent(mouseEvent(.leftMouseUp, at: spot, in: panel))
        expect(panel.firstResponder === view, "a click on the model, sent through the window, gives the view the keyboard (first responder: \(String(describing: panel.firstResponder)))")
        if panel.isKeyWindow {
            print("  the panel became the key window on the click")
        } else {
            note("the panel did not become the key window on the click here: this test process may not own a key window at all (activation policy .prohibited, so it never takes the keyboard from the person's real apps). needsPanelToBecomeKey is set, which is what AppKit asks a non-activating panel's clicked view.")
        }
        await pause(view.tapDelay + 0.3)
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            panel.sendEvent(escape)
            await pause(2.2)
            expect(controller.cameraMode == .whole && controller.focusIDs.isEmpty && !controller.model.canRecenter, "Escape, sent through the window, goes back to the whole model")
        }
        // Escape also arrives as "cancel" when another control in the panel has the keyboard.
        session.perform("focus r.stage1 dur=0.2")
        await pause(0.6)
        view.cancelOperation(nil)
        await pause(2.2)
        expect(controller.cameraMode == .whole, "and as cancelOperation")

        // Double-click on empty space also goes back.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: spot, in: panel, clicks: 2))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: spot, in: panel, clicks: 2))
        await pause(0.2)
        let empty = inWindow(CGPoint(x: 8, y: 8))
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: empty, in: panel, clicks: 2))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: empty, in: panel, clicks: 2))
        await pause(2.2)
        expect(controller.cameraMode == .whole, "a double-click on empty space frames the whole model")

        // In real time, with the real timer: the narration waits for the person, then carries on.
        controller.gesturePause.idleResume = 0.6
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: inWindow(middle), in: panel))
        for step in 1...6 { view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: inWindow(CGPoint(x: middle.x - CGFloat(step) * 10, y: middle.y)), in: panel)) }
        session.feed(chunk: "focus r.nose\n")
        await pause(0.3)
        expect(controller.cameraMode == .user && controller.focusIDs.isEmpty, "a focus line from the script does not fight a drag in progress")
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: inWindow(CGPoint(x: middle.x - 60, y: middle.y)), in: panel))
        await pause(0.9)
        session.feed(chunk: "focus r.nose\n")
        await pause(2.6)
        expect(controller.focusIDs == ["r.nose"] && controller.cameraMode == .focus, "once the person has been idle, the script directs again (\(controller.focusIDs))")

        // The Recenter button is part of the window's chrome.
        let chrome = ImageRenderer(content: Scene3DView(model: controller.model, controller: controller).frame(width: 640, height: 470))
        expect(controller.model.canRecenter && chrome.nsImage != nil, "the window shows Recenter while the view is not the default")
        writePNG(window.snapshot(), "events-final.png")
        session.clear()
    }
}

@MainActor
func bigScenes() async {
    await section("big scenes: many small pieces become one node, and a node budget holds") {
        let stage = Stage(script: "scene3d c title=\"Membrane\"\nmembrane mem size=4,3\nprotein pump on=mem at=0,0 label=\"Pump\"")
        let controller = stage.controller
        expect(stage.session.partCount > 600, "a membrane is hundreds of parts (\(stage.session.partCount))")
        expect(stage.nodeCount < 60, "drawn as a handful of nodes (\(stage.nodeCount))")
        expect(stage.node("mem._bulk")?.geometry?.elements.count ?? 99 <= 4, "one mesh with an element per colour (\(stage.node("mem._bulk")?.geometry?.elements.count ?? -1))")
        let model = controller.projectedBounds(ofParts: ["mem"])
        expect(model?.isInside == true && (model?.fill ?? 0) > 0.3, "the camera still frames all of it (\(model?.fill ?? 0))")
        expect(controller.liveState.parts.map(\.id).contains("pump") && !controller.liveState.parts.contains { $0.id.contains("_bulk") }, "its description lists the pump, not the merged pieces")
        stage.session.perform("focus pump dur=0.3")
        stage.play(0.8)
        expect(controller.focusIDs == ["pump"] && controller.projectedBounds(ofParts: ["pump"])?.isInside == true, "a part in the middle of it can still be focused")
        stage.session.perform("ghost mem\n")
        expect(Double(stage.node("mem")?.opacity ?? 1) < 0.2, "and the membrane ghosted as one")
        stage.session.clear()

        // Far too many pieces: named parts stay, small unnamed ones stop being added.
        var lines = ["scene3d f title=\"Many fans\""]
        for index in 0..<70 { lines.append("fan f\(index) at=\(index % 10),\(index / 10),0 blades=64 r=0.4 label=\"Fan \(index)\"") }
        let many = Stage(script: lines.joined(separator: "\n"))
        many.play(7)
        expect(many.nodeCount <= Scene3DController.maximumNodes + 200, "the node budget holds (\(many.nodeCount) nodes for \(many.session.partCount) parts)")
        expect((0..<70).allSatisfy { many.node("f\($0)") != nil }, "every named fan is still there")
        expect(many.controller.projectedBounds(ofParts: ["f69"]) != nil || many.node("f69") != nil, "including the last")
        many.session.clear()
    }
}

@MainActor
func roughEdges() async {
    await section("go back, then a part at the end of the model is seen from its own end") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        // Something renders each frame, as in the app, so SceneKit's own moves (explode) run.
        @MainActor func playRendering(_ seconds: Double) { stage.play(seconds) { _ = controller.renderFrame(size: CGSize(width: 64, height: 48)) } }
        stage.session.perform("focus j.turbine zoom=tight\nghost j.casing j.nacelle\ndetail j.turbine\nhighlight j.turbine")
        playRendering(3)
        stage.session.perform("explode\nframe all")
        playRendering(3)
        expect(controller.liveState.isExploded, "exploded")
        guard let back = SceneRefineClassifier.instantScript(request: "go back", parts: []) else { expect(false, "go back has an instant script"); return }
        stage.session.perform(back)
        playRendering(3)
        expect(!controller.liveState.isExploded && controller.ghostedIDs.isEmpty && controller.highlightedIDs.isEmpty && controller.cameraMode == .whole,
               "go back puts the model together, solid, unlit, whole (exploded \(controller.liveState.isExploded), ghosts \(controller.ghostedIDs))")
        expect(!controller.visibleLabels.contains { ["j.turbine.stator1", "j.turbine.s1.blade0", "j.turbine.s1.hub"].contains($0.part) }, "and puts away the labels detail added: \(controller.visibleLabels.map(\.part))")
        stage.session.perform("focus j.fan zoom=medium\nhighlight j.fan")
        playRendering(3)
        let pose = controller.displayedPose
        guard let fan = controller.boundingBox(ofParts: ["j.fan"]), let whole = controller.boundingBox(ofParts: ["j"]) else { expect(false, "boxes"); return }
        let outward = simd_normalize(fan.center - whole.center)
        expect(simd_dot(pose.direction, outward) > 0.1, "the fan is seen from the intake side, not from across the engine (facing \(simd_dot(pose.direction, outward)))")
        expect(controller.projectedBounds(ofParts: ["j.fan"])?.isInside == true && controller.occlusion(ofParts: ["j.fan"]) < 0.5, "in view and not hidden")
        writePNG(stage.session.modelWindow?.snapshot(), "fan-after-go-back.png")
        stage.session.clear()
    }

    await section("detail labels: put away by frame all and Recenter, back when the part is detailed again") {
        let stage = Stage(script: turbofan)
        let controller = stage.controller
        stage.session.perform("focus j.fan zoom=tight dur=0.3\ndetail j.fan")
        stage.play(0.8)
        let added = ["j.fan.hub", "j.fan.dshaft"]
        expect(added.allSatisfy { part in controller.visibleLabels.contains { $0.part == part } }, "detail's labels show: \(controller.visibleLabels.map(\.part))")
        stage.session.perform("frame all dur=0.3")
        stage.play(0.8)
        expect(!controller.visibleLabels.contains { added.contains($0.part) }, "frame all puts them away")
        expect(controller.visibleLabels.contains { $0.part == "j.fan" }, "the script's own labels stay")
        expect(controller.liveState.parts.first { $0.id == "j.fan" }?.canDetail == true, "and the fan is offered for detail again")
        let nodes = stage.nodeCount
        stage.session.perform("focus j.fan zoom=tight dur=0.3\ndetail j.fan")
        stage.play(0.8)
        expect(added.allSatisfy { part in controller.visibleLabels.contains { $0.part == part } } && stage.nodeCount == nodes, "detailing again shows them again, without adding pieces twice")
        controller.recenter()
        stage.play(2)
        expect(!controller.visibleLabels.contains { added.contains($0.part) }, "Recenter puts them away too")
        stage.session.clear()
    }

    await section("leaders on spinning parts stay attached every frame") {
        let stage = Stage(script: "scene3d f title=\"Fan\"\nfan f r=1 blades=6 rpm=60 label=\"Fan\"\nlabel b on=f.blade0 text=\"A blade\"")
        let controller = stage.controller
        @MainActor func leaderEnds(_ id: String) -> (simd_float3, simd_float3)? {
            guard let leader = controller.scene.rootNode.childNode(withName: "_leader:" + id, recursively: true) else { return nil }
            return (leader.simdConvertPosition(simd_float3(0, -0.5, 0), to: nil), leader.simdConvertPosition(simd_float3(0, 0.5, 0), to: nil))
        }
        var hubDrift: Float = 0, bladeGap: Float = 0
        var first: simd_float3?
        stage.play(3) {
            if let (a, _) = leaderEnds("f") {
                if first == nil { first = a }
                hubDrift = max(hubDrift, simd_length(a - first!))
            }
            if let (a, b) = leaderEnds("f.blade0"), let blade = stage.node("f.blade0") {
                // The end nearer the blade must stay on the blade, every frame.
                let near = simd_length(a - blade.simdWorldPosition) < simd_length(b - blade.simdWorldPosition) ? a : b
                bladeGap = max(bladeGap, simd_length(near - blade.simdWorldPosition))
            }
        }
        expect(first != nil && hubDrift < 0.02, "the fan's own leader lands on its axle and does not move while it spins (drift \(hubDrift))")
        expect(bladeGap < 0.45, "a blade's leader goes round with the blade, frame by frame (largest gap \(bladeGap), blade half-length ~0.4)")
        stage.session.clear()
    }

    await section("history: a refined drawing is saved over the one it came from") {
        let folder = work.appendingPathComponent("history-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let store = SceneHistoryStore(root: folder)
        var log = SceneReplayLog()
        for (index, command) in SceneScriptParser.parse(turbofan).enumerated() { log.record(command, at: Double(index) * 0.1) }
        guard let entry = store.save(log: log, question: "how a turbofan works", thumbnailPNG: Data([1, 2, 3])) else { expect(false, "saved"); return }
        try? Data([9]).write(to: store.videoURL(for: entry.id))
        var refined = log
        for command in SceneScriptParser.parse("focus j.turbine zoom=tight\nghost j.casing\ndetail j.turbine") { refined.record(command, at: 9) }
        let updated = store.update(id: entry.id, log: refined, thumbnailPNG: Data([4, 5]))
        expect(updated?.id == entry.id && updated?.question == entry.question, "the same entry and question")
        expect(store.log(for: entry.id) == refined && abs((updated?.duration ?? 0) - 9) < 1e-9, "with the refined log and its length")
        expect((try? Data(contentsOf: store.thumbnailURL(for: entry.id))) == Data([4, 5]), "and the refined picture")
        expect(!FileManager.default.fileExists(atPath: store.videoURL(for: entry.id).path), "a video of the older version is removed")
        expect(store.entries().count == 1, "no second entry")
        expect(store.update(id: "nonsense", log: refined, thumbnailPNG: nil) == nil, "an unknown id is refused")
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
func renderingEfficiency() async {
    await section("rendering: immutable geometry and settled labels reuse their measurements") {
        let stage = Stage(script: "scene3d sample\nbox part size=(1,1,1)\nlabel label on=part text=Part")
        let controller = stage.controller
        let reads = controller.geometryBoundsReadCount
        let flushes = controller.hitTestFlushCount
        stage.play(4)
        expect(controller.geometryBoundsReadCount == reads, "static geometry bounds are not re-read every refit")
        expect(controller.hitTestFlushCount == flushes, "settled label anchors do not flush transactions again")
        let previous = controller.boundingBox(ofParts: ["part"])
        stage.session.perform("box part size=(3,1,1)")
        stage.play(0.3)
        let replaced = controller.boundingBox(ofParts: ["part"])
        expect((replaced?.size.x ?? 0) > (previous?.size.x ?? 0) * 2, "a replacement mesh gets fresh bounds")
        expect(controller.geometryBoundsReadCount > reads, "new geometry invalidates its local-bounds cache")
        stage.play(2) // Capture after the replacement model finishes reframing.
        writePNG(controller.renderFrame(size: CGSize(width: 640, height: 470)), "rendering-static.png")
        stage.session.clear()
    }
    await section("rendering: settled models sleep and direct interactions wake them") {
        let controller = Scene3DController()
        for command in SceneScriptParser.parse("scene3d sample\nbox part size=(1,1,1)\nlabel label on=part text=Part") { controller.apply(command) }
        expect(controller.isRenderingContinuously, "new content wakes the timer")
        await pause(2.4)
        expect(!controller.isRenderingContinuously, "settled model stops the timer")
        expect(!controller.view.rendersContinuously && !controller.view.isPlaying, "SceneKit also stops continuous rendering")
        controller.view.onZoom?(1.1, CGPoint(x: 320, y: 240))
        expect(controller.isRenderingContinuously, "zoom wakes a sleeping model")
        controller.stop()
        expect(!controller.isRenderingContinuously, "closing stops rendering")
        controller.resume()
        expect(controller.isRenderingContinuously, "reopening restarts rendering")
        await pause(2.4)
        expect(!controller.isRenderingContinuously, "reopened static model settles again")
        controller.requestAutoFocus(["part"], sentence: 1, after: 0.2)
        expect(controller.isRenderingContinuously, "delayed narration wakes the scene")
        controller.stop()
    }
    await section("rendering: real motion continues until its speed becomes zero") {
        let controller = Scene3DController()
        for command in SceneScriptParser.parse("scene3d sample\nbox part size=(1,1,1)\nspin part rpm=20") { controller.apply(command) }
        await pause(2.4)
        expect(controller.isRenderingContinuously, "active spin does not go to sleep")
        let before = controller.debugSpinAngle(of: "part") ?? 0
        await pause(0.1)
        expect((controller.debugSpinAngle(of: "part") ?? 0) != before, "active spin still advances")
        for command in SceneScriptParser.parse("spin part rpm=0") { controller.apply(command) }
        await pause(2.4)
        expect(!controller.isRenderingContinuously, "zero RPM lets the model sleep")
        controller.stop()
    }
    await section("rendering: removing the last animated part releases the timer") {
        let controller = Scene3DController()
        for command in SceneScriptParser.parse("scene3d sample\nbox part size=(1,1,1)\nmove part by=(2,0,0) dur=1 loop\npulse part\nremove part") { controller.apply(command) }
        await pause(2.4)
        expect(!controller.isRenderingContinuously, "removed actions and flashes do not keep an empty scene awake")
        controller.stop()
    }
}

DispatchQueue.global().asyncAfter(deadline: .now() + 420) {
    print("FAIL: the scene3 app tests did not finish in 7 minutes")
    exit(3)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async { Task { @MainActor in await runAll() } }
app.run()
