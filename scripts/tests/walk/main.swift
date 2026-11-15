// Tests for walkthroughs and app skills. Run with scripts/tests/run_walk_tests.sh.
// The first argument is the folder of skill files to check (the repo's skills/).

import CoreGraphics
import Foundation

// WalkthroughAI.swift calls the router; these stand in for it so the file compiles here.
enum TeachyAIJob { case plan, quickCheck }
enum TeachyAIRouter {
    static func sendJSON(job: TeachyAIJob, hasImages: Bool, timeout: TimeInterval = 120, body: [String: Any]) async throws -> Data {
        throw NSError(domain: "test", code: 1)
    }
}

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func section(_ name: String) { print("— \(name)") }

// MARK: Synthetic screens

let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

func el(_ index: Int, _ role: String, _ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 120, _ h: CGFloat = 30,
        value: String = "", placeholder: String = "", focused: Bool = false, secure: Bool = false, subrole: String = "") -> AXSnapshotElement {
    AXSnapshotElement(index: index, role: role, subrole: subrole, name: name, value: value, placeholder: placeholder,
                      frame: CGRect(x: x, y: y, width: w, height: h), isFocused: focused, isSecure: secure, identifier: "")
}

func snap(_ title: String, _ elements: [AXSnapshotElement], app: String = "Safari", truncated: Bool = false) -> AXSnapshotData {
    AXSnapshotData(appName: app, windowTitle: title, windowFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), elements: elements, truncated: truncated)
}

func clickStep(_ label: String, role: String = "button", point: WalkthroughPoint? = nil, check: WalkthroughCheck? = nil, say: String? = nil) -> WalkthroughStep {
    WalkthroughStep(say: say ?? "Click \(label).", kind: .click, target: WalkthroughTarget(role: role, label: label, point: point),
                    doneWhen: "\(label) was clicked", check: check)
}

func speaks(_ effects: [WalkthroughEngine.Effect]) -> [String] {
    effects.compactMap { if case .speak(let line) = $0 { return line } else { return nil } }
}

func rings(_ effects: [WalkthroughEngine.Effect]) -> [WalkthroughRing] {
    effects.compactMap { if case .showRing(let ring) = $0 { return ring } else { return nil } }
}

func has(_ effects: [WalkthroughEngine.Effect], _ wanted: WalkthroughEngine.Effect) -> Bool { effects.contains(wanted) }

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// The LinkedIn "change my email" route, as three screens.
let feed = snap("Feed | LinkedIn", [
    el(1, "AXLink", "Home", 600, 20, 60, 40),
    el(2, "AXButton", "Me", 1250, 20, 50, 40),
    el(3, "AXTextField", "Search", 200, 20, 260, 34),
])
let meMenu = snap("Feed | LinkedIn", feed.elements + [
    el(10, "AXLink", "View Profile", 1150, 90, 200, 28),
    el(11, "AXLink", "Settings & Privacy", 1150, 150, 200, 28),
    el(12, "AXLink", "Sign Out", 1150, 300, 200, 28),
])
let settings = snap("Settings | LinkedIn", [
    el(20, "AXLink", "Account preferences", 40, 120, 220, 36),
    el(21, "AXLink", "Sign in & security", 40, 164, 220, 36),
    el(22, "AXHeading", "Account preferences", 320, 100, 400, 40),
])
let security = snap("Settings | LinkedIn", settings.elements.filter { $0.index != 22 } + [
    el(30, "AXHeading", "Account access", 320, 100, 400, 40),
    el(31, "AXLink", "Email addresses", 320, 160, 600, 44),
    el(32, "AXLink", "Phone numbers", 320, 210, 600, 44),
])

let linkedInSteps: [WalkthroughStep] = [
    clickStep("Me", point: WalkthroughPoint(x: 885, y: 44), check: WalkthroughCheck(type: .appears, role: "link", label: "Settings & Privacy")),
    clickStep("Settings & Privacy", role: "link", check: WalkthroughCheck(type: .titleContains, text: "Settings")),
    clickStep("Sign in & security", role: "link", check: WalkthroughCheck(type: .appears, role: "link", label: "Email addresses")),
    clickStep("Email addresses", role: "link"),
]

func startedEngine(_ steps: [WalkthroughStep], goal: String = "change my email on LinkedIn") -> WalkthroughEngine {
    var engine = WalkthroughEngine(goal: goal, appName: "Safari", bundleID: "com.apple.Safari", displayFrame: display, now: t0)
    _ = engine.start(now: t0)
    _ = engine.handle(.planReady(steps), now: t0)
    return engine
}

// MARK: - State machine

section("engine: plan, give a step, click in the ring advances without talking")
do {
    var engine = WalkthroughEngine(goal: "change my email on LinkedIn", displayFrame: display, now: t0)
    expect(engine.start(now: t0) == [.persist, .requestPlan], "start asks for a plan and saves")
    expect(engine.status == .planning, "starts in planning")
    expect(engine.handle(.click(CGPoint(x: 5, y: 5)), now: t0).isEmpty, "a click while planning does nothing")

    let planned = engine.handle(.planReady(linkedInSteps), now: t0)
    expect(planned == [.persist, .requestScreen], "a plan asks for the screen before anything is said, got \(planned)")
    expect(engine.status == .checking, "checking after the plan")

    let given = engine.handle(.screen(feed), now: t0)
    expect(engine.status == .waitingForUser, "waiting once the step is given")
    expect(speaks(given) == ["Click Me."], "speaks exactly the step's sentence, got \(speaks(given))")
    expect(rings(given).first?.frame == CGRect(x: 1250, y: 20, width: 50, height: 40), "ring sits on the Me button's live frame")
    expect(rings(given).first?.stepNumber == 1 && rings(given).first?.stepCount == 4, "ring carries 1 of 4")
    expect(rings(given).first?.isApproximate == false, "an element ring is not approximate")

    let moved = engine.handle(.click(CGPoint(x: 700, y: 500)), now: t0)
    expect(moved == [.requestScreen], "a click elsewhere only asks for the screen, got \(moved)")
    expect(engine.session.currentIndex == 0, "a click elsewhere does not advance")
    expect(engine.handle(.screen(feed), now: t0.addingTimeInterval(1)).isEmpty, "nothing changed: stay quiet")

    let advanced = engine.handle(.click(CGPoint(x: 1270, y: 35)), now: t0.addingTimeInterval(2))
    expect(advanced == [.hideRing(completed: true), .persist, .requestScreen], "click in the ring: fade, save, look again; got \(advanced)")
    expect(speaks(advanced).isEmpty, "advancing says nothing")
    expect(engine.session.currentIndex == 1 && engine.status == .checking, "now checking step 2")
    expect(engine.session.log.last?.outcome == .done && engine.session.log.last?.stepNumber == 1, "the log records step 1 as done")

    let next = engine.handle(.screen(meMenu), now: t0.addingTimeInterval(3))
    expect(speaks(next) == ["Click Settings & Privacy."], "the next instruction comes after the screen settles")
    expect(rings(next).first?.frame.minY == 150, "ring on the menu's Settings & Privacy link")

    // Just outside the frame, within tolerance.
    let edge = engine.handle(.click(CGPoint(x: 1146, y: 147)), now: t0.addingTimeInterval(4))
    expect(has(edge, .hideRing(completed: true)), "a click a few points outside the control still counts")
}

section("engine: steps the screen already shows as done are skipped silently")
do {
    // They already opened Settings and went to Sign in & security on their own.
    let steps = [
        clickStep("Settings & Privacy", role: "link", check: WalkthroughCheck(type: .titleContains, text: "Settings")),
        clickStep("Sign in & security", role: "link", check: WalkthroughCheck(type: .appears, role: "link", label: "Email addresses")),
        clickStep("Email addresses", role: "link"),
    ]
    var engine = startedEngine(steps)
    let effects = engine.handle(.screen(security), now: t0)
    expect(engine.session.currentIndex == 2, "skipped to step 3, at step \(engine.session.currentIndex + 1)")
    expect(speaks(effects) == ["Click Email addresses."], "only the first undone step is spoken, got \(speaks(effects))")
    expect(engine.session.log.filter { $0.outcome == .skipped }.map(\.stepNumber) == [1, 2], "both skips are in the log")
    expect(rings(effects).first?.stepNumber == 3, "the ring says step 3")
}
do {
    // Skipping needs every earlier check to hold: with the Me menu open, only step 1 is skipped.
    var engine = startedEngine(linkedInSteps)
    let effects = engine.handle(.screen(meMenu), now: t0)
    expect(engine.session.currentIndex == 1, "step 1 skipped because Settings & Privacy is already showing")
    expect(engine.session.log.first?.outcome == .skipped && engine.session.log.first?.stepNumber == 1, "the skip is in the log")
    expect(speaks(effects) == ["Click Settings & Privacy."], "goes straight to step 2")

    // All steps already done → finishes.
    let done = [clickStep("Me", check: WalkthroughCheck(type: .titleContains, text: "Feed"))]
    var short = startedEngine(done)
    let finish = short.handle(.screen(feed), now: t0)
    expect(short.status == .done && has(finish, .finished(.done)), "everything already done: finished")
    expect(speaks(finish).count == 1, "one closing line")

    // "disappears" cannot skip a step whose subject was never seen.
    let close = [clickStep("Close", check: WalkthroughCheck(type: .disappears, label: "Cookie banner"))]
    var cautious = startedEngine(close)
    _ = cautious.handle(.screen(feed), now: t0)
    expect(cautious.session.currentIndex == 0 && cautious.status == .waitingForUser, "a 'gone' check does not skip a step before its subject was ever seen")
}

