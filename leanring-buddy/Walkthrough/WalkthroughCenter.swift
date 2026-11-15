//
//  WalkthroughCenter.swift
//  leanring-buddy / Walkthrough
//
//  Runs a walkthrough: owns the engine (WalkthroughEngine, the state machine)
//  and does what it asks for — model calls, reading the screen, the ring, the
//  click tap, speech, and saving to ~/.teachy/walkthroughs/current.json.
//
//  The host sets two callbacks and calls three methods:
//
//      WalkthroughCenter.shared.speak = { text in … }            // say one line, return when it has been said
//      WalkthroughCenter.shared.captureScreen = { … }             // a JPEG of the display the person is on
//      WalkthroughCenter.shared.start(goal: "change my email on LinkedIn", screenshot: nil)
//      WalkthroughCenter.shared.handleSpoken(transcript)          // true = the walkthrough took it
//      WalkthroughCenter.shared.stop()
//
//  Nothing here moves the pointer, presses a key or blocks an event.
//

import AppKit
import Combine
import Foundation

struct WalkthroughUIState: Equatable {
    /// A walkthrough is running (planning, checking or waiting on the person).
    var isActive = false
    var status: WalkthroughStatus?
    var goal = ""
    /// 1-based. 0 while the first plan is being made.
    var stepNumber = 0
    var stepCount = 0
    /// The current step's sentence.
    var instruction = ""
    /// A paused walkthrough is saved and "continue" will pick it up.
    var canResume = false
}

@MainActor
final class WalkthroughCenter: ObservableObject {
    static let shared = WalkthroughCenter()

    /// A screenshot of one display. `displayFrame` is that display's frame in AppKit screen
    /// coordinates (`NSScreen.frame`), as in `CompanionScreenCapture`.
    typealias ScreenCapture = (data: Data, width: Int, height: Int, displayFrame: CGRect)

    /// Says one line out loud and returns when it has been said. Set by the host.
    var speak: (String) async -> Void = { _ in }
    /// Captures the display the person is working on. Set by the host.
    var captureScreen: () async -> ScreenCapture? = { nil }

    /// Makes the plan. The default asks the model; a test harness can put a fixed plan here.
    var planner: (WalkthroughPlanRequest, Data?) async -> WalkthroughPlanResult = { request, screenshot in
        await WalkthroughAI.plan(request, screenshotJPEG: screenshot)
    }
    /// The line `BrowserActiveTabReader` gives for the front browser tab (used to pick a site skill).
    var browserTabContext: () async -> String? = { await BrowserActiveTabReader.activeTabContext() }
    /// When set, the walkthrough reads this app instead of the front one. For test harnesses.
    var targetAppOverride: WalkthroughScreenReader.App?

    @Published private(set) var state = WalkthroughUIState()


    private let store: WalkthroughStore
    private let reader = WalkthroughScreenReader()
    private let clicks = WalkthroughClickMonitor()
    private let overlay = WalkthroughRingOverlay()

    private var engine: WalkthroughEngine?
    /// The last walkthrough that was paused or interrupted, for "continue".
    private var pausedSession: WalkthroughSession?
    /// Goes up whenever a walkthrough starts or ends, so late results from an old one are dropped.
    private var generation = 0
    private var watchTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var screenWanted = false
    private var lastSignature = ""
    private var lastTargetApp: WalkthroughScreenReader.App?
    private var startingScreenshot: ScreenCapture?
    private var waitingLine: String?
    private var isSpeaking = false

    init(store: WalkthroughStore? = nil) {
        let store = store ?? WalkthroughStore()
        self.store = store
        if let saved = store.load(), saved.status != .done {
            pausedSession = saved
        }
        clicks.onMouseDown = { [weak self] point in
            self?.feed(.click(point))
        }
        // Shows a walkthrough left paused (or cut off by a quit) as resumable right after launch.
        publish()
    }

    var isActive: Bool { engine != nil }

