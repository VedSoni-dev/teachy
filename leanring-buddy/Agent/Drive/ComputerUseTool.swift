//
//  ComputerUseTool.swift
//  leanring-buddy
//
//  `computer`: real computer use. The agent sees a screenshot and moves the
//  person's actual pointer and keyboard anywhere on screen: click, double
//  click, right click, drag, type, key combos, scroll. This is the same action
//  set open-source computer-use agents use (Anthropic's computer-use tool
//  schema, which trycua/cua, open-computer-use and others follow), built
//  directly on CGEvent so it needs nothing beyond the Accessibility and Screen
//  Recording permissions Teachy already has.
//
//  Drive (drive_*) stays the first choice inside one app: it is exact and
//  leaves the pointer alone. `computer` is for everything Drive cannot reach:
//  canvases, games, custom controls, web pages without the extension,
//  dragging between apps, the Dock and the menu bar extras.
//
//  Safety, same as Drive:
//  - Every call goes through the permission gate (ToolPolicy.classifyComputer),
//    judged by the app under the point or the app in front.
//  - The takeover watch runs while it acts: Escape, a click or moving the
//    mouse stops the job. Teachy's own events carry Drive's marker so they
//    are not mistaken for the person.
//  - Typing into a password / secure field hands back to the person.
//

import AppKit
import ApplicationServices

enum ComputerUseGuide {
    static let text = """
    COMPUTER USE (the computer tool):
    - computer moves the person's real mouse and keyboard anywhere on screen. Use it when drive_* cannot reach something (canvases, custom controls, drag and drop, web pages when the browser tools are not available, the Dock, menu bar extras), or when a drive_ action did nothing.
    - Look first: computer(action: "screenshot") returns the screen with a capture_id. Give x and y in that screenshot's pixels, together with its capture_id. Take a new screenshot after every action or two to check it worked; never act blind for long.
    - Actions: screenshot, click (button left/right/middle, clicks 1-3), move, drag (x,y to to_x,to_y), type (text into whatever has focus; click the field first), key ("cmd+s", "return", "escape", "tab"), scroll (direction up/down/left/right, amount 1-10, at x,y), wait (seconds), cursor_position.
    - To open an app use control_app; to go to a URL prefer the browser tools or key "cmd+l" then type then key "return".
    - Password, verification-code and card fields are the person's to type. If the result says so, stop and tell them.
    - The person can press Escape or move the mouse to take over; then you stop.
    """
}

