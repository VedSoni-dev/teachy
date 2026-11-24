//
//  SuggestionPanel.swift
//  leanring-buddy
//
//  The suggestions as they appear under the notch.
//
//  Collapsed:  "3 things I can take off your plate", the first idea, [Not now] [See all 3]
//  Expanded:   one card per idea, side by side: app, minutes, the headline, what you get,
//              the plan (shown on hover, or always for a single card), [Do it] [Adjust] [Nah].
//              Adjust turns the card's buttons into a one-line field for the change.
//
//  The panel never activates Teachy (the person's app stays in front); it becomes key only
//  so the Adjust field can take typing. Escape closes it without answering anything.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class SuggestionPanelModel: ObservableObject {
    @Published var suggestions: [TeachySuggestion] = []
    @Published var isExpanded = false
    /// The idea whose Adjust field is open, if any.
    @Published var adjustingSuggestionID: String?
    @Published var adjustText = ""
    /// Ideas just answered with Do it, shown briefly with "On it" before they leave.
    @Published var startedSuggestionIDs: Set<String> = []
}

private struct SuggestionCardView: View {
    let suggestion: TeachySuggestion
    let showsPlanAlways: Bool
    @ObservedObject var model: SuggestionPanelModel
    let onDoIt: () -> Void
    let onAdjust: (String) -> Void
    let onNah: () -> Void

    @State private var isHovered = false
    @FocusState private var adjustFieldFocused: Bool

    private var isAdjusting: Bool { model.adjustingSuggestionID == suggestion.id }
    private var isStarted: Bool { model.startedSuggestionIDs.contains(suggestion.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: 6) {
                Image(systemName: suggestion.symbolName)
                    .foregroundStyle(DS.Colors.pointer)
                Text(suggestion.appName)
                    .font(DS.Fonts.dataEmphasized)
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Image(systemName: "clock")
                    .foregroundColor(DS.Colors.textTertiary)
                Text("\(suggestion.estimatedMinutes) min")
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .font(DS.Fonts.caption)

            Text(suggestion.headline)
                .font(DS.Fonts.itemTitle)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !suggestion.outcome.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(suggestion.outcome)
                }
                .font(DS.Fonts.bodyEmphasized)
                .foregroundStyle(DS.Colors.pointer)
            }

