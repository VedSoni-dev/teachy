//
//  WalkthroughEngine.swift
//  leanring-buddy / Walkthrough
//
//  The walkthrough as an explicit state machine. It never talks to the model,
//  the screen or the speaker itself: events come in (a plan arrived, a fresh
//  accessibility snapshot, a click, something the person said, a check's
//  answer) and effects come out (speak this, ring that, ask for a plan, save).
//  WalkthroughCenter turns the effects into real work.
//
//    planning ──plan──▶ checking ──screen──▶ waitingForUser ──click in ring / check passes / "next"──▶ checking …
//                          │ step already done: skip, no talking          │ two failures on one step
//                          ▼ no steps left                                ▼
//                         done                                    planning (re-plan, at most twice) or stopped
//
//  Pure. Tested by scripts/tests/run_walk_tests.sh.
//

import CoreGraphics
import Foundation

struct WalkthroughRing: Equatable {
    /// Global CG coordinates (top-left origin).
    var frame: CGRect
    var label: String
    var stepNumber: Int
    var stepCount: Int
    /// A bare point is ringed with a looser circle than a real control.
    var isApproximate: Bool
}

struct WalkthroughEngine {
    enum Event {
        /// The steps for a first plan, or the remaining steps for a re-plan.
        case planReady([WalkthroughStep])
        /// The planner could not produce steps. `spokenReason` is said to the person when present.
        case planFailed(spokenReason: String?)
        /// A fresh, settled accessibility snapshot of the front window (nil when it cannot be read).
        case screen(AXSnapshotData?)
        /// A mouse-down at a global CG point.
        case click(CGPoint)
        case command(WalkthroughVoiceCommand)
        /// The model's answer to `requestQuickCheck`. Nil when it could not say.
        case quickCheck(stepID: String, isDone: Bool?)
        /// The model's answer to `requestResumeCheck`: how many remaining steps are already done.
        case resumeCheck(alreadyDone: Int?)
        /// The ringed control moved (its window was dragged or the page scrolled).
        case targetMoved(CGRect)
    }

    enum Effect: Equatable {
        case speak(String)
        case showRing(WalkthroughRing)
        /// `completed` plays the "done" fade; otherwise the ring just goes.
        case hideRing(completed: Bool)
        case requestPlan
        case requestReplan
        /// Read the screen once it has stopped changing, and send `.screen`.
        case requestScreen
        case requestQuickCheck(stepID: String, condition: String)
        case requestResumeCheck
        case persist
        /// The walkthrough is over for now (`.done` or `.stopped`).
        case finished(WalkthroughStatus)
    }

    /// A click this close outside a control still counts as on it.
    static let clickTolerance: CGFloat = 8
    /// Typed text must sit unchanged this long before a "type" step counts as done.
    static let typingPause: TimeInterval = 1.2
    /// No automatic model check sooner than this after a step was given.
    static let quickCheckDelay: TimeInterval = 2

    private(set) var session: WalkthroughSession

    // What is known about the step being waited on. Reset whenever the step changes.
    private(set) var resolvedTarget: WalkthroughResolvedTarget?
    private var isReplanning = false
    private var stepGivenAt: Date?
    private var signatureWhenGiven = ""
    private var pendingOutsideClick = false
    private var quickCheckUsed = false
    private var awaitingQuickCheck = false
    private var targetGoneAtQuickCheck = false
    private var checkSubjectSeen = false
    private var typedBaseline: String?
    private var typedLastValue: String?
    private var typedLastChange: Date?
    /// The step just returned to with "back": do not skip it even if it looks done.
    private var holdSkipForStepID: String?

    init(goal: String, appName: String = "", bundleID: String = "", displayFrame: CGRect = .zero, now: Date = Date()) {
        session = WalkthroughSession(goal: goal, appName: appName, bundleID: bundleID, displayFrame: displayFrame, now: now)
    }

    /// Picks a saved walkthrough back up.
    init(resuming session: WalkthroughSession) {
        self.session = session
    }

    var status: WalkthroughStatus { session.status }
    var currentStep: WalkthroughStep? { session.currentStep }

    // MARK: Starting

    mutating func start(now: Date = Date()) -> [Effect] {
        session.status = .planning
        session.updatedAt = now
        return [.persist, .requestPlan]
    }