section("engine: the screen showing doneWhen advances without a click")
do {
    var engine = startedEngine(linkedInSteps)
    _ = engine.handle(.screen(feed), now: t0)
    // They opened the menu with the keyboard.
    let effects = engine.handle(.screen(meMenu), now: t0.addingTimeInterval(2))
    expect(effects == [.hideRing(completed: true), .persist, .requestScreen], "local check passes: advance silently, got \(effects)")
    expect(engine.session.currentIndex == 1, "on step 2")
}

section("engine: one failure rephrases, two re-plan, at most two re-plans")
do {
    var engine = startedEngine(linkedInSteps)
    _ = engine.handle(.screen(feed), now: t0)

    let first = engine.handle(.command(.stuck), now: t0)
    expect(engine.session.steps[0].failureCount == 1, "one failure counted")
    expect(speaks(first).count == 1 && speaks(first)[0] != "Click Me.", "a failed step is never repeated word for word: \(speaks(first))")
    expect(speaks(first)[0].contains("Me"), "the retry line still names the control")
    expect(!has(first, .requestReplan), "one failure does not re-plan")
    expect(engine.status == .waitingForUser, "still waiting")

    let second = engine.handle(.command(.stuck), now: t0)
    expect(has(second, .requestReplan) && engine.status == .planning, "two failures re-plan")
    expect(speaks(second).count == 1, "says it is looking again instead of going silent")
    expect(engine.session.failedSays == ["Click Me."], "the failed instruction is remembered for the planner: \(engine.session.failedSays)")
    expect(engine.session.logText.contains("FAILED step 1"), "the log the planner reads has the failure")

    let newSteps = [clickStep("Profile photo", role: "image"), clickStep("Settings & Privacy", role: "link")]
    let replanned = engine.handle(.planReady(newSteps), now: t0)
    expect(replanned == [.persist, .requestScreen], "re-plan arrives: look at the screen")
    expect(engine.session.replanCount == 1 && engine.session.steps.count == 2 && engine.session.currentIndex == 0, "remaining steps replaced")

    _ = engine.handle(.screen(feed), now: t0)
    _ = engine.handle(.command(.stuck), now: t0)
    let again = engine.handle(.command(.stuck), now: t0)
    expect(has(again, .requestReplan), "second re-plan allowed")
    _ = engine.handle(.planReady([clickStep("Account", role: "link")]), now: t0)
    expect(engine.session.replanCount == 2, "two re-plans used")
    expect(Set(engine.session.failedSays) == ["Click Me.", "Click Profile photo."], "failed steps from before the re-plan are still remembered: \(engine.session.failedSays)")

    _ = engine.handle(.screen(feed), now: t0)
    _ = engine.handle(.command(.stuck), now: t0)
    let capped = engine.handle(.command(.stuck), now: t0)
    expect(!has(capped, .requestReplan), "no third re-plan")
    expect(engine.status == .stopped && has(capped, .finished(.stopped)), "stops instead of looping")
    expect(speaks(capped).count == 1, "says why it stopped")
}
do {
    // A re-plan keeps the finished steps and never grows past 15 in total.
    var steps = (1...14).map { clickStep("Item \($0)") }
    steps.append(clickStep("Last"))
    var engine = startedEngine(steps)
    _ = engine.handle(.screen(snap("List", (1...14).map { el($0, "AXButton", "Item \($0)", 10, CGFloat($0 * 40)) })), now: t0)
    for index in 1...12 {
        _ = engine.handle(.click(CGPoint(x: 20, y: CGFloat(index * 40 + 5))), now: t0)
        _ = engine.handle(.screen(snap("List", (1...14).map { el($0, "AXButton", "Item \($0)", 10, CGFloat($0 * 40)) })), now: t0)
    }
    expect(engine.session.currentIndex == 12, "twelve steps done")
    _ = engine.handle(.command(.stuck), now: t0)
    _ = engine.handle(.command(.stuck), now: t0)
    _ = engine.handle(.planReady((1...9).map { clickStep("New \($0)") }), now: t0)
    expect(engine.session.steps.count == 15, "kept 12 done + 3 new = 15, got \(engine.session.steps.count)")
    expect(engine.session.steps[11].say == "Click Item 12." && engine.session.steps[12].say == "Click New 1.", "done steps kept, new ones follow")
}

section("engine: clicking elsewhere and losing the target is a failure; otherwise ask the model once")
do {
    var engine = startedEngine(linkedInSteps)
    _ = engine.handle(.screen(feed), now: t0)
    _ = engine.handle(.click(CGPoint(x: 620, y: 40)), now: t0)
    // They clicked Home... and landed somewhere with no Me button and no menu.
    let elsewhere = snap("Jobs | LinkedIn", [el(40, "AXLink", "Saved jobs", 40, 120)])
    let effects = engine.handle(.screen(elsewhere), now: t0.addingTimeInterval(1))
    expect(engine.session.steps[0].failureCount == 1, "wrong click + target gone + check false = one failure")
    expect(speaks(effects).count == 1 && speaks(effects)[0] != "Click Me.", "rephrased, not repeated")
}
do {
    // No machine check on the step: undecidable → one quick model check.
    let steps = [clickStep("Email addresses", role: "link"), clickStep("Add email address")]
    var engine = startedEngine(steps)
    _ = engine.handle(.screen(security), now: t0)
    let stepID = engine.currentStep!.id
    _ = engine.handle(.click(CGPoint(x: 900, y: 700)), now: t0)
    let changed = snap("Settings | LinkedIn", [el(50, "AXButton", "Add email address", 320, 300, 200, 40)])
    let asked = engine.handle(.screen(changed), now: t0.addingTimeInterval(1))
    expect(asked == [.requestQuickCheck(stepID: stepID, condition: "Email addresses was clicked")], "asks the model once, got \(asked)")
    expect(engine.handle(.screen(changed), now: t0.addingTimeInterval(2)).isEmpty, "waits for the answer")

    let answered = engine.handle(.quickCheck(stepID: stepID, isDone: true), now: t0.addingTimeInterval(3))
    expect(answered == [.hideRing(completed: true), .persist, .requestScreen], "YES advances silently")
    expect(engine.session.currentIndex == 1, "on step 2")
}
do {
    let steps = [clickStep("Email addresses", role: "link"), clickStep("Add email address")]
    var engine = startedEngine(steps)
    _ = engine.handle(.screen(security), now: t0)
    let stepID = engine.currentStep!.id
    _ = engine.handle(.click(CGPoint(x: 900, y: 700)), now: t0)
    let wrongPage = snap("Help | LinkedIn", [el(60, "AXHeading", "Help Center", 320, 100)])
    _ = engine.handle(.screen(wrongPage), now: t0.addingTimeInterval(1))
    let no = engine.handle(.quickCheck(stepID: stepID, isDone: false), now: t0.addingTimeInterval(2))
    expect(engine.session.steps[0].failureCount == 1 && speaks(no).count == 1, "NO after wandering off is a failure")

    // The one model check for this step is used up.
    _ = engine.handle(.click(CGPoint(x: 900, y: 700)), now: t0.addingTimeInterval(3))
    let later = engine.handle(.screen(snap("Other", [el(61, "AXHeading", "Other", 320, 100)])), now: t0.addingTimeInterval(4))
    let askedAgain = later.contains { if case .requestQuickCheck = $0 { return true } else { return false } }
    expect(!askedAgain, "only ONE model check per step")

    // A stale answer for another step is ignored.
    expect(engine.handle(.quickCheck(stepID: "nope", isDone: true), now: t0).isEmpty, "an answer for a different step is ignored")
}
do {
    // A click on the ring while the model check is still out wins; the late answer is dropped.
    let steps = [clickStep("Email addresses", role: "link"), clickStep("Add email address")]
    var engine = startedEngine(steps)
    _ = engine.handle(.screen(security), now: t0)
    let stepID = engine.currentStep!.id
    _ = engine.handle(.click(CGPoint(x: 1300, y: 800)), now: t0)
    let shifted = snap("Settings | LinkedIn", security.elements + [el(70, "AXStaticText", "Tip", 1000, 700)])
    _ = engine.handle(.screen(shifted), now: t0.addingTimeInterval(1))
    let clicked = engine.handle(.click(CGPoint(x: 400, y: 180)), now: t0.addingTimeInterval(1.2))
    expect(has(clicked, .hideRing(completed: true)) && engine.session.currentIndex == 1, "click on the ring advances even mid-check")
    expect(engine.handle(.quickCheck(stepID: stepID, isDone: false), now: t0.addingTimeInterval(2)).isEmpty, "the late answer is ignored")
}

