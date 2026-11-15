//
//  DictationPillWindow.swift
//  leanring-buddy
//
//  The small "Dictating" pill under the notch. A non-activating panel that never
//  takes focus or clicks, so the field being dictated into keeps the caret. It
//  always shows the live on-device text; in speed mode DictationSession also
//  types the stable words into the field.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationPillModel: ObservableObject {
    enum Mode: Equatable {
        case dictating
        case handsFree
        case working
        case notice(String)
    }

    @Published var mode: Mode = .dictating
    @Published var liveText = ""
    @Published var level: Double = 0
}

private struct DictationPillView: View {
    @ObservedObject var model: DictationPillModel

    private var title: String {
        switch model.mode {
        case .dictating: return "Dictating"
        case .handsFree: return "Dictating hands-free"
        case .working: return "Finishing"
        case .notice(let message): return message
        }
    }

    private var isListening: Bool {
        model.mode == .dictating || model.mode == .handsFree
    }

    /// The end of the live text: the newest words are the ones worth seeing.
    private var liveTail: String {
        let text = model.liveText.replacingOccurrences(of: "\n", with: " ")
        return text.count > 70 ? "…" + text.suffix(70) : text
    }

    /// The names of the keys of the dictation shortcut, one per key cap.
    private var dictationShortcutKeyNames: [String] {
        DictationShortcut.current().map { PushToTalkShortcutKeys.displayName(forKeyCode: $0) }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if isListening {
                DictationMicrophoneLevelMeter(level: model.level)
            } else if model.mode == .working {
                TeachyStatusMark(kind: .live)
            }

            Text(title)
                .font(DS.Fonts.controlCompact)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize()

            if isListening, !liveTail.isEmpty {
                Text(liveTail)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if model.mode == .handsFree {
                HStack(spacing: DS.Spacing.xs) {
                    Text("double-tap")
                    ForEach(Array(dictationShortcutKeyNames.enumerated()), id: \.offset) { _, dictationShortcutKeyName in
                        KeyboardKeyLabel(text: dictationShortcutKeyName)
                    }
                    Text("to stop")
                }
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize()
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .teachyTile(cornerRadius: DS.CornerRadius.pill)
        .frame(maxWidth: DictationPillController.maximumWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The open microphone, drawn as four bars that rise with the input level,
/// in the pointer colour (Teachy's one tint).
private struct DictationMicrophoneLevelMeter: View {
    /// The raw input level from the dictation session (quiet speech is around 0.05).
    let level: Double

    /// How far each bar rises compared with the tallest one, so the meter has a shape.
    private let barHeightShares: [Double] = [0.55, 1.0, 0.75, 0.45]
    private let restingBarHeight: CGFloat = 3
    private let tallestBarHeight: CGFloat = 12

    /// The same gain the pill has always applied to the level, capped at full height.
    private var normalizedLevel: Double {
        min(max(level * 8, 0), 1)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(barHeightShares.enumerated()), id: \.offset) { _, barHeightShare in
                Capsule()
                    .fill(DS.Colors.pointer)
                    .frame(
                        width: 2,
                        height: restingBarHeight + (tallestBarHeight - restingBarHeight) * CGFloat(normalizedLevel * barHeightShare)
                    )
            }
        }
        .frame(height: tallestBarHeight)
        .animation(.easeOut(duration: DS.Animation.fast), value: level)
        .accessibilityHidden(true)
    }
}

@MainActor
final class DictationPillController {
    static let maximumWidth: CGFloat = 520
    private static let panelSize = NSSize(width: 560, height: 44)

    let model = DictationPillModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ mode: DictationPillModel.Mode) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        model.mode = mode
        if mode == .dictating {
            model.liveText = ""
            model.level = 0
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Shows a short message ("Copied") and then hides.
    func flash(_ message: String, seconds: TimeInterval = 1.6) {
        show(.notice(message))
        hide(after: seconds)
    }

    func hide(after seconds: TimeInterval = 0) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.model.liveText = ""
        }
        hideWorkItem = work
        if seconds <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DictationPillView(model: model))
        return panel
    }

    /// Top center of the screen the pointer is on, just under the menu bar or notch.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let topInset = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let origin = NSPoint(
            x: screen.frame.midX - Self.panelSize.width / 2,
            y: screen.frame.maxY - topInset - Self.panelSize.height - 6
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }
}
