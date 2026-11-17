//
//  SceneSession.swift
//  leanring-buddy / Scene
//
//  One drawing, start to finish. Owns the parser and the three renderers; the
//  host only streams model text in and reports when spoken sentences start.
//
//      let scene = SceneSession()
//      scene.onPartTapped = { id, label in ask("Tell me about the \(label)") }
//      scene.onChipTapped = { question in ask(question) }
//      scene.imageFetcher = { query in await photo(for: query) }
//      scene.begin(anchor: .display(frame: screenFrame, timing: .speech))
//      for try await delta in modelStream { scene.feed(chunk: delta) }
//      scene.end()
//      // from the speech engine:
//      scene.sentenceStarted(index: n)      // n matches `say n`
//      scene.speechEnded()
//
//  Every command is logged with the moment it was drawn, so `replay()` plays
//  the scene back exactly as it built up.
//

import AppKit
import SwiftUI

/// Where a scene goes on screen and how it is timed.
struct SceneAnchor {
    /// The display the screenshot came from, in AppKit screen coordinates.
    /// Overlay coordinates (0–1000) map onto this rectangle.
    var screenFrame: CGRect
    /// `.speech`: commands wait for `sentenceStarted`. `.stagger`: no speech, draw in order.
    var timing: SceneCueScheduler.Timing = .speech
    /// Top-left of the first card; nil puts it on the right of the display.
    var cardTopLeft: CGPoint?
    /// Top-left of the 3D model's window; nil centres it in the upper part of the display.
    var modelTopLeft: CGPoint?
    /// True when the host draws `session.overlayModel` in its own overlay
    /// (with `SceneOverlayView`), so the session must not open a second one.
    var hostsOverlay = false
    /// With speech timing, how long a line waits for its sentence before it is drawn anyway.
    /// A host that always reports sentences (or calls `speechEnded`) can make this long.
    var maximumHold: Double = 8
    /// No windows at all: everything is built in memory and drawn with `snapshots()` or
    /// the video exporter. The 3D model's clock only moves when `advance(by:)` is called.
    var headless = false

    static func display(frame: CGRect, timing: SceneCueScheduler.Timing = .speech) -> SceneAnchor {
        SceneAnchor(screenFrame: frame, timing: timing)
    }

    static func mainDisplay(timing: SceneCueScheduler.Timing = .speech) -> SceneAnchor {
        SceneAnchor(screenFrame: NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900), timing: timing)
    }
}

/// A photo for a card, with where it came from.
struct ScenePhoto {
    var image: NSImage
    /// The page the photo is from, shown as a small "source" link under it.
    var sourceURL: URL?
    /// A short name for that page ("Wikipedia").
    var sourceName: String?
}

@MainActor
final class SceneSession {
    // MARK: Host hooks

    /// The person clicked a 3D part: (part id, its label or name).
    var onPartTapped: ((String, String) -> Void)?
    /// The person tapped a follow-up chip.
    var onChipTapped: ((String) -> Void)?
    /// A `say N "…"` line was reached: the sentence to speak. Optional; hosts that
    /// get the narration elsewhere can ignore it.
    var onSay: ((Int, String) -> Void)?
    /// Finds a photo for an `image query="…"` line. Without it, cards show a placeholder.
    var imageFetcher: ((String) async -> NSImage?)?
    /// The same, with the photo's source page for a caption. Used in preference to `imageFetcher`.
    var photoFetcher: ((String) async -> ScenePhoto?)?
    /// Every line the model sent has been drawn (the stream ended and nothing is waiting).
    var onFinished: (() -> Void)?
    /// Returns false for commands that must not be drawn (a screen annotation allows only overlay verbs).
    var commandFilter: ((SceneCommand) -> Bool)?
    /// The person closed the last window of the drawing.
    var onDismissed: (() -> Void)?

    /// 2D items. Hosts with their own overlay draw this with `SceneOverlayView(model:mapping:)`.
    let overlayModel = SceneOverlayModel()

    /// False: the 3D camera only ever frames the whole model, as it did before it learned to direct
    /// itself (`focus`, `ghost`, `highlight` and automatic focus are ignored). For comparisons.
    var directsCamera = true {
        didSet { modelWindow?.controller.directsCamera = directsCamera }
    }
    /// True while lines are being applied to a drawing that was already up (see `beginRefinement`).
    private(set) var isRefining = false

