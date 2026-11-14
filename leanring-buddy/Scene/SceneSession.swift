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

    static func display(frame: CGRect, timing: SceneCueScheduler.Timing = .speech) -> SceneAnchor {
        SceneAnchor(screenFrame: frame, timing: timing)
    }

    static func mainDisplay(timing: SceneCueScheduler.Timing = .speech) -> SceneAnchor {
        SceneAnchor(screenFrame: NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900), timing: timing)
    }
}

enum SceneExportError: LocalizedError {
    case notAvailableYet

    var errorDescription: String? {
        "Saving a drawing as a video isn't available yet."
    }
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
        scheduler = SceneCueScheduler(timing: anchor.timing)
        log = SceneReplayLog()
        startTime = CACurrentMediaTime()
        streamEnded = false
        clearOverlayWhenDrained = false
    }

    /// Model text, in whatever pieces it arrives.
    func feed(chunk: String) {
        enqueue(parser.feed(chunk))
    }

    /// The model's stream is finished.
    func end() {
        enqueue(parser.finish())
        streamEnded = true
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

    /// Not built yet. The plan: replay the log off-screen, render each frame
    /// (SCNRenderer for 3D, ImageRenderer for cards and overlay) and write them
    /// with AVAssetWriter. The log already holds everything that needs.
    func exportMP4(to url: URL) async throws {
        throw SceneExportError.notAvailableYet
    }

    // MARK: Drawing

    private func enqueue(_ commands: [SceneCommand]) {
        guard !commands.isEmpty else { return }
        let now = CACurrentMediaTime() - startTime
        for command in commands { scheduler.enqueue(command, now: now) }
        drain()
    }

    private func drain() {
        let now = CACurrentMediaTime() - startTime
        for command in scheduler.due(now: now) { draw(command, record: true) }
        if scheduler.isEmpty {
            stopPump()
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
        if record { log.record(command, at: CACurrentMediaTime() - startTime) }
        switch command.verb {
        case .say:
            if let text = command.freeText, let cue = command.cue, !isReplaying { onSay?(cue, text) }
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
        let window = Scene3DWindow()
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
        log.record(command, at: CACurrentMediaTime() - startTime)
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
