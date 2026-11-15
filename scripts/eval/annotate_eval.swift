//
//  annotate_eval.swift
//
//  Checks "draw on the real screen": does the model put its mark on the right thing?
//
//  Ten made-up screenshots are drawn in-process (a code editor, a geometry diagram, a
//  toolbar, a spreadsheet…), each with a question and the rectangle the answer must land
//  in. Each screenshot goes to the model exactly as the app sends it (TeachyAIRouter, job
//  .scene, with the image, SceneScriptPrompt.annotateRequestBody). The first shape in the
//  reply is the answer; it scores a hit when the spot it points at (an arrow's tip, else the
//  shape's middle) is inside the target rectangle.
//
//  Run with scripts/eval/run_annotate_eval.sh. One model call per screenshot.
//  Every screenshot is saved twice in the output folder: plain, and with the model's
//  marks drawn on it and the target outlined in green.
//

import AppKit
import SwiftUI
import simd

// MARK: - Drawing screenshots

/// A bitmap addressed like a screen: origin top left, y down, in pixels.
final class Shot {
    let width: Int
    let height: Int
    private let bitmap: NSBitmapImageRep
    private let context: NSGraphicsContext

    init(width: Int, height: Int, background: NSColor) {
        self.width = width
        self.height = height
        bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        context = NSGraphicsContext(bitmapImageRep: bitmap)!
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        fill(CGRect(x: 0, y: 0, width: width, height: height), background)
    }

    private func draw(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        draw {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    func stroke(_ rect: CGRect, _ color: NSColor, width: CGFloat = 1, radius: CGFloat = 0) {
        draw {
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = width
            path.stroke()
        }
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor, width: CGFloat = 1) {
        draw {
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    func ellipse(_ rect: CGRect, _ color: NSColor) {
        draw {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Draws text with its top-left corner at `at`. Returns the rectangle it covers.
    @discardableResult
    func text(_ string: String, at: CGPoint, size: CGFloat = 14, color: NSColor = .black, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGRect {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let measured = attributed.size()
        draw { attributed.draw(at: at) }
        return CGRect(origin: at, size: measured)
    }

    /// A window with a title bar. Returns its content rectangle.
    func window(_ frame: CGRect, title: String, dark: Bool = false) -> CGRect {
        fill(frame.offsetBy(dx: 0, dy: 6).insetBy(dx: -4, dy: -4), NSColor.black.withAlphaComponent(0.18), radius: 14)
        fill(frame, dark ? NSColor(white: 0.13, alpha: 1) : .white, radius: 10)
        let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 30)
        fill(bar, dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.92, alpha: 1), radius: 10)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ellipse(CGRect(x: frame.minX + 12 + CGFloat(index) * 20, y: frame.minY + 9, width: 12, height: 12), color)
        }
        text(title, at: CGPoint(x: frame.midX - CGFloat(title.count) * 3.6, y: frame.minY + 7), size: 13, color: dark ? .white : NSColor(white: 0.25, alpha: 1), weight: .medium)
        return CGRect(x: frame.minX, y: frame.minY + 30, width: frame.width, height: frame.height - 30)
    }

    var image: NSImage {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    var jpeg: Data { bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) ?? Data() }
    var png: Data { bitmap.representation(using: .png, properties: [:]) ?? Data() }
}

struct AnnotateCase {
    let name: String
    let question: String
    let shot: Shot
    /// Where the answer must land, in screenshot pixels (origin top left).
    let target: CGRect
}

@MainActor
enum AnnotateCases {
    static let desktop = NSColor(srgbRed: 0.36, green: 0.52, blue: 0.70, alpha: 1)

    static func all() -> [AnnotateCase] {
        [code(), triangle(), toolbar(), spreadsheet(), login(), chart(), settings(), terminal(), browser(), calendar()]
    }

    static func code() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 180, y: 90, width: 980, height: 640), title: "math_utils.py", dark: true)
        let lines = ["def add(a, b):", "    \"\"\"Return the sum of a and b.\"\"\"", "    return a - b", "", "def multiply(a, b):", "    \"\"\"Return the product of a and b.\"\"\"", "    return a * b", "",
                     "def average(values):", "    total = 0", "    for value in values:", "        total = add(total, value)", "    return total / len(values)"]
        var target = CGRect.zero
        for (index, line) in lines.enumerated() {
            let y = content.minY + 24 + CGFloat(index) * 30
            shot.text("\(index + 1)", at: CGPoint(x: content.minX + 18, y: y), size: 17, color: NSColor(white: 0.45, alpha: 1), mono: true)
            let rect = shot.text(line, at: CGPoint(x: content.minX + 62, y: y), size: 17, color: NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1), mono: true)
            if index == 2 { target = CGRect(x: content.minX + 62, y: rect.minY - 4, width: rect.width, height: rect.height + 8) }
        }
        return AnnotateCase(name: "code", question: "circle the bug in this code", shot: shot, target: target.insetBy(dx: -12, dy: -4))
    }