    private(set) var log = SceneReplayLog()
    private(set) var isReplaying = false
    var parseStats: SceneParseStats { parser.stats }
    var parseRejections: [String] { parser.rejections }
    var partCount: Int { modelWindow?.controller.partCount ?? 0 }

    // MARK: State

    private let parser = SceneScriptParser()
    private var scheduler = SceneCueScheduler(timing: .speech)
    private var anchor = SceneAnchor.mainDisplay()
    private var startTime: CFTimeInterval = 0
    private var pump: Timer?
    private var replayTimer: Timer?
    private var streamEnded = false
    private var clearOverlayWhenDrained = false
    private var reportedFinished = false
    /// After a barge-in: lines for the on-screen overlay are logged but not drawn.
    private var overlayMuted = false
    /// Raw narration audio the host captured, placed on the scene's clock (see `appendNarrationAudio`).
    private(set) var narration = SceneNarrationAudio()
    /// Seconds on the scene's own clock while headless.
    private var headlessClock = 0.0
    private var sceneTime: Double { anchor.headless ? headlessClock : CACurrentMediaTime() - startTime }
    /// True while `advance(to:)` is moving a headless scene's clock.
    private var isAdvancing = false
    /// The moment a line drawn now is logged at. Off screen, a line drawn between two steps of the
    /// clock acts after the step just taken, so it is logged a hair later: played back, it is then
    /// drawn at the start of the next step, exactly where it acted.
    private var recordTime: Double { anchor.headless && !isAdvancing ? headlessClock + 1e-6 : sceneTime }

    // The camera following the narration
    /// The lines that belong to each spoken sentence, and the sentences themselves.
    private var linesByCue: [Int: [SceneCommand]] = [:]
    private var sentenceText: [Int: String] = [:]
    private var highestSay = 0
    private var lastStartedCue = 0
    /// A sentence has started and its subject has not been worked out yet (its lines are still appearing).
    private var pendingSubject: (cue: Int, startedAt: Double)?

    private var annotationTracker: SceneAnnotationTracker?
    private var overlayWindow: SceneOverlayWindow?
    private(set) var cards: [SceneCardWindow] = []
    private var cardIDs: [String] = []
    private(set) var modelWindow: Scene3DWindow?
    private var currentSurface: SceneSurface?

    init() {}

    // MARK: Lifecycle

    /// Starts a new drawing, clearing any previous one.
    func begin(anchor: SceneAnchor) {
        stopReplay()
        clearRenderers()
        self.anchor = anchor
        parser.reset()
        scheduler = SceneCueScheduler(timing: anchor.timing, maximumHold: anchor.maximumHold)
        log = SceneReplayLog()
        startTime = CACurrentMediaTime()
        headlessClock = 0
        streamEnded = false
        clearOverlayWhenDrained = false
        reportedFinished = false
        overlayMuted = false
        narration = SceneNarrationAudio()
        isRefining = false
        resetDirection()
        overlayModel.clock = anchor.headless ? { [weak self] in Date(timeIntervalSinceReferenceDate: self?.headlessClock ?? 0) } : { Date() }
    }