    // MARK: Public API

    /// Starts a walkthrough toward `goal`. Pass the screenshot the voice turn already took to save
    /// a capture; with nil the center asks `captureScreen`. Replaces any walkthrough already running.
    func start(goal: String, screenshot: ScreenCapture?) {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        endCurrentRun()
        startingScreenshot = screenshot
        var fresh = WalkthroughEngine(goal: trimmedGoal)
        let effects = fresh.start()
        engine = fresh
        pausedSession = nil
        clicks.start()
        apply(effects)
        publish()
    }

    /// Give every transcript to this first. True means the walkthrough used it ("next", "back",
    /// "stop", "repeat", "I'm stuck", or "continue" for a paused one) and the normal voice turn
    /// should be skipped. Anything else returns false and the walkthrough keeps waiting.
    func handleSpoken(_ transcript: String) -> Bool {
        if engine != nil {
            guard let command = WalkthroughCommandParser.parse(transcript, context: .active) else { return false }
            feed(.command(command))
            return true
        }
        guard case .resume(let explicit)? = WalkthroughCommandParser.parse(transcript, context: .paused) else { return false }
        guard let saved = pausedSession ?? store.load(), saved.isResumable(explicit: explicit, now: Date()) else { return false }
        resume(saved)
        return true
    }

    /// Ends the running walkthrough without saying anything. It stays saved, so "continue" works.
    func stop() {
        guard var running = engine else { return }
        let effects = running.handle(.command(.stop))
        engine = running
        apply(effects.filter {
            if case .speak = $0 { return false }
            return true
        })
        publish()
    }

    /// A few lines for the voice prompt while a walkthrough is running or paused, so a question
    /// asked in the middle of one is answered in context. Empty otherwise.
    func promptSection() -> String {
        if let engine { return engine.session.promptSummary }
        if let pausedSession, pausedSession.isResumable(explicit: false, now: Date()) { return pausedSession.promptSummary }
        return ""
    }

    // MARK: Engine plumbing

    private func feed(_ event: WalkthroughEngine.Event) {
        guard var running = engine else { return }
        let effects = running.handle(event)
        engine = running
        apply(effects)
        publish()
    }

    private func apply(_ effects: [WalkthroughEngine.Effect]) {
        for effect in effects {
            switch effect {
            case .speak(let line):
                say(line)
            case .showRing(let ring):
                overlay.show(ring)
                followTarget()
            case .hideRing(let completed):
                followTask?.cancel()
                followTask = nil
                overlay.hide(completed: completed)
            case .requestPlan:
                runPlan(isReplan: false)
            case .requestReplan:
                runPlan(isReplan: true)
            case .requestScreen:
                screenWanted = true
                ensureWatching()
            case .requestQuickCheck(let stepID, let condition):
                runQuickCheck(stepID: stepID, condition: condition)
            case .requestResumeCheck:
                runResumeCheck()
            case .persist:
                if let session = engine?.session {
                    do { try store.save(session) } catch { print("⚠️ Walkthrough: could not save (\(error.localizedDescription))") }
                }
            case .finished(let status):
                if status == .stopped { pausedSession = engine?.session }
                endCurrentRun(keepRingFade: true)
            }
        }
    }

    private func resume(_ saved: WalkthroughSession) {
        endCurrentRun()
        var resumed = WalkthroughEngine(resuming: saved)
        let effects = resumed.resume()
        engine = resumed
        pausedSession = nil
        clicks.start()
        apply(effects)
        publish()
    }

    /// Stops the watchers and drops the engine. The saved file is left as it is.
    private func endCurrentRun(keepRingFade: Bool = false) {
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        followTask?.cancel()
        followTask = nil
        clicks.stop()
        if !keepRingFade { overlay.close() }
        engine = nil
        screenWanted = false
        lastSignature = ""
        startingScreenshot = nil
    }

