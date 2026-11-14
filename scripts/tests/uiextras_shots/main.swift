// Run: scripts/tests/render_uiextras_shots.sh
// Renders the settings cards, caption bar, text box and paint trail to PNG files
// without launching Teachy, and checks the text box's key handling in-process.
// Nothing is put on screen. Output: $TMPDIR/uiextras-shots/
import AppKit
import SwiftUI

// MARK: - Stand-ins for app types the real files refer to

/// Same drawing as NotchPanelSharedComponents.swift (that file pulls in the model picker).
struct KeyboardKeyLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
    }
}

enum ClickyCursorColor: String, CaseIterable, Identifiable {
    case red, blue, yellow, green
    var id: String { rawValue }
    var displayColor: Color {
        switch self {
        case .red: return Color(hex: "#FF4D4D")
        case .blue: return Color(hex: "#3380FF")
        case .yellow: return Color(hex: "#FFD60A")
        case .green: return Color(hex: "#30D158")
        }
    }
}

/// No keychain access from a script.
enum TeachyElevenLabsKeyStore {
    static var apiKey: String?
    static var isConfigured: Bool { apiKey != nil }
    static let voiceID = "preview"
}

extension VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer { _, _, _ in Data() }
}

// MARK: - Rendering

@MainActor
func runShots() {

    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uiextras-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    func writePNG(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("FAIL no bitmap for \(name)"); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
    }

    /// Hosts a SwiftUI view at a fixed width in a window that is never shown.
    func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let fitting = hosting.fittingSize
        let size = NSSize(width: width, height: height ?? fitting.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        // Let onAppear and layout settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        writePNG(hosting, name: name)
    }

    var failures = 0
    func check(_ name: String, _ condition: Bool) {
        if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // The Home tab's content width: 640 panel, 12 shell padding and 8 scroll padding each side.
    let homeWidth: CGFloat = 640 - 2 * 12 - 2 * 8
    /// The notch panel is black.
    func onNotch<V: View>(_ view: V) -> some View {
        view.padding(8).background(Color.black)
    }

    let settings = TeachySettings.shared
    settings.voiceName = "nova"
    settings.speechSpeed = 1.15
    settings.captionsEnabled = true
    settings.dictationLanguage = "auto"
    settings.cursorColorName = "green"

    let dictionaryURL = outputDirectory.appendingPathComponent("sample-dictionary.json")
    try? FileManager.default.removeItem(at: dictionaryURL)
    let sampleDictionary = DictationDictionary(fileURL: dictionaryURL)
    for word in ["Vedant", "publik", "Teachy", "Conditor Fellowship", "SwiftUI", "Supabase", "Karpathy", "kubectl", "Oatmeal", "HeyClicky", "Gujarati", "xcodebuild", "Ahmedabad"] {
        sampleDictionary.add(word)
    }

    render(onNotch(VStack(spacing: 8) {
        VoiceSettingsSection()
        DictationSettingsSection(dictionary: sampleDictionary)
        ShortcutsSettingsSection()
        PrivacySettingsSection()
        AdvancedSettingsSection()
    }), width: homeWidth + 16, name: "01-settings-collapsed")
    render(onNotch(VoiceSettingsSection(startsExpanded: true)), width: homeWidth + 16, name: "02-voice")
    render(onNotch(DictationSettingsSection(startsExpanded: true, dictionary: sampleDictionary)), width: homeWidth + 16, name: "03-dictation")
    render(onNotch(ShortcutsSettingsSection(startsExpanded: true)), width: homeWidth + 16, name: "04-shortcuts")
    render(onNotch(PrivacySettingsSection(startsExpanded: true)), width: homeWidth + 16, name: "05-privacy")
    render(onNotch(AdvancedSettingsSection(startsExpanded: true)), width: homeWidth + 16, name: "06-advanced")

    // MARK: Caption bar (as it sits on a 1512-point-wide screen, over a busy light page)

    let screenWidth: CGFloat = 1512
    let captionPanelSize = CaptionBarStyle.panelSize(forScreenWidth: screenWidth)
    let pageBackdrop = LinearGradient(colors: [Color(white: 0.96), Color(red: 0.75, green: 0.85, blue: 0.98)], startPoint: .top, endPoint: .bottom)
    func captionShot(_ sentence: String, name: String) {
        let pages = CaptionLineFitter.pages(
            sentence,
            maxWidth: Double(CaptionBarStyle.textWidth(forScreenWidth: screenWidth)),
            maxLines: CaptionBarStyle.maximumLines,
            measure: CaptionBarStyle.measure
        )
        for (index, page) in pages.enumerated() {
            let model = CaptionBarModel()
            model.lines = page
            render(
                CaptionBarView(model: model).frame(height: captionPanelSize.height).background(pageBackdrop),
                width: captionPanelSize.width,
                height: captionPanelSize.height,
                name: pages.count > 1 ? "\(name)-page\(index + 1)" : name
            )
        }
    }
    captionShot("Click the blue Deploy button in the top right.", name: "07-caption-short")
    captionShot("That muscle is the deltoid. It has three parts, the front, the middle and the back, and together they lift your arm away from your body.", name: "08-caption-two-lines")
    captionShot("Open the File menu, choose Export, pick PNG from the format list, make sure the scale is set to two times so it stays sharp on a Retina display, then choose where to save it and press the Export button at the bottom right of the sheet.", name: "09-caption-long")

    // MARK: Text box (key handling checked through the same delegate calls AppKit makes)

    let textBox = TextBoxController.shared
    var submitted: [String] = []
    textBox.onSubmit = { submitted.append($0) }
    var shiftIsDown = false
    textBox.isShiftDown = { shiftIsDown }

    func textBoxShot(name: String) {
        guard let content = textBox.panel?.contentView else { return }
        // Over a light page, since the blur behind it can't be captured offscreen.
        let backdrop = NSView(frame: content.bounds.insetBy(dx: -20, dy: -20))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = backdrop
        let original = content.frame
        textBox.panel?.contentView = NSView()
        content.frame.origin = CGPoint(x: 20, y: 20)
        backdrop.addSubview(content)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        writePNG(backdrop, name: name)
        content.removeFromSuperview()
        content.frame = original
        textBox.panel?.contentView = content
    }

    let panel = textBox.loadEmptyPanel()
    let textView = textBox.textView!
    let emptyHeight = panel.frame.height
    check("text box panel can become key", panel.canBecomeKey)
    check("text box panel never becomes main", !panel.canBecomeMain)
    check("text box panel does not activate the app", panel.styleMask.contains(.nonactivatingPanel))
    textBoxShot(name: "10-textbox-empty")

    textView.insertText("How do I export this as a PNG?", replacementRange: textView.selectedRange())
    check("typing keeps one line the same height", abs(panel.frame.height - emptyHeight) < 1)
    textBoxShot(name: "11-textbox-typed")

    shiftIsDown = true
    check("Shift+Return is handled", textBox.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    check("Shift+Return adds a line and does not send", textView.string.hasSuffix("\n") && submitted.isEmpty)
    let topBefore = panel.frame.maxY
    textView.insertText("And can it keep the transparent background, or do I need a different format for that to work properly?", replacementRange: textView.selectedRange())
    check("the box grows with the text", panel.frame.height > emptyHeight + 20)
    check("it grows downward (top edge stays put)", abs(panel.frame.maxY - topBefore) < 1)
    textBoxShot(name: "12-textbox-multiline")

    let tallBefore = panel.frame.height
    for _ in 0..<12 {
        _ = textBox.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        textView.insertText("more", replacementRange: textView.selectedRange())
    }
    check("the box stops growing at five lines", panel.frame.height > tallBefore && panel.frame.height < emptyHeight * 3)

    shiftIsDown = false
    settings.captionsEnabled = false
    check("captions are off before a typed question", !CaptionPresenter.shared.willShowCaptions)
    textView.string = "  what is this button for?  \n"
    check("Return is handled", textBox.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    check("Return sends the trimmed question once", submitted == ["what is this button for?"])
    check("sending a typed question turns captions on for the reply", CaptionPresenter.shared.willShowCaptions)

    textView.string = "   "
    _ = textBox.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    check("an empty question is not sent", submitted.count == 1)
    check("Escape is handled", textBox.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    check("other commands are left to the text view", !textBox.textView(textView, doCommandBy: #selector(NSResponder.moveLeft(_:))))

    // MARK: Paint trail (a circled word, while held and halfway through the fade)

    func trailShot(name: String, color: NSColor, releasedFor: Double?) {
        let size = NSSize(width: 520, height: 300)
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        let label = NSTextField(labelWithString: "Deploy to production")
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = NSColor(white: 0.15, alpha: 1)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: (size.width - label.frame.width) / 2, y: (size.height - label.frame.height) / 2)
        backdrop.addSubview(label)

        // A slightly wobbly loop drawn over 1.1 s, a bit past a full turn, like a hand would.
        var points: [PaintTrailPoint] = []
        let steps = 90
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let angle = 2.25 * Double.pi * progress + 2.4
            let wobble = 1 + 0.05 * sin(progress * 13)
            let point = PaintTrailPoint(
                x: 260 + cos(angle) * 170 * wobble + progress * 14,
                y: 150 + sin(angle) * 62 * wobble - progress * 10,
                // Slower at the start and end of the gesture.
                time: 1.1 * (0.5 - 0.5 * cos(progress * Double.pi))
            )
            PaintTrailMath.append(point, to: &points)
        }
        let releasedAt: Double? = releasedFor == nil ? nil : 1.1
        let now = 1.1 + (releasedFor ?? 0)
        let trail = PaintTrailView(frame: backdrop.bounds)
        trail.setLocalSnapshot(PaintTrailSnapshot(
            points: points,
            widths: PaintTrailMath.widths(for: points, now: now, releasedAt: releasedAt),
            opacity: PaintTrailMath.releaseOpacity(now: now, releasedAt: releasedAt),
            color: color
        ))
        backdrop.addSubview(trail)
        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = backdrop
        writePNG(backdrop, name: name)
    }
    trailShot(name: "13-trail-held-green", color: NSColor(ClickyCursorColor.green.displayColor), releasedFor: nil)
    trailShot(name: "14-trail-held-blue", color: NSColor(ClickyCursorColor.blue.displayColor), releasedFor: nil)
    trailShot(name: "15-trail-fading", color: NSColor(ClickyCursorColor.red.displayColor), releasedFor: 0.35)

    print(failures == 0 ? "all text box checks passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runShots() }
