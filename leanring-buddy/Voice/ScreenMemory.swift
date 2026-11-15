//
//  ScreenMemory.swift
//  leanring-buddy
//
//  Writes a one-line note of the screen the person was on into the Brain's "Screen
//  memory" section, once per voice turn, so "what was that page I had open earlier"
//  can be answered later. No model call: see `ScreenMemorySummary`. The Brain keeps
//  the newest 15 notes; the same screen twice in a row is written once; password
//  managers and private browser windows are never written.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ScreenMemory {
    static let shared = ScreenMemory()

    private var log = ScreenMemoryLog()
    private let store: BrainStore

    init(store: BrainStore = .shared) {
        self.store = store
    }

    /// Notes one screen. `summary` is optional visible text (the first ~200 characters are kept).
    /// Returns the line that was stored, or nil when nothing was (same screen as last time,
    /// a private window, nothing to say).
    @discardableResult
    func note(frontApp: String, windowTitle: String?, browserURL: String?, summary: String? = nil) -> String? {
        let snapshot = ScreenSnapshot(frontApp: frontApp, windowTitle: windowTitle, browserURL: browserURL, text: summary)
        guard let line = log.lineToRecord(for: snapshot) else { return nil }
        store.remember(line, kind: .screen)
        return line
    }

    /// Reads the frontmost app and its window title itself and notes them. `browserTabContext`
    /// is the text `BrowserActiveTabReader.activeTabContext()` returned for this turn (or nil);
    /// the page address is taken from it. Teachy's own windows are skipped.
    @discardableResult
    func noteCurrentScreen(browserTabContext: String?, summary: String? = nil) -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let name = application.localizedName ?? application.bundleIdentifier ?? ""
        return note(
            frontApp: name,
            windowTitle: Self.focusedWindowTitle(of: application),
            browserURL: ScreenMemorySummary.firstURL(in: browserTabContext),
            summary: summary
        )
    }

    private static func focusedWindowTitle(of application: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