    private func publish() {
        var next = WalkthroughUIState()
        if let session = engine?.session {
            next.isActive = true
            next.status = session.status
            next.goal = session.goal
            next.stepCount = session.steps.count
            next.stepNumber = session.steps.isEmpty ? 0 : min(session.currentIndex + 1, session.steps.count)
            next.instruction = session.currentStep?.say ?? ""
        } else if let pausedSession {
            next.status = pausedSession.status
            next.goal = pausedSession.goal
            next.stepCount = pausedSession.steps.count
            next.stepNumber = pausedSession.steps.isEmpty ? 0 : min(pausedSession.currentIndex + 1, pausedSession.steps.count)
            next.instruction = pausedSession.currentStep?.say ?? ""
            next.canResume = pausedSession.isResumable(explicit: false, now: Date())
        }
        if next != state { state = next }
    }

    // MARK: Speech

    /// One line at a time, in order. A line still waiting its turn is replaced by a newer one,
    /// so quick clicking never leaves a queue of stale instructions.
    private func say(_ line: String) {
        waitingLine = line
        pumpSpeech()
    }

    private func pumpSpeech() {
        guard !isSpeaking, let line = waitingLine else { return }
        waitingLine = nil
        isSpeaking = true
        Task { [weak self] in
            guard let self else { return }
            await self.speak(line)
            self.isSpeaking = false
            self.pumpSpeech()
        }
    }

    // MARK: Screen

