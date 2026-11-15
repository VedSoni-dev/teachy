//
//  In-process tests for the parts of the drawing engine that need AppKit, SceneKit or
//  AVFoundation: speech-synced building and barge-in on a live session, real mouse events
//  into the 3D view and a slider, video export, drawing history and its card, and photos.
//
//  Run with scripts/tests/run_scene2_tests.sh. Nothing is shown: the windows these tests
//  need are placed far off every display, and events are delivered to them in-process
//  (they never go through the window server, so they cannot reach another app).
//
//  Pictures and videos are written to $TMPDIR/teachy-scene2/shots/.
//

import AppKit
import AVFoundation
import SceneKit
import SwiftUI

let arguments = CommandLine.arguments
let useNetwork = arguments.contains("--network")
let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-scene2", isDirectory: true)
let shots = work.appendingPathComponent("shots", isDirectory: true)
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

var failures = 0
var checks = 0
var notes: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL (line \(line)): \(message())")
    }
}

/// Something that could not be exercised in-process: printed in the summary, not a failure.
func note(_ text: String) {
    notes.append(text)
    print("  note: \(text)")
}

func section(_ name: String, _ body: () async -> Void) async {
    let before = failures
    await body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

func writePNG(_ image: NSImage?, _ name: String) {
    guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
        print("  (no picture for \(name))")
        return
    }
    let url = shots.appendingPathComponent(name)
    try? png.write(to: url)
    print("  wrote \(url.path)")
}

func log(from script: String, step: Double = 0.12) -> SceneReplayLog {
    var log = SceneReplayLog()
    for (index, command) in SceneScriptParser.parse(script).enumerated() { log.record(command, at: Double(index) * step) }
    return log
}

/// A place no display covers, so a window there is never seen.
let offscreen = CGPoint(x: -30000, y: -30000)

func offscreenAnchor(timing: SceneCueScheduler.Timing) -> SceneAnchor {
    var anchor = SceneAnchor(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), timing: timing)
    anchor.cardTopLeft = offscreen
    anchor.modelTopLeft = offscreen
    anchor.hostsOverlay = true
    return anchor
}

func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                       context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
}

// MARK: - Tests

@MainActor
func runAll() async {
    await speechSync()
    await mouse()
    await video()
    await history()
    await photos()

    print("\n\(checks) checks, \(failures) failures")
    if !notes.isEmpty {
        print("Could not be exercised in-process:")
        for note in notes { print("  - \(note)") }
    }
    exit(failures == 0 ? 0 : 1)
}