            if showsPlanAlways || isHovered || isAdjusting {
                planSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            if isStarted {
                HStack(spacing: 6) {
                    TeachyStatusMark(kind: .live)
                    Text("On it")
                        .font(DS.Fonts.bodyEmphasized)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if isAdjusting {
                adjustField
            } else {
                answerButtons
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: SuggestionPanelPresenter.cardWidth, alignment: .topLeading)
        .frame(minHeight: SuggestionPanelPresenter.cardMinimumHeight, alignment: .topLeading)
        .teachyTile()
        .onHover { hovering in
            withAnimation(DS.Motion.standard) { isHovered = hovering }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TeachySectionTitle(title: "The plan")
            ForEach(Array(suggestion.planSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(step)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !suggestion.resultLocation.isEmpty {
                Text(suggestion.resultLocation)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .teachyWell()
    }

    private var answerButtons: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button("Do it", action: onDoIt)
                .teachyButton(.primary, isFullWidth: true)
            Button("Adjust") {
                model.adjustText = ""
                model.adjustingSuggestionID = suggestion.id
            }
            .teachyButton(.secondary, isFullWidth: true)
            Button("Nah", action: onNah)
                .teachyButton(.quiet)
        }
    }

    private var adjustField: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            TextField("What should I change?", text: $model.adjustText)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .teachyWell(isEdged: true)
                .focused($adjustFieldFocused)
                .onSubmit(submitAdjust)
                .onAppear { adjustFieldFocused = true }
            HStack(spacing: DS.Spacing.sm) {
                Button("Do it like that", action: submitAdjust)
                    .teachyButton(.primary, isFullWidth: true)
                    .disabled(model.adjustText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Back") { model.adjustingSuggestionID = nil }
                    .teachyButton(.quiet)
            }
        }
    }

    private func submitAdjust() {
        let change = model.adjustText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !change.isEmpty else { return }
        onAdjust(change)
    }
}

struct SuggestionPanelView: View {
    @ObservedObject var model: SuggestionPanelModel
    let onClose: () -> Void
    let onDoIt: (TeachySuggestion) -> Void
    let onAdjust: (TeachySuggestion, String) -> Void
    let onNah: (TeachySuggestion) -> Void

    private var weekdayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: Date()).uppercased()
    }

    var body: some View {
        if model.isExpanded {
            expandedBody
        } else {
            collapsedBody
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(weekdayLabel)
                    .font(DS.Fonts.dataEmphasized)
                    .foregroundColor(DS.Colors.textTertiary)
                Text(TeachySuggestionRules.title(forCount: model.suggestions.count))
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                if model.isExpanded {
                    Text("Hover one for the plan. Do it, adjust it, or toss it.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .teachyIconButton()
            .help("Close")
        }
    }

    private var collapsedBody: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            if let first = model.suggestions.first {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: first.symbolName)
                        .foregroundStyle(DS.Colors.pointer)
                        .frame(width: 18)
                    Text(first.headline)
                        .font(DS.Fonts.bodyEmphasized)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(DS.Spacing.md)
                .teachyWell()
            }
            HStack(spacing: DS.Spacing.sm) {
                Button("Not now", action: onClose)
                    .teachyButton(.secondary, isFullWidth: true)
                Button(model.suggestions.count == 1 ? "See it" : "See all \(model.suggestions.count)") {
                    withAnimation(DS.Motion.standard) { model.isExpanded = true }
                }
                .teachyButton(.primary, isFullWidth: true)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: SuggestionPanelPresenter.collapsedWidth)
        .teachyTile()
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                ForEach(model.suggestions) { suggestion in
                    SuggestionCardView(
                        suggestion: suggestion,
                        showsPlanAlways: model.suggestions.count == 1,
                        model: model,
                        onDoIt: { onDoIt(suggestion) },
                        onAdjust: { change in onAdjust(suggestion, change) },
                        onNah: { onNah(suggestion) }
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .padding(DS.Spacing.lg)
        .teachyTile()
    }
}

/// A panel that can take typing (for Adjust) without making Teachy the active app.
private final class SuggestionKeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class SuggestionPanelPresenter {
    static let shared = SuggestionPanelPresenter()

    static let collapsedWidth: CGFloat = 400
    static let cardWidth: CGFloat = 250
    static let cardMinimumHeight: CGFloat = 230

    private let model = SuggestionPanelModel()
    private var panel: SuggestionKeyPanel?
    private var hostingView: NSHostingView<SuggestionPanelView>?
    private var resizeObserver: NSObjectProtocol?

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(_ suggestions: [TeachySuggestion], startExpanded: Bool) {
        guard !suggestions.isEmpty else { return }
        model.suggestions = suggestions
        model.isExpanded = startExpanded
        model.adjustingSuggestionID = nil
        model.startedSuggestionIDs = []

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if hostingView == nil {
            let view = SuggestionPanelView(
                model: model,
                onClose: { [weak self] in self?.close() },
                onDoIt: { [weak self] suggestion in self?.start(suggestion, change: nil) },
                onAdjust: { [weak self] suggestion, change in self?.start(suggestion, change: change) },
                onNah: { [weak self] suggestion in self?.toss(suggestion) }
            )
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = [.intrinsicContentSize]
            hostingView = hosting
            panel.contentView = hosting
            // The content changes size (collapsed → expanded, plan shown on hover): keep the
            // panel fitted and centred under the notch.
            hosting.postsFrameChangedNotifications = true
            resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: hosting, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.fitToContent() }
            }
        }
        panel.onEscape = { [weak self] in self?.close() }
        fitToContent()
        panel.orderFrontRegardless()
        DS.Haptics.stateChanged()
    }

    func close() {
        panel?.orderOut(nil)
        model.adjustingSuggestionID = nil
    }

    private func start(_ suggestion: TeachySuggestion, change: String?) {
        withAnimation(DS.Motion.standard) {
            model.adjustingSuggestionID = nil
            model.startedSuggestionIDs.insert(suggestion.id)
        }
        if let change {
            SuggestionCenter.shared.accept(suggestion, withChange: change)
        } else {
            SuggestionCenter.shared.accept(suggestion)
        }
        // Leave "On it" on screen for a moment so the press visibly landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.removeCard(suggestion)
        }
    }

    private func toss(_ suggestion: TeachySuggestion) {
        SuggestionCenter.shared.dismiss(suggestion)
        removeCard(suggestion)
    }

    private func removeCard(_ suggestion: TeachySuggestion) {
        withAnimation(DS.Motion.standard) {
            model.suggestions.removeAll { $0.id == suggestion.id }
            model.startedSuggestionIDs.remove(suggestion.id)
        }
        if model.suggestions.isEmpty { close() }
    }

    private func fitToContent() {
        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0,
              let frame = AgentNotchLayout.frame(for: size, offset: DriveTakeoverMonitor.shared.isDriving ? AgentNotchLayout.pillSlotHeight : 0)
        else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> SuggestionKeyPanel {
        let panel = SuggestionKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.collapsedWidth, height: 160),
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}