    /// The app the walkthrough is about: the front app, or the last one when Teachy itself is in front.
    private func targetApp() -> WalkthroughScreenReader.App? {
        if let targetAppOverride { return targetAppOverride }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastTargetApp = WalkthroughScreenReader.App(
                processID: front.processIdentifier,
                appName: front.localizedName ?? "the app",
                bundleID: front.bundleIdentifier ?? ""
            )
        }
        return lastTargetApp
    }

    /// One loop for the whole run. While a step is out it looks at the screen about once a second
    /// (cheaply: a full settle only when something changed); when the engine asks for the screen
    /// it waits for the page to stop changing first.
    private func ensureWatching() {
        guard watchTask == nil else { return }
        let run = generation
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == run, let status = self.engine?.status else { return }
                guard status == .checking || status == .waitingForUser else {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                let wanted = self.screenWanted
                self.screenWanted = false
                var snapshot: AXSnapshotData?
                if let app = self.targetApp() {
                    if wanted {
                        // Give the app a beat to start reacting to the click, then wait for it to settle.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        snapshot = await self.reader.settledRead(app, stableFor: 0.4, maximumWait: 4)?.snapshot
                    } else {
                        let quick = await self.reader.read(app)?.snapshot
                        if WalkthroughTargetMatcher.signature(of: quick) != self.lastSignature {
                            snapshot = await self.reader.settledRead(app, stableFor: 0.4, maximumWait: 2.5)?.snapshot ?? quick
                        } else {
                            snapshot = quick
                        }
                    }
                }
                guard !Task.isCancelled, self.generation == run else { return }
                self.lastSignature = WalkthroughTargetMatcher.signature(of: snapshot)
                self.feed(.screen(snapshot))

                var waited = 0.0
                while waited < 0.8, !self.screenWanted, !Task.isCancelled, self.generation == run {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 0.05
                }
            }
        }
    }

    /// Keeps the ring on its control between screen reads (a dragged window, a scrolled page).
    private func followTarget() {
        followTask?.cancel()
        followTask = nil
        guard let index = engine?.resolvedTarget?.elementIndex else { return }
        let run = generation
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, !Task.isCancelled, self.generation == run,
                      self.engine?.status == .waitingForUser,
                      let target = self.engine?.resolvedTarget, target.elementIndex == index
                else { return }
                if let frame = await self.reader.frame(ofElement: index), frame != target.frame {
                    guard !Task.isCancelled, self.generation == run else { return }
                    self.overlay.move(to: frame)
                    self.feed(.targetMoved(frame))
                }
            }
        }
    }

    // MARK: Model calls

    private struct ScreenContext {
        var screenshot: ScreenCapture?
        var reading: WalkthroughScreenReading?
        var controlList: String {
            guard let snapshot = reading?.snapshot, !snapshot.elements.isEmpty else { return "" }
            return AXSnapshotFormatter.text(for: snapshot)
        }
    }

    private func currentScreen(reuse screenshot: ScreenCapture? = nil) async -> ScreenContext {
        var context = ScreenContext()
        if let screenshot {
            context.screenshot = screenshot
        } else {
            context.screenshot = await captureScreen()
        }
        if let app = targetApp() {
            context.reading = await reader.settledRead(app, stableFor: 0.2, maximumWait: 1.2)
        }
        return context
    }

    private func runPlan(isReplan: Bool) {
        let run = generation
        let reused = isReplan ? nil : startingScreenshot
        startingScreenshot = nil
        Task { [weak self] in
            guard let self else { return }
            let screen = await self.currentScreen(reuse: reused)
            guard self.generation == run, var running = self.engine else { return }

            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let displayFrameAppKit = screen.screenshot?.displayFrame ?? NSScreen.main?.frame ?? .zero
            running.setPlanningContext(
                appName: screen.reading?.appName ?? "",
                bundleID: screen.reading?.bundleID ?? "",
                displayFrame: DriveCoordinates.globalCGRect(fromAppKit: displayFrameAppKit, primaryDisplayHeight: primaryHeight)
            )
            self.engine = running
            let session = running.session

            // The app's or site's skill file tells the planner where things are.
            let tabContext = await self.browserTabContext()
            guard self.generation == run else { return }
            let skillSection = SkillLibrary.shared.promptSection(
                frontmostBundleID: session.bundleID,
                browserTabContext: tabContext,
                budgetCharacters: SkillLibrary.defaultPromptBudget
            )

            let request = WalkthroughPlanRequest(
                goal: session.goal,
                appName: session.appName,
                windowTitle: screen.reading?.snapshot.windowTitle ?? "",
                controlList: screen.controlList,
                skillSection: skillSection,
                logText: isReplan ? session.logText : nil,
                failedSays: isReplan ? session.failedSays : [],
                maximumSteps: max(1, WalkthroughSession.maximumSteps - (isReplan ? session.currentIndex : 0))
            )
            let result = await self.planner(request, screen.screenshot?.data)
            guard self.generation == run else { return }
            switch result {
            case .steps(let steps):
                print("🧭 Walkthrough: \(isReplan ? "re-planned" : "planned") \(steps.count) step(s) for \"\(session.goal)\"")
                self.feed(.planReady(steps))
            case .failed(let spokenReason):
                self.feed(.planFailed(spokenReason: spokenReason.map { "I can't walk you through that. \($0)" }))
            }
        }
    }

    private func runQuickCheck(stepID: String, condition: String) {
        let run = generation
        Task { [weak self] in
            guard let self else { return }
            let screen = await self.currentScreen()
            guard self.generation == run else { return }
            let isDone = await WalkthroughAI.quickCheck(condition: condition, controlList: screen.controlList, screenshotJPEG: screen.screenshot?.data)
            guard self.generation == run else { return }
            self.feed(.quickCheck(stepID: stepID, isDone: isDone))
        }
    }

    private func runResumeCheck() {
        let run = generation
        Task { [weak self] in
            guard let self else { return }
            let screen = await self.currentScreen()
            guard self.generation == run, let session = self.engine?.session else { return }
            let remaining = Array(session.steps.dropFirst(session.currentIndex))
            let alreadyDone = await WalkthroughAI.resumeCheck(goal: session.goal, remaining: remaining, controlList: screen.controlList, screenshotJPEG: screen.screenshot?.data)
            guard self.generation == run else { return }
            self.feed(.resumeCheck(alreadyDone: alreadyDone))
        }
    }
}
