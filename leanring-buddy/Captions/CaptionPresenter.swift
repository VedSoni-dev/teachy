//
//  CaptionPresenter.swift
//  leanring-buddy
//
//  The caption bar: what Teachy is saying, as large text in a dark pill at the
//  bottom-centre of the screen the pointer is on. Click-through and never takes
//  focus. Shown when "Captions while Teachy talks" is on, and always for the
//  reply to a typed question (`forceNextReply()`).
//
//  Call `show(sentence:)` when a sentence starts playing, `speechEnded()` when
//  the reply has finished playing, and `hide()` when speech is cut off.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptionBarModel: ObservableObject {
    /// One or two lines, already wrapped to fit.
    @Published var lines: [String] = []
}

enum CaptionBarStyle {
    static let fontSize: CGFloat = 17
    static let fontWeight: NSFont.Weight = .medium
    static let maximumTextWidth: CGFloat = 820
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 13
    static let lineSpacing: CGFloat = 3
    static let maximumLines = 2
    /// Gap between the pill and the bottom of the usable screen (above the Dock).
    static let bottomMargin: CGFloat = 40
    /// How long the last caption stays after speech ends before it fades.
    static let lingerSeconds: TimeInterval = 1.5
    static let fadeSeconds: TimeInterval = 0.35

    /// The bar draws with this exact font and `measure` wraps with it, so the two
    /// can never drift apart.
    static var font: NSFont { .systemFont(ofSize: fontSize, weight: fontWeight) }

    static func measure(_ text: String) -> Double {
        Double((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The text width to wrap to on a screen this wide.
    static func textWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        max(240, min(maximumTextWidth, screenWidth * 0.72 - horizontalPadding * 2))
    }

    static func panelSize(forScreenWidth screenWidth: CGFloat) -> CGSize {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = lineHeight * CGFloat(maximumLines) + lineSpacing * CGFloat(maximumLines - 1)
        return CGSize(
            // Room around the pill for its shadow.
            width: textWidth(forScreenWidth: screenWidth) + horizontalPadding * 2 + 40,
            height: textHeight + verticalPadding * 2 + 40
        )
    }
}

struct CaptionBarView: View {
    @ObservedObject var model: CaptionBarModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if !model.lines.isEmpty {
                Text(model.lines.joined(separator: "\n"))
                    .font(Font(CaptionBarStyle.font))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(CaptionBarStyle.lineSpacing)
                    .lineLimit(CaptionBarStyle.maximumLines)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, CaptionBarStyle.horizontalPadding)
                    .padding(.vertical, CaptionBarStyle.verticalPadding)
                    .teachyTile()
                    .id(model.lines)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.14), value: model.lines)
        .allowsHitTesting(false)
    }
}

@MainActor
final class CaptionPresenter {
    static let shared = CaptionPresenter()

    let model = CaptionBarModel()

    private var panel: NSPanel?
    private var pageTask: Task<Void, Never>?
    private var hideWorkItem: DispatchWorkItem?

    /// Set by `forceNextReply()`: captions show for the next reply even when the
    /// setting is off. Cleared when that reply's captions have faded.
    private var forcedUntil: Date?
    private var hasShownForcedCaption = false

    private var isForced: Bool {
        guard let forcedUntil else { return false }
        return Date() < forcedUntil
    }

    /// True when a caption passed to `show(sentence:)` right now would be displayed.
    var willShowCaptions: Bool {
        TeachySettingsStorage.captionsEnabled() || isForced
    }

    /// Typed questions get captions regardless of the setting. Call just before
    /// sending one. Lapses by itself if no reply arrives within two minutes.
    func forceNextReply() {
        forcedUntil = Date().addingTimeInterval(120)
        hasShownForcedCaption = false
    }

    /// Shows one spoken sentence. A sentence too long for two lines rolls through
    /// two-line pages at roughly speaking pace.
    func show(sentence: String) {
        guard willShowCaptions else { return }
        guard let screen = Self.screenUnderPointer() else { return }

        let textWidth = CaptionBarStyle.textWidth(forScreenWidth: screen.frame.width)
        let pages = CaptionLineFitter.pages(
            sentence,
            maxWidth: Double(textWidth),
            maxLines: CaptionBarStyle.maximumLines,
            measure: CaptionBarStyle.measure
        )
        guard !pages.isEmpty else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        pageTask?.cancel()
        if isForced { hasShownForcedCaption = true }

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, on: screen)
        model.lines = pages[0]
        // Through the animator with no duration, so it also stops a fade in progress.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        guard pages.count > 1 else { return }
        let durations = CaptionLineFitter.pageDurations(pages, speed: TeachySettingsStorage.speechSpeed())
        pageTask = Task { [weak self] in
            for index in 1..<pages.count {
                try? await Task.sleep(for: .seconds(durations[index - 1]))
                guard !Task.isCancelled, let self else { return }
                self.model.lines = pages[index]
            }
        }
    }

    /// The reply finished playing: leave the last caption up briefly, then fade.
    func speechEnded() {
        guard panel?.isVisible == true else {
            finishForcedReplyIfShown()
            return
        }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptionBarStyle.lingerSeconds, execute: work)
    }

    /// Speech was cut off (a new question, the stop key): remove the caption now.
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        pageTask?.cancel()
        pageTask = nil
        panel?.orderOut(nil)
        model.lines = []
    }

    private func fadeOut() {
        guard let panel else { return }
        pageTask?.cancel()
        pageTask = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = CaptionBarStyle.fadeSeconds
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A new caption may have arrived during the fade.
                guard self.hideWorkItem?.isCancelled == false else { return }
                self.hideWorkItem = nil
                panel.orderOut(nil)
                self.model.lines = []
                self.finishForcedReplyIfShown()
            }
        })
    }

    private func finishForcedReplyIfShown() {
        if hasShownForcedCaption {
            forcedUntil = nil
            hasShownForcedCaption = false
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 140),
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
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CaptionBarView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let size = CaptionBarStyle.panelSize(forScreenWidth: screen.frame.width)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            // The view keeps 20 pt under the pill for its shadow.
            y: screen.visibleFrame.minY + CaptionBarStyle.bottomMargin - 20
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func screenUnderPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }
}