final class ComputerUseTool: BackgroundAgentTool {
    let name = "computer"
    let description = """
    Use the person's real mouse and keyboard anywhere on screen, like a person sitting at the Mac. \
    action: screenshot | click | move | drag | type | key | scroll | wait | cursor_position. \
    Points are x,y pixels in a screenshot plus that screenshot's capture_id (screenshot returns one). \
    Prefer drive_* inside one app and browser tools on websites; use this when those cannot do it.
    """
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["screenshot", "click", "move", "drag", "type", "key", "scroll", "wait", "cursor_position"]],
            "x": ["type": "number", "description": "Pixels from the left of the screenshot."],
            "y": ["type": "number", "description": "Pixels from the top of the screenshot."],
            "capture_id": ["type": "string", "description": "The capture_id of the screenshot x,y come from."],
            "to_x": ["type": "number", "description": "drag: where to drop, screenshot pixels."],
            "to_y": ["type": "number", "description": "drag: where to drop, screenshot pixels."],
            "button": ["type": "string", "enum": ["left", "right", "middle"], "description": "click: which button. Default left."],
            "clicks": ["type": "integer", "description": "click: 1, 2 (double) or 3 (triple). Default 1."],
            "modifiers": ["type": "string", "description": "click/drag: keys held, e.g. \"cmd\" or \"shift+option\"."],
            "text": ["type": "string", "description": "type: the text to type into the focused field."],
            "key": ["type": "string", "description": "key: a combo like \"cmd+s\", \"return\", \"escape\"."],
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "scroll direction."],
            "amount": ["type": "integer", "description": "scroll: 1-10 notches. Default 3."],
            "seconds": ["type": "number", "description": "wait: 0.1-10 seconds. Default 1."]
        ],
        "required": ["action"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        try await executeReturningRichResult(arguments: arguments).text
    }

    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult {
        guard let job = AgentJobContext.current else {
            throw DriveError("computer only works inside an agent job.")
        }
        let action = ToolPolicy.string(arguments["action"]).lowercased()
        switch action {
        case "screenshot":
            return try await CaptureScreenTool().executeReturningRichResult(arguments: ["primary_only": true])
        case "cursor_position":
            let location = CGEvent(source: nil)?.location ?? .zero
            return .textOnly("The pointer is at global point (\(Int(location.x)), \(Int(location.y))). Take a screenshot to see it in screenshot pixels.")
        case "wait":
            let seconds = max(0.1, min(DriveSession.double(arguments["seconds"]) ?? 1, 10))
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .textOnly("Waited \(String(format: "%.1f", seconds)) s. Take a screenshot to see what changed.")
        default:
            break
        }

        guard AXIsProcessTrusted() else {
            throw DriveError("Teachy needs Accessibility permission (System Settings > Privacy & Security > Accessibility) before it can use the mouse and keyboard. Tell the person.")
        }
        guard await job.drive.beginComputerUse() else {
            throw DriveError("Teachy could not start watching for Escape and mouse movement, so it will not take the mouse. Another job may be driving; try again when it finishes.")
        }
        try Task.checkCancellation()

        let line: String
        switch action {
        case "click":
            let point = try await job.drive.globalPoint(arguments: arguments, xKey: "x", yKey: "y")
            let button = ToolPolicy.string(arguments["button"]).lowercased()
            let clicks = max(1, min(DriveSession.int(arguments["clicks"]) ?? 1, 3))
            let flags = ComputerEvents.flags(from: ToolPolicy.string(arguments["modifiers"]))
            await ComputerEvents.click(at: point, button: button, clicks: clicks, flags: flags)
            line = "\(clicks == 2 ? "double-" : clicks == 3 ? "triple-" : "")\(button.isEmpty ? "left" : button)-clicked at \(Self.label(arguments))"
        case "move":
            let point = try await job.drive.globalPoint(arguments: arguments, xKey: "x", yKey: "y")
            ComputerEvents.move(to: point)
            line = "moved the pointer to \(Self.label(arguments))"
        case "drag":
            let start = try await job.drive.globalPoint(arguments: arguments, xKey: "x", yKey: "y")
            let end = try await job.drive.globalPoint(arguments: arguments, xKey: "to_x", yKey: "to_y")
            let flags = ComputerEvents.flags(from: ToolPolicy.string(arguments["modifiers"]))
            await ComputerEvents.drag(from: start, to: end, flags: flags)
            line = "dragged from \(Self.label(arguments)) to (\(Int(DriveSession.double(arguments["to_x"]) ?? 0)), \(Int(DriveSession.double(arguments["to_y"]) ?? 0)))"
        case "type":
            let text = ToolPolicy.string(arguments["text"])
            guard !text.isEmpty else { throw DriveError("type needs text.") }
            if let reason = ComputerEvents.secureFieldReason() {
                throw DriveHandBack(spokenLine: "\(reason), so that part is yours to type. Tell me when it's done.")
            }
            await ComputerEvents.type(text)
            line = "typed \(text.count) characters"
        case "key":
            let comboText = ToolPolicy.string(arguments["key"])
            guard let combo = DriveKeyCombo.parse(comboText) else {
                throw DriveError("\"\(comboText)\" is not a key combo Teachy knows. Use forms like cmd+s, return, escape, tab, up, f5.")
            }
            ComputerEvents.press(combo)
            line = "pressed \(combo.display)"
        case "scroll":
            let point: CGPoint
            if arguments["x"] != nil {
                point = try await job.drive.globalPoint(arguments: arguments, xKey: "x", yKey: "y")
            } else {
                point = CGEvent(source: nil)?.location ?? .zero
            }
            let direction = ToolPolicy.string(arguments["direction"]).lowercased()
            guard ["up", "down", "left", "right"].contains(direction) else { throw DriveError("scroll needs direction up, down, left or right.") }
            let amount = max(1, min(DriveSession.int(arguments["amount"]) ?? 3, 10))
            await ComputerEvents.scroll(at: point, direction: direction, notches: amount)
            line = "scrolled \(direction) \(amount) at \(arguments["x"] != nil ? Self.label(arguments) : "the pointer")"
        default:
            throw DriveError("Unknown action \"\(action)\". Use screenshot, click, move, drag, type, key, scroll, wait or cursor_position.")
        }
        await DriveTakeoverMonitor.shared.noteOwnPointerMovement(jobID: job.id)

        // Let the screen settle, then show the model the result so it checks its work.
        try await Task.sleep(nanoseconds: 450_000_000)
        try Task.checkCancellation()
        let after = try await CaptureScreenTool().executeReturningRichResult(arguments: ["primary_only": true])
        return AgentToolResult(
            text: "Done: \(line). The screen now:\n" + after.text,
            visionImageJPEGData: after.visionImageJPEGData,
            visionImageLabel: after.visionImageLabel
        )
    }

    private static func label(_ arguments: [String: Any]) -> String {
        let x = Int(DriveSession.double(arguments["x"]) ?? 0)
        let y = Int(DriveSession.double(arguments["y"]) ?? 0)
        return "(\(x), \(y)) of \(ToolPolicy.string(arguments["capture_id"]))"
    }
}