section("engine: typing, looking, and a target that appears or moves")
do {
    let typeStep = WalkthroughStep(say: "Type your new email in the box.", kind: .type,
                                   target: WalkthroughTarget(role: "text field", label: "Email address", point: nil), doneWhen: "The box has your new email")
    var engine = startedEngine([typeStep, clickStep("Save")])
    let empty = snap("Add email", [el(1, "AXTextField", "Email address", 300, 300, 300, 32), el(2, "AXButton", "Save", 300, 360)])
    let given = engine.handle(.screen(empty), now: t0)
    expect(rings(given).first?.label == "Type in Email address", "type steps say so on the pill")
    expect(engine.handle(.click(CGPoint(x: 320, y: 310)), now: t0).isEmpty, "clicking into the field is not the end of a type step")

    func typed(_ value: String) -> AXSnapshotData {
        snap("Add email", [el(1, "AXTextField", "Email address", 300, 300, 300, 32, value: value, focused: true), el(2, "AXButton", "Save", 300, 360)])
    }
    expect(engine.handle(.screen(typed("ved")), now: t0.addingTimeInterval(1)).isEmpty, "still typing")
    expect(engine.handle(.screen(typed("ved@ex")), now: t0.addingTimeInterval(1.8)).isEmpty, "still typing")
    expect(engine.handle(.screen(typed("ved@example.com")), now: t0.addingTimeInterval(2.6)).isEmpty, "just finished: wait for the pause")
    let paused = engine.handle(.screen(typed("ved@example.com")), now: t0.addingTimeInterval(4))
    expect(paused == [.hideRing(completed: true), .persist, .requestScreen], "text sat unchanged for the pause: advance, got \(paused)")
}
do {
    let look = WalkthroughStep(say: "Notice the sidebar on the left.", kind: .look, target: nil, doneWhen: "They have seen the sidebar")
    var engine = startedEngine([look, clickStep("Save")])
    let screen = snap("Doc", [el(2, "AXButton", "Save", 300, 360)])
    let given = engine.handle(.screen(screen), now: t0)
    expect(has(given, .hideRing(completed: false)) && rings(given).isEmpty, "no target: no ring")
    expect(engine.handle(.screen(screen), now: t0.addingTimeInterval(3)).isEmpty, "a look step waits")
    expect(engine.handle(.screen(screen), now: t0.addingTimeInterval(90)).isEmpty, "and never moves on by a timer (it may be 'go and open the email')")
    // The screen changes (they came back from their inbox): one model check, then on.
    let stepID = engine.currentStep!.id
    let changed = snap("Doc", [el(2, "AXButton", "Save", 300, 360), el(3, "AXStaticText", "Verified", 300, 420)])
    expect(engine.handle(.screen(changed), now: t0.addingTimeInterval(95)) == [.requestQuickCheck(stepID: stepID, condition: "They have seen the sidebar")], "a change on screen triggers the one model check")
    expect(has(engine.handle(.command(.next), now: t0.addingTimeInterval(96)), .requestScreen) && engine.session.currentIndex == 1, "or they just say next")
}
do {
    // The control is not on screen yet (still loading): no ring, then the ring appears; then the window moves.
    var engine = startedEngine([clickStep("Publish")])
    let loading = snap("Editor", [el(1, "AXStaticText", "Loading…", 300, 300)])
    let given = engine.handle(.screen(loading), now: t0)
    expect(rings(given).isEmpty && speaks(given) == ["Click Publish."], "speaks even when the control is not there yet")
    let loaded = snap("Editor", [el(2, "AXButton", "Publish", 1200, 60, 90, 32)])
    let appeared = engine.handle(.screen(loaded), now: t0.addingTimeInterval(1))
    expect(rings(appeared).first?.frame.minX == 1200 && speaks(appeared).isEmpty, "the ring appears with the control, without repeating the line")

    _ = engine.handle(.targetMoved(CGRect(x: 800, y: 260, width: 90, height: 32)), now: t0)
    expect(engine.handle(.click(CGPoint(x: 1240, y: 76)), now: t0) == [.requestScreen], "the old place no longer counts")
    expect(has(engine.handle(.click(CGPoint(x: 840, y: 276)), now: t0), .hideRing(completed: true)), "the ring's new place does")
}

section("engine: spoken commands")
do {
    var engine = startedEngine(linkedInSteps)
    _ = engine.handle(.screen(feed), now: t0)
    let next = engine.handle(.command(.next), now: t0)
    expect(next == [.hideRing(completed: true), .persist, .requestScreen] && engine.session.currentIndex == 1, "next advances")
    _ = engine.handle(.screen(meMenu), now: t0)

    let again = engine.handle(.command(.repeatStep), now: t0)
    expect(speaks(again) == ["Click Settings & Privacy."] && rings(again).count == 1, "repeat says the step again and re-shows the ring")
    expect(engine.session.steps[1].failureCount == 0, "repeat is not a failure")

    let back = engine.handle(.command(.back), now: t0)
    expect(engine.session.currentIndex == 0 && engine.status == .checking && has(back, .requestScreen), "back goes to the step before")
    // Step 1's check is true on this screen (menu open), but they asked to go back: do not skip it.
    let regiven = engine.handle(.screen(meMenu), now: t0)
    expect(engine.session.currentIndex == 0 && speaks(regiven) == ["Click Me."], "the step they went back to is given, not skipped")

    let stop = engine.handle(.command(.stop), now: t0)
    expect(engine.status == .stopped && has(stop, .finished(.stopped)) && has(stop, .persist) && has(stop, .hideRing(completed: false)), "stop pauses and saves")
    expect(engine.handle(.command(.next), now: t0).isEmpty, "nothing after stop")
}

section("engine: finishing and failing to plan")
do {
    var engine = startedEngine([clickStep("Me")])
    _ = engine.handle(.screen(feed), now: t0)
    _ = engine.handle(.click(CGPoint(x: 1270, y: 35)), now: t0)
    let end = engine.handle(.screen(meMenu), now: t0)
    expect(engine.status == .done, "done after the last step")
    expect(end.first == .hideRing(completed: true) && has(end, .finished(.done)) && speaks(end).count == 1, "one closing line, then finished: \(end)")

    var failed = WalkthroughEngine(goal: "x", displayFrame: display, now: t0)
    _ = failed.start(now: t0)
    let effects = failed.handle(.planFailed(spokenReason: "I can't walk you through that. LinkedIn is not open."), now: t0)
    expect(failed.status == .stopped && speaks(effects) == ["I can't walk you through that. LinkedIn is not open."], "a failed plan says why and stops")

    var capped = WalkthroughEngine(goal: "x", displayFrame: display, now: t0)
    _ = capped.start(now: t0)
    _ = capped.handle(.planReady((1...22).map { clickStep("Item \($0)") }), now: t0)
    expect(capped.session.steps.count == 15, "never more than 15 steps")
}

