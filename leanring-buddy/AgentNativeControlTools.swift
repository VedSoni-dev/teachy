//
//  AgentNativeControlTools.swift
//  Dedicated native Mac-control agent tools: open/quit/switch apps and
//  open/close/switch browser tabs and windows via NSWorkspace and AppleScript.
//  Registered in BackgroundAgentToolRegistry so they are available everywhere
//  the tool loop runs (Phase K .act steps, course "do it for me", and the new
//  one-shot [DO:] path from Phase L).
//

import AppKit
import Foundation

// MARK: - control_app

/// Controls a macOS application by name without simulating clicks.
/// Prefer this tool over run_applescript for any open/activate/quit/hide operation.
final class ControlAppTool: BackgroundAgentTool {
    let name = "control_app"
    let description = """
    Open, activate, quit, or hide a macOS application by name, natively (no clicking). \
    Prefer this over run_applescript for app control. \
    action="open" launches the app; "activate" brings it to the foreground if already running; \
    "quit" gracefully quits it; "hide" hides all of its windows.
    """

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["open", "activate", "quit", "hide"],
                "description": "What to do with the app: open (launch), activate (bring to front), quit (gracefully exit), or hide (hide all windows)."
            ],
            "appName": [
                "type": "string",
                "description": "The app's display name as it appears in the Dock or Applications folder, e.g. \"Spotify\", \"Safari\", \"Visual Studio Code\"."
            ]
        ],
        "required": ["action", "appName"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let actionName = arguments["action"] as? String else {
            throw NSError(domain: "ControlAppTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing 'action' argument"])
        }
        guard let appName = arguments["appName"] as? String, !appName.isEmpty else {
            throw NSError(domain: "ControlAppTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing 'appName' argument"])
        }

        switch actionName {
        case "open":
            return try await openApplication(named: appName)
        case "activate":
            return try activateRunningApplication(named: appName)
        case "quit":
            return try await quitApplication(named: appName)
        case "hide":
            return try hideApplication(named: appName)
        default:
            throw NSError(domain: "ControlAppTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(actionName). Use open, activate, quit, or hide."])
        }
    }

    // MARK: Open

    private func openApplication(named appName: String) async throws -> String {
        // Use NSWorkspace URL-based launch — more reliable than launchApplication(_:) which
        // is deprecated in macOS 10.15+ and requires the exact display name to match.
        return try await Task.detached(priority: .userInitiated) {
            let workspace = NSWorkspace.shared
            // First try to find the app via NSWorkspace's app-finder (handles both /Applications
            // and ~/Applications, plus Spotlight-indexed locations).
            if let appURL = workspace.urlForApplication(withBundleIdentifier: appName) {
                // Caller passed a bundle ID — open it directly.
                let openConfig = NSWorkspace.OpenConfiguration()
                openConfig.activates = true
                do {
                    _ = try await workspace.openApplication(at: appURL, configuration: openConfig)
                    return "Opened \(appName)"
                } catch {
                    throw NSError(domain: "ControlAppTool", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not open \(appName): \(error.localizedDescription)"])
                }
            }

            // Caller passed a display name — search for the app by name.
            let foundURL = Self.findApplicationURL(named: appName)
            guard let appURL = foundURL else {
                throw NSError(domain: "ControlAppTool", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "App not found: \"\(appName)\". Make sure the name matches how it appears in the Applications folder."])
            }
            let openConfig = NSWorkspace.OpenConfiguration()
            openConfig.activates = true
            do {
                _ = try await workspace.openApplication(at: appURL, configuration: openConfig)
                return "Opened \(appName)"
            } catch {
                throw NSError(domain: "ControlAppTool", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Could not open \(appName): \(error.localizedDescription)"])
            }
        }.value
    }

    // MARK: Activate

    private func activateRunningApplication(named appName: String) throws -> String {
        if let runningApp = findRunningApplication(named: appName) {
            // `activate(options:)` with `.activateIgnoringOtherApps` is deprecated in
            // macOS 14 — use the no-argument `activate()` which brings the app forward
            // without needing the now-meaningless "ignore other apps" flag.
            runningApp.activate()
            return "Activated \(runningApp.localizedName ?? appName)"
        }
        // Not currently running — attempt a launch instead so the caller gets the app open.
        return "App \"\(appName)\" is not currently running. Use action=\"open\" to launch it."
    }

    // MARK: Quit

    private func quitApplication(named appName: String) async throws -> String {
        // Prefer NSRunningApplication.terminate() — it's the same graceful quit as
        // Cmd-Q (unsaved-changes dialogs still appear) but goes through AppKit's
        // process APIs, NOT scriptable Apple Events, so it needs no Automation
        // permission and never triggers a "Teachy wants to control X" prompt.
        if let runningApp = findRunningApplication(named: appName) {
            let quitRequestSent = runningApp.terminate()
            if quitRequestSent {
                return "Quit \(runningApp.localizedName ?? appName)"
            }
            // terminate() refused (rare) — fall through to the AppleScript path below.
        } else {
            return "App \"\(appName)\" is not currently running — nothing to quit."
        }

        // AppleScript fallback — requires the Automation permission for the target app.
        let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
        let quitScript = "tell application \"\(escapedAppName)\" to quit"

        return try await Task.detached(priority: .userInitiated) {
            let appleScript = NSAppleScript(source: quitScript)
            var errorInfo: NSDictionary?
            appleScript?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                throw NativeControlPermissionSupport.actionableError(
                    from: errorInfo,
                    domain: "ControlAppTool",
                    fallbackDescription: "Could not quit \(appName)"
                )
            }
            return "Quit \(appName)"
        }.value
    }

    // MARK: Hide

    private func hideApplication(named appName: String) throws -> String {
        if let runningApp = findRunningApplication(named: appName) {
            runningApp.hide()
            return "Hid \(runningApp.localizedName ?? appName)"
        }
        return "App \"\(appName)\" is not currently running — nothing to hide."
    }

    // MARK: Helpers

    /// Searches NSWorkspace's running application list for a case-insensitive name match.
    private func findRunningApplication(named appName: String) -> NSRunningApplication? {
        let normalizedTarget = appName.lowercased()
        return NSWorkspace.shared.runningApplications.first { runningApp in
            let runningAppName = (runningApp.localizedName ?? "").lowercased()
            let bundleID = (runningApp.bundleIdentifier ?? "").lowercased()
            return runningAppName == normalizedTarget || bundleID == normalizedTarget
        }
    }

    /// Searches common application directories for a .app bundle matching `appName`.
    /// Returns the first matching URL or nil if not found.
    private static func findApplicationURL(named appName: String) -> URL? {
        let searchDirectories = [
            "/Applications",
            "\(NSHomeDirectory())/Applications",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]
        let normalizedTarget = appName.lowercased()
        // Exact match first, then prefix match.
        for directory in searchDirectories {
            let directoryURL = URL(fileURLWithPath: directory)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else { continue }

            let exactMatch = contents.first { url in
                let bundleName = url.deletingPathExtension().lastPathComponent.lowercased()
                return bundleName == normalizedTarget && url.pathExtension == "app"
            }
            if let exactMatch { return exactMatch }
        }
        // Loose contains-match as final fallback.
        for directory in searchDirectories {
            let directoryURL = URL(fileURLWithPath: directory)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else { continue }

            let looseMatch = contents.first { url in
                let bundleName = url.deletingPathExtension().lastPathComponent.lowercased()
                return bundleName.contains(normalizedTarget) && url.pathExtension == "app"
            }
            if let looseMatch { return looseMatch }
        }
        return nil
    }
}