@MainActor
func speechSync() async {
    await section("speech sync: sentences are handed over on arrival, drawings wait for their sentence") {
        let session = SceneSession()
        var said: [String] = []
        var finished = 0
        session.onSay = { index, text in said.append("\(index):\(text)") }
        session.onFinished = { finished += 1 }
        var anchor = offscreenAnchor(timing: .speech)
        anchor.maximumHold = 120
        session.begin(anchor: anchor)
        // The whole script arrives before a word is spoken (the stream is ahead of the voice).
        session.feed(chunk: "say 1 \"First.\"\nring a at=100,100 r=20\nsay 2 \"Second.\"\nrect b from=10,10 to=60,60\ncard c title=\"Card\"\ntext t \"hello\"\n")
        session.end()
        expect(said == ["1:First.", "2:Second."], "both sentences reach the host at once, before anything is drawn: \(said)")
        await pause(0.4)
        expect(session.overlayModel.items.isEmpty && session.cards.isEmpty, "nothing is drawn until a sentence starts")
        expect(finished == 0, "not finished while lines wait")

        session.sentenceStarted(index: 1)
        await pause(0.4)
        expect(session.overlayModel.items.map(\.id) == ["a"], "sentence 1 shows its ring and only that: \(session.overlayModel.items.map(\.id))")
        expect(session.cards.isEmpty, "the card belongs to sentence 2")

        session.sentenceStarted(index: 2)
        await pause(0.6)
        expect(session.overlayModel.items.map(\.id) == ["a", "b"], "sentence 2 shows its box")
        expect(session.cards.count == 1 && session.cards[0].model.title == "Card" && session.cards[0].model.items.count == 1, "and its card")
        expect(finished == 1, "finished once everything is drawn (\(finished))")
        expect(session.log.entries.map(\.command.verb) == [.say, .ring, .say, .rect, .card, .text], "the log holds every line in order")

        session.speechEnded()
        await pause(1.9)
        expect(session.overlayModel.items.isEmpty, "marks clear when speech ends")
        expect(session.cards.count == 1, "the card stays")
        session.clear()
    }

    await section("speech sync: a line that arrives after its sentence started is drawn at once") {
        let session = SceneSession()
        session.begin(anchor: offscreenAnchor(timing: .speech))
        session.feed(chunk: "say 1 \"First.\"\n")
        session.sentenceStarted(index: 1)
        await pause(0.2)
        // The stream is behind the voice.
        session.feed(chunk: "ring late at=5,5 r=9\n")
        await pause(0.3)
        expect(session.overlayModel.items.map(\.id) == ["late"], "drawn without waiting")
        session.clear()
    }

    await section("barge-in: what arrived is finished off, marks go, cards and 3D stay") {
        let session = SceneSession()
        var anchor = offscreenAnchor(timing: .speech)
        anchor.maximumHold = 120
        session.begin(anchor: anchor)
        session.feed(chunk: "say 1 \"One.\"\nring a at=100,100 r=20\nsay 2 \"Two.\"\ncard c title=\"Kept\"\nbullet \"x\"\nsay 3 \"Three.\"\nscene3d s title=\"Kept too\"\nsphere ball r=1\nrect z from=1,1 to=5,5")
        session.sentenceStarted(index: 1)
        await pause(0.3)
        expect(session.overlayModel.items.count == 1 && session.cards.isEmpty, "mid-narration: one mark, no card yet")
        session.interrupt()
        await pause(1.6)
        expect(session.overlayModel.items.isEmpty, "marks are gone: \(session.overlayModel.items.map(\.id))")
        expect(session.cards.count == 1 && session.cards[0].model.title == "Kept", "the card that had arrived is shown, not lost")
        expect(session.partCount == 1 && session.modelWindow != nil, "so is the 3D model")
        session.clear()
    }

    await section("annotate filter: only marks on the screen get through") {
        let session = SceneSession()
        session.commandFilter = { $0.verb.family == .overlay || $0.verb.family == .control }
        session.begin(anchor: offscreenAnchor(timing: .stagger))
        session.feed(chunk: "say 1 \"Here.\"\nrect a from=1,1 to=9,9\ncard c title=\"No\"\ntext \"no\"\nscene3d s\nbox b\nlabel l at=5,5 text=\"yes\"\nhighlight h from=1,1 to=9,3\n")
        session.end()
        await pause(1.0)
        expect(session.overlayModel.items.map(\.id) == ["a", "l", "h"], "rect, pill and highlight are drawn: \(session.overlayModel.items.map(\.id))")
        expect(session.cards.isEmpty && session.modelWindow == nil, "no card and no 3D window")
        // A highlight fades by itself after 2 s; shapes stay until speech ends.
        await pause(2.2)
        expect(session.overlayModel.items.map(\.id) == ["a", "l"], "the highlight has gone after 2 s, the shapes are still there: \(session.overlayModel.items.map(\.id))")
        session.clear()
    }
}

