//
//  NextStepChipsPanel.swift
//  leanring-buddy
//
//  The row of next-step buttons under the notch after an answer (see NextSteps.swift).
//  Rewrite buttons ("Make it shorter") are pointer-coloured outlines; ask-Teachy buttons
//  are filled, so "change the text" and "do something new" look different. A small ×
//  clears the row. It hides by itself after a while, and when the person talks again.
//
//  The panel never takes the keyboard or activates Teachy.
//

import AppKit
import SwiftUI

private struct NextStepChipsView: View {
    let chips: [NextStepChip]
    let onChoose: (NextStepChip) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(chips) { chip in
                Button {
                    onChoose(chip)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: chip.kind == .askTeachy ? "arrow.turn.down.right" : "text.bubble")
                        Text(chip.label)
                            .lineLimit(1)
                    }
                }
                .teachyButton(chip.kind == .askTeachy ? .primary : .secondary, size: .compact)
            }
            Button(action: onClear) {
                Image(systemName: "xmark")
            }
            .teachyIconButton(sideLength: 22)
            .help("Clear")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .teachyTile()
    }
}

@MainActor
final class NextStepChipsPresenter {
    static let shared = NextStepChipsPresenter()

    /// What a press does; set once by CompanionManager.
    var onChoose: ((NextStepChip) -> Void)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ chips: [NextStepChip]) {
        guard !chips.isEmpty else {
            hide()
            return
        }
        let view = NextStepChipsView(
            chips: chips,
            onChoose: { [weak self] chip in
                self?.hide()
                self?.onChoose?(chip)
            },
            onClear: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = self.panel ?? AgentNotchLayout.makePanel(size: size, acceptsClicks: true)
        self.panel = panel
        panel.contentView = hosting
        // Below any consent card or driving pill that is up.
        let offset = DriveTakeoverMonitor.shared.isDriving ? AgentNotchLayout.pillSlotHeight : 0
        if let frame = AgentNotchLayout.frame(for: size, offset: offset) {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NextStepRules.secondsBeforeHiding * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }
}