// MARK: - control_browser

/// Controls browser tabs and windows in the frontmost browser natively via AppleScript.
/// Supports Safari and the Chromium family (Chrome, Arc, Brave, Edge).
/// For opening a URL in a new tab, prefer this or open_browser_tab.
final class ControlBrowserTool: BackgroundAgentTool {
    let name = "control_browser"
    let description = """
    Manage browser tabs and windows in the frontmost browser natively (no clicking). \
    Prefer this over run_applescript for tab/window control. \
    Supports Safari, Chrome, Arc, Brave, and Edge. \
    action="new_tab" opens a URL (or blank tab) in a new tab; \
    "close_tab" closes the active tab; "close_all_tabs" closes every tab in the front window; \
    "close_other_tabs" closes everything except the active tab; "close_window" closes the front window; \
    "next_tab" / "previous_tab" switch tabs. \
    The optional url parameter is only used with new_tab.
    """

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["new_tab", "close_tab", "close_all_tabs", "close_other_tabs", "close_window", "next_tab", "previous_tab"],
                "description": "Tab/window action to perform in the frontmost browser."
            ],
            "url": [
                "type": "string",
                "description": "URL to open (only used with action=\"new_tab\"). Include https://. If omitted, a blank new tab is opened."
            ]
        ],
        "required": ["action"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let actionName = arguments["action"] as? String else {
            throw NSError(domain: "ControlBrowserTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing 'action' argument"])
        }

        // Detect the frontmost browser from NSWorkspace — this is what the user has open
        // and is looking at, so it's the right target for tab/window commands.
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            throw NSError(domain: "ControlBrowserTool", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No frontmost application found"])
        }

        let frontmostBundleID = frontmostApp.bundleIdentifier ?? ""
        guard let browserDialect = BrowserAppleScriptDialect(bundleID: frontmostBundleID) else {
            let appDisplayName = frontmostApp.localizedName ?? frontmostBundleID
            return "The frontmost app (\(appDisplayName)) is not a supported browser. Bring Safari, Chrome, Arc, Brave, or Edge to the front first."
        }

        let urlArgument = arguments["url"] as? String

        let appleScriptSource: String
        switch actionName {
        case "new_tab":
            appleScriptSource = browserDialect.scriptForNewTab(url: urlArgument)
        case "close_tab":
            appleScriptSource = browserDialect.scriptForCloseActiveTab()
        case "close_all_tabs":
            appleScriptSource = browserDialect.scriptForCloseAllTabs()
        case "close_other_tabs":
            appleScriptSource = browserDialect.scriptForCloseOtherTabs()
        case "close_window":
            appleScriptSource = browserDialect.scriptForCloseFrontWindow()
        case "next_tab":
            appleScriptSource = browserDialect.scriptForNextTab()
        case "previous_tab":
            appleScriptSource = browserDialect.scriptForPreviousTab()
        default:
            throw NSError(domain: "ControlBrowserTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(actionName)"])
        }

        let browserDisplayName = browserDialect.applicationName
        let actionDescription = Self.humanReadableActionDescription(actionName: actionName, url: urlArgument, browserName: browserDisplayName)

        return try await Task.detached(priority: .userInitiated) {
            let appleScript = NSAppleScript(source: appleScriptSource)
            var errorInfo: NSDictionary?
            appleScript?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                throw NativeControlPermissionSupport.actionableError(
                    from: errorInfo,
                    domain: "ControlBrowserTool",
                    fallbackDescription: "Browser control failed in \(browserDisplayName)"
                )
            }
            return actionDescription
        }.value
    }

    private static func humanReadableActionDescription(actionName: String, url: String?, browserName: String) -> String {
        switch actionName {
        case "new_tab":
            if let url, !url.isEmpty {
                return "Opened \(url) in a new tab in \(browserName)"
            }
            return "Opened a new blank tab in \(browserName)"
        case "close_tab":
            return "Closed the active tab in \(browserName)"
        case "close_all_tabs":
            return "Closed all tabs in \(browserName)'s front window"
        case "close_other_tabs":
            return "Closed every tab except the active one in \(browserName)"
        case "close_window":
            return "Closed the front window in \(browserName)"
        case "next_tab":
            return "Switched to the next tab in \(browserName)"
        case "previous_tab":
            return "Switched to the previous tab in \(browserName)"
        default:
            return "Browser action completed in \(browserName)"
        }
    }
}