section("engine: pause, save to JSON, resume")
do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-walk-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = WalkthroughStore(directory: folder)
    expect(store.load() == nil, "nothing saved yet")

    var engine = startedEngine(linkedInSteps)
    _ = engine.handle(.screen(feed), now: t0)
    _ = engine.handle(.click(CGPoint(x: 1270, y: 35)), now: t0.addingTimeInterval(5))
    _ = engine.handle(.screen(meMenu), now: t0.addingTimeInterval(6))
    _ = engine.handle(.command(.stuck), now: t0.addingTimeInterval(7))
    _ = engine.handle(.command(.stop), now: t0.addingTimeInterval(8))
    do { try store.save(engine.session) } catch { expect(false, "save threw \(error)") }
    expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("current.json").path), "current.json written")

    guard let loaded = store.load() else {
        expect(false, "could not load what was saved")
        exit(1)
    }
    expect(loaded == engine.session, "the saved walkthrough reads back the same")
    expect(loaded.goal == "change my email on LinkedIn" && loaded.currentIndex == 1 && loaded.status == .stopped, "goal, place and status survive")
    expect(loaded.steps[1].failureCount == 1 && loaded.log.contains { $0.outcome == .done } && loaded.log.contains { $0.outcome == .failed }, "the log and failure counts survive")
    expect(loaded.displayFrame == display, "the display frame survives")

    expect(loaded.isResumable(explicit: false, now: t0.addingTimeInterval(3600)), "an hour later a bare 'continue' resumes")
    expect(!loaded.isResumable(explicit: false, now: t0.addingTimeInterval(8 * 3600)), "eight hours later a bare 'continue' does not")
    expect(loaded.isResumable(explicit: true, now: t0.addingTimeInterval(2 * 24 * 3600)), "'continue the walkthrough' works two days later")
    expect(!loaded.isResumable(explicit: true, now: t0.addingTimeInterval(9 * 24 * 3600)), "but not nine days later")

    // A relaunch: a new engine from the file.
    var resumed = WalkthroughEngine(resuming: loaded)
    let effects = resumed.resume(now: t0.addingTimeInterval(600))
    expect(resumed.status == .checking && has(effects, .requestResumeCheck) && speaks(effects).count == 1, "resume says one line and checks how far they got")
    // They did the next two steps by hand while paused.
    let after = resumed.handle(.resumeCheck(alreadyDone: 2), now: t0.addingTimeInterval(601))
    expect(after == [.persist, .requestScreen] && resumed.session.currentIndex == 3, "two steps done while paused are skipped")
    expect(resumed.session.log.filter { $0.outcome == .skipped }.count == 2, "and logged")
    let given = resumed.handle(.screen(security), now: t0.addingTimeInterval(602))
    expect(speaks(given) == ["Click Email addresses."], "carries on at the right step")

    // The model could not say: carry on from the saved step.
    var unsure = WalkthroughEngine(resuming: loaded)
    _ = unsure.resume(now: t0)
    _ = unsure.handle(.resumeCheck(alreadyDone: nil), now: t0)
    expect(unsure.session.currentIndex == 1, "no answer: stay on the saved step")

    // A finished walkthrough does not resume.
    var finished = loaded
    finished.status = .done
    expect(!finished.isResumable(explicit: true, now: t0), "done is done")
    var none = WalkthroughEngine(resuming: finished)
    expect(none.resume(now: t0).isEmpty, "resuming a finished walkthrough does nothing")

    // Interrupted while planning (no steps yet): resume plans again.
    var early = WalkthroughEngine(goal: "x", displayFrame: display, now: t0)
    _ = early.start(now: t0)
    var again = WalkthroughEngine(resuming: early.session)
    expect(has(again.resume(now: t0), .requestPlan), "a walkthrough interrupted before it had steps plans again")

    store.clear()
    expect(store.load() == nil, "clear removes the file")
}

section("voice commands")
do {
    func active(_ text: String) -> WalkthroughVoiceCommand? { WalkthroughCommandParser.parse(text, context: .active) }
    func paused(_ text: String) -> WalkthroughVoiceCommand? { WalkthroughCommandParser.parse(text, context: .paused) }
    for phrase in ["next", "Next.", "Okay, next step", "done", "I'm done", "I did it", "continue", "keep going", "What's next?", "skip this step"] {
        expect(active(phrase) == .next, "\"\(phrase)\" should be next, got \(String(describing: active(phrase)))")
    }
    for phrase in ["go back", "Back.", "previous step"] { expect(active(phrase) == .back, "\"\(phrase)\" should be back") }
    for phrase in ["stop", "Stop the walkthrough.", "never mind", "pause", "cancel"] { expect(active(phrase) == .stop, "\"\(phrase)\" should be stop") }
    for phrase in ["repeat that", "say that again", "What was that?", "one more time"] { expect(active(phrase) == .repeatStep, "\"\(phrase)\" should be repeat") }
    for phrase in ["I'm stuck", "I’m stuck.", "it didn't work", "I can't find it", "I can't find the save button", "I don't see that", "nothing happened"] {
        expect(active(phrase) == .stuck, "\"\(phrase)\" should be stuck, got \(String(describing: active(phrase)))")
    }
    for phrase in ["what does done mean here", "why is my email not verified", "is the next page the right one", "can you explain what sign in and security is",
                   "stop sharing my screen in zoom", "I can't find my keys anywhere in this house today honestly", ""] {
        expect(active(phrase) == nil, "\"\(phrase)\" is a real question, not a command; got \(String(describing: active(phrase)))")
    }
    expect(paused("continue") == .resume(explicit: false), "paused + continue = resume")
    expect(paused("Continue the walkthrough.") == .resume(explicit: true), "naming the walkthrough is explicit")
    expect(paused("next") == nil && paused("stop") == nil && paused("I'm stuck") == nil, "with nothing running, other commands are not taken")
}

// MARK: - Target matching

section("target matching: label, moved, renamed, twins")
do {
    func resolve(_ target: WalkthroughTarget, _ snapshot: AXSnapshotData?) -> WalkthroughResolvedTarget? {
        WalkthroughTargetMatcher.resolve(target, in: snapshot, displayFrame: display)
    }
    // Planner saw "Save" at (1000, 100) px on a 1440x900 display → point ≈ (694, 111).
    let seen = WalkthroughPoint(x: 694.4, y: 111.1)
    expect(WalkthroughTargetMatcher.globalPoint(for: seen, displayFrame: display).map { abs($0.x - 1000) < 1 && abs($0.y - 100) < 1 } == true, "0–1000 point maps onto the display")
    let second = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
    expect(WalkthroughTargetMatcher.globalPoint(for: WalkthroughPoint(x: 500, y: 500), displayFrame: second) == CGPoint(x: 2400, y: 340), "and onto a second display with its own origin")

    // Moved: the label matches somewhere else entirely; the label wins over the stale point.
    let moved = snap("Doc", [el(1, "AXButton", "Cancel", 960, 85), el(2, "AXButton", "Save", 200, 700)])
    let movedHit = resolve(WalkthroughTarget(role: "button", label: "Save", point: seen), moved)
    expect(movedHit?.elementIndex == 2 && movedHit?.source == .element, "a moved control is followed by its label, got \(String(describing: movedHit))")

    // Renamed in place: no label match, same kind of control at the planner's point.
    let renamed = snap("Doc", [el(1, "AXButton", "Update email address", 940, 85, 160, 30), el(2, "AXButton", "Delete account", 200, 700)])
    let renamedHit = resolve(WalkthroughTarget(role: "button", label: "Change email", point: seen), renamed)
    expect(renamedHit?.elementIndex == 1, "a renamed control is found at the planner's point, got \(String(describing: renamedHit))")
    // …but a text paragraph at that point is not a button.
    let textThere = snap("Doc", [el(1, "AXStaticText", "Some paragraph", 940, 85, 160, 30)])
    expect(resolve(WalkthroughTarget(role: "button", label: "Change email", point: seen), textThere)?.source == .point, "plain text at the point is not taken for the button")

    // Twins: three "Edit" buttons; the one nearest the planner's point.
    let twins = snap("List", [el(1, "AXButton", "Edit", 1000, 300), el(2, "AXButton", "Edit", 1000, 90), el(3, "AXButton", "Edit", 1000, 500)])
    expect(resolve(WalkthroughTarget(role: "button", label: "Edit", point: seen), twins)?.elementIndex == 2, "duplicate labels: nearest to the fallback point")
    expect(resolve(WalkthroughTarget(role: "button", label: "Edit", point: nil), twins)?.elementIndex == 1, "duplicate labels, no point: the first")
    expect(resolve(WalkthroughTarget(role: "button", label: "Edit", point: WalkthroughPoint(x: 700, y: 560)), twins)?.elementIndex == 3, "a different point picks a different twin")

    // Role breaks a tie between a heading and the link with the same words.
    let both = snap("Settings", [el(1, "AXHeading", "Sign in & security", 320, 100, 400, 40), el(2, "AXLink", "Sign in & security", 40, 164, 220, 36)])
    expect(resolve(WalkthroughTarget(role: "link", label: "Sign in & security", point: nil), both)?.elementIndex == 2, "the link, not the heading with the same words")
    expect(resolve(WalkthroughTarget(role: "link", label: "Sign in and security", point: nil), both)?.elementIndex == 2, "'and' matches '&'")

    // Small differences in the label.
    let menu = snap("Doc", [el(1, "AXMenuItem", "Export…", 100, 200), el(2, "AXMenuItem", "Export As PDF…", 100, 230), el(3, "AXButton", "Save changes", 500, 500)])
    expect(resolve(WalkthroughTarget(role: "menu item", label: "Export", point: nil), menu)?.elementIndex == 1, "'Export' matches 'Export…' exactly, not 'Export As PDF…'")
    expect(resolve(WalkthroughTarget(role: "button", label: "Save", point: nil), menu)?.elementIndex == 3, "'Save' finds 'Save changes'")
    expect(resolve(WalkthroughTarget(role: "AXButton", label: "save changes", point: nil), menu)?.elementIndex == 3, "raw AX roles and case are fine")

    // Text carried in a link's value, and a field known by its placeholder.
    let web = snap("Page", [el(1, "AXLink", "", 100, 100, value: "Forgot password?"), el(2, "AXTextField", "", 100, 200, 300, 30, placeholder: "Search mail")])
    expect(resolve(WalkthroughTarget(role: "link", label: "Forgot password?", point: nil), web)?.elementIndex == 1, "a link named only by its value")
    expect(resolve(WalkthroughTarget(role: "search field", label: "Search mail", point: nil), web)?.elementIndex == 2, "a field named only by its placeholder")
    // What someone typed into a field is not its name.
    let filled = snap("Page", [el(1, "AXTextField", "Email", 100, 100, 300, 30, value: "Settings"), el(2, "AXLink", "Settings", 600, 100)])
    expect(resolve(WalkthroughTarget(role: "link", label: "Settings", point: nil), filled)?.elementIndex == 2, "a field's typed value does not make it the target")

    // A different kind of control needs the very same words (seen in a real plan: a "Password"
    // field step landed on the "Change password" link).
    let securityPage = snap("Settings", [el(1, "AXLink", "Change password", 360, 286, 900, 48), el(2, "AXLink", "Passkeys", 360, 334, 900, 48)])
    expect(resolve(WalkthroughTarget(role: "secure field", label: "Password", point: nil), securityPage) == nil, "a Password field is not the Change password link")
    expect(resolve(WalkthroughTarget(role: "button", label: "Change password", point: nil), securityPage)?.elementIndex == 1, "but a button/link mix-up with the same words is fine")
    expect(resolve(WalkthroughTarget(role: "row", label: "Change", point: nil), securityPage)?.elementIndex == 1, "a made-up role does not block a partial label")

    // Nothing matches.
    let bare = resolve(WalkthroughTarget(role: "button", label: "Publish", point: seen), snap("Empty", []))
    expect(bare?.source == .point && abs((bare?.frame.midX ?? 0) - 1000) < 1 && bare?.frame.width == WalkthroughTargetMatcher.pointTargetSize, "no element: ring the fallback point")
    expect(resolve(WalkthroughTarget(role: "button", label: "Publish", point: seen), nil)?.source == .point, "no snapshot at all: the fallback point")
    expect(resolve(WalkthroughTarget(role: "button", label: "Publish", point: nil), snap("Empty", [])) == nil, "no element and no point: nothing to ring")
    expect(WalkthroughTargetMatcher.resolve(nil, in: moved, displayFrame: display) == nil, "no target: nothing to ring")

    expect(WalkthroughTargetMatcher.labelSimilarity("Save", "Save") == 1, "same words = 1")
    expect(WalkthroughTargetMatcher.labelSimilarity("Change email", "Update email address") == 0, "one shared word out of four is not a match")
    expect(WalkthroughTargetMatcher.signature(of: moved) != WalkthroughTargetMatcher.signature(of: renamed), "different screens, different signatures")
    var scrolled = moved
    scrolled.elements = moved.elements.map { el($0.index, $0.role, $0.name, $0.frame.minX, $0.frame.minY + 40) }
    expect(WalkthroughTargetMatcher.signature(of: moved) == WalkthroughTargetMatcher.signature(of: scrolled), "scrolling alone is not a screen change")
}

