//
//  A live check of SceneDirector end to end, with the real scene model and a stand-in voice:
//
//    1. show(…): the drawing narrates itself. Each sentence goes to `speak` in order, and
//       nothing cued to a sentence is drawn before that sentence starts being spoken.
//    2. Barge-in: stop() cancels the stream and the speech, clears marks, keeps the model.
//    3. annotate(…): a screenshot goes to the model and the marks land on the thing asked about.
//
//  Run with scripts/tests/run_scene2_tests.sh --live. It makes three model calls through
//  TeachyAIRouter. Nothing is shown: windows are placed off every display. Drawings are
//  saved under a temp folder (TEACHY_DRAWINGS_DIR), never in the real ~/.teachy.
//

import AppKit
import SwiftUI
import simd

let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-scene2", isDirectory: true)
let drawings = work.appendingPathComponent("director-drawings-\(UUID().uuidString.prefix(8))", isDirectory: true)
setenv("TEACHY_DRAWINGS_DIR", drawings.path, 1)
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL (line \(line)): \(message())")
    }
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

/// Waits until `condition` holds or `limit` seconds pass. Returns whether it held.
@MainActor
func wait(_ limit: Double, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while Date() < deadline {
        if condition() { return true }
        await pause(0.1)
    }
    return condition()
}

