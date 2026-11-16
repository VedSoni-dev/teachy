import AppKit
import Combine
import SwiftUI

final class ComposerFixtureModel: ObservableObject {
    @Published var text = ""
    @Published var height: CGFloat = 22
    var focused = false
}

final class ComposerFixturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ComposerFixture: View {
    @ObservedObject var model: ComposerFixtureModel

    var body: some View {
        ChatComposerTextView(
            text: $model.text,
            height: $model.height,
            automaticallyFocus: false,
            onFocusChange: { model.focused = $0 },
            onSubmit: {}
        )
        .frame(width: 300, height: model.height)
        .padding(20)
        .background(DS.Colors.surface2)
        // Match the composer's decorative outline. The diagnostic flag enables
        // its hit testing to compare routing with the production-safe setting.
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(DS.Colors.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(CommandLine.arguments.contains("--hittable-outline"))
        }
    }
}

func runComposerFocusChecks() -> Int32 {
    // Shadow the only app preference read by DS in memory. Never change the
    // real pointer preference, or load a conversation, attachment, or account.
    UserDefaults.standard.setVolatileDomain(
        ["selectedCursorColor": "blue", "ApplePersistenceIgnoreState": true],
        forName: UserDefaults.argumentDomain
    )
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    print("OUTLINE hit testing: \(CommandLine.arguments.contains("--hittable-outline"))")
    var failures = 0
    var checks = 0
    func expect(_ condition: Bool, _ description: String) {
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL"): \(description)")
    }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    func findEditor(in view: NSView) -> ChatComposerNSTextView? {
        if let editor = view as? ChatComposerNSTextView { return editor }
        return view.subviews.compactMap { findEditor(in: $0) }.first
    }

    let model = ComposerFixtureModel()
    let panel = ComposerFixturePanel(
        contentRect: NSRect(x: 300, y: 300, width: 340, height: 62),
        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
        backing: .buffered,
        defer: false
    )
    panel.becomesKeyOnlyIfNeeded = true
    panel.isRestorable = false
    panel.contentView = NSHostingView(rootView: ComposerFixture(model: model))
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    settle()
    settle()

    guard let contentView = panel.contentView,
          let editor = findEditor(in: contentView),
          let scrollView = editor.enclosingScrollView else {
        print("FAIL: production composer did not create its native editor")
        return 1
    }
    expect(!model.focused && panel.firstResponder !== editor,
           "mounting an empty composer does not take keyboard focus")
    expect(editor.frame.width >= 300 && editor.frame.height >= 22,
           "empty native editor has a full-width, at least 22-point hit area")

    func clickAndType() {
        let target = scrollView.convert(
            NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil
        )
        let hit = contentView.hitTest(contentView.convert(target, from: nil))
        expect(hit === editor, "empty field center hit-tests to the native text view")
        let timestamp = ProcessInfo.processInfo.systemUptime
        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: target, modifierFlags: [],
            timestamp: timestamp, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: target, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0
        )!
        // NSTextView's mouse tracking consumes the queued mouse-up. Dispatch
        // through NSPanel, not directly to the editor: that catches first-click
        // rejection while another app owns focus in a nonactivating panel.
        NSApp.postEvent(mouseUp, atStart: false)
        panel.sendEvent(mouseDown)
        let keyDown = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7
        )!
        panel.sendEvent(keyDown)
        settle()
    }

    clickAndType()
    expect(panel.firstResponder === editor && model.focused,
           "first click makes the editor first responder and reports focus")
    expect(model.text == "x" && editor.string == "x",
           "keyboard input after the first click updates the SwiftUI draft")

    model.text = ""
    panel.makeFirstResponder(panel)
    settle()
    expect(!model.focused && editor.string.isEmpty,
           "clearing the draft and leaving the editor clears focus")
    expect(editor.frame.height >= 22, "cleared editor retains its empty hit area")
    clickAndType()
    expect(panel.firstResponder === editor && model.focused,
           "clicking again after clearing restores native keyboard focus")
    expect(model.text == "x" && editor.string == "x",
           "typing after clearing and refocusing updates the draft again")
    print(failures == 0 ? "ALL \(checks) COMPOSER FOCUS CHECKS PASSED" : "\(failures) OF \(checks) CHECKS FAILED")
    return failures == 0 ? 0 : 1
}

setvbuf(stdout, nil, _IOLBF, 0)
let result = MainActor.assumeIsolated { runComposerFocusChecks() }
exit(result)
