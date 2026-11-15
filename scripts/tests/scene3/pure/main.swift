//
//  Pure tests for the 3D camera that directs itself: which parts a sentence is about, refine
//  or redraw, the framing maths, which side to look from, calm-movement rules, the
//  person-always-wins pause, the new script verbs, detail on demand, and the replay log.
//
//  Run with scripts/tests/run_scene3_tests.sh. No AppKit, no network.
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

func section(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

let jetParts = [
    SceneSubjectCandidate(id: "j", name: "Jet engine"),
    SceneSubjectCandidate(id: "j.nacelle", name: "Nacelle"),
    SceneSubjectCandidate(id: "j.casing", name: "Core casing"),
    SceneSubjectCandidate(id: "j.fan", label: "Fan", name: "Fan"),
    SceneSubjectCandidate(id: "j.compressor", label: "Compressor", name: "Compressor"),
    SceneSubjectCandidate(id: "j.combustor", label: "Combustor", name: "Combustor"),
    SceneSubjectCandidate(id: "j.turbine", name: "Turbine"),
    SceneSubjectCandidate(id: "j.nozzle", label: "Exhaust nozzle", name: "Exhaust nozzle"),
    SceneSubjectCandidate(id: "air", label: "Air"),
]
let lens = SceneLens(fieldOfView: 30, aspect: 640.0 / 470.0)

// MARK: - What a sentence is about

section("subject matcher: the part a sentence names") {
    expect(SceneSubjectMatcher.match(sentence: "The compressor squeezes the air.", parts: jetParts) == ["j.compressor"],
           "\"the compressor squeezes the air\" is about the compressor: \(SceneSubjectMatcher.match(sentence: "The compressor squeezes the air.", parts: jetParts))")
    expect(SceneSubjectMatcher.match(sentence: "THE FANS pull air in", parts: jetParts) == ["j.fan"], "case and plural are ignored")
    expect(SceneSubjectMatcher.match(sentence: "Hot gas spins the turbine, then leaves through the nozzle.", parts: jetParts) == ["j.turbine", "j.nozzle"],
           "an unlabelled part is found by its id and name; \"the nozzle\" finds \"Exhaust nozzle\"; order follows the sentence")
    expect(SceneSubjectMatcher.match(sentence: "This part is on the inside, at the back.", parts: jetParts).isEmpty, "little and general words pick nothing")
    expect(SceneSubjectMatcher.match(sentence: "The engine's compressor and its combustor.", parts: jetParts) == ["j.compressor", "j.combustor"], "possessives are folded")
    expect(SceneSubjectMatcher.match(sentence: "", parts: jetParts).isEmpty, "an empty sentence")
    expect(SceneSubjectMatcher.match(sentence: "fan compressor combustor turbine nozzle", parts: jetParts, limit: 2).count == 2, "the limit holds")

    let blades = [SceneSubjectCandidate(id: "f", label: "Fan"), SceneSubjectCandidate(id: "f.b", label: "Fan blade"), SceneSubjectCandidate(id: "h", label: "Hub")]
    expect(SceneSubjectMatcher.match(sentence: "The fan blades are pitched like wings.", parts: blades) == ["f.b"], "the longest label wins over a shorter one on the same words")
    expect(SceneSubjectMatcher.match(sentence: "The fan turns on its hub.", parts: blades) == ["f", "h"], "the shorter label still matches on its own")

    let heart = [SceneSubjectCandidate(id: "h.lv", label: "Left ventricle"), SceneSubjectCandidate(id: "h.rv", label: "Right ventricle"),
                 SceneSubjectCandidate(id: "h.aorta", name: "Aorta"), SceneSubjectCandidate(id: "h.pulmonary", label: "Pulmonary arteries")]
    expect(SceneSubjectMatcher.match(sentence: "The left ventricle pumps it through the aorta.", parts: heart) == ["h.lv", "h.aorta"], "two-word labels match whole")
    expect(SceneSubjectMatcher.match(sentence: "Blood leaves through the pulmonary artery.", parts: heart) == ["h.pulmonary"], "\"artery\" matches \"arteries\"")

    expect(SceneSubjectMatcher.idWords("leftVentricle") == ["left", "ventricle"], "camel case ids split: \(SceneSubjectMatcher.idWords("leftVentricle"))")
    expect(SceneSubjectMatcher.idWords("usb_port2") == ["usb", "port"], "underscores and digits split")
    expect(SceneSubjectMatcher.idWords("j.turbine.s1").isEmpty, "only the last dotted piece counts, and \"s1\" means nothing")
    expect(SceneSubjectMatcher.stem("boxes") == "box" && SceneSubjectMatcher.stem("gas") == "gas" && SceneSubjectMatcher.stem("glass") == "glass", "plural folding leaves short and -ss words alone")
}

section("sentence subject: its own lines first, then its words") {
    let labelled = SceneScriptParser.parse("label a on=j.fan text=\"Fan\" n=1\npulse j.combustor")
    expect(SceneSentenceSubject.infer(sentence: "The combustor burns fuel.", commands: labelled, candidates: jetParts) == ["j.fan"], "a part the sentence labels is its subject")
    let acted = SceneScriptParser.parse("pulse j.combustor")
    expect(SceneSentenceSubject.infer(sentence: "Fuel burns here.", commands: acted, candidates: jetParts) == ["j.combustor"], "then a part it pulses")
    let built = SceneScriptParser.parse("box cpu at=0,0,0 size=1,1,1")
    expect(SceneSentenceSubject.infer(sentence: "And here is the brain.", commands: built, candidates: []) == ["cpu"], "then a part it creates")
    expect(SceneSentenceSubject.infer(sentence: "The compressor squeezes the air.", commands: [], candidates: jetParts) == ["j.compressor"], "with no lines, its words")
    let whole = SceneScriptParser.parse("scene3d t title=\"x\"\njet j")
    expect(["j"].starts(with: SceneSentenceSubject.infer(sentence: "A jet engine makes thrust.", commands: whole, candidates: jetParts)), "the sentence that builds the whole model is about the whole model, not a piece of it")
    let tour = SceneScriptParser.parse("label a on=j.fan text=\"Fan\"\nlabel b on=j.compressor text=\"C\"\nlabel c on=j.combustor text=\"B\"\nlabel d on=j.turbine text=\"T\"\nlabel e on=j.nozzle text=\"N\"")
    expect(SceneSentenceSubject.infer(sentence: "Here are the main parts.", commands: tour, candidates: jetParts).isEmpty, "five labels in one sentence is a tour of the whole")
    expect(SceneSentenceSubject.infer(sentence: "Here are the parts; look at the turbine.", commands: tour, candidates: jetParts) == ["j.turbine"], "unless the words single one out")
    expect(SceneSentenceSubject.hasCameraDirection(SceneScriptParser.parse("focus j.fan")), "a focus line is camera direction")
    expect(SceneSentenceSubject.hasCameraDirection(SceneScriptParser.parse("frame all")), "so is frame all")
    expect(SceneSentenceSubject.hasCameraDirection(SceneScriptParser.parse("orbit j.fan deg=90")), "and a camera orbit")
    expect(!SceneSentenceSubject.hasCameraDirection(SceneScriptParser.parse("orbit earth around=sun period=8\nlabel a on=x text=\"y\"\nhighlight j.fan")), "a planet's orbit, a label and a highlight are not")
    expect(!SceneSentenceSubject.hasCameraDirection(SceneScriptParser.parse("focus j.fan zoom=medium auto")), "a move the engine wrote itself does not count as the script directing")
}

// MARK: - Refine or redraw

section("refine classifier: adjust the drawing on screen, or draw a new one") {
    func decide(_ request: String, live: Bool = true) -> SceneRefineDecision {
        SceneRefineClassifier.classify(request: request, sceneIsLive: live, title: "How a turbofan works", parts: jetParts)
    }
    func refines(_ request: String) -> [String]? {
        if case .refine(let parts, _) = decide(request) { return parts }
        return nil
    }
    expect(!decide("zoom in on the turbine", live: false).isRefine, "nothing on screen: always a new drawing")
    expect(refines("zoom in on the turbine") == ["j.turbine"], "zoom in on a part")
    expect(refines("show me inside") == [], "show me inside")
    expect(refines("what's that orange part") == [], "a part asked about by colour")
    expect(refines("what is that orange thing?") != nil, "…in other words")
    expect(refines("rotate it") != nil && refines("explode it") != nil && refines("go back") != nil && refines("zoom out") != nil, "rotate, explode, go back, zoom out")
    expect(refines("take it apart") != nil && refines("turn it around so I can see the other side") != nil, "take it apart, other side")
    expect(refines("what does the compressor do") == ["j.compressor"], "a question that names a part")
    expect(refines("how does the turbine in a jet engine work") == ["j.turbine"], "a question about a part of the thing on screen")
    expect(refines("tell me more about the turbofan") != nil, "more about the thing in the title")
    expect(refines("explain it again") != nil, "a short request about \"it\"")
    expect(refines("hide the nacelle") == ["j.nacelle"], "hide a part")

    expect(!decide("draw a DNA double helix").isRefine, "draw something else")
    expect(!decide("show me how a piston engine works").isRefine, "a different machine")
    expect(!decide("show me the inside of a rocket").isRefine, "camera words, but about a thing this model is not")
    expect(!decide("explain the chain rule on a card").isRefine, "a card")
    expect(!decide("now show me a suspension bridge instead").isRefine, "instead")
    expect(!decide("how does a bicycle drivetrain work").isRefine, "nothing ties it to the model")
    expect(!decide("bar chart of planets by moons").isRefine, "a chart")
    expect(!decide("").isRefine, "an empty request")
    expect(refines("draw the turbine bigger") == ["j.turbine"], "\"draw\" with a part of this model still refines")

    expect(SceneRefineClassifier.instantScript(request: "zoom in on the turbine", parts: ["j.turbine"]) == "focus j.turbine zoom=tight", "zoom goes in tight, at once")
    expect(SceneRefineClassifier.instantScript(request: "what does the compressor do", parts: ["j.compressor"]) == "focus j.compressor zoom=medium", "a question about a part goes to it")
    let back = SceneRefineClassifier.instantScript(request: "go back", parts: []) ?? ""
    expect(back.hasSuffix("frame all") && back.contains("explode dist=0") && back.contains("show all") && back.contains("highlight none"),
           "go back is the whole model at once, put back together, solid and unlit: \(back)")
    expect(SceneScriptParser.parse(back).count == 4, "as four lines that parse")
    expect(SceneRefineClassifier.instantScript(request: "explode it", parts: []) == nil, "nothing to do at once when no place is named")
}

// MARK: - Framing maths

section("framing: how far back for a box, a field of view and a fill") {
    // A thin square panel seen face on: the distance has a closed form.
    let panel = SceneBox(center: .zero, size: SceneVec3(2, 2, 0.0001))
    let faceOn = SceneVec3(0, 0, 1)
    let distance = SceneFraming.distance(for: panel, direction: faceOn, lens: lens, fill: 0.5)
    expect(close(distance, 1 / (lens.tanVertical * 0.5), 1e-3), "a 2×2 panel at half the shorter side: \(distance) vs \(1 / (lens.tanVertical * 0.5))")
    expect(close(SceneFraming.distance(for: panel, direction: faceOn, lens: lens, fill: 0.25), distance * 2, 1e-2), "half the fill is twice the distance")
    let wide = SceneLens(fieldOfView: 60, aspect: 640.0 / 470.0)
    expect(SceneFraming.distance(for: panel, direction: faceOn, lens: wide, fill: 0.5) < distance * 0.5, "a wider lens stands closer")
    let portrait = SceneLens(fieldOfView: 30, aspect: 0.5)
    expect(close(SceneFraming.distance(for: panel, direction: faceOn, lens: portrait, fill: 0.5), 1 / (portrait.tanHorizontal * 0.5), 1e-3), "in a tall picture the width is the shorter side")

    // Whatever the box and the side, the subject ends up in view at about the fill asked for.
    var rng = SceneRNG(seed: 7)
    var worstLow = 1.0, worstHigh = 0.0
    for _ in 0..<400 {
        let box = SceneBox(center: SceneVec3(rng.range(-3, 3), rng.range(-3, 3), rng.range(-3, 3)), size: SceneVec3(rng.range(0.1, 4), rng.range(0.1, 4), rng.range(0.1, 4)))
        let direction = SceneCameraPose.direction(azimuth: rng.range(-3, 3), elevation: rng.range(-0.2, 1.2))
        for zoom in SceneZoom.allCases {
            let pose = SceneFraming.pose(framing: box, direction: direction, lens: lens, fill: zoom.fill)
            let projection = SceneFraming.project(box, pose: pose, lens: lens)
            expect(projection.isInside, "the box is fully in the picture")
            expect(projection.fill <= zoom.fill + 1e-6, "never bigger than asked: \(projection.fill) vs \(zoom.fill)")
            expect(SceneFraming.sensibleFill.contains(projection.fill) || projection.fill > 0.17, "a sensible share of the shorter side: \(projection.fill)")
            worstLow = min(worstLow, projection.fill / zoom.fill)
            worstHigh = max(worstHigh, projection.fill / zoom.fill)
            expect(abs(projection.center.x) < 0.2 && abs(projection.center.y) < 0.2, "and near the middle")
            expect(pose.distance > box.radius * 0.5, "the camera is outside the box")
        }
    }
    expect(worstLow > 0.55 && worstHigh <= 1 + 1e-6, "fill lands between \(worstLow) and \(worstHigh) of the target")

    let box = SceneBox(center: SceneVec3(1, 0, 0), size: SceneVec3(1, 1, 1))
    let direction = SceneCameraPose.direction(azimuth: 0.5, elevation: 0.3)
    let good = SceneFraming.pose(framing: box, direction: direction, lens: lens, fill: 0.5)
    expect(SceneFraming.isWellFramed(box, pose: good, lens: lens, zoom: .medium), "the framing pose is well framed")
    var far = good
    far.distance *= 4
    expect(!SceneFraming.isWellFramed(box, pose: far, lens: lens, zoom: .medium), "four times as far is too small")
    var off = good
    off.center += SceneVec3(0, 1.6, 0)
    expect(!SceneFraming.isWellFramed(box, pose: off, lens: lens, zoom: .medium), "well off-centre is not well framed")
    var near = good
    near.distance *= 0.45
    expect(!SceneFraming.isWellFramed(box, pose: near, lens: lens, zoom: .medium), "nor is cut off by the edges")
    expect(SceneZoom(script: "tight").fill > SceneZoom(script: nil).fill && SceneZoom(script: "wide").fill < SceneZoom.medium.fill, "tight > medium > wide")
    expect(SceneZoom.allCases.allSatisfy { SceneFraming.sensibleFill.contains($0.fill) }, "every zoom is within the sensible range")
}

section("pose: turntable, easing, interpolation") {
    let pose = SceneCameraPose(center: SceneVec3(1, 2, 3), azimuth: 0.5, elevation: 0.3, distance: 7)
    let again = SceneCameraPose(center: pose.center, direction: pose.direction, distance: pose.distance)
    expect(close(again.azimuth, 0.5) && close(again.elevation, 0.3), "a direction turns back into the same angles")
    expect(close(simd_length(pose.position - pose.center), 7), "the camera is `distance` from what it looks at")
    expect(SceneEasing.easeInOut(0) == 0 && SceneEasing.easeInOut(1) == 1 && close(SceneEasing.easeInOut(0.5), 0.5), "easing starts at 0, ends at 1, is half way at half time")
    expect(SceneEasing.easeInOut(0.1) < 0.02 && SceneEasing.easeInOut(0.9) > 0.98, "it starts and ends gently: \(SceneEasing.easeInOut(0.1))")
    var previous = 0.0
    var monotonic = true
    for step in 1...100 {
        let value = SceneEasing.easeInOut(Double(step) / 100)
        if value < previous { monotonic = false }
        previous = value
    }
    expect(monotonic, "and never goes backwards")
    let a = SceneCameraPose(center: .zero, azimuth: 3.0, elevation: 0, distance: 1), b = SceneCameraPose(center: SceneVec3(2, 0, 0), azimuth: -3.0, elevation: 0.4, distance: 3)
    let middle = SceneCameraPose.interpolate(a, b, 0.5)
    expect(abs(middle.azimuth) > 3.0, "the turn goes the short way round (through π, not through 0): \(middle.azimuth)")
    expect(close(middle.center.x, 1) && close(middle.distance, 2) && close(middle.elevation, 0.2), "centre, distance and elevation go straight")
    expect(pose.difference(from: pose, scale: 1) == 0 && pose.difference(from: b, scale: 1) > 1, "difference is zero for the same view")
}

// MARK: - Which side to look from

section("direction: the usual 3/4 view unless something is in the way") {
    let target = SceneBox(center: .zero, size: SceneVec3(1, 1, 1))
    let azimuth = 0.5, elevation = 0.3
    let open = SceneFraming.chooseDirection(target: target, occluders: [], azimuth: azimuth, elevation: elevation, lens: lens, fill: 0.5)
    expect(close(open.pose.azimuth, azimuth) && close(open.pose.elevation, elevation) && open.blocked == 0, "nothing in the way: the preferred view")

    // A wall between the preferred camera and the subject.
    let preferred = SceneCameraPose.direction(azimuth: azimuth, elevation: elevation)
    let wall = SceneOccluder(box: SceneBox(center: preferred * 2.2, size: SceneVec3(1.6, 1.6, 1.6)))
    let around = SceneFraming.chooseDirection(target: target, occluders: [wall], azimuth: azimuth, elevation: elevation, lens: lens, fill: 0.5)
    expect(around.blocked == 0, "a clear side is found")
    expect(!close(around.pose.azimuth, azimuth) || !close(around.pose.elevation, elevation), "and it is not the blocked one")
    expect(abs(SceneCameraPose.shortestTurn(from: azimuth, to: around.pose.azimuth)) < 0.6 || around.pose.elevation > elevation, "the nearest clear view is used, not the far side: az \(around.pose.azimuth) el \(around.pose.elevation)")
    expect(SceneOccluder.blockage(from: around.pose.position, to: target.center, occluders: [wall]) == 0, "the chosen line of sight misses the wall")

    // Walls on both sides too: the camera goes up.
    let ahead = SceneOccluder(box: SceneBox(center: preferred * 2.5, size: SceneVec3(1, 1, 1)))
    let left = SceneOccluder(box: SceneBox(center: SceneCameraPose.direction(azimuth: azimuth - 0.55, elevation: elevation) * 2.5, size: SceneVec3(1, 1, 1)))
    let right = SceneOccluder(box: SceneBox(center: SceneCameraPose.direction(azimuth: azimuth + 0.55, elevation: elevation) * 2.5, size: SceneVec3(1, 1, 1)))
    let over = SceneFraming.chooseDirection(target: target, occluders: [ahead, left, right], azimuth: azimuth, elevation: elevation, lens: lens, fill: 0.5)
    expect(over.blocked == 0 && over.pose.elevation > elevation + 0.2, "blocked ahead and both sides: look from higher (el \(over.pose.elevation))")

    // The subject is inside a shell: every side is blocked, so the preferred view is kept (and the shell gets ghosted).
    let shell = SceneOccluder(box: SceneBox(center: .zero, size: SceneVec3(3, 3, 3)))
    let inside = SceneFraming.chooseDirection(target: target, occluders: [shell], azimuth: azimuth, elevation: elevation, lens: lens, fill: 0.5)
    expect(inside.blocked == 1 && close(inside.pose.azimuth, azimuth), "inside a shell: blocked from everywhere, the preferred view stays")
    expect(SceneContainment.containers(of: "t", subject: target, among: [("shell", shell.box), ("t.child", target), ("far", SceneBox(center: SceneVec3(9, 0, 0), size: SceneVec3(1, 1, 1)))]) == ["shell"],
           "the shell is the subject's container")
    expect(SceneContainment.containers(of: "j.turbine", subject: target, among: [("j", shell.box), ("j.casing", shell.box)]) == ["j.casing"], "a part's own group is not its container")
    expect(!shell.box.contains(SceneBox(center: .zero, size: SceneVec3(2.95, 2.95, 2.95))), "a box of nearly the same size is not inside")

    // A see-through occluder hides less.
    let glass = SceneOccluder(box: wall.box, weight: 0.15)
    let through = SceneFraming.chooseDirection(target: target, occluders: [glass], azimuth: azimuth, elevation: elevation, lens: lens, fill: 0.5)
    expect(close(through.pose.azimuth, azimuth) && close(through.blocked, 0.15), "glass in front is not worth swinging round for")

    expect(SceneFraming.chooseDirection(blocked: [0.03, 0, 0, 0, 0]) == 0, "a sliver of blockage does not move the camera off the preferred view")
    expect(SceneFraming.chooseDirection(blocked: [1, 1, 0.5, 0, 1]) == 3, "the clearest view wins")
    expect(SceneFraming.chooseDirection(blocked: [1, 0.9, 0.6, 0.7]) == 2, "when nothing is clear, the least hidden")
    expect(SceneFraming.chooseDirection(blocked: [1, 0, 0]) == 1, "among equals, the earlier")
    expect(SceneFraming.candidateDirections(azimuth: azimuth, elevation: elevation).count >= 8, "a handful of candidates")
    // A disc is not shown edge on when a view of its face is about as clear.
    let disc = SceneBox(center: .zero, size: SceneVec3(0.2, 2, 2))
    expect(SceneFraming.edgeOnPenalty(for: disc, direction: SceneVec3(0, 0, 1)) > 0.25 && SceneFraming.edgeOnPenalty(for: disc, direction: SceneVec3(1, 0, 0)) == 0, "a disc seen edge on is penalised, face on is not")
    expect(SceneFraming.edgeOnPenalty(for: target, direction: SceneVec3(0, 0, 1)) == 0, "a cube has no bad side")
    expect(SceneFraming.chooseDirection(blocked: [0.2, 0, 0], extra: [0.02, 0.29, 0.05]) == 0, "a slightly blocked 3/4 view beats a clear edge-on one")

    // A part at one end of a long model is looked at from its own end.
    let engine = SceneBox(center: .zero, size: SceneVec3(4, 1.2, 1.2))
    let intake = SceneVec3(-1.8, 0, 0)
    let fromFront = SceneCameraPose.direction(azimuth: -0.6, elevation: 0.3), fromAcross = SceneCameraPose.direction(azimuth: 0.5, elevation: 0.3)
    expect(SceneFraming.facingPenalty(direction: fromFront, part: intake, model: engine) == 0, "seen from its own end: no penalty")
    expect(SceneFraming.facingPenalty(direction: fromAcross, part: intake, model: engine) > 0.05, "seen from across the model: a penalty (\(SceneFraming.facingPenalty(direction: fromAcross, part: intake, model: engine)))")
    expect(SceneFraming.facingPenalty(direction: SceneVec3(1, 0, 0), part: intake, model: engine) > SceneFraming.facingPenalty(direction: fromAcross, part: intake, model: engine), "seen from straight behind: more")
    expect(SceneFraming.facingPenalty(direction: fromAcross, part: SceneVec3(0.1, 0, 0), model: engine) == 0, "a part in the middle has no front")
    let extra = [fromAcross, SceneVec3(1, 0, 0), fromFront].map { SceneFraming.facingPenalty(direction: $0, part: intake, model: engine) }
    expect(SceneFraming.chooseDirection(blocked: [0.05, 0, 0], extra: extra) == 2, "between equally clear views, the one facing the part's front wins (\(extra))")

    let box = SceneBox(center: .zero, size: SceneVec3(2, 2, 2))
    expect(box.entry(ofSegmentFrom: SceneVec3(-5, 0, 0), to: SceneVec3(5, 0, 0)).map { close($0, 0.4) } ?? false, "a segment enters the box where it should")
    expect(box.entry(ofSegmentFrom: SceneVec3(-5, 3, 0), to: SceneVec3(5, 3, 0)) == nil, "and misses when it passes above")
    expect(box.entry(ofSegmentFrom: SceneVec3(-5, 0, 0), to: SceneVec3(-2, 0, 0)) == nil, "or stops short")
}

// MARK: - Calm movement

section("policy: dwell, one move per sentence, no fidgeting") {
    var policy = SceneCameraPolicy()
    expect(policy.decide(now: 0, sentence: 1, alreadyFramed: false, paused: false) == .move, "the first move is allowed")
    policy.noteMove(now: 0, sentence: 1)
    expect(policy.decide(now: 0.6, sentence: 1, alreadyFramed: false, paused: false) == .skipSentence, "never two moves in one sentence")
    expect(policy.decide(now: 5, sentence: 1, alreadyFramed: false, paused: false) == .skipSentence, "however long the sentence")
    expect(policy.decide(now: 0.6, sentence: 2, alreadyFramed: false, paused: false) == .wait(until: 1.2), "the next sentence waits out the dwell")
    expect(policy.decide(now: 1.19, sentence: 2, alreadyFramed: false, paused: false) == .wait(until: 1.2), "right up to it")
    expect(policy.decide(now: 1.21, sentence: 2, alreadyFramed: false, paused: false) == .move, "then moves")
    expect(policy.decide(now: 3, sentence: 2, alreadyFramed: true, paused: false) == .skipFramed, "a subject already well framed is left alone")
    expect(policy.decide(now: 3, sentence: 2, alreadyFramed: false, paused: true) == .skipPaused, "the person steering stops everything")
    expect(policy.decide(now: 3, sentence: 1, alreadyFramed: true, paused: true) == .skipPaused, "…before any other reason")
    policy.noteMove(now: 3, sentence: 2)
    expect(policy.decide(now: 3.5, sentence: nil, alreadyFramed: false, paused: false) == .wait(until: 4.2), "the return to the whole model at the end also waits its turn")
    expect(policy.decide(now: 4.3, sentence: nil, alreadyFramed: false, paused: false) == .move, "and then happens")
    policy.reset()
    expect(policy.decide(now: 4.31, sentence: 2, alreadyFramed: false, paused: false) == .move, "a new request starts afresh")
    var slow = SceneCameraPolicy(minimumDwell: 3)
    slow.noteMove(now: 10, sentence: 1)
    expect(slow.decide(now: 12, sentence: 2, alreadyFramed: false, paused: false) == .wait(until: 13), "the dwell can be changed")
}

section("gesture pause: the person always wins (injected clock)") {
    var pause = SceneGesturePause()
    expect(!pause.isPaused(now: 0) && !pause.hasTouched, "nothing touched: not paused")
    pause.began(now: 10)
    expect(pause.isPaused(now: 10) && pause.isPaused(now: 100), "paused for as long as a drag is held")
    pause.touched(now: 11.5)
    pause.ended(now: 12)
    expect(pause.isPaused(now: 12) && pause.isPaused(now: 16.9), "and for five seconds after it ends")
    expect(!pause.isPaused(now: 17.01), "then automatic moves may run again")
    pause.touched(now: 20)
    expect(pause.isPaused(now: 24.9) && !pause.isPaused(now: 25.1), "a scroll or a pinch (no begin and end) pauses the same way")
    pause.touched(now: 30)
    pause.touched(now: 33)
    expect(pause.isPaused(now: 37.9) && !pause.isPaused(now: 38.1), "each touch restarts the wait")
    pause.began(now: 40)
    pause.resume()
    expect(!pause.isPaused(now: 40) && !pause.hasTouched, "Recenter resumes at once, even mid-gesture")
    var quick = SceneGesturePause(idleResume: 1)
    quick.touched(now: 0)
    expect(quick.isPaused(now: 0.9) && !quick.isPaused(now: 1.1), "the idle time can be changed")
}

section("the person's hands: zoom toward the cursor, clamped; pan; turn") {
    let model = SceneBox(center: .zero, size: SceneVec3(4, 2, 2))
    let pose = SceneCameraPose(center: .zero, azimuth: 0.5, elevation: 0.3, distance: 10)
    let limits = SceneFraming.zoomLimits(model: model, wholeDistance: 10, pose: pose, lens: lens, surfaceAhead: nil)
    let cursor = SceneVec2(0.6, -0.4)
    let (right, up) = pose.basis
    let under = pose.center + right * (cursor.x * lens.tanHorizontal * pose.distance) + up * (cursor.y * lens.tanVertical * pose.distance)
    let zoomed = SceneFraming.zoom(pose, by: 1.5, toward: cursor, lens: lens, limits: limits)
    expect(close(zoomed.distance, 10 / 1.5, 1e-9), "zooming in by 1.5 brings the camera 1.5 times closer")
    let after = SceneFraming.project(under, pose: zoomed, lens: lens).ndc
    expect(close(after.x, cursor.x, 1e-6) && close(after.y, cursor.y, 1e-6), "the point under the cursor stays under the cursor: \(after)")
    let centred = SceneFraming.zoom(pose, by: 2, toward: .zero, lens: lens, limits: limits)
    expect(simd_length(centred.center - pose.center) < 1e-9, "zooming at the middle does not slide the view")

    var inward = pose
    for _ in 0..<200 { inward = SceneFraming.zoom(inward, by: 1.3, toward: .zero, lens: lens, limits: limits) }
    expect(close(inward.distance, limits.minimumDistance, 1e-9) && inward.distance > 0, "zooming in stops at the minimum: \(inward.distance)")
    var outward = pose
    for _ in 0..<200 { outward = SceneFraming.zoom(outward, by: 0.7, toward: cursor, lens: lens, limits: limits) }
    expect(close(outward.distance, limits.maximumDistance, 1e-9) && close(limits.maximumDistance, 30), "zooming out stops at three times the whole-model distance")
    let lost = SceneFraming.project(model, pose: outward, lens: lens)
    expect(!lost.behindCamera && lost.low.x < 1 && lost.high.x > -1 && lost.low.y < 1 && lost.high.y > -1, "and the model cannot be lost: it is still in the picture (\(lost.low)…\(lost.high))")

    // A surface 4 units ahead: the camera may come to just short of it, not through it.
    let guarded = SceneFraming.zoomLimits(model: model, wholeDistance: 10, pose: pose, lens: lens, surfaceAhead: 4)
    var through = pose
    for _ in 0..<50 { through = SceneFraming.zoom(through, by: 1.5, toward: .zero, lens: lens, limits: guarded) }
    expect(pose.distance - through.distance < 4, "the camera stops before the surface ahead (travelled \(pose.distance - through.distance) of 4)")
    expect(pose.distance - through.distance > 3.5, "but gets close to it")

    let panned = SceneFraming.pan(pose, by: SceneVec2(0.2, 0), lens: lens, limits: limits)
    expect(simd_dot(panned.center - pose.center, right) < 0, "dragging right slides the model right (the view left)")
    var away = pose
    for _ in 0..<100 { away = SceneFraming.pan(away, by: SceneVec2(0.5, 0.5), lens: lens, limits: limits) }
    let slidOff = SceneFraming.project(model, pose: away, lens: lens)
    expect(slidOff.low.x < 1 && slidOff.high.x > -1 && slidOff.low.y < 1 && slidOff.high.y > -1, "panning cannot push the model out of the picture (\(slidOff.low)…\(slidOff.high))")
    expect(simd_length(away.center - pose.center) > 1, "though it can slide it toward the edge")

    let turned = SceneFraming.turn(pose, azimuth: 0.4, elevation: 5)
    expect(close(turned.azimuth, 0.9) && close(turned.elevation, SceneCameraPose.maximumElevation), "turning adds to the angles and stops short of straight overhead")
    expect(close(SceneFraming.turn(pose, azimuth: 0, elevation: -5).elevation, -SceneCameraPose.maximumElevation), "and short of straight below")
}

// MARK: - The script

section("script: the camera and visibility verbs") {
    func one(_ line: String) -> SceneCommand? { SceneScriptParser.parse(line).first }
    let focus = one("focus j.fan,j.turbine zoom=tight dur=1.5")
    expect(focus?.verb == .focus && focus?.targetIDs == ["j.fan", "j.turbine"] && focus?.string("zoom") == "tight" && focus?.number("dur") == 1.5, "focus a,b zoom= dur=")
    expect(one("focus j.fan")?.targetIDs == ["j.fan"] && one("focus j.fan, j.turbine")?.targetIDs == ["j.fan", "j.turbine"], "one id, or a list with spaces")
    expect(one("focus")?.verb == nil, "focus with nothing to look at is dropped")
    expect(one("zoom turbine")?.verb == .focus, "\"zoom\" is focus")
    let frame = one("frame all")
    expect(frame?.verb == .frame && frame?.names("all") == true && frame?.targetIDs.isEmpty == true, "frame all")
    let orbit = one("orbit j.turbine deg=120 dur=4")
    expect(orbit?.isCameraOrbit == true && orbit?.movesCamera == true, "orbit with deg= swings the camera")
    expect(one("orbit earth around=sun period=8")?.isCameraOrbit == false, "orbit with around= is still a planet")
    expect(one("orbit all")?.isCameraOrbit == true, "orbit all turns round the whole model")
    let ghost = one("ghost j.nacelle j.casing opacity=0.2")
    expect(ghost?.verb == .ghost && ghost?.targetIDs == ["j.nacelle", "j.casing"] && ghost?.number("opacity") == 0.2, "ghost a b opacity=")
    expect(one("ghost others")?.names("others") == true && one("ghost others")?.targetIDs.isEmpty == true, "ghost others")
    expect(one("cutaway j.nacelle")?.verb == .ghost, "cutaway is ghost")
    expect(one("ghost")?.verb == nil, "ghost needs something")
    expect(one("hide a b")?.targetIDs == ["a", "b"] && one("show all")?.names("all") == true, "hide a b, show all")
    let glow = one("highlight j.turbine color=yellow")
    expect(glow?.isPartHighlight == true && glow?.targetIDs == ["j.turbine"], "highlight a part")
    expect(SceneRouter.surface(for: glow!, current: .scene3d) == .scene3d, "…goes to the 3D model")
    let swipe = one("highlight h from=100,200 to=300,220")
    expect(swipe?.isPartHighlight == false && SceneRouter.surface(for: swipe!, current: nil) == .overlay, "highlight from= to= is still a swipe on the screen")
    expect(one("detail j.fan")?.verb == .detail && one("detail")?.verb == nil, "detail needs a part")
    expect(one("camera to=1,2,3 look=0,0,0")?.movesCamera == true && one("label a on=b text=\"c\"")?.movesCamera == false, "movesCamera")
    for line in ["focus j.fan,j.turbine zoom=tight", "frame all", "orbit j.fan deg=90 dur=3", "ghost a b opacity=0.2", "ghost others", "highlight j.fan color=yellow", "detail j.fan", "focus j.fan zoom=medium auto", "show all"] {
        let first = one(line)
        let second = first.flatMap { one($0.scriptLine) }
        expect(first != nil && first?.verb == second?.verb && first?.targetIDs == second?.targetIDs && first?.args == second?.args && first?.flag("auto") == second?.flag("auto"),
               "\"\(line)\" survives being written out and read back: \(first?.scriptLine ?? "nil")")
    }
}

section("prompts: the examples parse, and a refine turn cannot rebuild the model") {
    for example in SceneScriptPrompt.examples + SceneRefinePrompt.examples {
        let parser = SceneScriptParser()
        _ = parser.feed(example) + parser.finish()
        expect(parser.stats.parseRate == 1, "example parses 100%: \(parser.rejections)")
    }
    expect(SceneRefinePrompt.examples.count == 2, "two examples in the refine prompt (\(SceneRefinePrompt.examples.count))")
    for example in SceneRefinePrompt.examples {
        for command in SceneScriptParser.parse(example) { expect(SceneRefinePrompt.allows(command), "the refine examples only use allowed lines: \(command.scriptLine)") }
    }
    expect(SceneScriptPrompt.system.contains("focus") && SceneScriptPrompt.system.contains("frame all") && SceneScriptPrompt.system.contains("ghost"), "the drawing prompt teaches the camera verbs")
    expect(SceneScriptPrompt.examples.contains { $0.contains("focus j.turbine") }, "with an example that opens on the part asked about")
    expect(SceneRefinePrompt.system.count < 2_600, "the refine prompt stays compact (\(SceneRefinePrompt.system.count) chars)")
    for line in ["scene3d t title=\"x\"", "jet j", "card c title=\"x\"", "clear", "gear g teeth=12", "slider s min=0 max=1 bind=g.rpm", "remove j.fan", "ring a at=1,2 r=3", "text \"hello\""] {
        if let command = SceneScriptParser.parse(line).first { expect(!SceneRefinePrompt.allows(command), "a refine turn drops \"\(line)\"") }
    }
    for line in ["say 1 \"Here.\"", "focus j.fan", "frame all", "ghost others", "show all", "hide j.nacelle", "highlight j.fan", "detail j.fan", "explode dist=0", "label x on=j.fan text=\"Fan\"",
                 "arrow3 a from=0,0,0 to=1,0,0", "flow f pts=0,0,0;1,0,0", "orbit j.fan deg=90", "pulse j.fan", "sphere s parent=j.fan r=0.1"] {
        if let command = SceneScriptParser.parse(line).first { expect(SceneRefinePrompt.allows(command), "a refine turn keeps \"\(line)\"") } else { expect(false, "\"\(line)\" parses") }
    }
    let state = SceneLiveState(title: "How a turbofan works",
                               parts: [SceneLivePart(id: "j.fan", title: "Fan", colour: "steel", canDetail: true),
                                       SceneLivePart(id: "j.turbine", title: "Turbine", colour: "copper", inside: "j.casing", isGhosted: false),
                                       SceneLivePart(id: "j.nacelle", title: "Nacelle", colour: "white", isGhosted: true)],
                               focus: ["j.turbine"], isExploded: true)
    let text = state.text()
    expect(text.contains("j.fan \"Fan\" steel detail") && text.contains("j.turbine \"Turbine\" copper inside=j.casing") && text.contains("j.nacelle \"Nacelle\" white ghosted"), "the scene is described part by part:\n\(text)")
    expect(text.contains("Camera now: on j.turbine") && text.contains("exploded"), "with where the camera is and whether it is exploded")
    let body = SceneRefinePrompt.requestBody(request: "zoom in on the turbine", state: state)
    let messages = body["messages"] as? [[String: Any]] ?? []
    expect(body["model"] == nil && body["stream"] as? Bool == true && messages.count == 2, "the request leaves the model to the router and streams")
    expect((messages.last?["content"] as? String)?.contains("The person asked: zoom in on the turbine") == true, "and carries the request after the description")
    expect((SceneRefinePrompt.requestBody(request: "Tell me about the Fan.", state: state, tappedPart: "j.fan")["messages"] as? [[String: Any]])?.last?["content"] as? String ?? "" ~= "tapped the part j.fan", "a tap says which part was tapped")
    expect(SceneColor(hex: 0xF76B15).nearestName == "orange" && SceneColor(hex: 0x3F6FD8).nearestName == "blue" && SceneColor(hex: 0xD8433F).nearestName == "red", "colours get everyday names")
}

// MARK: - Detail

section("detail: richer sub-assemblies for the common ready-made parts, a no-op elsewhere") {
    func source(_ line: String) -> SceneCommand { SceneScriptParser.parse(line)[0] }
    let fan = SceneDetailSubject(id: "j.fan", source: source("fan j.fan parent=j r=0.98 hub=0.3 blades=18 pitch=38 thick=0.2"), macro: .jet, parent: "j")
    expect(SceneDetail.kind(of: fan) == .fan, "a fan")
    let fanLines = SceneDetail.commands(for: fan)
    expect(fanLines.filter { $0.verb == .box }.count == 18, "gets a splitter blade between each pair of blades: \(fanLines.filter { $0.verb == .box }.count)")
    expect(fanLines.filter { $0.verb == .label }.compactMap(\.freeText) == ["Blades", "Hub", "Shaft"], "and names for blades, hub and shaft: \(fanLines.filter { $0.verb == .label }.compactMap(\.freeText))")
    expect(fanLines.filter { $0.verb != .label }.allSatisfy { $0.string("parent") == "j.fan" && $0.id.hasPrefix("j.fan.") }, "every added piece hangs from the fan")
    expect(fanLines.filter { $0.verb == .label }.allSatisfy { ($0.string("on") ?? "").hasPrefix("j.fan.") }, "and every label points at a piece of it")

    let stages = [source("fan j.turbine.s1 parent=j.turbine at=0,0.68,0 axis=y r=0.5 hub=0.24 blades=20"), source("fan j.turbine.s2 parent=j.turbine at=0,0.9,0 axis=y r=0.47 hub=0.24 blades=20")]
    let turbine = SceneDetailSubject(id: "j.turbine", source: source("group j.turbine parent=j rpm=70"), macro: .jet, children: stages, parent: "j")
    expect(SceneDetail.kind(of: turbine) == .fanStack, "a group of fan stages (a turbine)")
    let turbineLines = SceneDetail.commands(for: turbine)
    let stator = turbineLines.first { $0.verb == .fan }
    expect(stator?.string("parent") == "j" && stator?.args["rpm"] == nil && close(stator?.vec3("at")?.y ?? 0, 0.79, 1e-6), "gets still vanes between the stages, hung from the engine, not the spinning group")
    expect(turbineLines.compactMap { $0.verb == .label ? $0.freeText : nil }.contains("Stator vanes") && turbineLines.compactMap { $0.verb == .label ? $0.freeText : nil }.contains("Rotor blades"), "named rotor blades and stator vanes")

    let gear = SceneDetailSubject(id: "g1", source: source("gear g1 teeth=12 r=1"), localSize: SceneVec3(2.2, 2.2, 0.2))
    expect(SceneDetail.kind(of: gear) == .gear && SceneDetail.commands(for: gear).compactMap { $0.verb == .label ? $0.freeText : nil } == ["Hub", "Axle", "Pitch circle"], "a gear gets a hub, an axle and its pitch circle")
    let piston = SceneDetailSubject(id: "p", source: source("piston p bore=1 stroke=1"))
    let pistonLines = SceneDetail.commands(for: piston)
    expect(pistonLines.filter { $0.verb == .torus }.count == 3 && pistonLines.filter { $0.verb == .torus }.allSatisfy { $0.string("parent") == "p.head" }, "a piston gets three rings that ride on its head")
    expect(pistonLines.compactMap { $0.verb == .label ? $0.freeText : nil } == ["Piston", "Piston rings", "Connecting rod", "Crank", "Cylinder"], "and its pieces named")
    expect(SceneDetail.kind(of: SceneDetailSubject(id: "w", source: source("wheel w r=1"))) == .wheel, "a wheel")
    let chip = SceneDetailSubject(id: "cpu", source: source("comp cpu on=b at=0,0 size=1,1 label=\"CPU\""), localSize: SceneVec3(1, 0.14, 1))
    expect(SceneDetail.kind(of: chip) == .component && SceneDetail.commands(for: chip).filter { $0.verb == .box }.count >= 8, "a board component gets legs")
    let chamber = SceneDetailSubject(id: "h.lv", source: source("sphere h.lv parent=h r=0.62"), macro: .heart)
    expect(SceneDetail.kind(of: chamber) == .heartChamber && SceneDetail.commands(for: chamber).contains { $0.freeText == "Valve" }, "a heart chamber gets its valve")
    expect(SceneDetail.kind(of: SceneDetailSubject(id: "d", source: source("dna d turns=2"))) == .dna, "DNA gets its backbone and a base pair named")
    expect(SceneDetail.kind(of: SceneDetailSubject(id: "s", source: source("sphere s r=1"))) == nil, "a plain sphere: nothing")
    expect(SceneDetail.commands(for: SceneDetailSubject(id: "b", source: source("box b size=1,1,1"))).isEmpty, "a plain box: no lines at all")
    expect(SceneDetail.commands(for: SceneDetailSubject(id: "x")).isEmpty, "an unknown part: no lines at all")
    for subject in [fan, turbine, gear, piston, chip, chamber] {
        for command in SceneDetail.commands(for: subject) { expect(SceneValidator.problem(with: command) == nil, "every detail line is a valid line: \(command.scriptLine)") }
    }
}

// MARK: - Replay log

section("replay log: camera moves, ghosting and highlights round-trip") {
    let script = """
    say 1 "A jet engine."
    scene3d t title="Jet"
    jet j
    say 2 "The turbine."
    focus j.turbine zoom=tight dur=1.2
    ghost j.casing j.nacelle opacity=0.2
    highlight j.turbine color=yellow
    detail j.turbine
    say 3 "All of it."
    orbit j.turbine deg=90 dur=3
    show all
    frame all
    """
    var log = SceneReplayLog()
    var time = 0.0
    for command in SceneScriptParser.parse(script) {
        log.record(command, at: time)
        time += 0.4
    }
    // Lines the engine writes itself carry the sentence they belong to and the `auto` flag.
    var auto = SceneScriptParser.parse("focus j.fan zoom=medium auto")[0]
    auto.cue = 3
    log.record(auto, at: time)
    guard let data = try? log.encoded(), let decoded = try? SceneReplayLog.decoded(from: data) else {
        expect(false, "the log encodes and decodes")
        return
    }
    expect(decoded == log, "decoding gives back the same log")
    expect(decoded.entries.map(\.command.verb) == [.say, .scene3d, .jet, .say, .focus, .ghost, .highlight, .detail, .say, .orbit, .show, .frame, .focus], "every line in order")
    expect(decoded.entries[4].command.targetIDs == ["j.turbine"] && decoded.entries[4].command.string("zoom") == "tight" && decoded.entries[4].command.cue == 2, "the focus keeps its target, zoom and sentence")
    expect(decoded.entries[5].command.targetIDs == ["j.casing", "j.nacelle"] && decoded.entries[5].command.number("opacity") == 0.2, "the ghost keeps its parts and opacity")
    expect(decoded.entries[9].command.isCameraOrbit && decoded.entries[9].command.number("deg") == 90, "the orbit keeps its angle")
    expect(decoded.entries[12].command.flag("auto") && decoded.entries[12].command.cue == 3, "an automatic focus is in the log like any other line")
    expect(try! decoded.encoded() == data, "encoding is stable")
    // The log as plain script draws the same camera story.
    let again = SceneScriptParser.parse(decoded.script)
    expect(again.map(\.verb) == decoded.entries.map(\.command.verb), "written out as script and parsed again, the same lines")
    expect(again.filter(\.movesCamera).map(\.targetIDs) == decoded.entries.map(\.command).filter(\.movesCamera).map(\.targetIDs), "with the same camera targets")
    expect(decoded.entries(after: 1.5, upTo: 2.05).map(\.command.verb) == [.focus, .ghost], "a slice of time gives the lines in it")
}

print("\n\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

func ~= (text: String, part: String) -> Bool { text.contains(part) }
