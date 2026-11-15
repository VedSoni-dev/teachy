//
//  SceneDirector.swift
//  leanring-buddy
//
//  Connects the voice turn to the drawing engine.
//
//    show(_:)       [SHOW: …] in a reply: explain a thing with a card, a 3D model or a
//                   simulation. The scene model writes the narration into the script as
//                   `say` lines, and each sentence is spoken through `speak` while the
//                   lines after it are drawn, so the drawing narrates itself.
//    annotate(…)    [MARK: …] in a reply: draw on the live screen, over the screenshot the
//                   person was looking at (only on-screen marks and label pills).
//    stop()         barge-in: cancels the stream and the narration and clears the marks on
//                   the screen, keeping any card or 3D model.
//
//  Without a `speak` callback nothing is spoken and lines appear a beat apart.
//

import AppKit
import Foundation

@MainActor
final class SceneDirector {
    static let shared = SceneDirector()

    // MARK: Host hooks

    /// Speaks one sentence and returns when it has finished playing (the realtime voice).
    /// Set once by the voice turn. Nil: drawings build silently with stagger timing.
    var speak: ((String) async -> Void)?
    /// Silences whatever `speak` is saying. Called by `stop()`.
    var cancelSpeech: (() -> Void)?
    /// Called when the person taps a follow-up chip or a part of a 3D model.
    var onFollowUpQuestion: ((String) -> Void)?
    /// Seconds between handing a sentence to the voice and showing what it describes
    /// (voices take a moment to produce their first sound).
    var speechLeadTime: TimeInterval = 0.25
    /// Marks drawn without any narration stay at least this long.
    var silentMarkTime: TimeInterval = 5
    /// A follow-up within this long of the last drawing is told what that drawing showed.
    var followUpWindow: TimeInterval = 600
    /// Adjusts where a drawing's windows go before it starts (a host with its own overlay sets
    /// `hostsOverlay`; the tests move every window off the displays).
    var placement: ((inout SceneAnchor) -> Void)?

    // MARK: State

    let scene = SceneSession()
    private let photos: ScenePhotoFetcher
    private var streamTask: Task<Void, Never>?
    private var speechTasks: [Task<Void, Never>] = []
    private var sequencer = SceneNarrationSequencer()
    /// Goes up with every show/annotate/stop, so callbacks from an older drawing are ignored.
    private var generation = 0
    private var currentQuestion = ""
    private var savesToHistory = false
    private var beganAt = Date()
    private(set) var lastSummary: String?
    private var lastSummaryAt = Date.distantPast

    private init() {
        photos = ScenePhotoFetcher(search: SceneDirector.publikSearch)
        scene.onChipTapped = { [weak self] question in self?.onFollowUpQuestion?(question) }
        scene.onPartTapped = { [weak self] _, label in
            guard let self, !label.isEmpty else { return }
            self.onFollowUpQuestion?(Self.partQuestion(label: label, title: self.scene.log.title))
        }
        scene.photoFetcher = { [photos] query in await photos.photo(for: query) }
        scene.onSay = { [weak self] index, text in self?.sentenceArrived(index: index, text: text) }
        scene.onFinished = { [weak self] in self?.sceneFinished() }
        SceneHistory.shared.player = { [weak self] log in self?.replay(log) }
        SceneHistory.shared.photoFetcher = { [photos] query in await photos.photo(for: query) }
    }

    // MARK: Tags

    /// Pulls `[SHOW: …]` out of a reply. Returns the text without the tag and what to draw.
    static func extractShowRequest(from text: String) -> (text: String, request: String?) {
        extract(tag: "SHOW", from: text)
    }

    /// Pulls `[MARK: …]` out of a reply. Returns the text without the tag and what to point out on screen.
    static func extractMarkRequest(from text: String) -> (text: String, request: String?) {
        extract(tag: "MARK", from: text)
    }

