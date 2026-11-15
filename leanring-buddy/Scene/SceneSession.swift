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
        overlayModel.clock = anchor.headless ? { [weak self] in Date(timeIntervalSinceReferenceDate: self?.headlessClock ?? 0) } : { Date() }
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
        drain()
    }

    /// Narration is over: anything still waiting is drawn, then the on-screen
    /// annotations fade (cards and 3D models stay until `clear()`).
    func speechEnded() {
        scheduler.releaseAll()
        clearOverlayWhenDrained = true
        drain()
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

    /// Headless: draws every logged command up to `time` and moves the 3D model's clock there.
    func advance(to time: Double) {
        guard anchor.headless else { return }
        let step = max(time - headlessClock, 0)
        headlessClock = time
        for entry in log.entries(after: headlessPlayhead, upTo: time) { draw(entry.command, record: false) }
        headlessPlayhead = time
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
            scheduler.enqueue(command, now: now)
        }
        drain()
    }

    private func drain() {
        let now = sceneTime
        for command in scheduler.due(now: now) { draw(command, record: true) }
        if scheduler.isEmpty {
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
        } else if pump == nil {
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
        if record { log.record(command, at: sceneTime) }
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
