//
//  AgentMacNativeTools.swift
//  Mac-native agent tools: AppleScript, UI automation, screen capture.
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

// MARK: - UI Actions

final class UIActionTool: BackgroundAgentTool {
    let name = "ui_action"
    let description = """
    Control the Mac UI. Actions: click (x,y screen coords), type (text into frontmost app), \
    key_press (e.g. return, escape, cmd+c), frontmost_app (returns active app and window title). \
    Requires Accessibility permission.
    """

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["click", "type", "key_press", "frontmost_app"],
                "description": "The UI action to perform"
            ],
            "x": ["type": "number", "description": "X coordinate for click (Quartz/global screen space)"],
            "y": ["type": "number", "description": "Y coordinate for click (Quartz/global screen space)"],
            "text": ["type": "string", "description": "Text to type for the type action"],
            "key": ["type": "string", "description": "Key name for key_press (return, tab, escape, cmd+c, etc.)"]
        ],
        "required": ["action"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard WindowPositionManager.hasAccessibilityPermission() else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Accessibility permission required for ui_action"])
        }

        guard let actionName = arguments["action"] as? String else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing 'action' argument"])
        }

        switch actionName {
        case "click":
            return try performClick(arguments: arguments)
        case "type":
            return try performType(arguments: arguments)
        case "key_press":
            return try performKeyPress(arguments: arguments)
        case "frontmost_app":
            return describeFrontmostApplication()
        default:
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(actionName)"])
        }
    }

    private func performClick(arguments: [String: Any]) throws -> String {
        guard let xNumber = arguments["x"] as? NSNumber,
              let yNumber = arguments["y"] as? NSNumber else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "click requires x and y"])
        }

        let clickPoint = CGPoint(x: xNumber.doubleValue, y: yNumber.doubleValue)
        let source = CGEventSource(stateID: .hidSystemState)

        guard let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                      mouseCursorPosition: clickPoint, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                    mouseCursorPosition: clickPoint, mouseButton: .left) else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create mouse events"])
        }

        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        return "Clicked at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))"
    }

    private func performType(arguments: [String: Any]) throws -> String {
        guard let text = arguments["text"] as? String else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "type requires text"])
        }

        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            let unicodeScalars = Array(String(character).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            keyDown.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
            keyUp.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        return "Typed \(text.count) characters"
    }

    private func performKeyPress(arguments: [String: Any]) throws -> String {
        guard let keyName = arguments["key"] as? String else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "key_press requires key"])
        }

        let (virtualKeyCode, flags) = try virtualKeyAndFlags(forKeyName: keyName.lowercased())
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyCode, keyDown: false) else {
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create key events"])
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return "Pressed \(keyName)"
    }

    private func virtualKeyAndFlags(forKeyName keyName: String) throws -> (CGKeyCode, CGEventFlags) {
        if keyName.contains("cmd+") || keyName.contains("command+") {
            let parts = keyName.replacingOccurrences(of: "command+", with: "cmd+").split(separator: "+")
            guard parts.count == 2 else {
                throw NSError(domain: "UIActionTool", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid shortcut: \(keyName)"])
            }
            let (baseKey, _) = try virtualKeyAndFlags(forKeyName: String(parts[1]))
            return (baseKey, .maskCommand)
        }

        switch keyName {
        case "return", "enter": return (36, [])
        case "tab": return (48, [])
        case "escape", "esc": return (53, [])
        case "space": return (49, [])
        case "delete", "backspace": return (51, [])
        case "up": return (126, [])
        case "down": return (125, [])
        case "left": return (123, [])
        case "right": return (124, [])
        default:
            if let firstCharacter = keyName.first, keyName.count == 1 {
                let uppercased = String(firstCharacter).uppercased()
                if let scalar = uppercased.unicodeScalars.first {
                    let keyMap: [UnicodeScalar: CGKeyCode] = [
                        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
                        "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
                        "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
                        "Y": 16, "Z": 6
                    ]
                    if let keyCode = keyMap[scalar] {
                        return (keyCode, [])
                    }
                }
            }
            throw NSError(domain: "UIActionTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown key: \(keyName)"])
        }
    }

    private func describeFrontmostApplication() -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application"
        }

        let appName = frontmostApplication.localizedName ?? frontmostApplication.bundleIdentifier ?? "Unknown"
        var windowTitle = ""

        let appElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
           let focusedWindow = focusedWindowValue {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                windowTitle = title
            }
        }

        if windowTitle.isEmpty {
            return "Frontmost app: \(appName)"
        }
        return "Frontmost app: \(appName) — window: \(windowTitle)"
    }
}

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

        guard let primaryCapture = selectedCaptures.first(where: { $0.isCursorScreen })
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

        var textLines: [String] = []
        textLines.append(describeFrontmostApplicationForCapture())
        textLines.append(
            "\(primaryCapture.label) — saved to \(fileURL.path) (\(primaryCapture.screenshotWidthInPixels)x\(primaryCapture.screenshotHeightInPixels) px). Current screen attached below."
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