section("local done checks")
do {
    func verdict(_ check: WalkthroughCheck?, _ snapshot: AXSnapshotData?, seen: Bool = true) -> WalkthroughVerdict {
        WalkthroughDoneCheck.evaluate(check, in: snapshot, subjectWasSeen: seen)
    }
    expect(verdict(nil, feed) == .undecidable, "no check: undecidable")
    expect(verdict(WalkthroughCheck(type: .appears, label: "Me"), nil) == .undecidable, "no snapshot: undecidable")
    expect(verdict(WalkthroughCheck(type: .appears, role: "link", label: "Settings & Privacy"), meMenu) == .satisfied, "appears: there")
    expect(verdict(WalkthroughCheck(type: .appears, role: "link", label: "Settings & Privacy"), feed) == .notSatisfied, "appears: not there")
    expect(verdict(WalkthroughCheck(type: .appears, role: "text field", label: "Settings & Privacy"), meMenu) == .notSatisfied, "appears: wrong kind of control")
    expect(verdict(WalkthroughCheck(type: .appears, label: "Settings & Privacy"), snap("x", feed.elements, truncated: true)) == .undecidable, "a cut-off list cannot prove absence")
    expect(verdict(WalkthroughCheck(type: .appears, label: "Anything"), snap("x", [])) == .undecidable, "an empty list cannot prove absence")
    expect(verdict(WalkthroughCheck(type: .disappears, label: "Sign Out"), meMenu) == .notSatisfied, "disappears: still there")
    expect(verdict(WalkthroughCheck(type: .disappears, label: "Sign Out"), feed) == .satisfied, "disappears: gone")
    expect(verdict(WalkthroughCheck(type: .disappears, label: "Sign Out"), feed, seen: false) == .undecidable, "disappears: never seen, so not trusted")
    expect(verdict(WalkthroughCheck(type: .titleContains, text: "settings"), settings) == .satisfied, "title contains, any case")
    expect(verdict(WalkthroughCheck(type: .titleContains, text: "Settings"), feed) == .notSatisfied, "title does not contain")
    let focused = snap("Form", [el(1, "AXTextField", "Email address", 0, 0, value: "a@b.co", focused: true), el(2, "AXSecureTextField", "Password", 0, 40, secure: true)])
    expect(verdict(WalkthroughCheck(type: .focused, label: "Email address"), focused) == .satisfied, "focused: yes")
    expect(verdict(WalkthroughCheck(type: .focused, label: "Password"), focused) == .notSatisfied, "focused: elsewhere")
    expect(verdict(WalkthroughCheck(type: .valueContains, label: "Email address", text: "@B.CO"), focused) == .satisfied, "value contains, any case")
    expect(verdict(WalkthroughCheck(type: .valueContains, label: "Email address", text: "gmail"), focused) == .notSatisfied, "value does not contain")
    expect(verdict(WalkthroughCheck(type: .valueContains, label: "Password", text: "hunter2"), focused) == .undecidable, "a password field's value is never judged")
}

// MARK: - Plan JSON

