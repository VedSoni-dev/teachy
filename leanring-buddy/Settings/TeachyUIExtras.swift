//
//  TeachyUIExtras.swift
//  leanring-buddy
//
//  One call at launch that switches on the text box shortcut (double-tap
//  Control). The caption bar and paint trail need no start-up: they appear when
//  `CaptionPresenter.shared` and `PaintTrailPresenter.shared` are called.
//

import AppKit
import ApplicationServices

@MainActor
enum TeachyUIExtras {
    private static var hasStarted = false
    private static let textBoxHotkeyMonitor = TextBoxHotkeyMonitor()
    private static var permissionTimer: Timer?

    /// Safe to call more than once. Never shows a permission prompt: if
    /// Accessibility isn't granted yet, it waits quietly and installs the
    /// shortcut once it is.
    static func start() {
        guard !hasStarted else { return }
        hasStarted = true

        textBoxHotkeyMonitor.onDoubleTap = {
            TextBoxController.shared.toggle()
        }
        installTextBoxHotkeyWhenAllowed()
    }

    /// True once the double-tap Control shortcut is live.
    static var isTextBoxHotkeyActive: Bool { textBoxHotkeyMonitor.isRunning }

    private static func installTextBoxHotkeyWhenAllowed() {
        if textBoxHotkeyMonitor.start() { return }
        guard permissionTimer == nil else { return }
        // AXIsProcessTrusted() only checks; it doesn't prompt.
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted(), textBoxHotkeyMonitor.start() else { return }
                permissionTimer?.invalidate()
                permissionTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
}