@MainActor
func mouse() async {
    await section("mouse: a real click on a part of the 3D model asks about that part") {
        let session = SceneSession()
        var tapped: [String] = []
        session.onPartTapped = { id, label in tapped.append("\(id)|\(label)") }
        session.begin(anchor: offscreenAnchor(timing: .stagger))
        session.feed(chunk: "scene3d s title=\"Rocket\"\nrocket r stages=2\nslider spd min=0 max=100 value=20 label=\"Speed\" bind=r.rpm\n")
        session.end()
        await pause(1.5)
        guard let window = session.modelWindow, let panel = window.controller.view.window else {
            expect(false, "the 3D window exists")
            return
        }
        let controller = window.controller
        let view = controller.view
        // The window is off every display, so SceneKit never draws it and the parts' fade-in never
        // runs (a part at opacity 0 cannot be hit). Drawing a few frames in-process runs it.
        let pump = SCNRenderer(device: nil, options: nil)
        pump.scene = controller.scene
        pump.pointOfView = view.pointOfView
        let pumpStart = CACurrentMediaTime()
        for frame in 0..<30 { _ = pump.snapshot(atTime: pumpStart + Double(frame) / 30, with: CGSize(width: 64, height: 48), antialiasingMode: .none) }
        controller.freezeCamera(azimuth: 0.5)
        expect(!panel.frame.intersects(NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }), "the test window is off every display")

        // Where the first stage is in the view, then a real mouse down and up there.
        guard let point = controller.viewPoint(ofPart: "r.stage1") else {
            expect(false, "the part can be projected into the view")
            return
        }
        let inWindow = view.convert(point, to: nil)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: inWindow, in: panel))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: inWindow, in: panel))
        expect(tapped == ["r.stage1|First stage"], "mouseDown + mouseUp on the first stage reports it: \(tapped)")
        expect(controller.model.tappedLabel == "First stage", "and the model remembers what was tapped")

        // An unnamed piece of the object (a black band) stands for the piece it belongs to.
        tapped = []
        if let band = controller.viewPoint(ofPart: "r.nose") {
            let spot = view.convert(band, to: nil)
            view.mouseDown(with: mouseEvent(.leftMouseDown, at: spot, in: panel))
            view.mouseUp(with: mouseEvent(.leftMouseUp, at: spot, in: panel))
            expect(tapped == ["r.nose|Nose cone"], "a click on the nose reports the nose: \(tapped)")
        }

        // A click on empty space reports nothing.
        tapped = []
        let empty = view.convert(CGPoint(x: 6, y: 6), to: nil)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: empty, in: panel))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: empty, in: panel))
        expect(tapped.isEmpty, "empty space is not a part")

        // A drag is not a click, and it takes the camera from the auto-sway.
        tapped = []
        let before = (view.pointOfView ?? SCNNode()).presentation.simdWorldTransform
        expect(!controller.cameraWasTakenByUser, "clicks did not stop the model's own turning")
        let start = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: panel))
        for step in 1...12 {
            view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: start.x + CGFloat(step) * 12, y: start.y + CGFloat(step) * 3), in: panel))
        }
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: start.x + 144, y: start.y + 36), in: panel))
        await pause(0.4)
        expect(tapped.isEmpty, "a drag does not count as a click on a part")
        expect(controller.cameraWasTakenByUser, "dragging takes the camera from the auto-sway")
        let after = (view.pointOfView ?? SCNNode()).presentation.simdWorldTransform
        let moved = simd_length(after.columns.3 - before.columns.3) > 1e-3 || simd_length(after.columns.2 - before.columns.2) > 1e-3
        if moved {
            print("  the camera turned with the drag")
        } else {
            note("Orbit by dragging: mouseDown/mouseDragged/mouseUp were delivered to the SCNView and the engine handed the camera to the person, but SceneKit's own camera controller did not turn the view for a window that is off every display (it only tracks drags in a window it is drawing). Needs a look in the running app.")
        }

        // The slider under the model: a real press and release on its track.
        var changes: [String] = []
        let record = controller.onSliderChanged
        controller.onSliderChanged = { id, value in
            changes.append("\(id)=\(Int(value.rounded()))")
            record?(id, value)
        }
        // SwiftUI's Slider is not an NSSlider in the view tree on this macOS, so the press is aimed from the
        // chrome's layout: a 460-point box centred under the 640×470 model, 18 in, after a 110-point label.
        let trackLeft: CGFloat = (640 - 460) / 2 + 18 + 110 + 10, trackRight: CGFloat = 640 - (640 - 460) / 2 - 18 - 58 - 10
        let fromTop: CGFloat = Scene3DView.viewSize.height + 8 + 12 + 11
        let press = CGPoint(x: trackLeft + (trackRight - trackLeft) * 0.8, y: panel.frame.height - fromTop)
        let grab = CGPoint(x: trackLeft + (trackRight - trackLeft) * 0.2, y: press.y)
        // If the slider runs its own event loop until the button comes up, it finds the release queued here.
        NSApp.postEvent(mouseEvent(.leftMouseDragged, at: press, in: panel), atStart: false)
        NSApp.postEvent(mouseEvent(.leftMouseUp, at: press, in: panel), atStart: false)
        panel.sendEvent(mouseEvent(.leftMouseDown, at: grab, in: panel))
        // If it does not, these reach it the ordinary way.
        panel.sendEvent(mouseEvent(.leftMouseDragged, at: press, in: panel))
        panel.sendEvent(mouseEvent(.leftMouseUp, at: press, in: panel))
        await pause(0.4)
        let value = controller.model.sliders.first?.value ?? -1
        if abs(value - 20) > 0.5 {
            print("  the slider moved to \(String(format: "%.1f", value)) under a real press and drag")
            expect(value > 55 && value < 100, "dragging the knob to 80% of the track sets it near 80 (it is \(value))")
            expect(!changes.isEmpty && changes.last!.hasPrefix("spd="), "and the change is reported: \(changes)")
            expect(session.log.entries.contains { $0.command.verb == .set && $0.command.id == "spd" }, "the drag is in the log as a `set` line, so replays include it")
        } else {
            note("Slider by mouse: a press, drag and release were delivered to the panel at the slider's track, but SwiftUI's Slider did not move for a window that is off every display. What the slider calls, setSlider(_:value:fromUser:), is checked instead. Needs a look in the running app.")
            controller.setSlider("spd", value: 70, fromUser: true)
            expect(changes == ["spd=70"] && controller.model.sliders.first?.value == 70, "setSlider reports and stores the value: \(changes)")
            expect(session.log.entries.contains { $0.command.verb == .set && $0.command.id == "spd" }, "the change is in the log as a `set` line, so replays include it")
        }
        session.clear()
    }
}

