import Foundation
var checks = 0
var failures = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
check(ScreenAnnotationRequest("circle Alex").captureIndex(count: 2, cursorIndex: 1) == 1, "legacy tags prefer the captured cursor display")
check(ScreenAnnotationRequest("circle Alex").captureIndex(count: 2, cursorIndex: nil) == 0, "legacy tags can use first display")
let explicit = ScreenAnnotationRequest("screen=2 | circle the name Alex in Teachy's chat")
check(explicit.captureIndex(count: 3, cursorIndex: 0) == 1, "explicit display wins over cursor display")
check(explicit.instruction == "circle the name Alex in Teachy's chat", "instruction and exact name survive selection")
check(ScreenAnnotationRequest(" SCREEN=1 | underline Kernel ").captureIndex(count: 1, cursorIndex: nil) == 0, "whitespace and case accepted")
for invalid in ["", "screen=0 | circle Alex", "screen=-1 | circle Alex", "screen=two | circle Alex", "screen=2", "screen=2 | ", "screen=999999999999999999999 | circle Alex"] {
    check(ScreenAnnotationRequest(invalid).captureIndex(count: 2, cursorIndex: 0) == nil, "invalid explicit selection never marks another screen: \(invalid)")
}
check(explicit.captureIndex(count: 1, cursorIndex: 0) == nil, "disconnected display does not fall back to cursor")
check(explicit.captureIndex(count: 0, cursorIndex: nil) == nil, "no display yields no mark")
check(ScreenAnnotationCapturePolicy.includesOwnWindow(ignoresMouseEvents: false, isPrivate: false), "interactive Teachy content is visible")
check(!ScreenAnnotationCapturePolicy.includesOwnWindow(ignoresMouseEvents: true, isPrivate: false), "click-through drawing and pointer overlays are excluded")
check(!ScreenAnnotationCapturePolicy.includesOwnWindow(ignoresMouseEvents: false, isPrivate: true), "private camera preview is excluded")
check(!ScreenAnnotationCapturePolicy.includesOwnWindow(ignoresMouseEvents: true, isPrivate: true), "private overlays are excluded")
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
