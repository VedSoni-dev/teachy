//
//  ChatComposerTextView.swift
//  leanring-buddy
//
//  The text box at the bottom of the chat window. A real NSTextView so that
//  Return sends, Shift+Return (or Option+Return) adds a line, input methods
//  keep their own Return, and the box grows with the text up to a limit.
//

import AppKit
import SwiftUI

/// The text view class, so the window can find it and give it the keyboard.
final class ChatComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return super.keyDown(with: event) }
        let action = ChatComposerKeyRule.action(
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            isComposingText: hasMarkedText()
        )
        switch action {
        case .send: onSubmit?()
        case .insertNewline: insertNewlineIgnoringFieldEditor(nil)
        case .passThrough: super.keyDown(with: event)
        }
    }
}

struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var fontSize: CGFloat = 14.5
    var minimumHeight: CGFloat = 22
    var maximumHeight: CGFloat = 168
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = NSColor(DS.Colors.textPrimary)
        // The caret takes the tint, as it does in every macOS text field.
        textView.insertionPointColor = NSColor(DS.Colors.pointer)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("Ask Teachy")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        weak var textView: ChatComposerNSTextView?

        init(_ parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            let clamped = min(parent.maximumHeight, max(parent.minimumHeight, ceil(used)))
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
        }
    }
}