    static func triangle() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 240, y: 70, width: 900, height: 700), title: "Right triangles — lesson 3")
        shot.text("The Pythagorean theorem", at: CGPoint(x: content.minX + 40, y: content.minY + 30), size: 26, weight: .semibold)
        let a = CGPoint(x: content.minX + 220, y: content.minY + 520), b = CGPoint(x: content.minX + 640, y: content.minY + 520), c = CGPoint(x: content.minX + 220, y: content.minY + 180)
        shot.line(a, b, .black, width: 4)
        shot.line(a, c, .black, width: 4)
        shot.line(c, b, .black, width: 4)
        shot.stroke(CGRect(x: a.x, y: a.y - 28, width: 28, height: 28), .black, width: 2)
        shot.text("a = 3", at: CGPoint(x: a.x - 90, y: (a.y + c.y) / 2 - 12), size: 22)
        shot.text("b = 4", at: CGPoint(x: (a.x + b.x) / 2 - 30, y: a.y + 18), size: 22)
        // The answer must land on the sloping side: a band round its middle.
        let middle = CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2)
        return AnnotateCase(name: "triangle", question: "show me where the hypotenuse is on this diagram", shot: shot,
                            target: CGRect(x: middle.x - 150, y: middle.y - 120, width: 300, height: 240))
    }

    static func toolbar() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 120, y: 60, width: 1200, height: 760), title: "Quarterly report — Pages")
        shot.fill(CGRect(x: content.minX, y: content.minY, width: content.width, height: 52), NSColor(white: 0.96, alpha: 1))
        var target = CGRect.zero
        for (index, title) in ["New", "Open", "Save", "Print", "Export", "Share", "Comment"].enumerated() {
            let rect = CGRect(x: content.minX + 20 + CGFloat(index) * 104, y: content.minY + 10, width: 92, height: 32)
            shot.fill(rect, .white, radius: 6)
            shot.stroke(rect, NSColor(white: 0.78, alpha: 1), radius: 6)
            shot.text(title, at: CGPoint(x: rect.midX - CGFloat(title.count) * 4.2, y: rect.minY + 7), size: 14)
            if title == "Export" { target = rect }
        }
        for row in 0..<14 {
            shot.fill(CGRect(x: content.minX + 160, y: content.minY + 110 + CGFloat(row) * 38, width: row % 4 == 3 ? 520 : 880, height: 12), NSColor(white: 0.86, alpha: 1), radius: 6)
        }
        return AnnotateCase(name: "toolbar", question: "which button do I press to save this as a PDF?", shot: shot, target: target)
    }

    static func spreadsheet() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 160, y: 80, width: 1100, height: 700), title: "Sales 2026.xlsx")
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug"], values = [4120, 3980, 5210, 4870, 9640, 5020, 4410, 4760]
        var target = CGRect.zero
        for (column, header) in ["", "A", "B", "C", "D"].enumerated() {
            let x = content.minX + CGFloat(column) * 180
            shot.fill(CGRect(x: x, y: content.minY, width: 180, height: 34), NSColor(white: 0.93, alpha: 1))
            shot.stroke(CGRect(x: x, y: content.minY, width: 180, height: 34), NSColor(white: 0.8, alpha: 1))
            shot.text(header, at: CGPoint(x: x + 84, y: content.minY + 8), size: 14, weight: .medium)
        }
        for row in 0...months.count {
            let y = content.minY + 34 + CGFloat(row) * 40
            for column in 0..<5 {
                let cell = CGRect(x: content.minX + CGFloat(column) * 180, y: y, width: 180, height: 40)
                shot.stroke(cell, NSColor(white: 0.84, alpha: 1))
                var value = ""
                if column == 0 { value = "\(row + 1)" } else if row == 0 { value = ["", "Month", "Revenue", "Units", "Returns"][column] }
                else if column == 1 { value = months[row - 1] } else if column == 2 { value = "$\(values[row - 1])" }
                else if column == 3 { value = "\(values[row - 1] / 37)" } else { value = "\(values[row - 1] / 410)" }
                shot.text(value, at: CGPoint(x: cell.minX + 14, y: cell.minY + 10), size: 15, weight: row == 0 ? .semibold : .regular)
                if column == 2, row == 5 { target = cell }
            }
        }
        return AnnotateCase(name: "sheet", question: "circle the month with the highest revenue", shot: shot,
                            target: CGRect(x: target.minX - 180, y: target.minY, width: 360, height: target.height))
    }

    static func login() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: NSColor(white: 0.95, alpha: 1))
        let card = CGRect(x: 500, y: 160, width: 440, height: 520)
        shot.fill(card, .white, radius: 16)
        shot.stroke(card, NSColor(white: 0.85, alpha: 1), radius: 16)
        shot.text("Sign in to Northwind", at: CGPoint(x: card.minX + 40, y: card.minY + 44), size: 26, weight: .semibold)
        for (index, field) in ["Email", "Password"].enumerated() {
            let y = card.minY + 130 + CGFloat(index) * 96
            shot.text(field, at: CGPoint(x: card.minX + 40, y: y), size: 14, color: NSColor(white: 0.35, alpha: 1))
            shot.stroke(CGRect(x: card.minX + 40, y: y + 24, width: 360, height: 44), NSColor(white: 0.75, alpha: 1), radius: 8)
        }
        let button = CGRect(x: card.minX + 40, y: card.minY + 340, width: 360, height: 48)
        shot.fill(button, NSColor.systemBlue, radius: 8)
        shot.text("Sign in", at: CGPoint(x: button.midX - 28, y: button.minY + 13), size: 17, color: .white, weight: .semibold)
        let link = shot.text("Forgot your password?", at: CGPoint(x: card.minX + 40, y: card.minY + 412), size: 15, color: NSColor.systemBlue)
        shot.text("New here? Create an account", at: CGPoint(x: card.minX + 40, y: card.minY + 452), size: 15, color: NSColor(white: 0.4, alpha: 1))
        return AnnotateCase(name: "login", question: "I forgot my password, where do I click?", shot: shot, target: link.insetBy(dx: -14, dy: -10))
    }

    static func chart() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 220, y: 90, width: 1000, height: 680), title: "Dashboard")
        shot.text("Orders this week", at: CGPoint(x: content.minX + 50, y: content.minY + 30), size: 24, weight: .semibold)
        let base = content.minY + 560
        shot.line(CGPoint(x: content.minX + 80, y: base), CGPoint(x: content.minX + 920, y: base), NSColor(white: 0.5, alpha: 1), width: 2)
        var target = CGRect.zero
        for (index, pair) in [("Mon", 180), ("Tue", 240), ("Wed", 150), ("Thu", 410), ("Fri", 290), ("Sat", 120)].enumerated() {
            let bar = CGRect(x: content.minX + 120 + CGFloat(index) * 135, y: base - CGFloat(pair.1), width: 84, height: CGFloat(pair.1))
            shot.fill(bar, NSColor(srgbRed: 0.30, green: 0.56, blue: 0.93, alpha: 1), radius: 4)
            shot.text(pair.0, at: CGPoint(x: bar.midX - 16, y: base + 12), size: 16)
            if pair.0 == "Thu" { target = bar }
        }
        return AnnotateCase(name: "chart", question: "which day had the most orders? mark it", shot: shot, target: target.insetBy(dx: -20, dy: -40))
    }

    static func settings() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 330, y: 110, width: 780, height: 620), title: "Settings")
        var target = CGRect.zero
        for (index, pair) in [("Wi-Fi", true), ("Bluetooth", true), ("Dark mode", false), ("Notifications", true), ("Location services", false), ("Automatic updates", true)].enumerated() {
            let row = CGRect(x: content.minX + 40, y: content.minY + 40 + CGFloat(index) * 84, width: 700, height: 64)
            shot.fill(row, NSColor(white: 0.97, alpha: 1), radius: 10)
            shot.text(pair.0, at: CGPoint(x: row.minX + 24, y: row.minY + 20), size: 18)
            let toggle = CGRect(x: row.maxX - 84, y: row.minY + 17, width: 56, height: 30)
            shot.fill(toggle, pair.1 ? .systemGreen : NSColor(white: 0.78, alpha: 1), radius: 15)
            shot.ellipse(CGRect(x: pair.1 ? toggle.maxX - 28 : toggle.minX + 2, y: toggle.minY + 2, width: 26, height: 26), .white)
            if pair.0 == "Dark mode" { target = row }
        }
        return AnnotateCase(name: "settings", question: "where do I turn on dark mode?", shot: shot, target: target)
    }

    static func terminal() -> AnnotateCase {
        let shot = Shot(width: 1440, height: 900, background: desktop)
        let content = shot.window(CGRect(x: 200, y: 120, width: 1040, height: 560), title: "zsh — project", dark: true)
        let lines = ["$ python3 app.py", "Loading configuration from config.yaml", "Connecting to database... ok", "Starting worker pool (4 workers)",
                     "ModuleNotFoundError: No module named 'requests'", "$ git status", "On branch main", "nothing to commit, working tree clean", "$ "]
        var target = CGRect.zero
        for (index, line) in lines.enumerated() {
            let isError = line.hasPrefix("ModuleNotFoundError")
            let rect = shot.text(line, at: CGPoint(x: content.minX + 24, y: content.minY + 22 + CGFloat(index) * 32), size: 17,
                                 color: isError ? NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1) : NSColor(white: 0.86, alpha: 1), mono: true)
            if isError { target = rect }
        }
        return AnnotateCase(name: "terminal", question: "what went wrong here? show me the line", shot: shot, target: target.insetBy(dx: -14, dy: -8))
    }

    static func browser() -> AnnotateCase {
        // A larger display, to check coordinates don't depend on the screenshot's pixel size.
        let shot = Shot(width: 1920, height: 1080, background: desktop)
        let content = shot.window(CGRect(x: 160, y: 70, width: 1600, height: 920), title: "Recipes — Safari")
        shot.fill(CGRect(x: content.minX, y: content.minY, width: content.width, height: 48), NSColor(white: 0.95, alpha: 1))
        shot.fill(CGRect(x: content.minX + 380, y: content.minY + 8, width: 840, height: 32), .white, radius: 8)
        shot.text("simplerecipes.example/dinner", at: CGPoint(x: content.minX + 400, y: content.minY + 14), size: 15, color: NSColor(white: 0.4, alpha: 1))
        shot.text("Simple Recipes", at: CGPoint(x: content.minX + 60, y: content.minY + 90), size: 34, weight: .bold)
        for (index, item) in ["Home", "Dinner", "Dessert", "About"].enumerated() {
            shot.text(item, at: CGPoint(x: content.minX + 60 + CGFloat(index) * 110, y: content.minY + 150), size: 17, color: NSColor.systemBlue)
        }
        let search = CGRect(x: content.maxX - 420, y: content.minY + 92, width: 340, height: 40)
        shot.stroke(search, NSColor(white: 0.6, alpha: 1), width: 1.5, radius: 20)
        shot.text("Search recipes…", at: CGPoint(x: search.minX + 20, y: search.minY + 10), size: 16, color: NSColor(white: 0.55, alpha: 1))
        for row in 0..<3 {
            for column in 0..<4 {
                let tile = CGRect(x: content.minX + 60 + CGFloat(column) * 380, y: content.minY + 210 + CGFloat(row) * 220, width: 340, height: 190)
                shot.fill(tile, NSColor(srgbRed: 0.93, green: 0.88 - CGFloat(row) * 0.05, blue: 0.80 - CGFloat(column) * 0.04, alpha: 1), radius: 12)
            }
        }
        return AnnotateCase(name: "browser", question: "where can I search on this page?", shot: shot, target: search.insetBy(dx: -10, dy: -10))
    }

    static func calendar() -> AnnotateCase {
        // A smaller display with a different shape.
        let shot = Shot(width: 1280, height: 800, background: desktop)
        let content = shot.window(CGRect(x: 190, y: 60, width: 900, height: 680), title: "Calendar — November 2026")
        var target = CGRect.zero
        for (index, day) in ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].enumerated() {
            shot.text(day, at: CGPoint(x: content.minX + 40 + CGFloat(index) * 120, y: content.minY + 18), size: 15, color: NSColor(white: 0.4, alpha: 1), weight: .medium)
        }
        for date in 1...30 {
            let slot = date - 1
            let cell = CGRect(x: content.minX + 20 + CGFloat(slot % 7) * 120, y: content.minY + 54 + CGFloat(slot / 7) * 116, width: 116, height: 110)
            shot.stroke(cell, NSColor(white: 0.85, alpha: 1))
            shot.text("\(date)", at: CGPoint(x: cell.minX + 10, y: cell.minY + 8), size: 17)
            if date == 19 {
                shot.fill(CGRect(x: cell.minX + 8, y: cell.minY + 44, width: 100, height: 24), NSColor.systemOrange, radius: 5)
                shot.text("Dentist 3pm", at: CGPoint(x: cell.minX + 14, y: cell.minY + 48), size: 12, color: .white, weight: .medium)
                target = cell
            }
            if date == 6 {
                shot.fill(CGRect(x: cell.minX + 8, y: cell.minY + 44, width: 100, height: 24), NSColor.systemTeal, radius: 5)
                shot.text("Team lunch", at: CGPoint(x: cell.minX + 14, y: cell.minY + 48), size: 12, color: .white, weight: .medium)
            }
        }
        return AnnotateCase(name: "calendar", question: "when is my dentist appointment? circle it", shot: shot, target: target)
    }
}