    private static func extract(tag: String, from text: String) -> (text: String, request: String?) {
        guard let regex = try? NSRegularExpression(pattern: "\\[" + tag + ":\\s*([^\\]]+)\\]", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let inner = Range(match.range(at: 1), in: text)
        else { return (text, nil) }
        let request = text[inner].trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = text
        stripped.removeSubrange(whole)
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), request.isEmpty ? nil : request)
    }

    /// What tapping a part asks. Naming the drawing lets the voice turn answer about the right thing.
    static func partQuestion(label: String, title: String?) -> String {
        if let title, !title.isEmpty { return "In the drawing \"\(title)\", tell me about the \(label)." }
        return "Tell me about the \(label)."
    }

    /// The system-prompt rules that tell the voice model when to use each tag.
    /// (CompanionManager's prompt should carry this text; see the scene builder's report.)
    static let voicePromptRules = """
    - When a picture would explain it better than words — how a machine or a body part works, what a real object looks like inside, a concept, a comparison, numbers worth charting, or they say "show me" / "draw" / "in 3D" — add [SHOW: what to draw, in a few words] at the end and SAY only one short lead-in sentence ("Sure, here's how it works."). Teachy then draws it and explains it aloud while it draws, so do not explain it yourself. Use [SHOW:] for things that are NOT on their screen.
    - When they ask about something that IS on their screen right now and it would help to mark it — "circle the bug", "where is the hypotenuse on this diagram", "which button do I press", "show me where that is" — add [MARK: what to point out, in a few words] at the end and SAY only one short lead-in sentence. Teachy then draws on their screen (rings, boxes, arrows, small labels) and says what each mark is. Use [MARK:] for several things or a region; use [POINT:] for one single control they should click. Never use [SHOW:] and [MARK:] in the same reply.
    """

    // MARK: Explain a thing

    /// Draws `request` on the display under the mouse. Replaces any drawing already up.
    /// A request soon after another drawing is told what that drawing showed, so
    /// "show it in 3D" or "what does the turbine do" builds on it.
    func show(_ request: String) {
        let mouse = NSEvent.mouseLocation
        guard let screenFrame = SceneScreenMapping.displayFrame(containing: mouse, among: NSScreen.screens.map(\.frame)) ?? NSScreen.main?.frame else { return }
        let context = Date().timeIntervalSince(lastSummaryAt) < followUpWindow ? lastSummary : nil
        begin(question: request, screenFrame: screenFrame, saves: true, filter: nil)
        run(body: SceneScriptPrompt.requestBody(question: request, context: context), hasImages: false)
    }

    // MARK: Draw on the real screen

    /// Marks up the live screen to answer `question`. `screenshotJPEG` is the picture the
    /// model reasons over and `displayFrame` the AppKit frame of the display it shows, so
    /// marks land on that display whichever monitor it is.
    func annotate(question: String, screenshotJPEG: Data, displayFrame: CGRect) {
        begin(question: question, screenFrame: displayFrame, saves: false) { command in
            // Only marks on the screen: no cards, no 3D.
            command.verb.family == .overlay || command.verb.family == .control
        }
        run(body: SceneScriptPrompt.annotateRequestBody(question: question, screenshotJPEG: screenshotJPEG), hasImages: true)
    }

    // MARK: Stopping

    /// Barge-in. The stream and the narration stop and the marks on the screen clear;
    /// a card or 3D model that is already up stays.
    func stop() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        for task in speechTasks { task.cancel() }
        speechTasks = []
        let wasSpeaking = sequencer.isSpeaking
        sequencer.stop()
        if wasSpeaking { cancelSpeech?() }
        scene.interrupt()
    }

    /// Removes everything, cards and models included.
    func clear() {
        stop()
        scene.clear()
    }

    /// Plays a saved drawing again on the display under the mouse.
    func replay(_ log: SceneReplayLog) {
        stop()
        let mouse = NSEvent.mouseLocation
        let frame = SceneScreenMapping.displayFrame(containing: mouse, among: NSScreen.screens.map(\.frame)) ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        savesToHistory = false
        scene.commandFilter = nil
        var anchor = SceneAnchor.display(frame: frame, timing: .stagger)
        placement?(&anchor)
        scene.replay(log, anchor: anchor)
    }

    // MARK: Running a drawing

    private func begin(question: String, screenFrame: CGRect, saves: Bool, filter: ((SceneCommand) -> Bool)?) {
        stop()
        // A new drawing: anything still pending from the one before (its history picture, late speech) is stale.
        generation += 1
        currentQuestion = question
        savesToHistory = saves
        beganAt = Date()
        sequencer = SceneNarrationSequencer()
        scene.commandFilter = filter
        var anchor = SceneAnchor.display(frame: screenFrame, timing: speak == nil ? .stagger : .speech)
        // The sequencer always reports each sentence or the end of speech, so lines can wait as long as the voice needs.
        if speak != nil { anchor.maximumHold = 120 }
        placement?(&anchor)
        scene.begin(anchor: anchor)
    }

    private func run(body: [String: Any], hasImages: Bool) {
        let turn = generation
        let startedAt = Date()
        streamTask = Task { [weak self, scene] in
            var firstLineLogged = false
            do {
                let bytes = try await TeachyAIRouter.openStream(job: .scene, hasImages: hasImages, session: .shared, body: body)
                for try await line in StreamIdleGuard.lines(from: bytes) {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let delta = (event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                          let chunk = delta["content"] as? String, !chunk.isEmpty
                    else { continue }
                    if !firstLineLogged, chunk.contains("\n") {
                        firstLineLogged = true
                        print("🎨 First drawing line \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s after the request")
                    }
                    guard let self, self.generation == turn else { return }
                    scene.feed(chunk: chunk)
                }
            } catch {
                print("⚠️ Drawing failed: \(error.localizedDescription)")
            }
            guard !Task.isCancelled, let self, self.generation == turn else { return }
            scene.end()
            self.perform(self.sequencer.streamDidEnd(), turn: turn)
        }
    }

    // MARK: Narration

    private func sentenceArrived(index: Int, text: String) {
        guard speak != nil else { return }
        perform(sequencer.sentenceArrived(index: index, text: text), turn: generation)
    }

    private func perform(_ actions: [SceneNarrationSequencer.Action], turn: Int) {
        for action in actions {
            switch action {
            case .speak(let index, let text):
                guard let speak else { continue }
                let task = Task { [weak self] in
                    // Show what the sentence describes a moment after the voice is asked for it.
                    let reveal = Task { [weak self] in
                        let lead = self?.speechLeadTime ?? 0
                        if lead > 0 { try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000)) }
                        guard let self, !Task.isCancelled, self.generation == turn else { return }
                        self.scene.sentenceStarted(index: index)
                    }
                    await speak(text)
                    guard let self, !Task.isCancelled, self.generation == turn else {
                        reveal.cancel()
                        return
                    }
                    // A voice that returns at once (muted, failed) must not skip the reveal.
                    await reveal.value
                    self.scene.sentenceStarted(index: index)
                    self.perform(self.sequencer.speechFinished(), turn: turn)
                }
                speechTasks.append(task)
            case .finished:
                finishNarration(turn: turn)
            }
        }
    }

    /// Speech is over: everything still waiting is drawn, and the marks on the screen fade.
    private func finishNarration(turn: Int) {
        let quietFor = Date().timeIntervalSince(beganAt)
        // Marks nobody talked over (no speak callback, or a script without `say`) still need time to be seen.
        let wait = sequencer.spokenCount == 0 ? max(silentMarkTime - quietFor, 0) + 0.1 : 0.6
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == turn else { return }
            self.scene.speechEnded()
        }
        speechTasks.append(task)
    }

    // MARK: History and follow-ups

    private func sceneFinished() {
        let log = scene.log
        guard !log.isEmpty else { return }
        if savesToHistory {
            lastSummary = log.summary
            lastSummaryAt = Date()
        }
        guard savesToHistory else { return }
        savesToHistory = false
        let question = currentQuestion
        let turn = generation
        // Give the last parts a moment to appear and the camera to settle before the picture is taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.generation == turn else {
                // A newer drawing replaced this one: keep the log, without a picture of the wrong scene.
                SceneHistory.shared.save(log: log, question: question, thumbnail: nil)
                return
            }
            let thumbnail = SceneVideoExporter.picture(of: self.scene, size: CGSize(width: 640, height: 360))
            SceneHistory.shared.save(log: log, question: question, thumbnail: thumbnail, narration: self.scene.narration)
        }
    }

    /// Narration audio from the voice, for saved videos. The voice turn forwards PCM here as it plays.
    func appendNarrationAudio(_ pcm16: Data, sampleRate: Double) {
        scene.appendNarrationAudio(pcm16, sampleRate: sampleRate)
    }

    // MARK: Photos

    /// publik web search, for finding which page a card's photo should come from.
    private static let publikSearch: ScenePhotoFetcher.Search = { query in
        guard let route = try? TeachyAIRouter.routes(for: .scene, hasImages: false).first, route.isPublik else { return [] }
        return (try? await Publik.search(baseURL: route.baseURL, apiKey: route.apiKey, q: query, count: 6))?.results ?? []
    }
}