section("plan JSON: reading and validation")
do {
    let good = """
    {"steps":[
      {"say":"Click Me at the top right.","kind":"click","target":{"role":"button","label":"Me","point":[885,44]},"doneWhen":"A menu with Settings & Privacy is open","check":{"type":"appears","role":"link","label":"Settings & Privacy"}},
      {"say":"Type your new email.","kind":"type","target":{"role":"AXTextField","label":"Email address","point":{"x":1200,"y":-5}},"doneWhen":"The box has your email","check":null},
      {"say":"Wait for the code screen.","kind":"wait","target":null,"doneWhen":"A code box is showing","check":{"type":"sparkles","label":"x"}}
    ]}
    """
    let outcome = WalkthroughPlanParser.parse(good)
    expect(outcome.isValid && outcome.steps.count == 3, "a good plan is valid: \(outcome.issues)")
    expect(outcome.steps[0].target == WalkthroughTarget(role: "button", label: "Me", point: WalkthroughPoint(x: 885, y: 44)), "target read")
    expect(outcome.steps[0].check == WalkthroughCheck(type: .appears, role: "link", label: "Settings & Privacy", text: nil), "check read")
    expect(outcome.steps[1].target?.role == "text field", "raw AX role normalised")
    expect(outcome.steps[1].target?.point == WalkthroughPoint(x: 1000, y: 0), "an {x,y} point is read and clamped to 0…1000")
    expect(outcome.steps[2].target == nil && outcome.steps[2].kind == .wait, "a wait step may have no target")
    expect(outcome.steps[2].check == nil && outcome.notes.count == 1, "an unknown check is dropped with a note, not fatal")
    expect(Set(outcome.steps.map(\.id)).count == 3, "each step gets its own id")

    let fenced = "Sure! Here's the plan:\n```json\n{\"steps\":[{\"say\":\"Click File.\",\"kind\":\"press\",\"target\":{\"role\":\"menu\",\"label\":\"File\"},\"done_when\":\"The File menu is open\"}]}\n```\nLet me know!"
    let fencedOutcome = WalkthroughPlanParser.parse(fenced)
    expect(fencedOutcome.isValid && fencedOutcome.steps.first?.kind == .click && fencedOutcome.steps.first?.doneWhen == "The File menu is open", "tolerates a code fence, chatter, a kind synonym and done_when")

    let array = WalkthroughPlanParser.parse("[{\"say\":\"Click File.\",\"kind\":\"click\",\"target\":{\"label\":\"File\"},\"doneWhen\":\"open\"}]")
    expect(array.isValid && array.steps.count == 1, "a bare array of steps is accepted")

    expect(!WalkthroughPlanParser.parse("I think you should click the Me button first.").isValid, "prose is not a plan")
    expect(!WalkthroughPlanParser.parse("{\"plan\":[]}").isValid, "no steps array is invalid")
    expect(!WalkthroughPlanParser.parse("{\"steps\":[]}").isValid, "an empty plan with no problem is invalid")

    let problem = WalkthroughPlanParser.parse("{\"steps\":[],\"problem\":\"LinkedIn is not open.\"}")
    expect(problem.isValid && problem.problem == "LinkedIn is not open." && problem.steps.isEmpty, "a problem is a valid answer")

    let bad = """
    {"steps":[
      {"say":"","kind":"click","target":{"role":"button","label":"Me"},"doneWhen":"x"},
      {"say":"Do the thing.","kind":"dance","target":{"role":"button","label":"Me"},"doneWhen":"x"},
      {"say":"Click it.","kind":"click","target":{"role":"button"},"doneWhen":"x"},
      {"say":"Click it.","kind":"click","doneWhen":"x"},
      {"say":"Click Save.","kind":"click","target":{"role":"button","label":"Save"}},
      "just a string",
      {"say":"Click OK.","kind":"click","target":{"role":"button","label":"OK"},"doneWhen":"The sheet closed"}
    ]}
    """
    let badOutcome = WalkthroughPlanParser.parse(bad)
    expect(!badOutcome.isValid && badOutcome.issues.count == 6, "six broken steps, six issues: \(badOutcome.issues.map(\.text))")
    expect(badOutcome.steps.count == 1 && badOutcome.steps[0].say == "Click OK.", "the one good step is still read")
    expect(badOutcome.issues[0].text.contains("step 1") && badOutcome.issues[1].text.contains("kind"), "issues name the step and the fault")

    let long = WalkthroughPlanParser.parse("{\"steps\":[{\"say\":\"\(String(repeating: "word ", count: 60))\",\"kind\":\"look\",\"doneWhen\":\"x\"}]}")
    expect(!long.isValid, "a paragraph is not one spoken sentence")

    let many = "{\"steps\":[" + (1...18).map { "{\"say\":\"Click Item \($0).\",\"kind\":\"click\",\"target\":{\"role\":\"button\",\"label\":\"Item \($0)\"},\"doneWhen\":\"x\"}" }.joined(separator: ",") + "]}"
    let manyOutcome = WalkthroughPlanParser.parse(many)
    expect(manyOutcome.isValid && manyOutcome.steps.count == 15 && manyOutcome.notes.count == 1, "more than 15 steps: the first 15 are kept, with a note")
    expect(WalkthroughPlanParser.parse(many, maximumSteps: 4).steps.count == 4, "a re-plan's smaller budget is honoured")

    let repeated = WalkthroughPlanParser.parse(good, forbiddenSays: ["click me at the top right"])
    expect(!repeated.isValid && repeated.issues == [.repeatsFailedStep(stepNumber: 1)] && repeated.steps.count == 2, "repeating a failed instruction word for word is rejected")

    expect(WalkthroughPlanParser.yesNo("YES") == true && WalkthroughPlanParser.yesNo(" no.") == false && WalkthroughPlanParser.yesNo("Yes, the page is showing") == true, "yes/no")
    expect(WalkthroughPlanParser.yesNo("maybe") == nil && WalkthroughPlanParser.yesNo("") == nil, "neither yes nor no")
    expect(WalkthroughPlanParser.count("2", maximum: 5) == 2 && WalkthroughPlanParser.count("About 9 of them", maximum: 5) == 5 && WalkthroughPlanParser.count("none", maximum: 5) == nil, "resume count")
}

section("plan prompts")
do {
    let request = WalkthroughPlanRequest(goal: "change my email on LinkedIn", appName: "Safari", windowTitle: "Feed | LinkedIn",
                                         controlList: "[1] button \"Me\"", skillSection: "APP SKILL: LinkedIn — notes", maximumSteps: 15)
    let text = WalkthroughPrompts.planUserText(request)
    expect(text.contains("GOAL: change my email on LinkedIn") && text.contains("[1] button \"Me\"") && text.contains("APP SKILL: LinkedIn"), "the plan request carries the goal, the controls and the skill")
    expect(WalkthroughPrompts.planSystemText(maximumSteps: 7).contains("1 to 7 steps"), "the step budget is in the system prompt")

    var replan = request
    replan.logText = "- DONE step 1: they clicked \"Me\""
    replan.failedSays = ["Click Settings & Privacy."]
    let replanText = WalkthroughPrompts.planUserText(replan)
    expect(replanText.contains("DONE step 1") && replanText.contains("\"Click Settings & Privacy.\"") && replanText.contains("ONLY the steps that remain"), "a re-plan carries the log and the failed instructions")

    let messages = WalkthroughPrompts.planMessages(request, screenshotJPEG: Data([0xFF, 0xD8]))
    let content = messages[1]["content"] as? [[String: Any]]
    expect(messages.count == 2 && content?.count == 2 && content?.first?["type"] as? String == "image_url", "the screenshot is sent as an image part")
    expect(WalkthroughPrompts.planMessages(request, screenshotJPEG: nil)[1]["content"] is String, "no screenshot: plain text")

    let longList = (1...2000).map { "[\($0)] button \"Button number \($0)\"" }.joined(separator: "\n")
    let clipped = WalkthroughPrompts.clip(longList, to: 1000)
    expect(clipped.count < 1100 && clipped.split(separator: "\n").dropLast().allSatisfy { $0.hasSuffix("\"") }, "a long control list is cut at a line end")

    let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "hello"]]]])
    expect(WalkthroughPrompts.assistantText(from: response) == "hello", "assistant text read from a response")
}

section("plan: one repair retry")
do {
    final class Calls: @unchecked Sendable { var bodies: [[String: Any]] = []; var jobs: [TeachyAIJob] = []; var images: [Bool] = [] }
    func response(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
    }
    let goodPlan = "{\"steps\":[{\"say\":\"Click Me.\",\"kind\":\"click\",\"target\":{\"role\":\"button\",\"label\":\"Me\"},\"doneWhen\":\"menu open\"}]}"
    let request = WalkthroughPlanRequest(goal: "g", appName: "Safari", windowTitle: "", controlList: "", skillSection: "")

    let calls = Calls()
    let repaired = await WalkthroughAI.plan(request, screenshotJPEG: Data([1, 2, 3]), send: { job, hasImages, _, body in
        calls.bodies.append(body); calls.jobs.append(job); calls.images.append(hasImages)
        return response(calls.bodies.count == 1 ? "{\"steps\":[{\"say\":\"Click Me.\",\"kind\":\"click\"}]}" : goodPlan)
    })
    if case .steps(let steps) = repaired {
        expect(steps.count == 1 && steps[0].say == "Click Me.", "the repaired plan is used")
    } else {
        expect(false, "a bad first answer and a good repair should give steps")
    }
    expect(calls.bodies.count == 2, "exactly one repair retry, made \(calls.bodies.count) calls")
    expect(calls.images == [true, false], "the repair goes without the screenshot")
    expect(calls.bodies.allSatisfy { $0["model"] == nil }, "no model name in the body: the router picks")
    let repairMessages = calls.bodies.last?["messages"] as? [[String: Any]] ?? []
    expect(repairMessages.count == 4 && (repairMessages[3]["content"] as? String)?.contains("needs a \"target\"") == true, "the repair names what was wrong")

    let stubborn = Calls()
    let failed = await WalkthroughAI.plan(request, screenshotJPEG: nil, send: { _, _, _, body in
        stubborn.bodies.append(body)
        return response("not json at all")
    })
    if case .failed = failed { expect(stubborn.bodies.count == 2, "gives up after one retry, made \(stubborn.bodies.count) calls") } else { expect(false, "two bad answers should fail") }

    let once = Calls()
    _ = await WalkthroughAI.plan(request, screenshotJPEG: nil, send: { _, _, _, body in
        once.bodies.append(body)
        return response(goodPlan)
    })
    expect(once.bodies.count == 1, "a good first answer needs no retry")

    let refused = await WalkthroughAI.plan(request, screenshotJPEG: nil, send: { _, _, _, _ in response("{\"steps\":[],\"problem\":\"That app is not open.\"}") })
    if case .failed(let reason) = refused { expect(reason == "That app is not open.", "the planner's reason is passed on") } else { expect(false, "a problem should fail the plan") }

    // A re-plan that keeps repeating a failed line: that step is dropped, the rest is used.
    var replan = request
    replan.failedSays = ["Click Me."]
    let twoSteps = "{\"steps\":[{\"say\":\"Click Me.\",\"kind\":\"click\",\"target\":{\"role\":\"button\",\"label\":\"Me\"},\"doneWhen\":\"x\"},{\"say\":\"Open your profile photo menu.\",\"kind\":\"click\",\"target\":{\"role\":\"image\",\"label\":\"Photo\"},\"doneWhen\":\"x\"}]}"
    let salvaged = await WalkthroughAI.plan(replan, screenshotJPEG: nil, send: { _, _, _, _ in response(twoSteps) })
    if case .steps(let steps) = salvaged { expect(steps.map(\.say) == ["Open your profile photo menu."], "the repeated failed step is dropped") } else { expect(false, "should salvage") }

    let yes = await WalkthroughAI.quickCheck(condition: "x", controlList: "[1] button", screenshotJPEG: nil, send: { job, _, _, _ in
        expect(job == .quickCheck, "quick checks use the quickCheck job")
        return response("YES")
    })
    expect(yes == true, "quick check reads YES")
    let nothing = await WalkthroughAI.quickCheck(condition: "x", controlList: "", screenshotJPEG: nil, send: { _, _, _, _ in response("YES") })
    expect(nothing == nil, "nothing to look at: no call, no answer")
    let count = await WalkthroughAI.resumeCheck(goal: "g", remaining: [clickStep("A"), clickStep("B")], controlList: "[1] button", screenshotJPEG: nil, send: { _, _, _, _ in response("7") })
    expect(count == 2, "resume count is limited to the steps that remain")
}

