import AppKit
import Foundation

@MainActor
private func fixture() -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 900,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    let cg = context.cgContext
    cg.translateBy(x: 0, y: 900)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1440, height: 900)).fill()
    for (text, point) in [
        ("Microphone", CGPoint(x: 288, y: 355)),
        ("Avery Chen", CGPoint(x: 750, y: 366)),
        ("General", CGPoint(x: 288, y: 215)),
        ("Morgan Lee", CGPoint(x: 750, y: 280))
    ] {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black
        ]).draw(at: point)
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

@main
enum AnnotationTextTests {
    static func main() async {
        let data = await fixture()
        var checks = 0
        for (question, target, xRange, yRange) in [
            ("Circle the Microphone name in Teachy's settings sidebar.", "Microphone", 225...250, 393...425),
            ("Circle the name Avery Chen in the document list.", "Avery Chen", 530...590, 400...445)
        ] {
            let context = await SceneAnnotationText.context(imageData: data, question: question)
            precondition(context.count <= 6000, "context budget")
            checks += 1
            let rows = context.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            precondition(rows.count <= 80, "record budget")
            checks += 1
            guard let match = rows.first(where: { ($0["text"] as? String)?.localizedCaseInsensitiveContains(target) == true }),
                  let center = match["center"] as? [Int], let box = match["box"] as? [Int] else {
                fatalError("Missing synthetic OCR match for \(target)")
            }
            precondition(center.count == 2 && xRange.contains(center[0]) && yRange.contains(center[1]), "Wrong normalized center: \(center)")
            checks += 1
            precondition(box.count == 4 && box[0] < center[0] && center[0] < box[2] && box[1] < center[1] && center[1] < box[3], "Bounds must contain center")
            checks += 1
        }
        let empty = await SceneAnnotationText.context(imageData: Data(), question: "circle the name")
        precondition(empty.isEmpty)
        checks += 1
        let invalid = await SceneAnnotationText.context(imageData: Data("not an image".utf8), question: "circle the name")
        precondition(invalid.isEmpty)
        checks += 1
        let irrelevant = await SceneAnnotationText.context(imageData: data, question: "circle Quetzalcoatl")
        precondition(irrelevant.isEmpty)
        checks += 1
        print("\(checks) annotation OCR checks passed.")
    }
}
