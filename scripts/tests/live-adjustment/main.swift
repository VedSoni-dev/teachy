import Foundation
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
