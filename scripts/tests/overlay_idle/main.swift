import AppKit
import SwiftUI

var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures += 1; print("FAIL: \(message)") }
}
func dates(_ model: SceneOverlayModel, from date: Date) -> [Date] {
    Array(SceneOverlayTimelineSchedule(intervals: model.animationIntervals).entries(from: date, mode: .normal))
}
func save(_ image: NSImage?, name: String, directory: URL) {
    guard let image, let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
        failures += 1; print("FAIL: render \(name)"); return
    }
    do { try data.write(to: directory.appendingPathComponent(name + ".png")) }
    catch { failures += 1; print("FAIL: write \(name): \(error)") }
}

MainActor.assumeIsolated {
    let anchor = Date(timeIntervalSinceReferenceDate: 10_000)
    var current = anchor
    let model = SceneOverlayModel()
    model.clock = { current }
    let ring = SceneCommand(verb: .ring, id: "ring", args: ["at": "300,400", "r": "120"])
    model.apply(ring)
    let reveal = dates(model, from: anchor)
    expect(reveal.first == anchor, "start frame is immediate")
    expect(reveal.last == anchor.addingTimeInterval(SceneOverlayModel.drawDuration), "reveal includes its exact completed frame")
    expect(reveal.count < 32, "one reveal is finite, not an idle 60 Hz loop")
    expect(zip(reveal, reveal.dropFirst()).allSatisfy { $0 < $1 }, "frame dates strictly increase")
    expect(dates(model, from: anchor.addingTimeInterval(1)).count == 1, "settled permanent marks schedule one initial frame only")

    current = anchor.addingTimeInterval(4)
    model.apply(SceneCommand(verb: .rect, id: "late", args: ["from": "500,300", "to": "800,600"]))
    let restarted = dates(model, from: current)
    expect(restarted.count > 20, "a late-added item restarts reveal scheduling")
    expect(restarted.last == current.addingTimeInterval(SceneOverlayModel.drawDuration), "late item reaches its final frame")
    current = anchor.addingTimeInterval(5)
    model.apply(SceneCommand(verb: .highlight, id: "highlight", args: ["from": "100,700", "to": "900,760", "for": "10"]))
    let highlightDates = dates(model, from: current)
    let holdStart = current.addingTimeInterval(SceneOverlayModel.drawDuration)
    let fadeStart = current.addingTimeInterval(10)
    expect(!highlightDates.contains { $0 > holdStart && $0 < fadeStart }, "highlight hold time schedules no repeated frames")
    expect(highlightDates.contains(fadeStart), "future fade wakes at its start")
    expect(highlightDates.last == fadeStart.addingTimeInterval(SceneOverlayModel.fadeDuration), "fade includes its fully transparent final frame")
    expect(!model.isAnimating(at: current.addingTimeInterval(1)), "a held highlight is not animating")
    expect(model.isAnimating(at: fadeStart.addingTimeInterval(0.1)), "a fading highlight is animating")

    current = anchor.addingTimeInterval(6)
    model.remove(id: "late")
    expect(dates(model, from: current).contains(current.addingTimeInterval(SceneOverlayModel.fadeDuration)), "explicit remove schedules its fade end")
    current = anchor.addingTimeInterval(7)
    model.clearAll(animated: true)
    let clearedDates = dates(model, from: current)
    expect(clearedDates.last == current.addingTimeInterval(SceneOverlayModel.fadeDuration), "clear replaces future hold with immediate fade")
    model.clearAll(animated: false)
    expect(dates(model, from: current).count == 1, "empty overlay has no animation ticks")
    expect(Array(SceneOverlayTimelineSchedule(intervals: []).entries(from: current, mode: .normal)) == [current], "frozen view gets only one frame")

    // Overlapping items share a frame schedule instead of multiplying its cadence.
    let intervals = [DateInterval(start: anchor, duration: 0.45), DateInterval(start: anchor.addingTimeInterval(0.2), duration: 0.45)]
    let merged = SceneOverlayTimelineSchedule(intervals: intervals)
    expect(merged.intervals.count == 1, "overlapping animations are merged")
    expect(Array(merged.entries(from: anchor, mode: .normal)).count < 43, "overlap has one 60 Hz cadence")

    let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OVERLAY_TEST_OUTPUT"] ?? NSTemporaryDirectory()).appendingPathComponent("teachy-overlay-idle")
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    current = anchor
    model.apply(ring)
    model.apply(SceneCommand(verb: .label, id: "label", args: ["at": "650,400", "text": "Settled drawing"]))
    let window = SceneOverlayWindow(model: model)
    current = anchor.addingTimeInterval(0.1)
    save(window.snapshot(size: CGSize(width: 640, height: 360)), name: "01-reveal", directory: outputDirectory)
    current = anchor.addingTimeInterval(1)
    save(window.snapshot(size: CGSize(width: 640, height: 360)), name: "02-settled", directory: outputDirectory)
    current = anchor.addingTimeInterval(2)
    model.clearAll(animated: true)
    current = anchor.addingTimeInterval(2.5)
    save(window.snapshot(size: CGSize(width: 640, height: 360)), name: "03-faded", directory: outputDirectory)
    model.clearAll(animated: false)
    print("Rendered snapshots: \(outputDirectory.path)")
    print(failures == 0 ? "ALL OVERLAY IDLE TESTS PASSED" : "\(failures) FAILED")
}
exit(failures == 0 ? 0 : 1)
