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
//                   When a 3D model is already up and the request is about it ("zoom in on the
//                   turbine", "show me inside", "go back", a tap on a part), nothing is drawn
//                   again: `refine` sends the model the parts that are on screen and applies
//                   its camera, visibility and speech lines to the live scene.
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
    /// Called when the person taps a follow-up chip (or, with `refinesInPlace` off, a part of a 3D model).
    var onFollowUpQuestion: ((String) -> Void)?
    /// A request about the drawing on screen was answered on the drawing itself (a tapped part, or
    /// "zoom in on the turbine"): what was asked, and the sentences that were spoken in reply. The
    /// voice turn keeps it in the conversation, so the next question can build on it.
    var onRefinementAnswered: ((_ question: String, _ spokenAnswer: String) -> Void)?
    /// Seconds between handing a sentence to the voice and showing what it describes
    /// (voices take a moment to produce their first sound).
    var speechLeadTime: TimeInterval = 0.25
    /// Marks drawn without any narration stay at least this long.
    var silentMarkTime: TimeInterval = 5
    /// A follow-up within this long of the last drawing is told what that drawing showed.
    var followUpWindow: TimeInterval = 600
    /// False: every request draws from scratch and a tapped part asks through `onFollowUpQuestion`, as before.
    var refinesInPlace = true
    /// Adjusts where a drawing's windows go before it starts (a host with its own overlay sets
    /// `hostsOverlay`; the tests move every window off the displays).
    var placement: ((inout SceneAnchor) -> Void)?

    // MARK: State

    let scene = SceneSession()
    /// Marks sit above the user's content, including the persistent drawing in `scene`.
    /// Starting a mark must not close the very card or model being marked.
    let annotationScene = SceneSession()
    private var isAnnotating = false
    private var activeScene: SceneSession { isAnnotating ? annotationScene : scene }
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
    /// The saved drawing the scene on screen is, so a refinement can update it rather than add another.
    private(set) var lastSavedEntryID: String?
    /// The refinement being answered: its question and the sentences spoken so far (nil when not refining).
    private var refinementInProgress: (question: String, sentences: [String])?

    /// How the most recent `show` or `refine` went, for measuring (seconds from the request).
    struct TurnTiming {
        enum Kind { case drawing, refinement, annotation }
        var kind = Kind.drawing
        var request = ""
        var startedAt = Date()
        /// Why the request was (or was not) treated as a refinement.
        var reason = ""
        /// The camera moved at once, before the model answered.
        var instantScript: String?
        var firstLine: TimeInterval?
        var streamEnded: TimeInterval?
    }
    private(set) var lastTurn = TurnTiming()

    private init() {
        photos = ScenePhotoFetcher(search: SceneDirector.publikSearch)
        scene.onChipTapped = { [weak self] question in self?.onFollowUpQuestion?(question) }
        scene.onPartTapped = { [weak self] id, label in
            guard let self, !label.isEmpty else { return }
            // A tapped part is answered on the drawing itself: the camera goes to it and one or two
            // sentences are spoken about it. (Before, it went out as a new question and the drawing was redrawn.)
            if self.refinesInPlace, self.scene.canRefine {
                self.refine(Self.partQuestion(label: label, title: self.scene.log.title), tappedPart: id)
            } else {
                self.onFollowUpQuestion?(Self.partQuestion(label: label, title: self.scene.log.title))
            }
        }
        scene.photoFetcher = { [photos] query in await photos.photo(for: query) }
        scene.onSay = { [weak self] index, text in
            guard let self, !self.isAnnotating else { return }
            if self.refinementInProgress != nil { self.refinementInProgress?.sentences.append(text) }
            self.sentenceArrived(index: index, text: text)
        }
        scene.onFinished = { [weak self] in
            guard let self, !self.isAnnotating else { return }
            self.sceneFinished()
        }
        annotationScene.onSay = { [weak self] index, text in
            guard let self, self.isAnnotating else { return }
            self.sentenceArrived(index: index, text: text)
        }
        SceneHistory.shared.player = { [weak self] log in
            self?.replay(log)
            self?.adoptSavedDrawing(SceneHistory.shared.replayingID)
        }
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
    - When a 3D drawing Teachy made is still up and they ask to zoom in or out, look closer at or inside a part, rotate it, take it apart, go back, or ask what one of its parts is or does, add [SHOW: their request, naming the subject and part] as usual. Teachy then moves the camera on the drawing that is already there instead of drawing it again.
    - When a picture would explain it better than words — how a machine or a body part works, what a real object looks like inside, a concept with structure or relationships, software layers, an algorithm, an agent loop, a network request, a process, a comparison, numbers worth charting, or they say "show me" / "draw" / "in 3D" — add [SHOW: the subject and what to show, preserving their requested medium, named parts, relationships, and constraints] at the end and SAY only one short lead-in sentence ("Sure, here's how it works."). Teachy then draws it and explains it aloud while it draws, so do not explain it yourself. Prefer a drawn explanation for how-it-works questions with parts, stages, or flows; do not wait for them to explicitly say "draw". Use [SHOW:] to explain a subject even when that subject is mentioned in the screenshot. Keep simple factual answers conversational, and preserve explicit requests for text summaries, formulas or charts.
    - When they ask to circle, underline, highlight, box, draw an arrow to, or otherwise mark a visible name, word, label, object or control, use [MARK: screen=N | the exact mark and target, including its text, app and location]. N is the screen number from the supplied screenshots (1 on a single display). Preserve the requested shape and color. This works in any visible app, including Teachy's chat, settings, cards and drawings. Even ONE name or button should use MARK when they ask to circle it; POINT only moves the pointer and does not draw the requested mark. Say one short lead-in, then let the drawing narrate itself. Do not claim you cannot draw over an app or request Accessibility permission just to mark it.
    - Use [MARK:] to locate actual screen content, and [SHOW:] to create a separate explanation. For "circle the Kernel label" on an existing diagram, mark that label instead of recreating the diagram. Never combine MARK with SHOW, POINT or a job for the same request. If a target is missing or ambiguous, ask one concise clarification instead of guessing. Use [POINT:] for a single control to click only when no drawn mark was requested.
    """

    // MARK: Explain a thing

    /// Draws `request` on the display under the mouse. Replaces any drawing already up.
    /// A request soon after another drawing is told what that drawing showed, so
    /// "show it in 3D" or "what does the turbine do" builds on it.
    func show(_ request: String) {
        if refinesInPlace, scene.canRefine, let controller = scene.modelWindow?.controller {
            let decision = SceneRefineClassifier.classify(request: request, sceneIsLive: true, title: controller.model.title, parts: controller.subjectCandidates)
            if case .refine(let parts, let reason) = decision {
                print("🎥 Adjusting the drawing on screen (\(reason))")
                refine(request, parts: parts, reason: reason)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        guard let screenFrame = SceneScreenMapping.displayFrame(containing: mouse, among: NSScreen.screens.map(\.frame)) ?? NSScreen.main?.frame else { return }
        lastSavedEntryID = nil
        let context = Date().timeIntervalSince(lastSummaryAt) < followUpWindow ? lastSummary : nil
        begin(question: request, screenFrame: screenFrame, saves: true, filter: nil)
        lastTurn = TurnTiming(kind: .drawing, request: request, startedAt: Date())
        run(body: SceneScriptPrompt.requestBody(question: request, context: context), hasImages: false)
    }

    // MARK: Adjust the drawing that is up

    /// Answers a request about the 3D model on screen without drawing it again. The camera goes
    /// at once to the part the request names (`parts`, or the part that was tapped); the model is
    /// told what is on screen and answers with camera, visibility, label and `say` lines, which
    /// are applied to the live scene and added to its log.
    func refine(_ request: String, tappedPart: String? = nil, parts: [String] = [], reason: String = "") {
        guard scene.canRefine, let controller = scene.modelWindow?.controller else { return }
        stop()
        generation += 1
        currentQuestion = request
        savesToHistory = false
        beganAt = Date()
        sequencer = SceneNarrationSequencer()
        scene.commandFilter = SceneRefinePrompt.allows
        // What is on screen, described before anything moves.
        let state = controller.liveState
        scene.beginRefinement(timing: speak == nil ? .stagger : .speech, maximumHold: speak == nil ? 8 : 120)
        var turn = TurnTiming(kind: .refinement, request: request, startedAt: Date(), reason: tappedPart == nil ? reason : "tapped \(tappedPart ?? "")")
        if let tappedPart {
            turn.instantScript = "focus \(tappedPart) zoom=medium\nhighlight \(tappedPart)"
        } else {
            turn.instantScript = SceneRefineClassifier.instantScript(request: request, parts: parts)
        }
        if let instant = turn.instantScript { scene.perform(instant) }
        lastTurn = turn
        refinementInProgress = (request, [])
        // The drawing stays "recent" for follow-ups while the person keeps working with it.
        if lastSummary != nil { lastSummaryAt = Date() }
        run(body: SceneRefinePrompt.requestBody(request: request, state: state, tappedPart: tappedPart), hasImages: false)
    }

    // MARK: Draw on the real screen

    /// Marks up the live screen to answer `question`. `screenshotJPEG` is the picture the
    /// model reasons over and `displayFrame` the AppKit frame of the display it shows, so
    /// marks land on that display whichever monitor it is.
    func annotate(question: String, screenshotJPEG: Data, displayFrame: CGRect) {
        beginAnnotation(question: question, displayFrame: displayFrame)
        let turn = generation
        streamTask = Task { [weak self] in
            let visibleText = await SceneAnnotationText.context(imageData: screenshotJPEG, question: question)
            guard let self, !Task.isCancelled, self.generation == turn else { return }
            self.run(body: SceneScriptPrompt.annotateRequestBody(
                question: question, screenshotJPEG: screenshotJPEG, visibleText: visibleText), hasImages: true)
        }
    }

    /// Starts only the annotation layer. Kept separate from transport so its lifecycle can
    /// also be exercised without capturing a screen or making a model request.
    func beginAnnotation(question: String, displayFrame: CGRect) {
        begin(question: question, screenFrame: displayFrame, saves: false, annotating: true) { command in
            // Even a stray clear/remove command is confined to this disposable layer.
            command.verb.family == .overlay || command.verb.family == .control
        }
        lastTurn = TurnTiming(kind: .annotation, request: question, startedAt: Date())
    }

    // MARK: Stopping

    /// Barge-in. The stream and the narration stop and the marks on the screen clear;
    /// a card or 3D model that is already up stays.
    func stop() {
        reportRefinement()
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        for task in speechTasks { task.cancel() }
        speechTasks = []
        let wasSpeaking = sequencer.isSpeaking
        sequencer.stop()
        if wasSpeaking { cancelSpeech?() }
        activeScene.interrupt()
        annotationScene.clear()
        isAnnotating = false
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
        // Played from the Drawings list: which saved drawing it is is not known here, so a refinement of it is not saved over it.
        lastSavedEntryID = nil
        scene.commandFilter = nil
        var anchor = SceneAnchor.display(frame: frame, timing: .stagger)
        placement?(&anchor)
        scene.replay(log, anchor: anchor)
    }

    // MARK: Running a drawing

    private func begin(question: String, screenFrame: CGRect, saves: Bool, annotating: Bool = false, filter: ((SceneCommand) -> Bool)?) {
        stop()
        // A new drawing: anything still pending from the one before (its history picture, late speech) is stale.
        generation += 1
        currentQuestion = question
        savesToHistory = saves
        beganAt = Date()
        sequencer = SceneNarrationSequencer()
        isAnnotating = annotating
        activeScene.commandFilter = filter
        var anchor = SceneAnchor.display(frame: screenFrame, timing: speak == nil ? .stagger : .speech)
        // The sequencer always reports each sentence or the end of speech, so lines can wait as long as the voice needs.
        if speak != nil { anchor.maximumHold = 120 }
        placement?(&anchor)
        activeScene.begin(anchor: anchor)
    }

    private func run(body: [String: Any], hasImages: Bool) {
        let turn = generation
        let startedAt = Date()
        let target = activeScene
        streamTask = Task { [weak self, target] in
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
                    guard let self, self.generation == turn else { return }
                    if !firstLineLogged, chunk.contains("\n") {
                        firstLineLogged = true
                        self.lastTurn.firstLine = Date().timeIntervalSince(self.lastTurn.startedAt)
                        print("🎨 First drawing line \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s after the request")
                    }
                    target.feed(chunk: chunk)
                }
            } catch {
                print("⚠️ Drawing failed: \(error.localizedDescription)")
            }
            guard !Task.isCancelled, let self, self.generation == turn else { return }
            self.lastTurn.streamEnded = Date().timeIntervalSince(self.lastTurn.startedAt)
            self.finishCurrentStream()
        }
    }

    /// Completes transport for the current turn; the generation check belongs to its caller.
    func finishCurrentStream() {
        activeScene.end()
        perform(sequencer.streamDidEnd(), turn: generation)
    }

    // MARK: Narration

    private func sentenceArrived(index: Int, text: String) {
        guard speak != nil else { return }
        perform(sequencer.sentenceArrived(index: index, text: text), turn: generation)
    }

    private func perform(_ actions: [SceneNarrationSequencer.Action], turn: Int) {
        guard generation == turn else { return }
        let target = activeScene
        for action in actions {
            switch action {
            case .speak(let index, let text):
                guard let speak else { continue }
                let task = Task { [weak self, target] in
                    // Show what the sentence describes a moment after the voice is asked for it.
                    let reveal = Task { [weak self, target] in
                        let lead = self?.speechLeadTime ?? 0
                        if lead > 0 { try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000)) }
                        guard let self, !Task.isCancelled, self.generation == turn else { return }
                        target.sentenceStarted(index: index)
                    }
                    await speak(text)
                    guard let self, !Task.isCancelled, self.generation == turn else {
                        reveal.cancel()
                        return
                    }
                    // A voice that returns at once (muted, failed) must not skip the reveal.
                    await reveal.value
                    target.sentenceStarted(index: index)
                    self.perform(self.sequencer.speechFinished(), turn: turn)
                }
                speechTasks.append(task)
            case .finished:
                finishNarration(turn: turn)
            }
        }
    }

    /// Speech is over: everything still waiting is drawn, and marks fade after a reading pause.
    /// Screen annotations stay for three seconds so a short “here it is” does not erase them at once.
    private func finishNarration(turn: Int) {
        let quietFor = Date().timeIntervalSince(beganAt)
        // Marks nobody talked over (no speak callback, or a script without `say`) still need time to be seen.
        let wait = sequencer.spokenCount == 0 ? max(silentMarkTime - quietFor, 0) + 0.1 : (isAnnotating ? 3.0 : 0.6)
        let target = activeScene
        let task = Task { [weak self, target] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == turn else { return }
            target.speechEnded()
            self.reportRefinement()
        }
        speechTasks.append(task)
    }

    /// The drawing on screen is the saved drawing `id`: refinements of it are saved over it.
    func adoptSavedDrawing(_ id: String?) {
        lastSavedEntryID = id
    }

    /// Hands a finished (or interrupted) refinement to the conversation, once.
    private func reportRefinement() {
        guard let refinement = refinementInProgress else { return }
        refinementInProgress = nil
        let answer = refinement.sentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onRefinementAnswered?(refinement.question, answer)
    }

    // MARK: History and follow-ups

    private func sceneFinished() {
        let log = scene.log
        guard !log.isEmpty else { return }
        if lastTurn.kind == .refinement {
            // Without a voice nothing marks the end of the narration: the drawing is done, so is the answer.
            if speak == nil { reportRefinement() }
            lastSummary = log.summary
            lastSummaryAt = Date()
            saveRefinement()
            return
        }
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
            self.lastSavedEntryID = SceneHistory.shared.save(log: log, question: question, thumbnail: thumbnail, narration: self.scene.narration)?.id
        }
    }

    /// The refined drawing replaces the saved one: the log carries the refinement's lines (camera,
    /// ghosting, detail…) after the original ones, so replaying it ends where the person left it,
    /// and the picture in the Drawings list shows the refined view.
    private func saveRefinement() {
        guard let id = lastSavedEntryID else { return }
        let turn = generation
        // After the camera has settled on what was asked for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.lastSavedEntryID == id else { return }
            let log = self.scene.log
            let thumbnail = self.generation == turn ? SceneVideoExporter.picture(of: self.scene, size: CGSize(width: 640, height: 360)) : nil
            SceneHistory.shared.update(id: id, log: log, thumbnail: thumbnail, narration: self.scene.narration)
        }
    }

    /// Narration audio from the voice, for saved videos. The voice turn forwards PCM here as it plays.
    func appendNarrationAudio(_ pcm16: Data, sampleRate: Double) {
        guard sequencer.isSpeaking else { return }
        activeScene.appendNarrationAudio(pcm16, sampleRate: sampleRate)
    }

    // MARK: Photos

    /// publik web search, for finding which page a card's photo should come from.
    private static let publikSearch: ScenePhotoFetcher.Search = { query in
        guard let route = try? TeachyAIRouter.routes(for: .scene, hasImages: false).first, route.isPublik else { return [] }
        return (try? await Publik.search(baseURL: route.baseURL, apiKey: route.apiKey, q: query, count: 6))?.results ?? []
    }
}