// MARK: - Running

struct AnnotateResult {
    var name: String
    var hit = false
    var anyHit = false
    var shapes = 0
    var onlyOverlay = true
    var says = 0
    var firstCommand: Double?
    var total = 0.0
    var focus: SceneVec2?
    var note = ""
}

@main
@MainActor
enum AnnotateEval {
    static func main() async {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let only = value("--only")
        let folder = URL(fileURLWithPath: value("--out") ?? NSTemporaryDirectory() + "annotate-eval", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cases = AnnotateCases.all().filter { only == nil || only == $0.name }
        for testCase in cases { try? testCase.shot.png.write(to: folder.appendingPathComponent("\(testCase.name).png")) }
        if arguments.contains("--draw-only") {
            print("drew \(cases.count) screenshots in \(folder.path)")
            return
        }
        guard TeachyAIRouter.isReadyForAI else {
            print("Teachy isn't signed in to publik on this Mac, so there is no model to ask.")
            exit(2)
        }

        var results: [AnnotateResult] = []
        for testCase in cases {
            let result = await run(testCase, folder: folder)
            results.append(result)
            print(row(result))
        }
        print("\ncase       hit  any  shapes  says  first cmd   total  note")
        for result in results { print(row(result)) }
        let hits = results.filter(\.hit).count, any = results.filter(\.anyHit).count
        let firsts = results.compactMap(\.firstCommand).sorted()
        print(String(format: "\nhit rate %d/%d (%.0f%%)   any shape on target %d/%d   only-overlay replies %d/%d   median first mark %.1f s   pictures in %@",
                     hits, results.count, results.isEmpty ? 0 : Double(hits) / Double(results.count) * 100, any, results.count,
                     results.filter(\.onlyOverlay).count, results.count, firsts.isEmpty ? .nan : firsts[firsts.count / 2], folder.path))
    }

    static func row(_ r: AnnotateResult) -> String {
        r.name.padding(toLength: 10, withPad: " ", startingAt: 0)
            + String(format: " %@   %@   %5d  %4d  %@  %5.1f s  %@", r.hit ? "yes" : "NO ", r.anyHit ? "yes" : "no ", r.shapes, r.says,
                     r.firstCommand.map { String(format: "%6.1f s", $0) } ?? "     –  ", r.total, r.note)
    }

    static func run(_ testCase: AnnotateCase, folder: URL) async -> AnnotateResult {
        var result = AnnotateResult(name: testCase.name)
        let body = SceneScriptPrompt.annotateRequestBody(question: testCase.question, screenshotJPEG: testCase.shot.jpeg)
        let started = Date()
        var text = ""
        let parser = SceneScriptParser()
        var commands: [SceneCommand] = []
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 40
            let session = URLSession(configuration: configuration)
            let bytes = try await TeachyAIRouter.openStream(job: .scene, hasImages: true, timeout: 40, session: session, body: body)
            for try await line in StreamIdleGuard.lines(from: bytes, firstByteTimeout: 40, idleTimeout: 4) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                if let delta = (choice["delta"] as? [String: Any])?["content"] as? String, !delta.isEmpty {
                    text += delta
                    let fresh = parser.feed(delta)
                    if result.firstCommand == nil, fresh.contains(where: { $0.verb != .say }) { result.firstCommand = Date().timeIntervalSince(started) }
                    commands += fresh
                }
                if choice["finish_reason"] is String { break }
            }
            session.invalidateAndCancel()
        } catch {
            result.note = "error: \(error.localizedDescription.prefix(50))"
        }
        commands += parser.finish()
        result.total = Date().timeIntervalSince(started)
        // A short reply can arrive in one piece with no newline at the end: its mark only parses here.
        if result.firstCommand == nil, commands.contains(where: { $0.verb != .say }) { result.firstCommand = result.total }
        try? text.write(to: folder.appendingPathComponent("\(testCase.name).txt"), atomically: true, encoding: .utf8)