// MARK: - Permission-error mapping

/// Maps raw NSAppleScript failures to messages the agent can actually act on and
/// speak. The critical case is -1743 (errAEEventNotPermitted): macOS blocked the
/// Apple Event because the user hasn't approved Teachy under Automation — the raw
/// error text ("Not authorized to send Apple events") is useless spoken aloud, so
/// we return concrete guidance instead. -10004 is System Events' privilege
/// violation (same root cause, Accessibility/Automation not granted).
enum NativeControlPermissionSupport {
    static func actionableError(
        from errorInfo: NSDictionary,
        domain: String,
        fallbackDescription: String
    ) -> NSError {
        let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        let rawMessage = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"

        if errorNumber == -1743 || errorNumber == -10004 {
            return NSError(domain: domain, code: errorNumber, userInfo: [
                NSLocalizedDescriptionKey: """
                macOS blocked this — Teachy needs the Automation permission for that app. \
                Tell the user: look for a "Teachy wants to control..." prompt and click OK, \
                or open System Settings > Privacy & Security > Automation and enable the \
                toggles under Teachy, then ask me again.
                """
            ])
        }

        return NSError(domain: domain, code: errorNumber, userInfo: [
            NSLocalizedDescriptionKey: "\(fallbackDescription): \(rawMessage)"
        ])
    }
}

// MARK: - BrowserAppleScriptDialect

