//
//  ConsentPrompt.swift
//  leanring-buddy
//
//  The question Teachy puts to the user before the agent does something that
//  needs a yes: a small card under the notch.
//
//      Want me to drive Preview and make that crop? You watch. Esc takes it back.
//      [Go ahead]  [Always allow]  [Not now]
//
//  - Return = Go ahead, Escape = Not now, no answer in 60 s = Not now.
//  - The panel never activates Teachy (the user's app stays in front); it takes
//    the keyboard only while it is up, so Return and Escape do not leak into
//    the app underneath.
//  - Two guards against a yes nobody meant: Return is ignored for the first
//    0.8 s (a key already on its way down), and for delete / send / pay
//    requests Return does nothing at all: those need a click.
//
//  `ConsentPrompter.shared.ask(_:)` is the whole API. One card at a time; more
//  requests wait their turn.
//

import AppKit
import SwiftUI

struct ConsentRequest: Identifiable {
    let id = UUID()
    let jobID: String
    let jobTitle: String
    /// "Want me to drive Preview and make that crop? You watch. Esc takes it back."
    let headline: String
    /// The exact command, path or control. Shown small under the question. May be empty.
    let detail: String
    /// Why this one is asked every time. May be empty.
    let reason: String
    let offersAlwaysAllow: Bool
    /// Deletes, sends, pays or touches credentials: needs a click, not just Return.
    let isHighStakes: Bool
}

private struct ConsentCardView: View {
    let request: ConsentRequest
    let onChoice: (ConsentChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Group {
                    if request.isHighStakes {
                        // The system's caution sign: a dark mark on an orange triangle.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.black.opacity(0.8), DS.Colors.warning)
                    } else {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(DS.Colors.pointer)
                    }
                }
                .font(DS.Fonts.sans(17, weight: .medium))
                .frame(width: 22)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(request.headline)
                        .font(DS.Fonts.sans(14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Which job is asking, for when several are running.
                    if !request.jobTitle.isEmpty {
                        Text(request.jobTitle)
                            .font(DS.Fonts.data)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    if !request.detail.isEmpty {
                        // The exact command, path or control: this is the one place for mono.
                        Text(request.detail)
                            .font(DS.Fonts.mono(11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(4)
                            .truncationMode(.tail)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .teachyWell()
                            .padding(.top, 2)
                    }

                    if !request.reason.isEmpty {
                        Text(request.reason)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                // Delete / send / pay need a click, so those do not advertise the Return key.
                choiceButton("Go ahead", keyHint: request.isHighStakes ? nil : "⏎", kind: .primary) { onChoice(.allowForJob) }
                if request.offersAlwaysAllow {
                    choiceButton("Always allow", keyHint: nil, kind: .secondary) { onChoice(.alwaysAllow) }
                }
                choiceButton("Not now", keyHint: "esc", kind: .secondary) { onChoice(.notNow) }
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: ConsentPrompter.cardWidth)
        .teachyTile(edgeColor: request.isHighStakes ? DS.Colors.warning : .clear)
    }

    /// A choice with the key that also triggers it, shown as a quiet hint inside the button.
    private func choiceButton(_ label: String, keyHint: String?, kind: TeachyButtonKind, action: @escaping () -> Void) -> some View {
        Button {
            DS.Haptics.stateChanged()
            action()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                if let keyHint {
                    Text(keyHint)
                        .font(DS.Fonts.sans(11))
                        .opacity(0.6)
                }
            }
        }
        .teachyButton(kind, isFullWidth: true)
    }
}

/// A panel that can hold the keyboard without making Teachy the active app.
private final class ConsentPanel: NSPanel {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: break // swallow: nothing typed here should reach the app underneath
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class ConsentPrompter: ConsentAsking {
    static let shared = ConsentPrompter()

    static let cardWidth: CGFloat = 400
    static let autoDeclineSeconds: TimeInterval = 60
    static let returnKeyGraceSeconds: TimeInterval = 0.8

    private struct Pending {
        let request: ConsentRequest
        let continuation: CheckedContinuation<ConsentChoice, Never>
    }

    private var waiting: [Pending] = []
    private var current: Pending?
    private var panel: ConsentPanel?
    private var shownAt = Date.distantPast
    private var autoDeclineTask: Task<Void, Never>?

    var isShowing: Bool { current != nil }

    /// Shows the card and returns what the user chose. Never throws: no answer is "not now".
    func ask(_ request: ConsentRequest) async -> ConsentChoice {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConsentChoice, Never>) in
                waiting.append(Pending(request: request, continuation: continuation))
                showNextIfIdle()
            }
        } onCancel: {
            Task { @MainActor in self.resolve(requestID: request.id, choice: .notNow) }
        }
    }

    /// Takes down (as "not now") any card belonging to a job that was stopped.
    func dismissCurrent(forJobID jobID: String) {
        let ids = ([current].compactMap { $0 } + waiting).filter { $0.request.jobID == jobID }.map(\.request.id)
        ids.forEach { resolve(requestID: $0, choice: .notNow) }
    }

    private func resolve(requestID: UUID, choice: ConsentChoice) {
        if let current, current.request.id == requestID {
            self.current = nil
            autoDeclineTask?.cancel()
            autoDeclineTask = nil
            panel?.orderOut(nil)
            current.continuation.resume(returning: choice)
            showNextIfIdle()
            return
        }
        if let position = waiting.firstIndex(where: { $0.request.id == requestID }) {
            let pending = waiting.remove(at: position)
            pending.continuation.resume(returning: choice)
        }
    }

    private func showNextIfIdle() {
        guard current == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        current = next
        shownAt = Date()
        present(next.request)

        autoDeclineTask?.cancel()
        let requestID = next.request.id
        autoDeclineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDeclineSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolve(requestID: requestID, choice: .notNow)
        }
    }

    private func present(_ request: ConsentRequest) {
        let requestID = request.id
        let card = ConsentCardView(request: request) { [weak self] choice in
            self?.resolve(requestID: requestID, choice: choice)
        }
        let hosting = NSHostingView(rootView: card)
        let size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.onReturn = { [weak self] in
            guard let self else { return }
            // Delete / send / pay need a deliberate click.
            guard !request.isHighStakes else { return }
            // A Return that was already on its way when the card appeared is not an answer.
            guard Date().timeIntervalSince(self.shownAt) >= Self.returnKeyGraceSeconds else { return }
            self.resolve(requestID: requestID, choice: .allowForJob)
        }
        panel.onEscape = { [weak self] in
            self?.resolve(requestID: requestID, choice: .notNow)
        }

        let offset = DriveTakeoverMonitor.shared.isDriving ? AgentNotchLayout.pillSlotHeight : 0
        if let frame = AgentNotchLayout.frame(for: size, offset: offset) {
            panel.setFrame(frame, display: true)
        }
        // Key, so Return and Escape land here; non-activating, so the user's app stays in front.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> ConsentPanel {
        let panel = ConsentPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}