func firstView<T: NSView>(ofClass type: T.Type, in root: NSView) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews { if let match = firstView(ofClass: type, in: child) { return match } }
    return nil
}

@MainActor
func video() async {
    let script = """
    say 1 "A turbofan pulls air in with a big fan."
    scene3d t title="How a turbofan works"
    jet j
    label a on=j.fan text="Fan" n=1
    say 2 "The compressor squeezes it and fuel burns in the combustor."
    label b on=j.compressor text="Compressor" n=2
    label c on=j.combustor text="Combustor" n=3
    card k title="Thrust"
    formula "Thrust ≈ airflow × speed gain"
    bullet "Most thrust comes from the bypass air"
    ring r at=500,500 r=60
    chip "Why is the fan so big?"
    """
    let sceneLog = log(from: script, step: 0.15)

    await section("video: a drawing is rendered to MP4 off screen, with the voice when there is one") {
        // 1.2 s of a 440 Hz tone at 24 kHz, starting half a second in, stands in for the voice.
        var narration = SceneNarrationAudio()
        let tone: [Int16] = (0..<28_800).map { Int16(9000 * sin(Double($0) * 2 * Double.pi * 440 / 24_000)) }
        narration.append(tone.withUnsafeBufferPointer { Data(buffer: $0) }, sampleRate: 24_000, at: 0.5)
        var options = SceneVideoOptions()
        options.size = CGSize(width: 640, height: 360)
        options.framesPerSecond = 15
        options.tail = 1.0
        let url = work.appendingPathComponent("export-small.mp4")
        var progress: [Double] = []
        let exportStarted = Date()
        do {
            try await SceneVideoExporter.export(log: sceneLog, narration: narration, to: url, options: options) { progress.append($0) }
            print(String(format: "  640×360, 15 fps: rendered in %.1f s", Date().timeIntervalSince(exportStarted)))
        } catch {
            expect(false, "export threw: \(error.localizedDescription)")
            return
        }
        let asset = AVURLAsset(url: url)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let duration = ((try? await asset.load(.duration)) ?? .zero).seconds
        expect(videoTracks.count == 1, "one video track")
        if let track = videoTracks.first {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let rate = (try? await track.load(.nominalFrameRate)) ?? 0
            expect(size == CGSize(width: 640, height: 360), "640×360: \(size)")
            expect(abs(rate - 15) < 0.5, "15 fps: \(rate)")
        }
        let expected = sceneLog.duration + 1.0
        expect(abs(duration - expected) < 0.25, "lasts the scene plus its tail (\(String(format: "%.2f", duration)) s, expected \(String(format: "%.2f", expected)))")
        expect(audioTracks.count == 1, "the voice is in the file as an audio track (\(audioTracks.count))")
        if let track = audioTracks.first {
            let range = (try? await track.load(.timeRange)) ?? .zero
            expect(range.duration.seconds > 1.4 && range.duration.seconds < duration + 0.3, "audio runs from the start to the end of the voice: \(String(format: "%.2f", range.duration.seconds)) s")
        }
        expect(progress.last == 1 && progress == progress.sorted(), "progress goes up to 1")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        expect(bytes > 20_000, "the file has real content (\(bytes) bytes)")

        // A frame from the middle and the last frame, read back out of the file.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (name, time) in [("export-frame-early.png", 0.5), ("export-frame-end.png", duration - 0.1)] {
            if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                writePNG(NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height)), name)
            }
        }
        if let early = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image,
           let late = try? await generator.image(at: CMTime(seconds: duration - 0.1, preferredTimescale: 600)).image {
            expect(differingPixels(early, late) > 0.02, "the picture builds up over time (early and late frames differ)")
        }

        // Silent when no audio was captured.
        let silent = work.appendingPathComponent("export-silent.mp4")
        try? await SceneVideoExporter.export(log: sceneLog, to: silent, options: options)
        let silentAudio = (try? await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)) ?? []
        expect(silentAudio.isEmpty && FileManager.default.fileExists(atPath: silent.path), "no voice captured: a silent video")
    }

    await section("video: the same log gives the same picture, and 1080p works") {
        let first = await SceneVideoExporter.poster(log: sceneLog, size: CGSize(width: 640, height: 360))
        let second = await SceneVideoExporter.poster(log: sceneLog, size: CGSize(width: 640, height: 360))
        writePNG(first, "poster-turbofan.png")
        if let a = first?.cgImage(forProposedRect: nil, context: nil, hints: nil), let b = second?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let different = differingPixels(a, b)
            expect(different < 0.003, "two renders of one log match (\(String(format: "%.4f", different * 100))% of pixels differ)")
        } else {
            expect(false, "posters were rendered")
        }
        do {
            try await SceneVideoExporter.export(log: SceneReplayLog(), to: work.appendingPathComponent("empty.mp4"))
            expect(false, "an empty log is refused")
        } catch {
            expect(error is SceneExportError, "an empty log throws a readable error: \(error.localizedDescription)")
        }

        var options = SceneVideoOptions()
        options.tail = 0.5
        let url = shots.appendingPathComponent("turbofan-1080p.mp4")
        let started = Date()
        do {
            try await SceneVideoExporter.export(log: sceneLog, to: url, options: options)
            let asset = AVURLAsset(url: url)
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            let duration = ((try? await asset.load(.duration)) ?? .zero).seconds
            expect(size == CGSize(width: 1920, height: 1080), "1080p by default: \(size)")
            print(String(format: "  1080p, 30 fps: %.1f s of video rendered in %.1f s -> %@", duration, Date().timeIntervalSince(started), url.path))
        } catch {
            expect(false, "1080p export threw: \(error.localizedDescription)")
        }
    }
}