// MARK: - Skills

section("skills: front matter and sections")
let sheetsFile = """
---
name: Google Sheets
bundleIds: []
sites: [docs.google.com/spreadsheets, "sheets.google.com"]
summary: Spreadsheets in the browser, with menus under the title.
---
Intro line before any heading.

## Layout
- Menu bar under the title: File, Edit, View, Insert, Format, Data, Tools, Extensions, Help.
- The formula bar sits above the grid.

## Where things are
- Freeze rows: View > Freeze.
- Make a chart: Insert > Chart.

### A deeper heading stays in its section
More text.

## Shortcuts
- Cmd+/ shows all shortcuts.
"""
do {
    guard let skill = SkillParser.parse(sheetsFile) else {
        expect(false, "the sample skill should parse")
        exit(1)
    }
    expect(skill.name == "Google Sheets", "name")
    expect(skill.bundleIDs.isEmpty, "empty inline list")
    expect(skill.sites == ["docs.google.com/spreadsheets", "sheets.google.com"], "inline list with a quoted item: \(skill.sites)")
    expect(skill.summary == "Spreadsheets in the browser, with menus under the title.", "a summary keeps its commas")
    expect(skill.sections.map(\.title) == ["", "Layout", "Where things are", "Shortcuts"], "sections split at ## only: \(skill.sections.map(\.title))")
    expect(skill.sections[2].text.contains("### A deeper heading") && skill.sections[2].text.hasSuffix("More text."), "deeper headings stay inside, no trailing blank lines")

    let listForm = """
    ---
    name: "Finder"
    bundleIds:
      - com.apple.finder
      - 'com.example.other'
    sites:
    summary: Files.
    ---
    ## Layout
    Text.
    """
    let finder = SkillParser.parse(listForm)
    expect(finder?.name == "Finder" && finder?.bundleIDs == ["com.apple.finder", "com.example.other"] && finder?.sites == [], "YAML list form and quotes: \(String(describing: finder?.bundleIDs))")

    expect(SkillParser.parse("## Layout\nNo front matter.") == nil, "no front matter: not a skill")
    expect(SkillParser.parse("---\nsummary: x\n---\nbody") == nil, "no name: not a skill")
    expect(SkillParser.parse("---\nname: X\nbody with no closing fence") == nil, "an unclosed front matter: not a skill")
    expect(SkillParser.parse("\u{FEFF}---\r\nname: Win\r\nbundleIds: [a.b]\r\n---\r\n## One\r\ntext\r\n")?.sections.first?.text == "## One\ntext", "BOM and CRLF are fine")
    expect(SkillParser.normalizeSite("https://www.GitHub.com/") == "github.com" && SkillParser.normalizeSite("*.slack.com") == "slack.com" && SkillParser.normalizeSite("localhost:3000/app") == "localhost/app", "sites are normalised")
}

section("skills: matching by bundle ID and site")
do {
    func make(_ name: String, bundles: [String] = [], sites: [String] = []) -> Skill {
        Skill(name: name, bundleIDs: bundles, sites: sites, summary: "", sections: [Skill.Section(title: "Layout", text: "## Layout\nx")])
    }
    let all = [
        make("Safari", bundles: ["com.apple.Safari"]),
        make("Chrome", bundles: ["com.google.Chrome"]),
        make("Google Docs", sites: ["docs.google.com/document"]),
        make("Google Sheets", sites: ["docs.google.com/spreadsheets", "sheets.google.com"]),
        make("Google (any)", sites: ["google.com"]),
        make("GitHub", sites: ["github.com"]),
        make("Slack", bundles: ["com.tinyspeck.slackmacgap"], sites: ["app.slack.com"]),
        make("Finder", bundles: ["com.apple.finder"]),
    ]
    func pick(_ bundle: String?, _ location: String?) -> String? { SkillMatcher.bestSkill(in: all, bundleID: bundle, browserLocation: location)?.name }

    expect(pick("com.apple.finder", nil) == "Finder", "bundle ID match")
    expect(pick("COM.APPLE.FINDER", nil) == "Finder", "bundle IDs match in any case")
    expect(pick("com.unknown.app", nil) == nil, "an unknown app has no skill")
    expect(pick(nil, nil) == nil, "nothing known: no skill")
    expect(pick("com.apple.Safari", nil) == "Safari", "a browser with no known page: the browser's skill")
    expect(pick("com.apple.Safari", "github.com") == "GitHub", "a site skill beats the browser's")
    expect(pick("com.google.Chrome", "https://github.com/VedSoni-dev/teachy/pulls?q=is%3Aopen") == "GitHub", "a full URL works")
    expect(pick("com.google.Chrome", "gist.github.com") == "GitHub", "host suffix: a subdomain matches")
    expect(pick("com.google.Chrome", "notgithub.com") == "Chrome", "but not a host that merely ends with the same letters")
    expect(pick("com.google.Chrome", "https://docs.google.com/spreadsheets/d/abc/edit#gid=0") == "Google Sheets", "path prefix picks Sheets")
    expect(pick("com.google.Chrome", "https://docs.google.com/document/d/abc/edit") == "Google Docs", "path prefix picks Docs")
    expect(pick("com.google.Chrome", "https://docs.google.com/presentation/d/abc") == "Google (any)", "an unlisted path falls to the broader site skill")
    expect(pick("com.google.Chrome", "https://www.google.com/search?q=x") == "Google (any)", "www is ignored")
    expect(pick("com.google.Chrome", "docs.google.com/spreadsheetsfoo") == "Google (any)", "a path prefix ends at a slash")
    expect(pick("com.google.Chrome", "https://example.org/") == "Chrome", "an unknown site: the browser's skill")
    expect(pick("com.tinyspeck.slackmacgap", nil) == "Slack" && pick("com.apple.Safari", "app.slack.com/client/T1/C1") == "Slack", "one skill for the app and its site")

    expect(SkillMatcher.browserLocation(fromTabContext: "Safari tab: \"Feed | LinkedIn\" — https://www.linkedin.com/feed/") == "https://www.linkedin.com/feed/", "URL pulled out of the tab line")
    expect(SkillMatcher.browserLocation(fromTabContext: "Safari tab: \"A — B: c\" — http://localhost:3000/x") == "http://localhost:3000/x", "even with dashes and colons in the title")
    expect(SkillMatcher.browserLocation(fromTabContext: nil) == nil && SkillMatcher.browserLocation(fromTabContext: "no url here") == nil, "no URL, no location")
}

