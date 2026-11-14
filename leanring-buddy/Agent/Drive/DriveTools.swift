//
//  DriveTools.swift
//  leanring-buddy
//
//  The Drive tools the model calls. Thin wrappers: each finds the running job's
//  DriveSession and calls it. The permission gate (AgentToolRegistry.invoke) has
//  already classified and, where needed, asked the user before execute runs.
//

import Foundation

private func currentDriveSession() throws -> DriveSession {
    guard let job = AgentJobContext.current else {
        throw DriveError("Drive tools only work inside an agent job.")
    }
    return job.drive
}

enum DriveToolGuide {
    /// Added to the system prompt whenever Drive tools are on offer.
    static let text = """
    DRIVING AN APP (drive_* tools):
    - Teachy asks the user for permission itself, in its own window, the moment a tool needs it. Never ask for permission in your reply and never tell the user to approve something: just call the tool. If a tool result says the user said not now, or that it is blocked, do not try it again or work around it.
    - Work in ONE app at a time. Start with drive_snapshot (optionally naming the app). It lists the controls in that app's front window as lines like: [12] button "Export…".
    - Act by number: drive_press(index), drive_set_text(index, text), drive_scroll(index, direction). Use drive_menu(["File", "Export…"]) for menu bar commands and drive_key("cmd+s") for shortcuts.
    - Every action returns what changed (new controls, changed values, a new window title). Read it and confirm the step worked before the next one. If it says nothing changed, look again (drive_snapshot or capture_screen) instead of repeating the action.
    - drive_click_point is the LAST resort, for things the snapshot does not list (canvases, custom controls). Give x and y in the pixels of a screenshot you were shown, plus that screenshot's capture_id; or give index to click the middle of a listed control.
    - Password, verification-code and card fields are the user's to fill in. Teachy stops by itself when one shows up.
    - The user can press Escape or move the mouse to take the app back at any time; then you stop.
    """
}

final class DriveSnapshotTool: BackgroundAgentTool {
    let name = "drive_snapshot"
    let description = """
    Read the controls in one app's front window through accessibility: buttons, fields, links, menus, text, including web page content. \
    Returns numbered lines like [12] button "Export…". Call this before any other drive_ tool, and again whenever you need the full list. \
    Leave app empty for the app in front (or the app you are already working in).
    """
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "app": ["type": "string", "description": "Optional app name, e.g. \"Preview\". Must already be running."]
        ]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await currentDriveSession().snapshot(appName: app?.isEmpty == false ? app : nil)
    }
}

final class DrivePressTool: BackgroundAgentTool {
    let name = "drive_press"
    let description = "Press a control (button, link, checkbox, tab, menu item, popup) by its [number] from the latest drive_snapshot. Does not move the user's pointer. Returns what changed."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "index": ["type": "integer", "description": "The [number] of the control."]
        ],
        "required": ["index"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let index = DriveSession.int(arguments["index"]) else { throw DriveError("drive_press needs index.") }
        return try await currentDriveSession().press(index: index)
    }
}

final class DriveSetTextTool: BackgroundAgentTool {
    let name = "drive_set_text"
    let description = "Replace the text of a text field or text area by its [number]. Teachy reads the field back and tells you whether the text really landed. Never for passwords or codes."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "index": ["type": "integer", "description": "The [number] of the field."],
            "text": ["type": "string", "description": "The full text the field should hold."]
        ],
        "required": ["index", "text"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let index = DriveSession.int(arguments["index"]) else { throw DriveError("drive_set_text needs index.") }
        guard let text = arguments["text"] as? String else { throw DriveError("drive_set_text needs text.") }
        return try await currentDriveSession().setText(index: index, text: text)
    }
}

final class DriveMenuTool: BackgroundAgentTool {
    let name = "drive_menu"
    let description = "Choose a command from the app's menu bar by its titles, e.g. [\"File\", \"Export…\"] or [\"Tools\", \"Adjust Size…\"]. More reliable than clicking. Returns what changed."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Menu titles from the menu bar down to the command."
            ]
        ],
        "required": ["path"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let path = (arguments["path"] as? [Any])?.compactMap { $0 as? String } ?? []
        return try await currentDriveSession().chooseMenu(path: path)
    }
}

final class DriveKeyTool: BackgroundAgentTool {
    let name = "drive_key"
    let description = "Press a key or shortcut in the app you are driving (sent to that app only). Examples: return, tab, escape, cmd+s, cmd+shift+z, option+left."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "combo": ["type": "string", "description": "Key or shortcut, parts joined with +."]
        ],
        "required": ["combo"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let combo = arguments["combo"] as? String else { throw DriveError("drive_key needs combo.") }
        return try await currentDriveSession().pressKey(combo: combo)
    }
}

final class DriveScrollTool: BackgroundAgentTool {
    let name = "drive_scroll"
    let description = "Scroll the area that holds a control (by [number]), or the window when index is left out. direction: up, down, left, right."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "index": ["type": "integer", "description": "A control inside the area to scroll. Optional."],
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
            "pages": ["type": "number", "description": "How far, in rough pages. Default 1."]
        ],
        "required": ["direction"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let direction = arguments["direction"] as? String else { throw DriveError("drive_scroll needs direction.") }
        return try await currentDriveSession().scroll(
            index: DriveSession.int(arguments["index"]),
            direction: direction,
            pages: DriveSession.double(arguments["pages"]) ?? 1
        )
    }
}

final class DriveClickPointTool: BackgroundAgentTool {
    let name = "drive_click_point"
    let description = """
    LAST RESORT click for things drive_snapshot does not list. Either give index (clicks the middle of that control), or x and y in the PIXELS of a screenshot \
    you were shown plus that screenshot's capture_id, so Teachy can map the point to the right screen. Only clicks inside the app you are driving. Does not move the user's pointer.
    """
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "x": ["type": "number", "description": "X in screenshot pixels (0 = left edge of that image)."],
            "y": ["type": "number", "description": "Y in screenshot pixels (0 = top edge of that image)."],
            "capture_id": ["type": "string", "description": "The id of the screenshot the x,y came from, e.g. cap-2."],
            "index": ["type": "integer", "description": "Instead of x,y: the [number] of a listed control."]
        ]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        try await currentDriveSession().clickPoint(arguments: arguments)
    }
}