    /// Opt in only for live screen annotations, after begin(anchor:).
    func enableLiveAnnotationTracking() {
        annotationTracker?.stop()
        annotationTracker = nil
        guard !anchor.headless, !isReplaying else { return }
        annotationTracker = SceneAnnotationTracker(model: overlayModel, displayFrame: anchor.screenFrame,
                                                  primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Model text, in whatever pieces it arrives.
    func feed(chunk: String) {
        enqueue(parser.feed(chunk))
    }

    /// The model's stream is finished.
    func end() {
        enqueue(parser.finish())
        streamEnded = true
        drain()
    }

    /// The speech engine began sentence `index` (1-based, matching `say N`).
    func sentenceStarted(index: Int) {
        scheduler.sentenceStarted(index)
        noteSentenceStarted(index)
        drain()
    }

    /// A drawing with a 3D model is up and can be adjusted in place.
    var canRefine: Bool { !isReplaying && (modelWindow?.controller.hasContent ?? false) }

    /// Starts applying new lines to the drawing that is already on screen, without clearing it:
    /// the answer to "zoom in on the turbine" or a tap on a part. Feed the lines with `feed(chunk:)`
    /// and finish with `end()` as usual. They are added to the same log, so a replay shows the refinement too.
    func beginRefinement(timing: SceneCueScheduler.Timing, maximumHold: Double = 8) {
        guard modelWindow != nil else { return }
        stopReplay()
        // Anything still waiting from the turn before is drawn now.
        _ = parser.finish()
        for command in scheduler.drainAll() { draw(command, record: true) }
        parser.reset()
        anchor.timing = timing
        anchor.maximumHold = maximumHold
        scheduler = SceneCueScheduler(timing: timing, maximumHold: maximumHold)
        streamEnded = false
        reportedFinished = false
        clearOverlayWhenDrained = false
        overlayMuted = false
        resetDirection()
        isRefining = true
        // Minutes may have passed since the drawing was made; a replay should not sit through them.
        let gap = sceneTime - log.duration
        if gap > 1.5, !anchor.headless { startTime += gap - 1.5 }
        modelWindow?.controller.beginRefinement()
    }

    /// Draws lines at once as the person's own request (a tap focusing a part before the model has answered).
    /// They are recorded like any other line.
    func perform(_ script: String) {
        guard let controller = modelWindow?.controller else { return }
        let previous = controller.commandOrigin
        controller.commandOrigin = .person
        for command in SceneScriptParser.parse(script) { draw(command, record: !isReplaying) }
        controller.commandOrigin = previous
    }

    /// Narration is over: anything still waiting is drawn, then the on-screen
    /// annotations fade (cards and 3D models stay until `clear()`).
    func speechEnded() {
        scheduler.releaseAll()
        clearOverlayWhenDrained = true
        drain()
        returnToWholeModel()
    }

    /// The person interrupted. Whatever was already received is drawn at once (so a card or a
    /// model is not left half built), then the marks on the screen go; cards and 3D stay.
    func interrupt() {
        // From here on no new marks go on the screen, including ones still waiting for their sentence.
        overlayMuted = true
        enqueue(parser.finish())
        streamEnded = true
        clearOverlayWhenDrained = false
        for command in scheduler.drainAll() { draw(command, record: true) }
        drain()
        clearOverlay(animated: true)
    }

    /// Fades the on-screen annotations out, leaving cards and 3D models.
    func clearOverlay(animated: Bool = true) {
        annotationTracker?.stop()
        annotationTracker = nil
        overlayModel.clearAll(animated: animated)
        if !animated {
            overlayWindow?.close()
            overlayWindow = nil
        }
    }

    /// Narration audio as the voice produced it: mono 16-bit PCM. It is laid on the scene's
    /// clock where it arrived (a pause of a quarter second starts a new stretch), and goes
    /// into the saved drawing so an exported video has the voice.
    func appendNarrationAudio(_ pcm16: Data, sampleRate: Double) {
        narration.append(pcm16, sampleRate: sampleRate, at: sceneTime)
    }

    /// A short description of what is on screen, for follow-up questions.
    var summary: String { log.summary }

    /// Removes everything this session drew.
    func clear() {
        stopReplay()
        stopPump()
        scheduler.reset()
        clearRenderers()
    }

    // MARK: Replay and export

    /// Plays the recorded scene again with its original timing.
    func replay() {
        guard !log.isEmpty else { return }
        stopReplay()
        stopPump()
        clearRenderers()
        isReplaying = true
        resetDirection()
        let recorded = log
        let began = CACurrentMediaTime()
        var playhead = -1.0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isReplaying else {
                    timer.invalidate()
                    return
                }
                let now = CACurrentMediaTime() - began
                for entry in recorded.entries(after: playhead, upTo: now) { self.draw(entry.command, record: false) }
                playhead = now
                if now >= recorded.duration {
                    timer.invalidate()
                    self.replayTimer = nil
                    self.isReplaying = false
                    self.modelWindow?.controller.commandOrigin = .narration
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        replayTimer = timer
    }

    /// Loads a saved log (see `log.encoded()`) and plays it.
    func replay(_ saved: SceneReplayLog, anchor: SceneAnchor) {
        begin(anchor: anchor)
        log = saved
        replay()
    }

    /// Renders the recorded scene to an MP4, off screen, frame by frame from the log
    /// (so the same drawing always gives the same video). See `SceneVideoExporter`.
    func exportMP4(to url: URL, options: SceneVideoOptions = SceneVideoOptions()) async throws {
        try await SceneVideoExporter.export(log: log, narration: narration, to: url, options: options, photoFetcher: photoFetcher)
    }

    // MARK: Headless playback (video export, thumbnails)

    /// Starts an empty off-screen scene that the caller plays a log into with `advance(to:)`.
    func beginHeadless(log saved: SceneReplayLog, size: CGSize) {
        var anchor = SceneAnchor(screenFrame: CGRect(origin: .zero, size: size), timing: .stagger)
        anchor.headless = true
        anchor.hostsOverlay = true
        begin(anchor: anchor)
        log = saved
        isReplaying = true
        headlessPlayhead = -1
    }

    private var headlessPlayhead = -1.0

    /// Starts an empty off-screen scene that is fed like a live one (`feed`, `sentenceStarted`, `end`)
    /// while the caller moves its clock with `advance(to:)`. Used to measure and film the camera without a window.
    func beginHeadless(size: CGSize, timing: SceneCueScheduler.Timing, maximumHold: Double = 120) {
        var anchor = SceneAnchor(screenFrame: CGRect(origin: .zero, size: size), timing: timing)
        anchor.headless = true
        anchor.hostsOverlay = true
        anchor.maximumHold = maximumHold
        begin(anchor: anchor)
    }

    /// Headless: moves the scene's clock to `time`. A scene being played from a log draws every
    /// logged command up to then; a scene being fed draws whatever has become due. The 3D model's
    /// clock (motion, camera) moves with it.
    func advance(to time: Double) {
        guard anchor.headless else { return }
        let step = max(time - headlessClock, 0)
        headlessClock = time
        isAdvancing = true
        defer { isAdvancing = false }
        if isReplaying {
            for entry in log.entries(after: headlessPlayhead, upTo: time) { draw(entry.command, record: false) }
            headlessPlayhead = time
        } else {
            drain()
        }
        modelWindow?.controller.advance(by: step)
    }

    // MARK: Drawing

    private func enqueue(_ commands: [SceneCommand]) {
        guard !commands.isEmpty else { return }
        let now = sceneTime
        for command in commands {
            if let commandFilter, command.verb != .say, !commandFilter(command) { continue }
            // With speech timing the host has to hear a sentence before it can speak it,
            // so `say` is handed over as it arrives, not when its turn to be drawn comes.
            if command.verb == .say, anchor.timing == .speech, let text = command.freeText, let cue = command.cue { onSay?(cue, text) }
            if let cue = command.cue {
                if command.verb == .say {
                    sentenceText[cue] = command.freeText ?? ""
                    highestSay = max(highestSay, cue)
                } else {
                    linesByCue[cue, default: []].append(command)
                }
            }
            scheduler.enqueue(command, now: now)
        }
        drain()
    }

    private func drain() {
        let now = sceneTime
        for command in scheduler.due(now: now) { draw(command, record: true) }
        resolvePendingSubject(now: now)
        if scheduler.isEmpty, pendingSubject == nil {
            stopPump()
            if streamEnded, !reportedFinished, !isReplaying {
                reportedFinished = true
                onFinished?()
            }
            if clearOverlayWhenDrained {
                clearOverlayWhenDrained = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.overlayModel.clearAll(animated: true)
                }
            }
        } else if pump == nil, !anchor.headless {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    if let self { self.drain() } else { timer.invalidate() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pump = timer
        }
    }

    private func stopPump() {
        pump?.invalidate()
        pump = nil
    }

    private func stopReplay() {
        replayTimer?.invalidate()
        replayTimer = nil
        isReplaying = false
    }

    private func draw(_ command: SceneCommand, record: Bool) {
        if record, holdsFrameAll(command) {
            if let cue = command.cue { heldFrameCues.insert(cue) }
            return
        }
        if record { log.record(command, at: recordTime) }
        switch command.verb {
        case .say:
            if anchor.timing == .stagger, let text = command.freeText, let cue = command.cue, !isReplaying { onSay?(cue, text) }
            return
        case .clear:
            clearRenderers()
            return
        case .remove, .hide, .show:
            if overlayModel.items.contains(where: { $0.id == command.id }) {
                if command.verb != .show { overlayModel.remove(id: command.id) }
            } else if command.verb == .remove, let card = cards.last, card.model.items.contains(where: { $0.id == command.id }) {
                card.model.remove(id: command.id)
            } else {
                modelWindow?.controller.apply(command)
            }
            return
        case .set:
            modelWindow?.controller.apply(command)
            return
        default:
            break
        }
        // Camera and visibility lines act on the model that is there; without one they do nothing
        // (they must not open an empty 3D window).
        if command.directsView {
            modelWindow?.controller.apply(command)
            return
        }

        guard let surface = SceneRouter.surface(for: command, current: currentSurface) else { return }
        currentSurface = surface
        switch surface {
        case .overlay:
            if overlayMuted { return }
            if !anchor.hostsOverlay {
                if overlayWindow == nil { overlayWindow = SceneOverlayWindow(model: overlayModel) }
                overlayWindow?.show(on: anchor.screenFrame)
            }
            overlayModel.apply(command)
            annotationTracker?.register(command)
        case .card:
            card(for: command).model.apply(command)
        case .scene3d:
            let window = ensureModelWindow()
            if command.verb == .scene3d, window.controller.hasContent {
                window.controller.reset()
            }
            window.controller.apply(command)
        }
    }

    private func card(for command: SceneCommand) -> SceneCardWindow {
        if command.verb == .card {
            if let index = cardIDs.firstIndex(of: command.id) { return cards[index] }
            return openCard(id: command.id)
        }
        return cards.last ?? openCard(id: "_card")
    }

    private func openCard(id: String) -> SceneCardWindow {
        let card = SceneCardWindow()
        card.model.imageFetcher = imageFetcher
        card.model.photoFetcher = photoFetcher
        card.isHeadless = anchor.headless
        card.model.onChipTapped = { [weak self] text in self?.onChipTapped?(text) }
        let visible = visibleFrame
        let offset = CGFloat(cards.count) * 28
        let topLeft = anchor.cardTopLeft ?? CGPoint(x: visible.maxX - SceneCardView.width - 36 - offset, y: visible.maxY - 70 - offset)
        cards.append(card)
        cardIDs.append(id)
        card.show(topLeft: topLeft)
        return card
    }

    private func ensureModelWindow() -> Scene3DWindow {
        if let modelWindow { return modelWindow }
        let window = Scene3DWindow(headless: anchor.headless)
        window.controller.directsCamera = directsCamera
        window.controller.commandOrigin = isReplaying ? .replay : (isRefining ? .person : .narration)
        // Lines the engine writes itself (automatic focus, a double-click, Recenter) are drawn and
        // recorded here, so a replay or a saved video repeats them.
        window.controller.onDirectorCommand = { [weak self] command in
            guard let self else { return }
            self.draw(command, record: !self.isReplaying)
        }
        window.controller.onPartTapped = { [weak self] id, label in self?.onPartTapped?(id, label) }
        window.controller.onSliderChanged = { [weak self] id, value in self?.recordSlider(id: id, value: value) }
        window.onChipTapped = { [weak self] text in self?.onChipTapped?(text) }
        window.onClosed = { [weak self] in
            self?.modelWindow = nil
            self?.onDismissed?()
        }
        let visible = visibleFrame
        let topLeft = anchor.modelTopLeft ?? CGPoint(x: visible.midX - Scene3DView.viewSize.width / 2, y: visible.maxY - 70)
        window.show(topLeft: topLeft)
        modelWindow = window
        return window
    }

    // MARK: The camera following the narration

    /// How long the opening sentence shows the whole model before the camera may go in on a part,
    /// and how many words that sentence needs for there to be time for both.
    static let establishingHold = 1.3
    static let wordsForEstablishingMove = 8
    /// Sentences whose `frame all` is being kept for the end of the narration (see `holdsFrameAll`).
    private var heldFrameCues: Set<Int> = []

    private static func isPlainFrameAll(_ command: SceneCommand) -> Bool {
        command.verb == .frame && !command.flag("auto") && !command.flag("hold") && command.targetIDs.isEmpty
    }

    /// A script often ends "…and that is the optic nerve" with `frame all` on the same sentence.
    /// Going wide at once would skip the part the sentence is about, so when a sentence labels or
    /// moves a part of its own, its `frame all` waits: the camera shows that part while it is
    /// talked about, and the narration still ends on the whole model.
    /// `frame all hold` explicitly keeps the overview during that sentence instead.
    private func holdsFrameAll(_ command: SceneCommand) -> Bool {
        guard Self.isPlainFrameAll(command), directsCamera, !isReplaying, !isRefining, anchor.timing == .speech, let cue = command.cue else { return false }
        let others = (linesByCue[cue] ?? []).filter { !$0.movesCamera }
        guard !(linesByCue[cue] ?? []).contains(where: { $0.movesCamera && !Self.isPlainFrameAll($0) }) else { return false }
        return !SceneSentenceSubject.infer(sentence: "", commands: others, candidates: []).isEmpty
    }

    /// The lines of a sentence that really direct the camera (a held `frame all` does not, yet).
    private func directingLines(of cue: Int) -> [SceneCommand] {
        (linesByCue[cue] ?? []).filter { !(heldFrameCues.contains(cue) && Self.isPlainFrameAll($0)) }
    }

    private func resetDirection() {
        linesByCue = [:]
        sentenceText = [:]
        highestSay = 0
        lastStartedCue = 0
        pendingSubject = nil
        heldFrameCues = []
    }

    /// A sentence began to be spoken. Its subject is worked out a moment later, once its own lines
    /// have appeared (the parts it names may not exist yet).
    private func noteSentenceStarted(_ cue: Int) {
        guard directsCamera, !isReplaying, anchor.timing == .speech, cue > lastStartedCue else { return }
        lastStartedCue = cue
        pendingSubject = (cue, sceneTime)
    }

    private func resolvePendingSubject(now: Double) {
        guard let pending = pendingSubject else { return }
        let waited = now - pending.startedAt
        guard let controller = modelWindow?.controller else {
            // No 3D model (a card, or marks on the screen): nothing to direct.
            if waited > 1.5 || (streamEnded && scheduler.isEmpty) { pendingSubject = nil }
            return
        }
        if scheduler.hasPending(cue: pending.cue), waited < 2.5 { return }
        // The sentence's lines are all here once the next sentence (or the end of the script) has arrived.
        let complete = streamEnded || highestSay > pending.cue
        if waited < 0.3 || (!complete && waited < 0.9) { return }
        pendingSubject = nil
        let lines = linesByCue[pending.cue] ?? []
        // The script directs the camera itself for this sentence.
        if SceneSentenceSubject.hasCameraDirection(directingLines(of: pending.cue)) { return }
        let text = sentenceText[pending.cue] ?? ""
        let subject = SceneSentenceSubject.infer(sentence: text, commands: lines, candidates: controller.subjectCandidates)
        if !isRefining, lines.contains(where: { $0.verb == .scene3d }) {
            // The sentence that builds the model is the establishing shot: the whole thing first.
            // If it is long enough and singles out a part, the camera then goes in on that part.
            guard !subject.isEmpty, text.split(separator: " ").count >= Self.wordsForEstablishingMove else { return }
            controller.requestAutoFocus(subject, sentence: pending.cue, wholeIfEmpty: false, after: Self.establishingHold)
            return
        }
        controller.requestAutoFocus(subject, sentence: pending.cue, wholeIfEmpty: !isRefining)
    }

    /// The narration is over: a drawing ends on the whole model, unless its last sentence told the
    /// camera where to be or the person asked to look at something (a refinement stays where it is).
    private func returnToWholeModel() {
        guard directsCamera, !isReplaying, !isRefining, anchor.timing == .speech, let controller = modelWindow?.controller else { return }
        pendingSubject = nil
        if let last = linesByCue.keys.max(), SceneSentenceSubject.hasCameraDirection(directingLines(of: last)) { return }
        controller.requestAutoFocus([], sentence: nil, wholeIfEmpty: true)
    }

    /// A slider the person dragged becomes a `set` line in the log, so replays include it.
    private func recordSlider(id: String, value: Double) {
        guard !isReplaying else { return }
        let command = SceneCommand(verb: .set, id: id, args: ["value": String(format: "%.4g", value)])
        log.record(command, at: sceneTime)
    }

    private var visibleFrame: CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.screenFrame) } ?? NSScreen.main
        return screen?.visibleFrame ?? anchor.screenFrame
    }

    private func clearRenderers() {
        annotationTracker?.stop()
        annotationTracker = nil
        overlayModel.clearAll(animated: false)
        overlayWindow?.close()
        overlayWindow = nil
        for card in cards { card.close() }
        cards = []
        cardIDs = []
        modelWindow?.close()
        modelWindow = nil
        currentSurface = nil
    }

    // MARK: Checking without a screen recording

    /// Renders each surface to an image in-process (no screen-capture permission needed).
    func snapshots() -> [(name: String, image: NSImage)] {
        var result: [(String, NSImage)] = []
        if !overlayModel.isEmpty {
            let size = CGSize(width: 1280, height: 1280 * anchor.screenFrame.height / max(anchor.screenFrame.width, 1))
            let window = overlayWindow ?? SceneOverlayWindow(model: overlayModel)
            if let image = window.snapshot(size: size) { result.append(("overlay", image)) }
        }
        for (index, card) in cards.enumerated() {
            if let image = card.snapshot() { result.append((cards.count > 1 ? "card\(index + 1)" : "card", image)) }
        }
        if let modelWindow, let image = modelWindow.snapshot() { result.append(("model", image)) }
        return result
    }
}