    /// Continue after a pause or a relaunch: check how far they got on their own, then carry on.
    mutating func resume(now: Date = Date()) -> [Effect] {
        guard session.status != .done else { return [] }
        resetStepState()
        session.record(.note, "picked back up", now: now)
        if session.steps.isEmpty {
            session.status = .planning
            return [.speak("Picking that back up. Give me a moment to look."), .persist, .requestPlan]
        }
        if session.currentIndex >= session.steps.count {
            return finish(now: now)
        }
        session.status = .checking
        return [.speak("Picking up where we left off."), .persist, .requestResumeCheck]
    }

    /// Tells the engine which display the plan is being made on (known only once the screen is captured).
    mutating func setPlanningContext(appName: String, bundleID: String, displayFrame: CGRect) {
        if !appName.isEmpty { session.appName = appName }
        if !bundleID.isEmpty { session.bundleID = bundleID }
        if displayFrame.width > 0, displayFrame.height > 0 { session.displayFrame = displayFrame }
    }

    // MARK: Events

    mutating func handle(_ event: Event, now: Date = Date()) -> [Effect] {
        switch event {
        case .planReady(let steps):
            return planArrived(steps, now: now)
        case .planFailed(let spokenReason):
            return planFailed(spokenReason: spokenReason, now: now)
        case .screen(let snapshot):
            switch session.status {
            case .checking: return giveCurrentStep(snapshot, now: now)
            case .waitingForUser: return watch(snapshot, now: now)
            case .planning, .done, .stopped: return []
            }
        case .click(let point):
            return clicked(at: point, now: now)
        case .command(let command):
            return heard(command, now: now)
        case .quickCheck(let stepID, let isDone):
            return quickCheckAnswered(stepID: stepID, isDone: isDone, now: now)
        case .resumeCheck(let alreadyDone):
            return resumeCheckAnswered(alreadyDone, now: now)
        case .targetMoved(let frame):
            if session.status == .waitingForUser, resolvedTarget != nil { resolvedTarget?.frame = frame }
            return []
        }
    }

    // MARK: Plans

    private mutating func planArrived(_ steps: [WalkthroughStep], now: Date) -> [Effect] {
        guard session.status == .planning else { return [] }
        guard !steps.isEmpty else { return planFailed(spokenReason: nil, now: now) }

        if isReplanning {
            let kept = Array(session.steps.prefix(session.currentIndex))
            let room = WalkthroughSession.maximumSteps - kept.count
            guard room > 0 else { return planFailed(spokenReason: nil, now: now) }
            let fresh = Array(steps.prefix(room))
            session.steps = kept + fresh
            session.replanCount += 1
            session.record(.replanned, "worked out \(fresh.count) new step\(fresh.count == 1 ? "" : "s") from where they are", now: now)
            isReplanning = false
        } else {
            session.steps = Array(steps.prefix(WalkthroughSession.maximumSteps))
            session.currentIndex = 0
        }
        resetStepState()
        session.status = .checking
        session.updatedAt = now
        return [.persist, .requestScreen]
    }

    private mutating func planFailed(spokenReason: String?, now: Date) -> [Effect] {
        guard session.status == .planning else { return [] }
        let line: String
        if let spokenReason, !spokenReason.isEmpty {
            line = spokenReason
        } else if isReplanning {
            line = "I couldn't find another way from here. I've paused the walkthrough; say continue to try this step again."
        } else {
            line = "I couldn't work out the steps for that. Try asking me again in different words."
        }
        session.record(.note, isReplanning ? "re-planning failed" : "planning failed", now: now)
        isReplanning = false
        session.status = .stopped
        return [.hideRing(completed: false), .speak(line), .persist, .finished(.stopped)]
    }

    // MARK: Giving a step

