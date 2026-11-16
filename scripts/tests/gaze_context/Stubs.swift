// The one type CompanionGazeContext needs from the capture utility, copied so the test needs no ScreenCaptureKit.
import CoreGraphics
import Foundation

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}
