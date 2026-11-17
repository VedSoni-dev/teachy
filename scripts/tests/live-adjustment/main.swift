import Foundation
import simd
#if LIVE_ENGINE
import AppKit
import SceneKit
#endif

#if LIVE_ENGINE
@MainActor
#endif
func runChecks() {
    var checks = 0
    func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { print("FAIL: \(message)"); exit(1) }
    }
    func plan(_ request: String, rate: Double = 1, resume: Double = 1) -> SceneLiveAdjustment? {
        SceneLiveAdjustment.plan(request: request, sceneIsLive: true, motionRate: rate, resumeRate: resume)
    }
    for request in ["Zoom in!", "Please zoom out", "Can you recenter it please?", "slow it down", "speed it up", "pause motion", "resume the animation", "normal speed"] {
        guard let adjustment = plan(request) else { fatalError("Missing plan: \(request)") }
        let commands = SceneScriptParser.parse(adjustment.script)
        expect(commands.count == 1, "one valid command: \(request)")
        expect(!commands.contains { $0.verb.makes3DPart }, "never rebuilds: \(request)")
    }
    for request in ["slow my computer", "make a rocket instead", "draw a new diagram", "show airflow", "zoom in and explain airflow", "don't zoom in", "pause my music", "resume my download", "slow your voice down", "zoom in on a new diagram", "", "what is motion"] {
        expect(plan(request) == nil, "normal route retained: \(request)")
    }
    expect(SceneLiveAdjustment.plan(request: "zoom in", sceneIsLive: false) == nil, "no scene means no control")
    expect(SceneRefineClassifier.classify(request: "show the airflow", sceneIsLive: true, title: "Jet turbine", parts: []).isRefine, "airflow augments the live drawing")
    expect(!SceneRefineClassifier.classify(request: "show airflow in a new rocket", sceneIsLive: true, title: "Jet turbine", parts: []).isRefine, "new flow subject still creates its own drawing")
    func rate(_ request: String, current: Double = 1, resume: Double = 1) -> Double? {
        plan(request, rate: current, resume: resume).flatMap { SceneScriptParser.parse($0.script).first?.number("value") }
    }
    expect(rate("slow it down") == 0.5, "halve rate")
    expect(rate("slow it down", current: 0.125) == 0.125, "lower bound")
    expect(rate("speed it up", current: 4) == 4, "upper bound")
    expect(rate("pause motion", current: 0.5) == 0, "pause")
    expect(rate("resume motion", current: 0, resume: 0.5) == 0.5, "restore previous pace")
    expect(rate("resume motion", current: .nan, resume: .infinity) == 1, "finite fallback")
    expect(plan("recenter")?.script.contains("hold") == true, "explicit framing wins")
    
    for degrees in [SceneVec3(15, 25, -35), SceneVec3(0, 90, 0), SceneVec3(90, 0, 0), SceneVec3(0, 0, -90)] {
        let original = SceneOrientation.euler(degrees: degrees)
        let recovered = SceneOrientation.euler(degrees: SceneLiveState.rotationDegrees(original))
        expect(abs(simd_dot(original.vector, recovered.vector)) > 0.999999, "snapshot rotation round-trips command convention")
    }
    #if LIVE_ENGINE
    let controller = Scene3DController(headless: true)
    func apply(_ script: String) {
        for command in SceneScriptParser.parse(script) { controller.apply(command) }
    }
    apply("scene3d test\nbox rotor size=(1,1,1)\nspin rotor rpm=20\nbox traveler at=(2,0,0) size=(0.2,0.2,0.2)\nmove traveler by=(1,0,0) loop")
    controller.advance(by: 0.5)
    let firstAngle = controller.debugSpinAngle(of: "rotor")!
    let node = controller.scene.rootNode.childNode(withName: "rotor", recursively: true)!
    let originalGeometry = node.geometry
    let traveler = controller.scene.rootNode.childNode(withName: "traveler", recursively: true)!
    apply(plan("slow it down")!.script)
    expect(controller.motionRate == 0.5, "global control needs no slider")
    expect(controller.model.sliders.isEmpty, "no artificial control slider")
    expect(controller.scene.physicsWorld.speed == 0.5, "physics shares pace")
    expect(traveler.action(forKey: "move")?.speed == 0.5, "SceneKit actions share pace")
    controller.advance(by: 0.5)
    let secondAngle = controller.debugSpinAngle(of: "rotor")!
    expect(abs((secondAngle - firstAngle) - firstAngle / 2) < 1e-6, "actual rotation at half pace")
    apply(plan("pause motion", rate: 0.5)!.script)
    controller.advance(by: 1)
    expect(controller.debugSpinAngle(of: "rotor") == secondAngle, "pause freezes rotation")
    expect(controller.resumeMotionRate == 0.5, "pause remembers pace")
    expect(traveler.action(forKey: "move")?.speed == 0, "pause freezes actions")
    apply(plan("zoom in")!.script)
    controller.advance(by: 0.5)
    expect(controller.motionRate == 0, "camera works without resuming motion")
    apply(plan("resume motion", rate: controller.motionRate, resume: controller.resumeMotionRate)!.script)
    controller.advance(by: 0.5)
    expect(controller.debugSpinAngle(of: "rotor")! > secondAngle, "resume restarts motion")
    expect(node.geometry === originalGeometry, "adjustments preserve geometry identity")
    expect(controller.view.preferredFramesPerSecond == 30 && Scene3DController.liveFramesPerSecond == 30, "live renderer and timer share 30 FPS cap")
    apply("group assembly at=(10,0,0)\nbox unnamed parent=assembly at=(0,0,0) size=(1,1,1)")
    let edited = controller.scene.rootNode.childNode(withName: "unnamed", recursively: true)!
    let shape = edited.geometry
    apply("set unnamed at=(1,2,3) rotation=(0,90,0) scale=(2,2,2)")
    expect(edited === controller.scene.rootNode.childNode(withName: "unnamed", recursively: true) && edited.geometry === shape, "transform command preserves existing node and geometry")
    let livePart = controller.liveState.parts.first { $0.id == "unnamed" }!
    expect(livePart.parent == "assembly" && livePart.position == SceneVec3(1,2,3), "snapshot includes unlabelled part and current parent-local position")
    expect(livePart.worldPosition == SceneVec3(11,2,3) && livePart.scale == SceneVec3(2,2,2), "snapshot exposes real world transform and scale")
    expect(abs((livePart.rotation?.y ?? 0) - 90) < 0.05, "snapshot rotation uses degrees")
    expect(livePart.geometry == "box" && livePart.boundsLow != nil, "snapshot includes geometry type and world bounds")
    apply("hide assembly")
    expect(controller.liveState.parts.first { $0.id == "unnamed" }?.isHidden == true, "child snapshot includes inherited visibility")
    apply("show assembly\nset unnamed color=red opacity=0.5")
    expect(controller.liveState.parts.first { $0.id == "unnamed" }?.colour == "red" && controller.liveState.parts.first { $0.id == "unnamed" }?.opacity == 0.5, "material edit appears in authoritative state")
    func allowed(_ text: String) -> Bool { SceneScriptParser.parse(text).first.map { controller.canApplyCanvasCommand($0) } ?? false }
    expect(!allowed("set missing at=0,0,0"), "unknown edit target rejected")
    expect(!allowed("set unnamed scale=0,1,1"), "degenerate scale rejected")
    expect(!allowed("set unnamed rotation=90"), "malformed transform rejected")
    expect(!allowed("box unnamed size=5,5,5"), "shape command cannot replace an existing part")
    expect(!allowed("sphere fresh parent=missing r=1"), "unknown parent rejected")
    expect(allowed("arrow3 fresh from=0,0,0 to=1,0,0"), "fresh explanatory geometry accepted")
    expect(allowed("set scene-motion bind=timescale value=0.5"), "global speed command accepted")
    expect(controller.canApplyCanvasCommand(SceneScriptParser.parse("label lab on=fresh text=Flow")[0], additionalPartIDs: ["fresh"]), "batch can label a newly added part")
    apply("set rotor rotation=0,0,90")
    let fixedOrientation = node.simdOrientation
    controller.advance(by: 0.5)
    expect(node.simdOrientation == fixedOrientation, "orientation edits stay fixed instead of spinning back")
    let stateText = controller.liveState.text(limit: 1, maximumCharacters: 1600, matching: "unnamed")
    expect(stateText.contains("unnamed") && stateText.count <= 1600 && stateText.contains("omitted"), "bounded snapshot prioritizes requested part")
    apply("remove assembly")
    expect(!controller.liveState.parts.contains { $0.id == "unnamed" }, "deleting parent removes non-dotted descendant IDs too")
    controller.reset()
    expect(controller.motionRate == 1 && controller.resumeMotionRate == 1, "new scene resets motion")
    #endif
    print("Passed \(checks) live adjustment checks")
}

#if LIVE_ENGINE
MainActor.assumeIsolated { runChecks() }
#else
runChecks()
#endif