section("skills: budgeted prompt section")
do {
    let skill = SkillParser.parse(sheetsFile)!
    let full = SkillPrompt.section(for: skill, budgetCharacters: 10_000)
    expect(full.hasPrefix("APP SKILL: Google Sheets — Spreadsheets in the browser") && full.contains("## Shortcuts") && full.contains("Intro line"), "with room, everything is in")

    let sourceLines = Set(sheetsFile.components(separatedBy: "\n"))
    for budget in stride(from: 0, through: 900, by: 7) {
        let text = SkillPrompt.section(for: skill, budgetCharacters: budget)
        expect(text.count <= budget, "budget \(budget): \(text.count) characters")
        if text.isEmpty { continue }
        let lines = text.components(separatedBy: "\n")
        // Every line after the two header lines is a whole line of the file.
        expect(lines.dropFirst(2).allSatisfy { $0.isEmpty || sourceLines.contains($0) }, "budget \(budget): no line is cut")
        // Every section that is in is in whole.
        for section in skill.sections where text.contains(section.text.components(separatedBy: "\n")[0]) && !section.title.isEmpty {
            expect(text.contains(section.text), "budget \(budget): section \(section.title) is whole")
        }
    }
    let header = SkillPrompt.section(for: skill, budgetCharacters: 10_000).components(separatedBy: "\n\n")[0]
    expect(SkillPrompt.section(for: skill, budgetCharacters: header.count - 1).isEmpty, "not even the heading fits: nothing")
    expect(SkillPrompt.section(for: skill, budgetCharacters: header.count + 5).isEmpty, "a heading with no section under it is not worth sending")

    // A long section that does not fit is left out; a later short one still goes in.
    let tight = SkillPrompt.section(for: skill, budgetCharacters: header.count + 2 + skill.sections[0].text.count + 2 + skill.sections[3].text.count)
    expect(tight.contains("Intro line") && tight.contains("## Shortcuts") && !tight.contains("## Layout"), "skips what does not fit, keeps later sections that do")
}

section("skills: library, user folder overrides bundled by name")
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-skill-tests-\(UUID().uuidString)")
    let bundled = root.appendingPathComponent("bundle"), user = root.appendingPathComponent("user")
    try! FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, _ url: URL) { try! text.write(to: url, atomically: true, encoding: .utf8) }
    write("---\nname: Finder\nbundleIds: [com.apple.finder]\nsummary: Bundled.\n---\n## Layout\nbundled text\n", bundled.appendingPathComponent("finder.skill.md"))
    write("---\nname: Notes\nbundleIds: [com.apple.Notes]\nsummary: Bundled.\n---\n## Layout\nnotes text\n", bundled.appendingPathComponent("notes.skill.md"))
    // Other Markdown in the app bundle (AGENTS.md is there today) must not be read as a skill.
    write("---\nname: Not A Skill\nbundleIds: [com.apple.finder]\n---\n## x\ny\n", bundled.appendingPathComponent("AGENTS.md"))
    write("not a skill at all", bundled.appendingPathComponent("broken.skill.md"))

    let library = SkillLibrary(bundledDirectories: [bundled], userDirectory: user)
    expect(library.skills.map(\.name) == ["Finder", "Notes"], "loads only *.skill.md from the bundle, skipping broken files: \(library.skills.map(\.name))")
    expect(library.skill(forBundleID: "com.apple.finder", browserHost: nil)?.summary == "Bundled.", "bundled skill found")

    write("---\nname: finder\nbundleIds: [com.apple.finder]\nsummary: Mine.\n---\n## Layout\nmy text\n", user.appendingPathComponent("my-finder.md"))
    write("---\nname: Linear\nsites: [linear.app]\nsummary: Community.\n---\n## Layout\nlinear text\n", user.appendingPathComponent("linear.md"))
    let names = library.skills.map(\.name)
    expect(names == ["finder", "Notes", "Linear"], "a user file replaces the bundled skill of the same name and new ones are added, got \(names)")
    let mine = library.skill(forBundleID: "com.apple.finder", browserHost: nil)
    expect(mine?.summary == "Mine." && mine?.origin == "user", "the user's Finder skill wins")
    expect(library.skill(forBundleID: "com.apple.Safari", browserHost: "linear.app/team/issue/1")?.name == "Linear", "community site skill found")

    let prompt = library.promptSection(frontmostBundleID: "com.apple.Safari", browserTabContext: "Safari tab: \"Issue\" — https://linear.app/t/1", budgetCharacters: 500)
    expect(prompt.contains("APP SKILL: Linear") && prompt.contains("linear text"), "one call from bundle ID + tab line to prompt text")
    expect(library.promptSection(frontmostBundleID: "com.unknown", browserTabContext: nil).isEmpty, "no skill: empty string")

    try! FileManager.default.removeItem(at: user.appendingPathComponent("my-finder.md"))
    expect(library.skill(forBundleID: "com.apple.finder", browserHost: nil)?.summary == "Bundled.", "removing the user file brings the bundled skill back without a restart")
}

section("skills: every file in skills/")
do {
    // skills/ is a link to leanring-buddy/Skills/Library (the only folder Xcode bundles).
    let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "skills").resolvingSymlinksInPath()
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasSuffix(".skill.md") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    expect(files.count >= 25, "at least 25 skill files, found \(files.count) in \(folder.path)")

    var names = Set<String>()
    var claimed: [String: String] = [:]
    var loaded: [Skill] = []
    for file in files {
        let name = file.lastPathComponent
        guard let text = try? String(contentsOf: file, encoding: .utf8), let skill = SkillParser.parse(text) else {
            expect(false, "\(name) does not parse")
            continue
        }
        loaded.append(skill)
        expect(names.insert(skill.name.lowercased()).inserted, "\(name): the name \"\(skill.name)\" is used twice")
        expect(!skill.bundleIDs.isEmpty || !skill.sites.isEmpty, "\(name): needs a bundle ID or a site")
        expect(!skill.summary.isEmpty && skill.summary.count <= 140, "\(name): needs a short summary")
        expect(skill.sections.count >= 3 && skill.sections.allSatisfy { !$0.title.isEmpty }, "\(name): at least three ## sections and no loose text")
        // Words: anything with a letter or digit in it (so "-", ">" and "##" do not count).
        let words = skill.body.split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
        expect((150...400).contains(words), "\(name): body is \(words) words, wanted 150–400")
        expect(!text.contains("—") && !text.contains("\t"), "\(name): no em dashes or tabs")
        for key in skill.bundleIDs.map({ "bundle " + $0.lowercased() }) + skill.sites.map({ "site " + $0 }) {
            expect(claimed[key] == nil, "\(name): \(key) is already claimed by \(claimed[key] ?? "")")
            claimed[key] = name
        }
        // Each one fits the default budget whole.
        let prompt = SkillPrompt.section(for: skill, budgetCharacters: SkillLibrary.defaultPromptBudget)
        expect(skill.sections.allSatisfy { prompt.contains($0.text) }, "\(name): does not fit the default prompt budget whole (\(prompt.count) of \(SkillLibrary.defaultPromptBudget) characters used)")
    }

    let expected: [(String, String?, String?)] = [
        ("Finder", "com.apple.finder", nil), ("System Settings", "com.apple.systempreferences", nil), ("Safari", "com.apple.Safari", nil),
        ("Google Chrome", "com.google.Chrome", nil), ("Mail", "com.apple.mail", nil), ("Notes", "com.apple.Notes", nil),
        ("Calendar", "com.apple.iCal", nil), ("Keynote", "com.apple.iWork.Keynote", nil), ("Pages", "com.apple.iWork.Pages", nil),
        ("Numbers", "com.apple.iWork.Numbers", nil), ("Xcode", "com.apple.dt.Xcode", nil), ("Visual Studio Code", "com.microsoft.VSCode", nil),
        ("Cursor", "com.todesktop.230313mzl4w4u92", nil), ("Terminal", "com.apple.Terminal", nil), ("Figma", "com.figma.Desktop", nil),
        ("Figma", "com.google.Chrome", "https://www.figma.com/design/abc/File"), ("Notion", "notion.id", nil),
        ("Slack", "com.tinyspeck.slackmacgap", nil), ("Google Docs", "com.apple.Safari", "https://docs.google.com/document/d/1/edit"),
        ("Google Sheets", "com.apple.Safari", "https://docs.google.com/spreadsheets/d/1/edit"), ("Gmail", "com.google.Chrome", "https://mail.google.com/mail/u/0/#inbox"),
        ("GitHub", "com.apple.Safari", "https://github.com/apple/swift"), ("Photoshop", "com.adobe.Photoshop", nil),
        ("Final Cut Pro", "com.apple.FinalCut", nil), ("Blender", "org.blenderfoundation.blender", nil), ("Microsoft Excel", "com.microsoft.Excel", nil),
        ("LinkedIn", "com.apple.Safari", "https://www.linkedin.com/feed/"),
    ]
    for (name, bundle, location) in expected {
        let found = SkillMatcher.bestSkill(in: loaded, bundleID: bundle, browserLocation: location)?.name
        expect(found == name, "\(bundle ?? "-") \(location ?? "") should pick \(name), got \(found ?? "nothing")")
    }
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASSED")