        let size = CGSize(width: testCase.shot.width, height: testCase.shot.height)
        let low = SceneScreenMapping.normalized(pixel: CGPoint(x: testCase.target.minX, y: testCase.target.minY), screenshotSize: size)
        let high = SceneScreenMapping.normalized(pixel: CGPoint(x: testCase.target.maxX, y: testCase.target.maxY), screenshotSize: size)
        func inside(_ point: SceneVec2) -> Bool { point.x >= low.x && point.x <= high.x && point.y >= low.y && point.y <= high.y }

        result.says = commands.filter { $0.verb == .say }.count
        result.onlyOverlay = commands.allSatisfy { $0.verb.family == .overlay || $0.verb.family == .control }
        let marks = commands.filter { $0.verb.family == .overlay }
        let shapes = marks.filter { $0.verb != .label }
        result.shapes = shapes.count
        // The first shape is the answer; a reply with only pills is judged by its first pill.
        if let first = shapes.first ?? marks.first, let focus = SceneScreenMapping.focus(of: first) {
            result.focus = focus
            result.hit = inside(focus)
            if !result.hit { result.note += String(format: "pointed at %.0f,%.0f; target %.0f-%.0f, %.0f-%.0f", focus.x, focus.y, low.x, high.x, low.y, high.y) }
        } else if result.note.isEmpty {
            result.note = "no mark"
        }
        result.anyHit = shapes.contains { SceneScreenMapping.focus(of: $0).map(inside) ?? false }
        savePicture(testCase, marks: marks, to: folder.appendingPathComponent("\(testCase.name)-marked.png"))
        return result
    }

    /// The screenshot with the model's marks drawn by the real overlay renderer, and the target in green.
    static func savePicture(_ testCase: AnnotateCase, marks: [SceneCommand], to url: URL) {
        let model = SceneOverlayModel()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        model.clock = { start }
        for mark in marks { model.apply(mark) }
        let size = CGSize(width: testCase.shot.width, height: testCase.shot.height)
        let view = ZStack(alignment: .topLeading) {
            Image(nsImage: testCase.shot.image).resizable().frame(width: size.width, height: size.height)
            Rectangle().stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .frame(width: testCase.target.width, height: testCase.target.height)
                .offset(x: testCase.target.minX, y: testCase.target.minY)
            // One second in: every stroke has drawn itself and nothing has started to fade.
            SceneOverlayView(model: model, frozenAt: start.addingTimeInterval(1)).frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let tiff = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
