//
//  AgentMacNativeTools.swift
//  Mac-native agent tools: AppleScript, opening browser tabs, screen capture.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - AppleScript

final class RunAppleScriptTool: BackgroundAgentTool {
    let name = "run_applescript"
    let description = """
    Run AppleScript to control Mac apps (Finder, Mail, Calendar, Safari, Notes, etc.). \
    Returns the script result as text. Use for native app automation.
    """

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script": [
                "type": "string",
                "description": "AppleScript source code to execute"
            ]
        ],
        "required": ["script"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let scriptSource = arguments["script"] as? String else {
            throw NSError(domain: "RunAppleScriptTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing 'script' argument"])
        }

        return try await Task.detached(priority: .userInitiated) {
            let appleScript = NSAppleScript(source: scriptSource)
            var errorInfo: NSDictionary?
            let outputDescriptor = appleScript?.executeAndReturnError(&errorInfo)

            if let errorInfo {
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
                throw NSError(domain: "RunAppleScriptTool", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }

            return outputDescriptor?.stringValue ?? "(no output)"
        }.value
    }
}

// ui_action (raw-coordinate clicks and global keystrokes) is gone. Drive replaces it:
// see Agent/Drive/DriveTools.swift.

// MARK: - Open Browser Tab

final class OpenBrowserTabTool: BackgroundAgentTool {
    let name = "open_browser_tab"
    let description = """
    Open a URL in the user's browser. Use for docs, download pages, GitHub, API references, \
    or any website. Optionally target Safari, Chrome, Arc, Brave, or Edge.
    """

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": [
                "type": "string",
                "description": "Full URL including https://"
            ],
            "browser": [
                "type": "string",
                "description": "Optional: Safari, Chrome, Arc, Brave, Edge. Defaults to system browser."
            ],
            "new_tab": [
                "type": "boolean",
                "description": "Open in a new tab when a specific browser is used. Default true."
            ]
        ],
        "required": ["url"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String else {
            throw NSError(domain: "OpenBrowserTabTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing 'url' argument"])
        }

        let normalizedURLString = normalizeURLString(urlString)
        guard URL(string: normalizedURLString) != nil else {
            throw NSError(domain: "OpenBrowserTabTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }

        let browserName = (arguments["browser"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let openInNewTab = arguments["new_tab"] as? Bool ?? true

        if let browserName, !browserName.isEmpty {
            let appleScript = appleScriptForOpeningURL(
                normalizedURLString,
                browserName: browserName,
                openInNewTab: openInNewTab
            )
            return try await Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: appleScript)
                var errorInfo: NSDictionary?
                script?.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
                    throw NSError(domain: "OpenBrowserTabTool", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: message])
                }
                return "Opened \(normalizedURLString) in \(browserName)"
            }.value
        }

        guard let url = URL(string: normalizedURLString) else {
            throw NSError(domain: "OpenBrowserTabTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        NSWorkspace.shared.open(url)
        return "Opened \(normalizedURLString) in default browser"
    }

    private func normalizeURLString(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func appleScriptForOpeningURL(
        _ urlString: String,
        browserName: String,
        openInNewTab: Bool
    ) -> String {
        let escapedURL = urlString.replacingOccurrences(of: "\"", with: "\\\"")
        let applicationName = resolvedBrowserApplicationName(browserName)

        if applicationName == "Safari" {
            if openInNewTab {
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
            return "tell application \"Safari\" to open location \"\(escapedURL)\""
        }

        // Chromium-based browsers (Chrome, Arc, Brave, Edge)
        if openInNewTab {
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
        return "tell application \"\(applicationName)\" to open location \"\(escapedURL)\""
    }

    private func resolvedBrowserApplicationName(_ browserName: String) -> String {
        let normalized = browserName.lowercased()
        if normalized.contains("safari") { return "Safari" }
        if normalized.contains("arc") { return "Arc" }
        if normalized.contains("brave") { return "Brave Browser" }
        if normalized.contains("edge") { return "Microsoft Edge" }
        if normalized.contains("firefox") { return "Firefox" }
        return "Google Chrome"
    }
}

// MARK: - Screen Capture

final class CaptureScreenTool: BackgroundAgentTool {
    let name = "capture_screen"
    let description = """
    Capture the user's screen(s) and save JPEGs to disk. Returns paths, dimensions, \
    frontmost app, and cursor screen info. Use to understand what's on screen before acting.
    """

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "primary_only": [
                "type": "boolean",
                "description": "If true, only capture the screen where the cursor is"
            ]
        ]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let richResult = try await executeReturningRichResult(arguments: arguments)
        return richResult.text
    }

    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult {
        let primaryOnly = arguments["primary_only"] as? Bool ?? true

        let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let selectedCaptures = primaryOnly
            ? captures.filter(\.isCursorScreen)
            : captures

        // While driving an app, look at the screen that app's window is on, not just the pointer's screen.
        var drivenWindowCapture: CompanionScreenCapture?
        if let job = AgentJobContext.current, let windowFrame = await job.drive.targetWindowFrameInGlobalCG, !windowFrame.isEmpty {
            let primaryDisplayHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
            let centerInAppKit = CGPoint(x: windowFrame.midX, y: primaryDisplayHeight - windowFrame.midY)
            drivenWindowCapture = captures.first { $0.displayFrame.contains(centerInAppKit) }
        }

        guard let primaryCapture = drivenWindowCapture
            ?? selectedCaptures.first(where: { $0.isCursorScreen })
            ?? selectedCaptures.first else {
            return .textOnly("No screen capture available")
        }

        let captureDirectory = agentCaptureDirectoryURL()
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)

        let fileName = "capture-\(ISO8601DateFormatter().string(from: Date()))-1.jpg"
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = captureDirectory.appendingPathComponent(fileName)
        try primaryCapture.imageData.write(to: fileURL)

        let dimensionInfo = " (image dimensions: \(primaryCapture.screenshotWidthInPixels)x\(primaryCapture.screenshotHeightInPixels) pixels, grid overlay: columns A-X, rows 1-16)"
        let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
            originalJPEGData: primaryCapture.imageData,
            screenshotWidthInPixels: primaryCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: primaryCapture.screenshotHeightInPixels
        ) ?? primaryCapture.imageData

        // Remember how this image maps onto its display, so a point named in its pixels
        // can be turned into the right place on the right screen (drive_click_point).
        var captureIDNote = ""
        if let job = AgentJobContext.current {
            let primaryDisplayHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
            let captureID = await job.drive.registerCapture(
                screenshotWidth: primaryCapture.screenshotWidthInPixels,
                screenshotHeight: primaryCapture.screenshotHeightInPixels,
                displayFrameInAppKitPoints: primaryCapture.displayFrame,
                primaryDisplayHeight: primaryDisplayHeight
            )
            captureIDNote = " capture_id: \(captureID)."
        }

        var textLines: [String] = []
        textLines.append(describeFrontmostApplicationForCapture())
        textLines.append(
            "\(primaryCapture.label) — saved to \(fileURL.path) (\(primaryCapture.screenshotWidthInPixels)x\(primaryCapture.screenshotHeightInPixels) px).\(captureIDNote) Current screen attached below."
        )

        return .withVisionImage(
            text: textLines.joined(separator: "\n"),
            visionImageJPEGData: annotatedImageData,
            visionImageLabel: primaryCapture.label + dimensionInfo
        )
    }

    private func agentCaptureDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teachy/AgentCaptures", isDirectory: true)
    }

    private func describeFrontmostApplicationForCapture() -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return "Frontmost app: unknown"
        }
        let appName = frontmostApplication.localizedName ?? frontmostApplication.bundleIdentifier ?? "Unknown"
        return "Frontmost app: \(appName)"
    }
}
