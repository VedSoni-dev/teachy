// redact_image: the pure rules plus one real run on a synthetic image (no user files).
import AppKit
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// Rules
let parsed = ImageRedactionRules.request(from: ["faces": true, "text_matching": ["Acme", " "], "regions": [[0.1, 0.1, 0.2, 0.2], [2, 2, 1, 1], [0, 0]], "style": "PIXELATE"])
check(parsed.coverFaces && parsed.textMatches == ["Acme"], "reads faces and text words")
check(parsed.givenRegions.count == 1, "drops boxes outside the image and malformed boxes")
check(parsed.style == .pixelate, "reads the style")
check(!ImageRedactionRules.request(from: [:]).asksForAnything, "nothing asked → nothing to do")

let bigFace = ImageRedactionRules.Region(rectInImageFractions: CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.4), kind: .face)
let smallFace = ImageRedactionRules.Region(rectInImageFractions: CGRect(x: 0.05, y: 0.1, width: 0.1, height: 0.1), kind: .face)
let clientLine = ImageRedactionRules.Region(rectInImageFractions: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.05), kind: .text("Deal signed with ACME Corp"))
let otherLine = ImageRedactionRules.Region(rectInImageFractions: CGRect(x: 0.1, y: 0.9, width: 0.4, height: 0.05), kind: .text("Thursday"))
var keepMine = ImageRedactionRules.Request()
keepMine.coverFaces = true
keepMine.keepLargestFace = true
keepMine.textMatches = ["acme"]
let chosen = ImageRedactionRules.regionsToCover(found: [bigFace, smallFace, clientLine, otherLine], request: keepMine)
check(chosen.count == 2, "keeps the largest face and unmatched text clear")
check(chosen.allSatisfy { $0.rectInImageFractions.width > 0 }, "padded boxes stay inside the image")
check(ImageRedactionRules.topLeftRect(fromVisionRect: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)).minY.distance(to: 0.1) < 0.0001, "Vision boxes flip to a top-left origin")
check(ImageRedactionRules.outputFileName(forInputName: "shot.jpg", existingNames: ["shot-redacted.png"]) == "shot-redacted-2.png", "never overwrites an earlier output")
let circle = (0..<12).map { CGPoint(x: 400 + 100 * cos(Double($0) / 2), y: 300 + 80 * sin(Double($0) / 2)) }
let circled = JobRequestScreenshotFiles.circledAreaPixelRect(outlinePoints: circle, screenshotWidth: 1000, screenshotHeight: 800)
check(circled != nil && circled!.minX < 310 && circled!.maxX > 490, "circled area box covers the circle")
check(JobRequestScreenshotFiles.circledAreaPixelRect(outlinePoints: [.zero, .zero, .zero], screenshotWidth: 100, screenshotHeight: 100) == nil, "a dot is not a circle")

// One real run on a synthetic image (given regions always work, even without Vision)
var regionRequest = ImageRedactionRules.Request()
regionRequest.givenRegions = [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)]
let workDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let imageURL = workDirectory.appendingPathComponent("synthetic.png")
let size = NSSize(width: 900, height: 400)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.black]
("Signed with Northwind Traders" as NSString).draw(at: NSPoint(x: 40, y: 260), withAttributes: attributes)
("See you on Thursday" as NSString).draw(at: NSPoint(x: 40, y: 100), withAttributes: attributes)
image.unlockFocus()
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: imageURL)

var textRequest = ImageRedactionRules.Request()
textRequest.textMatches = ["northwind"]
do {
    let outcome = try ImageRedactor.redact(imageAt: imageURL, request: textRequest)
    if outcome.detectionFailures.isEmpty {
        check(outcome.foundTextLineCount >= 2, "Vision reads both lines")
        check(outcome.coveredRegions.count == 1, "covers only the matching line")
    } else {
        print("note Vision text recognition is unavailable on this Mac (\(outcome.detectionFailures)); skipping the OCR checks")
    }
    check(FileManager.default.fileExists(atPath: outcome.outputURL.path), "writes the redacted copy")
    check(try Data(contentsOf: imageURL) == png, "the original is unchanged")
    try? FileManager.default.removeItem(at: outcome.outputURL)
} catch {
    check(false, "redaction ran: \(error)")
}

do {
    let outcome = try ImageRedactor.redact(imageAt: imageURL, request: regionRequest)
    check(outcome.coveredRegions.count == 1 && FileManager.default.fileExists(atPath: outcome.outputURL.path), "covers a given region")
    let original = NSBitmapImageRep(data: png)!
    let redacted = NSBitmapImageRep(data: outcome.pngData)!
    check(redacted.pixelsWide == original.pixelsWide && redacted.pixelsHigh == original.pixelsHigh, "keeps the image size")
    try? FileManager.default.removeItem(at: outcome.outputURL)
} catch {
    check(false, "region redaction ran: \(error)")
}

print(failures == 0 ? "All redaction checks passed." : "\(failures) redaction check(s) failed.")
exit(failures == 0 ? 0 : 1)