    /// Skips steps the screen shows are already done, then gives the first one that is not.
    private mutating func giveCurrentStep(_ snapshot: AXSnapshotData?, now: Date) -> [Effect] {
        while let step = session.currentStep {
            if step.id == holdSkipForStepID { break }
            // `disappears` is not trusted here: its subject has not been seen during this step.
            guard WalkthroughDoneCheck.evaluate(step.check, in: snapshot, subjectWasSeen: false) == .satisfied else { break }
            session.record(.skipped, "\"\(step.say)\" — the screen already shows: \(step.doneWhen)", stepNumber: session.currentIndex + 1, now: now)
            session.currentIndex += 1
        }
        holdSkipForStepID = nil

        guard let step = session.currentStep else { return finish(now: now) }

        resetStepState()
        stepGivenAt = now
        signatureWhenGiven = WalkthroughTargetMatcher.signature(of: snapshot)
        checkSubjectSeen = WalkthroughDoneCheck.subjectIsPresent(step.check, in: snapshot)
        resolvedTarget = WalkthroughTargetMatcher.resolve(step.target, in: snapshot, displayFrame: session.displayFrame)
        typedBaseline = currentValue(of: resolvedTarget, in: snapshot)

        session.status = .waitingForUser
        session.updatedAt = now

        var effects: [Effect] = [.persist]
        effects.append(ringEffect(for: step) ?? .hideRing(completed: false))
        effects.append(.speak(step.say))
        return effects
    }

    private mutating func finish(now: Date) -> [Effect] {
        session.status = .done
        session.record(.note, "finished", now: now)
        resetStepState()
        return [.hideRing(completed: true), .speak("That's everything. You're all set."), .persist, .finished(.done)]
    }

    // MARK: Waiting on the person

    /// A new settled snapshot while a step is out: is it done, did the target move, did they wander off?
    private mutating func watch(_ snapshot: AXSnapshotData?, now: Date) -> [Effect] {
        guard let step = session.currentStep, !awaitingQuickCheck else { return [] }

        let hadElement = resolvedTarget?.source == .element
        let fresh = WalkthroughTargetMatcher.resolve(step.target, in: snapshot, displayFrame: session.displayFrame)
        let targetGone = hadElement && fresh?.source != .element
        if WalkthroughDoneCheck.subjectIsPresent(step.check, in: snapshot) { checkSubjectSeen = true }

        var verdict = WalkthroughDoneCheck.evaluate(step.check, in: snapshot, subjectWasSeen: checkSubjectSeen)
        if verdict == .undecidable {
            verdict = builtInVerdict(for: step, target: fresh, snapshot: snapshot, now: now)
        }
        if verdict == .satisfied {
            return advance(note: "the screen shows: \(step.doneWhen)", now: now)
        }

        let screenChanged = WalkthroughTargetMatcher.signature(of: snapshot) != signatureWhenGiven
        let outsideClick = pendingOutsideClick
        pendingOutsideClick = false

        // Something happened that the snapshot cannot judge: ask the model, once per step.
        if verdict == .undecidable, !quickCheckUsed, screenChanged,
           outsideClick || targetGone || canCheckWithoutClick(step, target: fresh),
           now.timeIntervalSince(stepGivenAt ?? now) >= (outsideClick ? 0 : Self.quickCheckDelay) {
            quickCheckUsed = true
            awaitingQuickCheck = true
            targetGoneAtQuickCheck = outsideClick && targetGone
            updateTarget(to: fresh)
            return [.requestQuickCheck(stepID: step.id, condition: step.doneWhen)]
        }

        // They clicked somewhere else and the control they were sent to is no longer there.
        if outsideClick, targetGone, verdict != .satisfied {
            updateTarget(to: fresh)
            return fail(reason: "they clicked somewhere else and \"\(step.target?.label ?? "the control")\" is no longer on screen", now: now)
        }

        // Keep the ring on the control as it appears, moves or goes.
        if fresh != resolvedTarget {
            updateTarget(to: fresh)
            return [ringEffect(for: step) ?? .hideRing(completed: false)]
        }
        return []
    }

    /// A check that needs no `check` from the planner: text typed into the ringed field, then a pause.
    private mutating func builtInVerdict(for step: WalkthroughStep, target: WalkthroughResolvedTarget?, snapshot: AXSnapshotData?, now: Date) -> WalkthroughVerdict {
        switch step.kind {
        case .type:
            guard let value = currentValue(of: target, in: snapshot), !value.isEmpty, value != (typedBaseline ?? "") else {
                typedLastValue = nil
                typedLastChange = nil
                return .undecidable
            }
            if value == typedLastValue, let since = typedLastChange {
                return now.timeIntervalSince(since) >= Self.typingPause ? .satisfied : .undecidable
            }
            typedLastValue = value
            typedLastChange = now
            return .undecidable
        case .click, .wait, .look:
            // A "look" step is often "go and do this somewhere else" (open the email, read the code).
            // It never moves on by a timer: the person says "next", or the one model check sees it done.
            return .undecidable
        }
    }

