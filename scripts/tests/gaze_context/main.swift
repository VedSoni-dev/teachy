// Tests for CompanionGazeContext: gaze samples → grid cells and the question hint.
// Run with scripts/tests/run_touch_gaze_tests.sh (second binary).
import AppKit
import Foundation

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL (line \(line)): \(message)") }
}

/// A 1512×982 pt display at the origin, captured at 2×, plus a second display to its right.
func capture(frame: CGRect, isCursorScreen: Bool) -> CompanionScreenCapture {
    CompanionScreenCapture(
        imageData: Data(), label: "screen", isCursorScreen: isCursorScreen,
        displayWidthInPoints: Int(frame.width), displayHeightInPoints: Int(frame.height), displayFrame: frame,
        screenshotWidthInPixels: Int(frame.width) * 2, screenshotHeightInPixels: Int(frame.height) * 2
    )
}
let mainScreen = capture(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isCursorScreen: true)
let sideScreen = capture(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), isCursorScreen: false)

func dwell(at point: CGPoint, from start: Double, seconds: Double) -> [GazeSample] {
    stride(from: start, to: start + seconds, by: 1.0 / 30).map { GazeSample(time: $0, pointInGlobalCoordinates: point) }
}

// Top-left area of the main screen: AppKit y is measured from the bottom, so y = 982 - 40.
let topLeftLook = dwell(at: CGPoint(x: 40, y: 942), from: 0, seconds: 1.2)
let context = CompanionGazeContext.build(gazeSamples: topLeftLook, screenCaptures: [mainScreen, sideScreen])
expect(context?.screenCaptureIndex == 0, "gaze lands on the main screen")
expect(context?.centerCellLabel == "A1", "top-left corner is cell A1: \(context?.centerCellLabel ?? "nil")")
expect(context.map { Set($0.gazeRegionCellLabels) == ["A1", "A2", "B1", "B2"] } == true,
       "region is padded by one cell and clipped at the edge: \(context?.gazeRegionCellLabels ?? [])")
expect(context.map { abs($0.dwellInSeconds - 1.17) < 0.1 } == true, "dwell measured: \(context?.dwellInSeconds ?? 0)")
expect(context?.questionHint.contains("A1") == true && context?.questionHint.contains("approximate") == true, "hint names the cell and says it is approximate")

let middle = dwell(at: CGPoint(x: 756, y: 491), from: 0, seconds: 0.8)
let middleContext = CompanionGazeContext.build(gazeSamples: middle, screenCaptures: [mainScreen])
expect(middleContext?.centerCellLabel == "M9", "screen centre is M9: \(middleContext?.centerCellLabel ?? "nil")")
expect(middleContext?.gazeRegionCellLabels.count == 9, "a 3×3 region in the middle")

let sideLook = dwell(at: CGPoint(x: 1512 + 1900, y: 20), from: 0, seconds: 1.0)
let sideContext = CompanionGazeContext.build(gazeSamples: sideLook, screenCaptures: [mainScreen, sideScreen])
expect(sideContext?.screenCaptureIndex == 1, "gaze on the second display uses that display's screenshot")
expect(sideContext?.centerCellLabel == "X16", "its bottom-right corner is X16: \(sideContext?.centerCellLabel ?? "nil")")

let comparing = dwell(at: CGPoint(x: 200, y: 700), from: 0, seconds: 1.0) + dwell(at: CGPoint(x: 1300, y: 200), from: 1.1, seconds: 0.6)
let comparingContext = CompanionGazeContext.build(gazeSamples: comparing, screenCaptures: [mainScreen])
expect(comparingContext?.secondaryCellLabel != nil, "a second place looked at is mentioned")
expect(comparingContext?.questionHint.contains("also at") == true, "hint mentions both places")

expect(CompanionGazeContext.build(gazeSamples: dwell(at: CGPoint(x: 400, y: 400), from: 0, seconds: 0.1), screenCaptures: [mainScreen]) == nil,
       "a glance too short to mean anything adds nothing")
expect(CompanionGazeContext.build(gazeSamples: [], screenCaptures: [mainScreen]) == nil, "no gaze, no context")
expect(CompanionGazeContext.build(gazeSamples: dwell(at: CGPoint(x: -500, y: 400), from: 0, seconds: 1), screenCaptures: [mainScreen]) == nil,
       "looking off every screen adds nothing")

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASSED")