@MainActor
func run() async {
    guard TeachyAIRouter.isReadyForAI else {
        print("Teachy isn't signed in to publik on this Mac, so there is no model to ask.")
        exit(2)
    }
    let director = SceneDirector.shared
    director.placement = { anchor in
        anchor.cardTopLeft = CGPoint(x: -30000, y: -30000)
        anchor.modelTopLeft = CGPoint(x: -30000, y: -30000)
        anchor.hostsOverlay = true
    }

    // 1. A drawing that narrates itself.
    var spoken: [(text: String, at: CFTimeInterval, partsThen: Int, labelsThen: Int)] = []
    var cancels = 0
    let sentenceLength = 1.6
    director.speak = { text in
        let log = director.scene.log
        spoken.append((text, CACurrentMediaTime(), director.scene.partCount, log.entries.filter { $0.command.verb == .label }.count))
        try? await Task.sleep(nanoseconds: UInt64(sentenceLength * 1_000_000_000))
    }
    director.cancelSpeech = { cancels += 1 }
    var followUps: [String] = []
    director.onFollowUpQuestion = { followUps.append($0) }

    print("show: how a turbofan works")
    let started = CACurrentMediaTime()
    director.show("how a turbofan works, in 3D")
    let done = await wait(60) { SceneHistory.shared.entries.count == 1 }
    expect(done, "the drawing finished and was saved within a minute")
    let log = director.scene.log
    let says = log.entries.filter { $0.command.verb == .say }
    print("  \(spoken.count) sentences spoken, \(log.entries.count) lines drawn, \(director.scene.partCount) parts, \(String(format: "%.1f", CACurrentMediaTime() - started)) s")
    for (index, sentence) in spoken.enumerated() {
        print(String(format: "  %5.1f s  say %d: %@   (parts on screen then: %d, labels: %d)", sentence.at - started, index + 1, sentence.text, sentence.partsThen, sentence.labelsThen))
    }
    expect((3...6).contains(spoken.count), "3–6 sentences were spoken (\(spoken.count))")
    expect(spoken.map(\.text) == says.compactMap(\.command.freeText), "every `say` line was spoken, in order")
    for index in spoken.indices.dropFirst() {
        expect(spoken[index].at - spoken[index - 1].at >= sentenceLength - 0.05, "sentence \(index + 1) waited for sentence \(index) to finish")
    }
    // Nothing cued to a sentence is drawn before that sentence starts being spoken.
    var early = 0, cued = 0
    for entry in log.entries where entry.command.verb != .say {
        guard let cue = entry.command.cue, let position = says.firstIndex(where: { $0.command.cue == cue }), position < spoken.count else { continue }
        cued += 1
        if started + entry.time < spoken[position].at - 0.05 { early += 1 }
    }
    expect(cued > 3 && early == 0, "of \(cued) cued lines, \(early) were drawn before their sentence started")
    // And each sentence brought something: more on screen by the time the next one starts.
    let growth = zip(spoken, spoken.dropFirst()).filter { $1.partsThen + $1.labelsThen > $0.partsThen + $0.labelsThen }.count
    expect(growth >= spoken.count - 2, "the drawing grew with the narration (\(growth) of \(spoken.count - 1) steps added something)")
    expect(director.scene.partCount > 10, "a real model was built (\(director.scene.partCount) parts)")
    expect(director.lastSummary?.isEmpty == false, "a summary is kept for follow-ups")
    print("  summary for follow-ups:\n    " + (director.lastSummary ?? "").replacingOccurrences(of: "\n", with: "\n    "))
    if let entry = SceneHistory.shared.entries.first {
        expect(entry.question == "how a turbofan works, in 3D" && entry.kind == "3D model", "history entry: \(entry.title), \(entry.kind)")
        let thumb = await wait(4) { SceneHistory.shared.thumbnail(for: entry.id) != nil }
        expect(thumb, "with a thumbnail")
        expect(SceneHistory.shared.store.root.path == drawings.path, "saved under the temp folder, not ~/.teachy")
    }
    // A click on a part asks a follow-up that names the drawing.
    director.scene.modelWindow?.controller.tapPart("j.turbine")
    expect(followUps.count == 1 && followUps[0].contains("Turbine") || followUps.first?.contains("turbine") == true, "tapping a part asks about it: \(followUps)")
    expect(followUps.first?.hasPrefix("In the drawing \"") == true, "and names the drawing it is in: \(followUps)")

    // 2. Barge-in.
    print("barge-in: stop() in the middle of a drawing")
    spoken = []
    cancels = 0
    director.show("how the heart pumps blood")
    let speaking = await wait(40) { spoken.count == 1 }
    expect(speaking, "the second drawing started speaking")
    await pause(0.5)
    let partsAtStop = director.scene.partCount
    director.stop()
    expect(cancels == 1, "the voice was told to stop (\(cancels))")
    await pause(sentenceLength + 2.0)
    expect(spoken.count == 1, "no sentence was spoken after the barge-in (\(spoken.count))")
    expect(director.scene.overlayModel.items.isEmpty, "no marks on the screen")
    expect(director.scene.modelWindow != nil || !director.scene.cards.isEmpty, "the model or card that was up is kept")
    expect(director.scene.partCount >= partsAtStop, "nothing was taken away from it (\(partsAtStop) -> \(director.scene.partCount))")
    let linesAfterStop = director.scene.log.entries.count
    await pause(1.5)
    expect(director.scene.log.entries.count == linesAfterStop, "the cancelled stream draws nothing more")

    // 3. Draw on the real screen.
    print("annotate: where is the Save button")
    spoken = []
    let size = CGSize(width: 1440, height: 900)
    let save = CGRect(x: 980, y: 96, width: 120, height: 40)      // top-left origin, pixels
    let image = NSImage(size: size, flipped: true) { _ in
        NSColor(white: 0.93, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: 240, y: 60, width: 960, height: 700), xRadius: 12, yRadius: 12).fill()
        for (title, rect, color) in [("Cancel", CGRect(x: 700, y: 96, width: 120, height: 40), NSColor(white: 0.85, alpha: 1)),
                                     ("Delete", CGRect(x: 840, y: 96, width: 120, height: 40), NSColor.systemRed),
                                     ("Save", save, NSColor.systemBlue)] {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: rect.minX + 34, y: rect.minY + 9))
        }
        NSAttributedString(string: "Edit profile", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 280, y: 96))
        return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
        expect(false, "screenshot drawn")
        return
    }
    // A display to the left of the main one and set lower, to prove marks are anchored to the display given.
    let display = CGRect(x: -1440, y: -120, width: 1440, height: 900)
    var seen: [SceneCommand] = []
    director.annotate(question: "where is the Save button?", screenshotJPEG: jpeg, displayFrame: display)
    let marked = await wait(40) {
        for item in director.scene.overlayModel.items where !seen.contains(where: { $0.id == item.id }) { seen.append(item.command) }
        return !spoken.isEmpty && !seen.isEmpty
    }
    expect(marked, "a mark appeared and a sentence was spoken")
    await pause(0.6)
    for item in director.scene.overlayModel.items where !seen.contains(where: { $0.id == item.id }) { seen.append(item.command) }
    print("  said: \(spoken.map(\.text))   marks: \(seen.map(\.scriptLine))")
    let low = SceneScreenMapping.normalized(pixel: CGPoint(x: save.minX, y: save.minY), screenshotSize: size)
    let high = SceneScreenMapping.normalized(pixel: CGPoint(x: save.maxX, y: save.maxY), screenshotSize: size)
    if let first = seen.first(where: { $0.verb != .label }) ?? seen.first, let focus = SceneScreenMapping.focus(of: first) {
        expect(focus.x >= low.x && focus.x <= high.x && focus.y >= low.y && focus.y <= high.y, "the mark is on the Save button (\(focus) in \(low)…\(high))")
        let onScreen = SceneScreenMapping.screenPoint(focus, displayFrame: display)
        expect(display.contains(onScreen) && onScreen.x < 0, "and it is placed on the display the screenshot came from: \(onScreen)")
    } else {
        expect(false, "there is a mark to judge")
    }
    expect(director.scene.cards.isEmpty && director.scene.modelWindow == nil, "annotation drew no card and no 3D")
    let cleared = await wait(12) { director.scene.overlayModel.items.isEmpty }
    expect(cleared, "marks clear after the speech ends")
    expect(SceneHistory.shared.entries.count <= 2, "an annotation is not saved as a drawing")

    director.clear()
    try? FileManager.default.removeItem(at: drawings)
    print("\n\(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
    print("FAIL: the director test did not finish in 5 minutes")
    exit(3)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async { Task { @MainActor in await run() } }
app.run()