/// Share of pixels that differ noticeably between two same-sized images.
func differingPixels(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
    let first = bytes(a), second = bytes(b)
    var different = 0
    for pixel in stride(from: 0, to: first.count, by: 4) {
        let delta = abs(Int(first[pixel]) - Int(second[pixel])) + abs(Int(first[pixel + 1]) - Int(second[pixel + 1])) + abs(Int(first[pixel + 2]) - Int(second[pixel + 2]))
        if delta > 48 { different += 1 }
    }
    return Double(different) / Double(a.width * a.height)
}

@MainActor
func history() async {
    await section("history: finished drawings are kept, replayed, exported, and shown on the Drawings card") {
        let root = work.appendingPathComponent("history-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SceneHistory(root: root)
        expect(history.entries.isEmpty, "a new history is empty")
        writePNG(render(DrawingsSection(history: history, startsExpanded: true)), "drawings-card-empty.png")

        let scripts: [(String, String)] = [
            ("show me how a rocket works", "say 1 \"A rocket.\"\nscene3d s title=\"Two-stage rocket\"\nrocket r stages=2 labels"),
            ("explain the chain rule", "say 1 \"The chain rule.\"\ncard c title=\"The chain rule\"\nformula \"dy/dx = dy/du × du/dx\"\nsteps \"x\" \"u = 3x² + 1\" \"y = ln u\"\nbullet \"Outer rate: 1/u\"\nbullet \"Inner rate: 6x\""),
            ("what's inside a battery", "say 1 \"A battery.\"\nscene3d s title=\"Inside a battery\"\nbattery b labels"),
            ("how does the heart pump", "scene3d s title=\"How the heart pumps\"\nheart h labels"),
            ("why does a bridge stay up", "scene3d s title=\"Suspension bridge\"\nbridge b labels"),
        ]
        var saved: [SceneHistoryEntry] = []
        for (question, script) in scripts {
            let sceneLog = log(from: script)
            let poster = await SceneVideoExporter.poster(log: sceneLog)
            if let entry = history.save(log: sceneLog, question: question, thumbnail: poster) { saved.append(entry) }
        }
        expect(saved.count == scripts.count && history.entries.count == scripts.count, "five drawings saved (\(history.entries.count))")
        expect(Set(history.entries.map(\.title)) == ["Two-stage rocket", "The chain rule", "Inside a battery", "How the heart pumps", "Suspension bridge"], "titles: \(history.entries.map(\.title))")
        expect(history.entries.allSatisfy { history.thumbnail(for: $0.id) != nil }, "each has a thumbnail")
        expect(saved.allSatisfy { $0.id.hasPrefix(SceneHistoryStore.makeID(date: Date()).prefix(10)) }, "folders are named by today's date")

        writePNG(render(DrawingsSection(history: history, startsExpanded: true)), "drawings-card.png")
        writePNG(render(DrawingsSection(history: history, startsExpanded: false)), "drawings-card-collapsed.png")
        if let first = saved.first { writePNG(history.thumbnail(for: first.id), "history-thumbnail-rocket.png") }

        // Replay goes through whoever plays drawings (the director in the app).
        var played: SceneReplayLog?
        history.player = { played = $0 }
        history.replay(saved[1].id)
        expect(played?.title == "The chain rule" && played?.entries.count == 6, "replay hands the saved log to the player")
        history.replay("2026-01-01-00000000")
        expect(played?.title == "The chain rule", "an unknown id plays nothing")

        // Export writes video.mp4 into the drawing's folder, once.
        do {
            let url = try await history.export(saved[1].id)
            expect(url.lastPathComponent == "video.mp4" && url.path.hasPrefix(root.path), "the video is written inside the drawing's folder")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            expect(size > 10_000, "it is a real file (\(size) bytes)")
            let stamp = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            let again = try await history.export(saved[1].id)
            expect(again == url && (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == stamp, "asking again returns the same file without rendering twice")
            expect(history.exportProgress.isEmpty, "no export left marked as running")
        } catch {
            expect(false, "export threw: \(error.localizedDescription)")
        }
        do {
            _ = try await history.export("2026-01-01-00000000")
            expect(false, "exporting a missing drawing throws")
        } catch {
            expect(error is SceneHistoryError, "a missing drawing gives a readable error")
        }

        history.delete(saved[0].id)
        expect(history.entries.count == scripts.count - 1 && !FileManager.default.fileExists(atPath: history.store.folder(for: saved[0].id).path), "a drawing can be removed")
        expect(DrawingTile.dayText(Date()) == "Today" && DrawingTile.dayText(Date().addingTimeInterval(-86_400)) == "Yesterday", "dates read as Today and Yesterday")
    }
}

/// Draws a SwiftUI view through an off-screen hosting view (ImageRenderer cannot draw the
/// AppKit-backed pointer-cursor modifier the design system puts on buttons).
@MainActor
func render<V: View>(_ view: V, width: CGFloat = 320) -> NSImage? {
    let hosting = NSHostingView(rootView: view.frame(width: width).padding(14).background(DS.Colors.background).environment(\.colorScheme, .dark))
    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    guard hosting.bounds.width > 0, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let image = NSImage(size: hosting.bounds.size)
    image.addRepresentation(bitmap)
    return image
}

@MainActor
func photos() async {
    await section("photos: a cached photo is used without the network, and the card shows its source") {
        let cache = work.appendingPathComponent("photo-cache-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Seed the cache with a picture drawn here, as if it had been downloaded before.
        let picture = NSImage(size: CGSize(width: 320, height: 200))
        picture.lockFocus()
        NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: CGRect(x: 0, y: 0, width: 320, height: 200), angle: 40)
        picture.unlockFocus()
        let key = ScenePhotoPicker.cacheKey(for: "Test Subject")
        try? SceneHistory.png(picture)?.write(to: cache.appendingPathComponent("\(key).img"))
        try? Data(#"{"query":"test subject","source":"https://en.wikipedia.org/wiki/Test","sourceName":"Wikipedia"}"#.utf8).write(to: cache.appendingPathComponent("\(key).json"))

        var searches = 0
        let fetcher = ScenePhotoFetcher(cacheFolder: cache) { _ in searches += 1; return [] }
        let photo = await fetcher.photo(for: "  test   SUBJECT ")
        expect(photo != nil && searches == 0, "served from the cache, no search made (\(searches))")
        expect(photo?.sourceURL?.absoluteString == "https://en.wikipedia.org/wiki/Test" && photo?.sourceName == "Wikipedia", "with its source page")
        let nothing = await fetcher.photo(for: "")
        expect(nothing == nil, "an empty query finds nothing")

        // A card asks for the photo on its own task and fills in when it arrives.
        let session = SceneSession()
        session.photoFetcher = { query in await fetcher.photo(for: query) }
        session.begin(anchor: offscreenAnchor(timing: .stagger))
        session.feed(chunk: "card c title=\"Photo card\"\nimage query=\"test subject\" caption=\"A test photo\"\ntext \"Text keeps arriving while the photo loads.\"\n")
        session.end()
        await pause(1.0)
        let item = session.cards.first?.model.items.first { if case .image = $0.kind { return true } else { return false } }
        expect(item?.image != nil && item?.sourceName == "Wikipedia", "the card has the photo and its source")
        expect(session.cards.first?.model.items.count == 2, "the text line was not held up by the photo")
        writePNG(session.cards.first?.snapshot(), "card-photo-source.png")
        session.clear()
    }

    guard useNetwork else {
        print("skip photos from the network (run with --network)")
        return
    }
    await section("photos (network): a real photo is found, downloaded, cached and captioned") {
        let cache = work.appendingPathComponent("photo-cache-net-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        // 1. Wikipedia alone (no search service).
        let plain = ScenePhotoFetcher(cacheFolder: cache)
        let bridge = await plain.photo(for: "Golden Gate Bridge")
        expect(bridge != nil, "Wikipedia has a photo of the Golden Gate Bridge")
        expect(bridge?.sourceURL?.host == "en.wikipedia.org" && bridge?.sourceName == "Wikipedia", "its source is the article: \(bridge?.sourceURL?.absoluteString ?? "nil")")
        expect((bridge?.image.size.width ?? 0) > 200, "a real picture (\(bridge?.image.size ?? .zero))")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        expect(files.count == 2 && files.contains { $0.hasSuffix(".img") } && files.contains { $0.hasSuffix(".json") }, "cached as an image and a note: \(files)")
        // 2. A phrase that is not an article title, resolved through publik search.
        var searches = 0
        let searching = ScenePhotoFetcher(cacheFolder: cache) { query in
            searches += 1
            guard let route = try? TeachyAIRouter.routes(for: .scene, hasImages: false).first, route.isPublik else { return [] }
            return (try? await Publik.search(baseURL: route.baseURL, apiKey: route.apiKey, q: query, count: 6))?.results ?? []
        }
        let engine = await searching.photo(for: "GE9X turbofan engine")
        expect(searches == 1, "one search")
        expect(engine != nil, "a photo was found for a phrase that is not an article title")
        print("  GE9X photo source: \(engine?.sourceURL?.absoluteString ?? "none"), size \(engine?.image.size ?? .zero)")
        _ = await searching.photo(for: "ge9x turbofan engine")
        expect(searches == 1, "asking again uses the cache, not another search")

        let session = SceneSession()
        session.photoFetcher = { query in await searching.photo(for: query) }
        session.begin(anchor: offscreenAnchor(timing: .stagger))
        session.feed(chunk: "card c title=\"The GE9X\"\nimage query=\"GE9X turbofan engine\" caption=\"The largest jet engine\"\nbullet \"Fan 3.4 m across\"\nbullet \"Built for the Boeing 777X\"\n")
        session.end()
        await pause(1.2)
        writePNG(session.cards.first?.snapshot(), "card-real-photo.png")
        session.clear()
    }
}

// A hung event loop must not hang the test run.
setvbuf(stdout, nil, _IONBF, 0)
DispatchQueue.global().asyncAfter(deadline: .now() + 540) {
    print("FAIL: the app tests did not finish in 9 minutes")
    exit(3)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async { Task { @MainActor in await runAll() } }
app.run()
