//
//  TextBoxController.swift
//  leanring-buddy
//
//  The text box: double-tap Control and a small composer opens next to the
//  pointer for typing a question instead of saying it. Return sends,
//  Shift+Return adds a line, Escape (or clicking elsewhere, or double-tapping
//  Control again) closes it.
//
//  The panel is a non-activating NSPanel that can become key, so typing works
//  while the app the person was in stays the active app and none of Teachy's
//  other windows come forward. Built in plain AppKit so focus is set the moment
//  it opens.
//

import AppKit

/// Borderless panels refuse key status unless told otherwise.
final class TextBoxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TextBoxContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class TextBoxController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = TextBoxController()

    /// Called with the trimmed question when the person presses Return.
    var onSubmit: ((String) -> Void)?

    /// Whether Shift is held for the key being handled. Replaceable in tests.
    var isShiftDown: () -> Bool = { NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false }

    private(set) var panel: TextBoxPanel?
    private(set) var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var placeholderLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var accentDot: NSView?

    private enum Metrics {
        static let width: CGFloat = 440
        static let horizontalPadding: CGFloat = 14
        static let topPadding: CGFloat = 12
        static let dotSize: CGFloat = 8
        static let dotGap: CGFloat = 10
        static let hintGap: CGFloat = 6
        static let hintHeight: CGFloat = 13
        static let bottomPadding: CGFloat = 9
        static let maximumLines: CGFloat = 5
        static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
        static var textX: CGFloat { horizontalPadding + dotSize + dotGap }
        static var textWidth: CGFloat { width - textX - horizontalPadding }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// What the double-tap does: open, or close if already open.
    func toggle() {
        if isVisible { close() } else { show() }
    }

    /// Builds the panel if needed and resets it to an empty one-line box,
    /// without putting it on screen. `show()` calls this; previews use it too.
    @discardableResult
    func loadEmptyPanel() -> TextBoxPanel {
        let panel = panel ?? makePanel()
        self.panel = panel

        textView?.string = ""
        accentDot?.layer?.backgroundColor = TeachySettings.currentCursorNSColor.cgColor
        textView?.insertionPointColor = TeachySettings.currentCursorNSColor
        updatePlaceholder()

        var frame = panel.frame
        frame.size = NSSize(width: Metrics.width, height: panelHeight(forTextHeight: lineHeight))
        panel.setFrame(frame, display: false)
        layoutContents()
        return panel
    }

    func show() {
        let panel = loadEmptyPanel()
        let size = panel.frame.size
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let origin = TextBoxPlacement.origin(
            cursor: mouseLocation,
            panelSize: size,
            visibleFrame: screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        layoutContents()

        // Key without activating the app: the panel is `.nonactivatingPanel`.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        textView?.string = ""
    }

    // MARK: Sending

    private func submit() {
        let text = (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        guard !text.isEmpty else { return }
        // A typed question is answered with captions even when they are off.
        CaptionPresenter.shared.forceNextReply()
        if let onSubmit {
            onSubmit(text)
        } else {
            print("⚠️ Text box: nothing is listening for typed questions (TextBoxController.shared.onSubmit is not set)")
        }
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if isShiftDown() {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                submit()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            // Option+Return and Control+Return add a line the usual way.
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        resizeToFitText()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses it, like Spotlight.
        close()
    }

    // MARK: Layout

    private var lineHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: Metrics.font))
    }

    private func panelHeight(forTextHeight textHeight: CGFloat) -> CGFloat {
        Metrics.topPadding + textHeight + Metrics.hintGap + Metrics.hintHeight + Metrics.bottomPadding
    }

    /// Height of the typed text, between one and five lines.
    private var fittedTextHeight: CGFloat {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return lineHeight
        }
        layoutManager.ensureLayout(for: container)
        var used = ceil(layoutManager.usedRect(for: container).height)
        // A trailing newline has an empty last line that usedRect leaves out.
        if textView.string.hasSuffix("\n") { used += lineHeight }
        return min(max(used, lineHeight), lineHeight * Metrics.maximumLines)
    }

    private func resizeToFitText() {
        guard let panel else { return }
        let newHeight = panelHeight(forTextHeight: fittedTextHeight)
        guard abs(newHeight - panel.frame.height) > 0.5 else { return }
        // Grow downward: the top edge stays where it is.
        var frame = panel.frame
        frame.origin.y = frame.maxY - newHeight
        frame.size.height = newHeight
        if let visibleFrame = panel.screen?.visibleFrame, frame.minY < visibleFrame.minY + 10 {
            frame.origin.y = visibleFrame.minY + 10
        }
        panel.setFrame(frame, display: true)
        layoutContents()
    }

    private func layoutContents() {
        guard let panel, let contentView = panel.contentView else { return }
        let textHeight = contentView.bounds.height - panelHeight(forTextHeight: 0)
        scrollView?.frame = NSRect(x: Metrics.textX, y: Metrics.topPadding, width: Metrics.textWidth, height: textHeight)
        placeholderLabel?.frame = NSRect(x: Metrics.textX, y: Metrics.topPadding, width: Metrics.textWidth, height: lineHeight)
        accentDot?.frame = NSRect(
            x: Metrics.horizontalPadding,
            y: Metrics.topPadding + (lineHeight - Metrics.dotSize) / 2,
            width: Metrics.dotSize,
            height: Metrics.dotSize
        )
        hintLabel?.frame = NSRect(
            x: Metrics.textX,
            y: Metrics.topPadding + textHeight + Metrics.hintGap,
            width: Metrics.textWidth,
            height: Metrics.hintHeight
        )
    }

    private func updatePlaceholder() {
        placeholderLabel?.isHidden = !(textView?.string.isEmpty ?? true)
    }

    // MARK: Building

    private func makePanel() -> TextBoxPanel {
        let initialSize = NSSize(width: Metrics.width, height: panelHeight(forTextHeight: lineHeight))
        let panel = TextBoxPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let contentView = TextBoxContentView(frame: NSRect(origin: .zero, size: initialSize))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 14
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        contentView.layer?.borderWidth = 0.75
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let background = NSVisualEffectView(frame: contentView.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        contentView.addSubview(background)

        // A dark wash over the blur so white text stays readable on bright pages.
        let wash = NSView(frame: contentView.bounds)
        wash.autoresizingMask = [.width, .height]
        wash.wantsLayer = true
        wash.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        contentView.addSubview(wash)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.dotSize / 2
        contentView.addSubview(dot)
        accentDot = dot

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: Metrics.textWidth, height: lineHeight))
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Metrics.font
        textView.textColor = .white
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityLabel("Ask Teachy")
        scrollView.documentView = textView
        contentView.addSubview(scrollView)
        self.scrollView = scrollView
        self.textView = textView

        let placeholder = NSTextField(labelWithString: "Ask Teachy anything…")
        placeholder.font = Metrics.font
        placeholder.textColor = NSColor.white.withAlphaComponent(0.38)
        contentView.addSubview(placeholder)
        placeholderLabel = placeholder

        let hint = NSTextField(labelWithString: "return to send  ·  shift + return for a new line  ·  esc to close")
        hint.font = .systemFont(ofSize: 10, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.34)
        hint.lineBreakMode = .byTruncatingTail
        contentView.addSubview(hint)
        hintLabel = hint

        panel.contentView = contentView
        return panel
    }
}