    /// Steps that finish without a click (waiting, or typing where the field cannot be read).
    private func canCheckWithoutClick(_ step: WalkthroughStep, target: WalkthroughResolvedTarget?) -> Bool {
        switch step.kind {
        case .wait, .look: return true
        case .type: return target?.source != .element
        case .click: return false
        }
    }

    private func currentValue(of target: WalkthroughResolvedTarget?, in snapshot: AXSnapshotData?) -> String? {
        guard let index = target?.elementIndex, let element = snapshot?.element(at: index),
              AXSnapshotBuilder.textEntryRoles.contains(element.role), !element.isSecure
        else { return nil }
        return element.value
    }

    private mutating func clicked(at point: CGPoint, now: Date) -> [Effect] {
        // A click on the ring counts even while a model check is out; its late answer is then ignored.
        guard session.status == .waitingForUser, let step = session.currentStep else { return [] }
        let isOnTarget = resolvedTarget.map {
            $0.frame.insetBy(dx: -Self.clickTolerance, dy: -Self.clickTolerance).contains(point)
        } ?? false

        if isOnTarget {
            switch step.kind {
            case .click:
                return advance(note: "they clicked \"\(resolvedTarget?.name ?? step.target?.label ?? "it")\"", now: now)
            case .type, .wait, .look:
                // Clicking into the field they are about to type in is part of the step, not the end of it.
                return []
            }
        }
        pendingOutsideClick = true
        return [.requestScreen]
    }

    private mutating func heard(_ command: WalkthroughVoiceCommand, now: Date) -> [Effect] {
        switch command {
        case .stop:
            guard session.status != .done, session.status != .stopped else { return [] }
            session.status = .stopped
            session.record(.note, "paused by the person", now: now)
            isReplanning = false
            awaitingQuickCheck = false
            return [.hideRing(completed: false), .speak("Okay, paused. Say continue when you want to pick it back up."), .persist, .finished(.stopped)]

        case .next, .resume:
            guard session.status == .waitingForUser, let step = session.currentStep else { return [] }
            awaitingQuickCheck = false
            return advance(note: "they said \"\(step.say)\" is done", now: now)

        case .back:
            guard session.status == .waitingForUser else { return [] }
            awaitingQuickCheck = false
            if session.currentIndex > 0 {
                session.currentIndex -= 1
                session.record(.note, "went back a step", stepNumber: session.currentIndex + 1, now: now)
            }
            holdSkipForStepID = session.currentStep?.id
            resetStepState()
            session.status = .checking
            return [.hideRing(completed: false), .persist, .requestScreen]

        case .repeatStep:
            guard session.status == .waitingForUser, let step = session.currentStep else { return [] }
            var effects: [Effect] = []
            if let ring = ringEffect(for: step) { effects.append(ring) }
            effects.append(.speak(step.say))
            return effects

        case .stuck:
            guard session.status == .waitingForUser else { return [] }
            awaitingQuickCheck = false
            return fail(reason: "they said they were stuck", now: now)
        }
    }

    private mutating func quickCheckAnswered(stepID: String, isDone: Bool?, now: Date) -> [Effect] {
        guard session.status == .waitingForUser, awaitingQuickCheck, let step = session.currentStep, step.id == stepID else { return [] }
        awaitingQuickCheck = false
        if isDone == true {
            return advance(note: "checked the screen: \(step.doneWhen)", now: now)
        }
        if isDone == false, targetGoneAtQuickCheck {
            targetGoneAtQuickCheck = false
            return fail(reason: "they clicked somewhere else and the screen does not show: \(step.doneWhen)", now: now)
        }
        return []
    }

    private mutating func resumeCheckAnswered(_ alreadyDone: Int?, now: Date) -> [Effect] {
        guard session.status == .checking else { return [] }
        let remaining = session.steps.count - session.currentIndex
        let skipped = min(max(alreadyDone ?? 0, 0), remaining)
        for _ in 0..<skipped {
            if let step = session.currentStep {
                session.record(.skipped, "\"\(step.say)\" — done while paused", stepNumber: session.currentIndex + 1, now: now)
            }
            session.currentIndex += 1
        }
        return [.persist, .requestScreen]
    }