/// Real HID-level events. They move the person's pointer, like a hand on the mouse.
enum ComputerEvents {
    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: DriveSession.syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    static func flags(from text: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "," }) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    static func move(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        post(event)
    }

    static func click(at point: CGPoint, button: String, clicks: Int, flags: CGEventFlags) async {
        let (downType, upType, mouseButton): (CGEventType, CGEventType, CGMouseButton) = {
            switch button {
            case "right": return (.rightMouseDown, .rightMouseUp, .right)
            case "middle": return (.otherMouseDown, .otherMouseUp, .center)
            default: return (.leftMouseDown, .leftMouseUp, .left)
            }
        }()
        move(to: point)
        try? await Task.sleep(nanoseconds: 60_000_000)
        for clickNumber in 1...clicks {
            for type in [downType, upType] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
                event.flags = flags
                post(event)
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint, flags: CGEventFlags) async {
        move(to: start)
        try? await Task.sleep(nanoseconds: 60_000_000)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) {
            down.flags = flags
            post(down)
        }
        // Move in steps: many apps only start a drag after several dragged events.
        let steps = 20
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            if let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                dragged.flags = flags
                post(dragged)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            up.flags = flags
            post(up)
        }
    }

    static func type(_ text: String) async {
        let units = Array(text.utf16)
        var offset = 0
        while offset < units.count {
            var end = min(offset + 16, units.count)
            // Do not split a surrogate pair across two events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[offset..<end])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
            try? await Task.sleep(nanoseconds: 12_000_000)
            offset = end
        }
    }

    static func press(_ combo: DriveKeyCombo) {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            post(event)
            usleep(15_000)
        }
    }

    static func scroll(at point: CGPoint, direction: String, notches: Int) async {
        move(to: point)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let lines: Int32 = 3
        let deltaY: Int32 = direction == "down" ? -lines : (direction == "up" ? lines : 0)
        let deltaX: Int32 = direction == "right" ? -lines : (direction == "left" ? lines : 0)
        for _ in 0..<notches {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else { continue }
            event.location = point
            post(event)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Why typing must hand back, or nil. Looks at the focused element system-wide.
    static func secureFieldReason() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = AXRead.element(systemWide, kAXFocusedUIElementAttribute as String) else { return nil }
        let role = AXRead.string(focused, kAXRoleAttribute as String)
        let subrole = AXRead.string(focused, kAXSubroleAttribute as String)
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return "The cursor is in a password field" }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .map { AXRead.string(focused, $0 as String) }
            .joined(separator: " ")
            .lowercased()
        if let word = SecretFieldDetector.fieldWords.first(where: { label.contains($0) }) {
            return "The field in front asks for a \(word)"
        }
        return nil
    }

    /// The app that would receive this pointer action: the frontmost normal window under the
    /// point. Teachy's own small panels (notch, cards) count as Teachy; its full-screen,
    /// click-through overlay does not.
    @MainActor
    static func appUnder(globalPoint point: CGPoint) -> (name: String, bundleID: String)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let screenAreas = NSScreen.screens.map { $0.frame.width * $0.frame.height }
        for window in windows {
            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.05 { continue }
            if pid == ownPID {
                // The cursor overlay covers a whole screen and lets clicks through: look past it.
                if screenAreas.contains(where: { bounds.width * bounds.height >= $0 * 0.9 }) { continue }
                return ("Teachy", Bundle.main.bundleIdentifier ?? "")
            }
            let application = NSRunningApplication(processIdentifier: pid)
            let name = application?.localizedName ?? (window[kCGWindowOwnerName as String] as? String) ?? ""
            return (name, application?.bundleIdentifier ?? "")
        }
        return nil
    }
}