/// Encapsulates the AppleScript vocabulary differences between Safari and
/// Chromium-family browsers (Chrome, Arc, Brave, Edge). Safari uses `document`
/// and `current tab of front window`; Chrome-family uses `tab` and `active tab`.
/// Internal (not private) so `BrowserActiveTabReader` can reuse the bundle-ID
/// mapping instead of duplicating it.
struct BrowserAppleScriptDialect {
    let applicationName: String
    let isSafari: Bool

    /// Returns nil if the bundle ID is not a supported browser.
    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Safari":
            self.applicationName = "Safari"
            self.isSafari = true
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev":
            self.applicationName = "Google Chrome"
            self.isSafari = false
        case "company.thebrowser.Browser":
            self.applicationName = "Arc"
            self.isSafari = false
        case "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly":
            self.applicationName = "Brave Browser"
            self.isSafari = false
        case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev":
            self.applicationName = "Microsoft Edge"
            self.isSafari = false
        default:
            return nil
        }
    }

    // MARK: Script builders

    func scriptForNewTab(url: String?) -> String {
        let escapedURL = url?.replacingOccurrences(of: "\"", with: "\\\"") ?? ""
        let hasURL = !(url ?? "").isEmpty

        if isSafari {
            if hasURL {
                return """
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then
                        make new document with properties {URL:"\(escapedURL)"}
                    else
                        tell window 1
                            set current tab to (make new tab with properties {URL:"\(escapedURL)"})
                        end tell
                    end if
                end tell
                """
            }
            // Blank tab in Safari — open a new empty document tab.
            return """
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document
                else
                    tell window 1
                        set current tab to (make new tab)
                    end tell
                end if
            end tell
            """
        }

        // Chromium family.
        if hasURL {
            return """
            tell application "\(applicationName)"
                activate
                if (count of windows) = 0 then
                    make new window
                end if
                tell window 1
                    make new tab with properties {URL:"\(escapedURL)"}
                end tell
            end tell
            """
        }
        return """
        tell application "\(applicationName)"
            activate
            if (count of windows) = 0 then
                make new window
            else
                tell window 1
                    make new tab
                end tell
            end if
        end tell
        """
    }

    /// Returns a two-item list {URL, title} of the active tab in the front window.
    func scriptForActiveTabInfo() -> String {
        if isSafari {
            return """
            tell application "Safari"
                get {URL of current tab of front window, name of current tab of front window}
            end tell
            """
        }
        return """
        tell application "\(applicationName)"
            get {URL of active tab of front window, title of active tab of front window}
        end tell
        """
    }

    func scriptForCloseActiveTab() -> String {
        if isSafari {
            return """
            tell application "Safari"
                close current tab of front window
            end tell
            """
        }
        return """
        tell application "\(applicationName)"
            close active tab of front window
        end tell
        """
    }

    func scriptForCloseAllTabs() -> String {
        // Same verb in both dialects. Closing the last tab closes the window too —
        // that's the expected outcome of "close all my tabs".
        return """
        tell application "\(applicationName)"
            close every tab of front window
        end tell
        """
    }

    func scriptForCloseOtherTabs() -> String {
        if isSafari {
            // Safari tabs are addressed by index; snapshot the current tab's index
            // and close the rest. AppleScript resolves the `whose` list before
            // closing, so shifting indices during the close don't skip tabs.
            return """
            tell application "Safari"
                tell front window
                    set keepIndex to index of current tab
                    close (every tab whose index is not keepIndex)
                end tell
            end tell
            """
        }
        // Chromium tabs carry a stable `id` — safer than index while tabs close.
        return """
        tell application "\(applicationName)"
            tell front window
                set keepId to id of active tab
                close (every tab whose id is not keepId)
            end tell
        end tell
        """
    }

    func scriptForCloseFrontWindow() -> String {
        // Both Safari and Chromium-family use `close front window` in AppleScript.
        return """
        tell application "\(applicationName)"
            close front window
        end tell
        """
    }

    func scriptForNextTab() -> String {
        if isSafari {
            // Safari doesn't expose a direct "next tab" verb in AppleScript;
            // use keyboard shortcut simulation via System Events instead.
            return """
            tell application "System Events"
                keystroke "}" using {command down, shift down}
            end tell
            """
        }
        // Chromium-family also lacks a direct AppleScript next-tab verb; use same shortcut.
        return """
        tell application "System Events"
            keystroke "}" using {command down, shift down}
        end tell
        """
    }

    func scriptForPreviousTab() -> String {
        if isSafari {
            return """
            tell application "System Events"
                keystroke "{" using {command down, shift down}
            end tell
            """
        }
        return """
        tell application "System Events"
            keystroke "{" using {command down, shift down}
        end tell
        """
    }
}