    // MARK: Moving on, or not

    /// The step is done: no praise, no chatter. The next instruction is spoken once the screen settles.
    private mutating func advance(note: String, now: Date) -> [Effect] {
        session.record(.done, note, stepNumber: session.currentIndex + 1, now: now)
        session.currentIndex += 1
        resetStepState()
        session.status = .checking
        return [.hideRing(completed: true), .persist, .requestScreen]
    }

    /// One failure: say it another way. Two on the same step: plan the rest again from where they
    /// are, with the log as context. After two re-plans: stop rather than loop.
    private mutating func fail(reason: String, now: Date) -> [Effect] {
        guard let step = session.currentStep else { return [] }
        session.steps[session.currentIndex].failureCount += 1
        session.record(.failed, WalkthroughSession.failedLogText(say: step.say, reason: reason), stepNumber: session.currentIndex + 1, now: now)
        pendingOutsideClick = false

        if session.steps[session.currentIndex].failureCount >= WalkthroughSession.failuresBeforeReplan {
            resetStepState()
            if session.replanCount < WalkthroughSession.maximumReplans {
                isReplanning = true
                session.status = .planning
                return [.hideRing(completed: false), .speak("Let me look again and find another way."), .persist, .requestReplan]
            }
            session.status = .stopped
            return [
                .hideRing(completed: false),
                .speak("I've tried a couple of routes and we're still not there, so I've paused the walkthrough. Ask me about what's on your screen and we'll sort it out."),
                .persist,
                .finished(.stopped),
            ]
        }

        var effects: [Effect] = [.persist]
        if let ring = ringEffect(for: step) { effects.append(ring) }
        effects.append(.speak(Self.retryLine(for: step, target: resolvedTarget)))
        return effects
    }

    /// What is said after a first failure. Never the step's own sentence again.
    static func retryLine(for step: WalkthroughStep, target: WalkthroughResolvedTarget?) -> String {
        let label = step.target?.label ?? ""
        let line: String
        if let target, target.source == .element {
            let name = target.name.isEmpty ? label : target.name
            line = name.isEmpty
                ? "It's the \(target.role) I've circled."
                : "It's the \(target.role) called \(name). I've circled it for you."
        } else if target != nil {
            line = label.isEmpty
                ? "Try the spot I've circled."
                : "Try the spot I've circled; it should say \(label)."
        } else if !label.isEmpty {
            line = "I can't see \(label) on this screen yet. Scroll or look around for it, and tell me you're stuck if it isn't there."
        } else {
            line = "No rush. You'll know it worked when you see this: \(step.doneWhen)."
        }
        return WalkthroughTargetMatcher.normalize(line) == WalkthroughTargetMatcher.normalize(step.say)
            ? "Have another look: \(step.doneWhen) is what we're after."
            : line
    }

    // MARK: Ring

    private mutating func updateTarget(to target: WalkthroughResolvedTarget?) {
        resolvedTarget = target
    }

    private func ringEffect(for step: WalkthroughStep) -> Effect? {
        guard let target = resolvedTarget else { return nil }
        return .showRing(WalkthroughRing(
            frame: target.frame,
            label: Self.ringLabel(for: step, target: target),
            stepNumber: session.currentIndex + 1,
            stepCount: session.steps.count,
            isApproximate: target.source == .point
        ))
    }

    static func ringLabel(for step: WalkthroughStep, target: WalkthroughResolvedTarget) -> String {
        var name = step.target?.label ?? ""
        if name.isEmpty { name = target.name }
        if name.count > 30 { name = String(name.prefix(29)) + "…" }
        switch step.kind {
        case .click: return name.isEmpty ? "Click here" : name
        case .type: return name.isEmpty ? "Type here" : "Type in \(name)"
        case .wait: return name.isEmpty ? "Wait for this" : name
        case .look: return name.isEmpty ? "Look here" : name
        }
    }

    private mutating func resetStepState() {
        resolvedTarget = nil
        stepGivenAt = nil
        signatureWhenGiven = ""
        pendingOutsideClick = false
        quickCheckUsed = false
        awaitingQuickCheck = false
        targetGoneAtQuickCheck = false
        checkSubjectSeen = false
        typedBaseline = nil
        typedLastValue = nil
        typedLastChange = nil
    }
}
