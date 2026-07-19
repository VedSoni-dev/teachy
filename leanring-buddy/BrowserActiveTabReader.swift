//
//  BrowserActiveTabReader.swift
//  leanring-buddy
//
//  Reads the frontmost browser's active tab (URL + title) via AppleScript so the
//  companion prompt can say WHICH PAGE the user is on — not just which app.
//  Window titles alone often omit the URL entirely; this closes the biggest
//  remaining hole in Teachy's situational awareness.
//
//  Requires the Automation permission for the target browser (same permission
//  the native control tools use). Returns nil silently when not granted, when
//  the frontmost app isn't a supported browser, or on any script failure — a
//  companion turn must never fail or stall because tab context was unavailable.
//

import AppKit
import Foundation

enum BrowserActiveTabReader {

    /// e.g. `Safari tab: "GitHub - VedSoni-dev/teachy" — https://github.com/VedSoni-dev/teachy`
    /// Hard-capped at ~1.5s so a hung or permission-blocked browser never delays a turn.
    static func activeTabContext() async -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let browserDialect = BrowserAppleScriptDialect(bundleID: frontmostApp.bundleIdentifier ?? "") else {
            return nil
        }

        let scriptSource = browserDialect.scriptForActiveTabInfo()
        let browserName = browserDialect.applicationName

        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    await Task.detached(priority: .userInitiated) { () -> String? in
                        let appleScript = NSAppleScript(source: scriptSource)
                        var errorInfo: NSDictionary?
                        let resultDescriptor = appleScript?.executeAndReturnError(&errorInfo)
                        guard errorInfo == nil,
                              let resultDescriptor,
                              resultDescriptor.numberOfItems >= 2,
                              let urlString = resultDescriptor.atIndex(1)?.stringValue,
                              let titleString = resultDescriptor.atIndex(2)?.stringValue,
                              !urlString.isEmpty else {
                            return nil
                        }
                        let truncatedTitle = String(titleString.prefix(80))
                        let truncatedURL = String(urlString.prefix(120))
                        return "\(browserName) tab: \"\(truncatedTitle)\" — \(truncatedURL)"
                    }.value
                }
                // Timeout guard — mirrors the zoom-refinement race pattern in CompanionManager.
                group.addTask {
                    try await Task.sleep(for: .milliseconds(1500))
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch {
            print("🌐 Browser tab context unavailable: \(error.localizedDescription)")
            return nil
        }
    }
}
