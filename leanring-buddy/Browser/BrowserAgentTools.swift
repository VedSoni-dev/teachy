//
//  BrowserAgentTools.swift
//  leanring-buddy
//
//  The browser tools the agent calls: browser_open, browser_read, browser_click,
//  browser_type, browser_select, browser_key, browser_scroll, browser_navigate,
//  browser_wait, browser_screenshot, browser_upload, browser_close_job.
//
//  Thin adapters over BrowserBridge. Like every tool, they only run through
//  BackgroundAgentToolRegistry.invoke, so the permission gate has already
//  classified the call (BrowserRiskClassifier) and asked the person if needed.
//
//  Two rules are enforced below this layer, in the extension itself, whatever
//  the model asks for: password / verification-code / card fields are never
//  typed into or read, and no file is attached without a consent token that is
//  minted here, after the gate said yes, for that one path.
//

import AppKit
import Foundation

enum BrowserToolGuide {
    /// Added to the agent's system prompt whenever the browser tools are on offer.
    static let text = """
    WORKING IN THE PERSON'S BROWSER (browser_* tools):
    - These work inside the person's own Chrome (or Edge, Brave, Arc, Vivaldi), signed in as them, in a tab group named after this job. Prefer them over drive_* and over screenshots whenever the task is on a website: they read the page as text, act on exact controls, work in the background without taking the person's mouse, and tell you what changed. Use web_fetch or web_search instead when a public page only needs reading and no sign-in. Use drive_* for Mac apps, and for the browser's own window furniture (bookmarks bar, settings, downloads), which browser_* cannot see.
    - Start with browser_open(url). It returns the page's text and its controls as numbered lines like [12] button "Add to cart". Act by number: browser_click(index), browser_type(index, text), browser_select(index, option), browser_key("Enter"), browser_scroll(direction or index). Numbers stay the same while the page stays; a new page gets new numbers, listed in the result.
    - Every action returns what changed (new controls, changed values, a new address or title). Read it and confirm the step worked before the next one. If nothing changed, look again with browser_read or browser_screenshot instead of repeating the action. Use browser_wait for things that take time to appear.
    - Teachy asks the person for permission itself, the first time a job acts on a site and every time for buying, paying, sending, posting, deleting and uploading. Never ask for permission in your reply; just call the tool. If the result says the person said not now, do not retry or work around it.
    - Passwords, verification codes and card or bank numbers are the person's to type. If a tool result says a field needs the person, stop, tell them exactly which field to fill in the browser tab, and wait for them to say it is done. Never try to fill it another way.
    - The person can press Escape on the page, click the Teachy button in the toolbar, or cancel Chrome's debugging bar to take the browser back; then you stop.
    - When the job ends, the tabs you opened along the way close by themselves; the page you finished on stays open for the person. If they should not be left with a page, call browser_close_job with keep_current_tab false.
    """
}

@MainActor
private func currentBrowserJob() throws -> (id: String, title: String) {
    guard let job = AgentJobContext.current else {
        throw BrowserToolError("Browser tools only work inside an agent job.")
    }
    return (job.id, job.title)
}

/// One browser tool. `browserRisk` is its class before the page and the control are looked at;
/// `browserRisk(arguments:context:)` is the full verdict the permission gate uses.
final class BrowserAgentTool: BackgroundAgentTool {
    typealias Handler = @MainActor (_ arguments: [String: Any], _ job: (id: String, title: String)) async throws -> AgentToolResult

    let name: String
    let description: String
    let jsonSchema: [String: Any]
    private let handler: Handler

    var browserRisk: BrowserRisk { BrowserRiskClassifier.baseRisk(forTool: name) }

    func browserRisk(arguments: [String: Any], context: BrowserRiskContext) -> BrowserRiskDecision {
        BrowserRiskClassifier.classify(toolName: name, arguments: arguments, context: context)
    }

    init(name: String, description: String, properties: [String: Any], required: [String] = [], handler: @escaping Handler) {
        self.name = name
        self.description = description
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        self.jsonSchema = schema
        self.handler = handler
    }

    func execute(arguments: [String: Any]) async throws -> String {
        try await executeReturningRichResult(arguments: arguments).text
    }

    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult {
        return try await handler(arguments, try currentBrowserJob())
    }
}

enum BrowserAgentTools {
    /// Register these with the agent's tool registry.
    static var all: [BrowserAgentTool] {
        [open, read, click, type, select, key, scroll, navigate, wait, screenshot, upload, closeJob]
    }

    private static let tabProperty: [String: Any] = [
        "type": "integer",
        "description": "Which of the job's tabs. Leave out for the tab you used last."
    ]
    private static let indexProperty: [String: Any] = [
        "type": "integer",
        "description": "The [number] of the control, from the latest read or result."
    ]

    // MARK: Argument and result helpers

    static func integer(_ value: Any?) -> Int? { BrowserBridge.integer(value) }

    static func text(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func base(_ arguments: [String: Any], needsIndex: Bool = false) throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let tab = integer(arguments["tab"]) { params["tab"] = tab }
        if let index = integer(arguments["index"]) {
            params["index"] = index
        } else if needsIndex {
            throw BrowserToolError("Give index: the [number] of the control from the latest browser_read.")
        }
        return params
    }

    /// When the extension handed a private field back: the words that make the model stop and ask.
    static func needsUserText(_ result: [String: Any]) -> String? {
        guard let need = result["needs_user"] as? [String: Any] else { return nil }
        let what = need["what"] as? String ?? "private"
        let field = (need["field"] as? String).flatMap { $0.isEmpty ? nil : "\"\($0)\"" } ?? "that field"
        let number = integer(need["index"]).map { " [\($0)]" } ?? ""
        return """
        STOP: \(field)\(number) is a \(what) field. Teachy never types or reads passwords, verification codes or card and bank details, and nothing was typed. \
        Ask the person to type it themselves in the browser tab, and wait until they say it is done before you continue. Do not try to fill it any other way.
        """
    }

    static func describePage(_ result: [String: Any], heading: String) -> String {
        var lines: [String] = [heading]
        let title = result["title"] as? String ?? ""
        let url = result["url"] as? String ?? ""
        if let tab = integer(result["tab"]) { lines.append("Tab \(tab): \(title.isEmpty ? "(no title)" : title)") }
        if !url.isEmpty { lines.append(url) }
        if let scroll = result["scroll"] as? [String: Any],
           let y = integer(scroll["y"]), let height = integer(scroll["height"]), let viewport = integer(scroll["viewport"]), height > viewport + 40 {
            lines.append("Scrolled to \(y) of \(max(0, height - viewport)).")
        }
        let body = result["text"] as? String ?? ""
        if !body.isEmpty {
            lines.append("")
            lines.append("TEXT")
            lines.append(body)
        }
        let outline = result["outline"] as? String ?? ""
        lines.append("")
        lines.append("CONTROLS")
        lines.append(outline.isEmpty ? "(none found)" : outline)
        return lines.joined(separator: "\n")
    }

    static func describeAction(_ result: [String: Any], did: String) -> String {
        if let need = needsUserText(result) { return need }
        var lines = [did]
        if let diff = result["diff"] as? String, !diff.isEmpty { lines.append(diff) }
        return lines.joined(separator: "\n")
    }

    /// A standard baseline JPEG for the model, whatever the browser produced, no wider than `maxWidth`.
    static func normalizedJPEG(from data: Data, maxWidth: CGFloat = 1400) -> Data? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        var rep = source
        let width = CGFloat(source.pixelsWide)
        if width > maxWidth, source.pixelsWide > 0, let image = source.cgImage {
            let scale = maxWidth / width
            let newWidth = Int(maxWidth)
            let newHeight = max(1, Int(CGFloat(source.pixelsHigh) * scale))
            if let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
                if let scaled = context.makeImage() { rep = NSBitmapImageRep(cgImage: scaled) }
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    // MARK: The tools

    static let open = BrowserAgentTool(
        name: "browser_open",
        description: """
        Open a web page in the person's own browser, signed in as them, in this job's tab group, and read it. \
        Returns the page's main text and its controls as numbered lines like [12] button "Add to cart". \
        Set current_tab to work in the tab the person has open instead of opening a new one.
        """,
        properties: [
            "url": ["type": "string", "description": "The address, starting with https:// or http://."],
            "current_tab": ["type": "boolean", "description": "true: use the tab the person is looking at (it goes back where it was when the job ends)."]
        ]
    ) { arguments, job in
        var params: [String: Any] = [:]
        let url = text(arguments["url"])
        if arguments["current_tab"] as? Bool == true {
            params["borrow"] = "active"
        } else if url.isEmpty {
            throw BrowserToolError("Give url, or set current_tab to true.")
        } else {
            params["url"] = url.contains("://") ? url : "https://" + url
        }
        let opened = try await BrowserBridge.shared.call("open_tab", params: params, jobID: job.id, jobTitle: job.title, timeout: 35)
        var readParams: [String: Any] = ["max_chars": 6000]
        if let tab = integer(opened["tab"]) { readParams["tab"] = tab }
        let page = try await BrowserBridge.shared.call("read_page", params: readParams, jobID: job.id, jobTitle: job.title, timeout: 20)
        let loaded = opened["loaded"] as? Bool ?? true
        let heading = (opened["borrowed"] as? Bool == true ? "Working in the person's tab." : "Opened in the \"\(job.title)\" tab group.")
            + (loaded ? "" : " The page is still loading; use browser_wait if something is missing.")
        return .textOnly(describePage(page, heading: heading))
    }

    static let read = BrowserAgentTool(
        name: "browser_read",
        description: "Read the job's tab again: address, title, the page's main text, and its controls as numbered lines. Use it after the page changed a lot, or to see more text.",
        properties: [
            "tab": tabProperty,
            "max_chars": ["type": "integer", "description": "How much page text to return. Default 12000."]
        ]
    ) { arguments, job in
        var params = try base(arguments)
        if let limit = integer(arguments["max_chars"]), limit > 0 { params["max_chars"] = min(limit, 60000) }
        let page = try await BrowserBridge.shared.call("read_page", params: params, jobID: job.id, jobTitle: job.title, timeout: 20)
        return .textOnly(describePage(page, heading: "Read the page."))
    }

    static let click = BrowserAgentTool(
        name: "browser_click",
        description: "Click a control on the page by its [number]. Returns what changed. For a file chooser use browser_upload instead.",
        properties: [
            "index": indexProperty,
            "tab": tabProperty,
            "accept_dialogs": ["type": "boolean", "description": "If this click makes the page ask an OK / Cancel question, answer OK. Default: Cancel."]
        ],
        required: ["index"]
    ) { arguments, job in
        var params = try base(arguments, needsIndex: true)
        if arguments["accept_dialogs"] as? Bool == true { params["accept_dialogs"] = true }
        let result = try await BrowserBridge.shared.call("click", params: params, jobID: job.id, jobTitle: job.title, timeout: 30)
        return .textOnly(describeAction(result, did: "Clicked \(result["clicked"] as? String ?? "the control")."))
    }

    static let type = BrowserAgentTool(
        name: "browser_type",
        description: """
        Type text into a field by its [number]. Replaces what is there unless clear is false. Set submit to press Return afterwards. \
        Password, verification-code and card fields are refused: the person types those.
        """,
        properties: [
            "index": indexProperty,
            "text": ["type": "string", "description": "The text to type."],
            "clear": ["type": "boolean", "description": "false: add to what is already in the field. Default true (replace)."],
            "submit": ["type": "boolean", "description": "true: press Return after typing."],
            "tab": tabProperty
        ],
        required: ["index", "text"]
    ) { arguments, job in
        var params = try base(arguments, needsIndex: true)
        guard let typed = arguments["text"] as? String else { throw BrowserToolError("Give text: what to type.") }
        params["text"] = typed
        if arguments["clear"] as? Bool == false { params["clear"] = false }
        if arguments["submit"] as? Bool == true { params["submit"] = true }
        let result = try await BrowserBridge.shared.call("type", params: params, jobID: job.id, jobTitle: job.title, timeout: 30)
        let submitted = result["submitted"] as? Bool == true ? " and pressed Return" : ""
        return .textOnly(describeAction(result, did: "Typed \(typed.count) characters\(submitted)."))
    }

    static let select = BrowserAgentTool(
        name: "browser_select",
        description: "Pick an option in a drop-down list (a combobox line) by the option's text. For custom menus, click them open and click the option instead.",
        properties: [
            "index": indexProperty,
            "option": ["type": "string", "description": "The visible text of the option."],
            "tab": tabProperty
        ],
        required: ["index", "option"]
    ) { arguments, job in
        var params = try base(arguments, needsIndex: true)
        let option = text(arguments["option"])
        guard !option.isEmpty else { throw BrowserToolError("Give option: the text of the option to pick.") }
        params["option"] = option
        let result = try await BrowserBridge.shared.call("select", params: params, jobID: job.id, jobTitle: job.title, timeout: 25)
        return .textOnly(describeAction(result, did: "Chose \"\(result["selected"] as? String ?? option)\"."))
    }

    static let key = BrowserAgentTool(
        name: "browser_key",
        description: "Press a key or shortcut in the page, e.g. \"Enter\", \"Tab\", \"Escape\", \"ArrowDown\", \"cmd+a\". It goes to whatever has focus (click a field first).",
        properties: [
            "combo": ["type": "string", "description": "The key, with modifiers joined by +."],
            "tab": tabProperty
        ],
        required: ["combo"]
    ) { arguments, job in
        var params = try base(arguments)
        let combo = text(arguments["combo"])
        guard !combo.isEmpty else { throw BrowserToolError("Give combo: the key to press.") }
        params["combo"] = combo
        let result = try await BrowserBridge.shared.call("press_key", params: params, jobID: job.id, jobTitle: job.title, timeout: 25)
        return .textOnly(describeAction(result, did: "Pressed \(result["pressed"] as? String ?? combo)."))
    }

    static let scroll = BrowserAgentTool(
        name: "browser_scroll",
        description: "Scroll the page: give direction (up, down, left, right, top, bottom), or index to bring that control into view. With both, scrolls the area that control is in.",
        properties: [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"]],
            "index": indexProperty,
            "tab": tabProperty
        ]
    ) { arguments, job in
        var params = try base(arguments)
        let direction = text(arguments["direction"]).lowercased()
        if !direction.isEmpty { params["direction"] = direction }
        guard !direction.isEmpty || params["index"] != nil else { throw BrowserToolError("Give direction, or index.") }
        let result = try await BrowserBridge.shared.call("scroll", params: params, jobID: job.id, jobTitle: job.title, timeout: 25)
        var did = "Scrolled."
        if result["moved"] as? Bool == false { did = "Did not move: already at the end that way." }
        else if result["at_end"] as? Bool == true { did = "Scrolled to the end." }
        return .textOnly(describeAction(result, did: did))
    }

    static let navigate = BrowserAgentTool(
        name: "browser_navigate",
        description: "Take the job's tab to another address, or go back, forward or reload. Returns the new page's controls.",
        properties: [
            "url": ["type": "string", "description": "The address to go to."],
            "action": ["type": "string", "enum": ["back", "forward", "reload"], "description": "Instead of url."],
            "tab": tabProperty
        ]
    ) { arguments, job in
        var params = try base(arguments)
        let url = text(arguments["url"])
        let action = text(arguments["action"]).lowercased()
        let method: String
        if !url.isEmpty {
            params["url"] = url.contains("://") ? url : "https://" + url
            method = "navigate"
        } else if ["back", "forward", "reload"].contains(action) {
            method = action
        } else {
            throw BrowserToolError("Give url, or action: back, forward or reload.")
        }
        let result = try await BrowserBridge.shared.call(method, params: params, jobID: job.id, jobTitle: job.title, timeout: 40)
        return .textOnly(describeAction(result, did: method == "navigate" ? "Went to \(url)." : "Went \(action)."))
    }

    static let wait = BrowserAgentTool(
        name: "browser_wait",
        description: "Wait for the page: until some text shows up, a control with that label appears, the address contains something, or loading finishes. Give exactly one of text, element, url_contains, selector; with none it waits for loading to finish.",
        properties: [
            "text": ["type": "string", "description": "Wait until this text is on the page."],
            "element": ["type": "string", "description": "Wait until a control whose label contains this appears."],
            "url_contains": ["type": "string", "description": "Wait until the address contains this."],
            "selector": ["type": "string", "description": "Wait until this CSS selector matches something visible."],
            "timeout_seconds": ["type": "number", "description": "Default 10, at most 30."],
            "tab": tabProperty
        ]
    ) { arguments, job in
        var params = try base(arguments)
        var condition: [String: Any] = [:]
        for name in ["text", "element", "url_contains", "selector"] {
            let value = text(arguments[name])
            if !value.isEmpty { condition[name] = value; break }
        }
        if condition.isEmpty { condition["load"] = "complete" }
        let seconds = min(30, max(0.5, (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 10))
        params["condition"] = condition
        params["timeout"] = seconds
        let result = try await BrowserBridge.shared.call("wait_for", params: params, jobID: job.id, jobTitle: job.title, timeout: seconds + 8)
        let what = condition.map { "\($0.key) \"\($0.value)\"" }.joined()
        let waited = String(format: "%.1f", Double(integer(result["waited_ms"]) ?? 0) / 1000)
        if result["met"] as? Bool == true {
            let found = (result["found"] as? String).map { " Found \($0)." } ?? ""
            return .textOnly("Ready after \(waited) s (\(what)).\(found)")
        }
        return .textOnly("Still not there after \(waited) s (\(what)). The page is at \(result["url"] as? String ?? "?"). Read it to see what it shows instead.")
    }

    static let screenshot = BrowserAgentTool(
        name: "browser_screenshot",
        description: "Take a picture of the job's tab as it looks now (the visible part). Use it when the text and controls do not explain the page: charts, images, layout. Private fields are blurred.",
        properties: ["tab": tabProperty]
    ) { arguments, job in
        let params = try base(arguments)
        let result = try await BrowserBridge.shared.call("screenshot", params: params, jobID: job.id, jobTitle: job.title, timeout: 25)
        guard let encoded = result["data"] as? String, let raw = Data(base64Encoded: encoded), let jpeg = normalizedJPEG(from: raw) else {
            throw BrowserToolError("The browser did not return a usable picture. Use browser_read instead.")
        }
        let title = result["title"] as? String ?? ""
        let url = result["url"] as? String ?? ""
        let label = "Browser tab: \(title.isEmpty ? url : title)"
        let hidden = integer(result["hidden_fields"]) ?? 0
        let note = hidden > 0 ? " \(hidden) private field\(hidden == 1 ? " is" : "s are") blurred." : ""
        return .withVisionImage(
            text: "Picture of the tab \"\(title)\" at \(url).\(note) To act on something in it, find its [number] with browser_read.",
            visionImageJPEGData: jpeg,
            visionImageLabel: label
        )
    }

    static let upload = BrowserAgentTool(
        name: "browser_upload",
        description: "Attach a file from this Mac to a file chooser on the page. Teachy asks the person first, every time. Give the index of the file control, or leave it out right after clicking the page's own upload button.",
        properties: [
            "path": ["type": "string", "description": "Absolute path of the file."],
            "index": indexProperty,
            "tab": tabProperty
        ],
        required: ["path"]
    ) { arguments, job in
        var params = try base(arguments)
        let given = text(arguments["path"])
        guard !given.isEmpty else { throw BrowserToolError("Give path: the file to attach.") }
        let resolved = URL(fileURLWithPath: (given as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BrowserToolError("There is no file at \(resolved).")
        }
        // The person said yes to this exact file a moment ago (the gate asks every time for uploads).
        // The token tells the extension so; it works once, for this path, for two minutes.
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = try await BrowserBridge.shared.call("grant_upload", params: ["token": token, "path": resolved, "ttl": 120], jobID: job.id, jobTitle: job.title, timeout: 10)
        params["path"] = resolved
        params["consent_token"] = token
        let result = try await BrowserBridge.shared.call("upload_file", params: params, jobID: job.id, jobTitle: job.title, timeout: 40)
        return .textOnly(describeAction(result, did: "Attached \(result["uploaded"] as? String ?? (resolved as NSString).lastPathComponent)."))
    }

    static let closeJob = BrowserAgentTool(
        name: "browser_close_job",
        description: "Finish with the browser: close the tabs this job opened and give back any tab it borrowed. By default the page you are on stays open for the person.",
        properties: [
            "keep_current_tab": ["type": "boolean", "description": "false: close that one too. Default true."]
        ]
    ) { arguments, job in
        var params: [String: Any] = [:]
        if arguments["keep_current_tab"] as? Bool != false {
            let listed = try? await BrowserBridge.shared.call("list_tabs", jobID: job.id, jobTitle: job.title, timeout: 10)
            let current = (listed?["tabs"] as? [[String: Any]])?.first { $0["current"] as? Bool == true }
            if let tab = integer(current?["tab"]) { params["keep"] = [tab] }
        }
        let result = try await BrowserBridge.shared.call("close_job", params: params, jobID: job.id, jobTitle: job.title, timeout: 15)
        let closed = integer(result["closed"]) ?? 0
        let kept = integer(result["kept"]) ?? 0
        let returned = integer(result["returned"]) ?? 0
        var parts = ["Closed \(closed) tab\(closed == 1 ? "" : "s")"]
        if kept > 0 { parts.append("left \(kept) open for the person") }
        if returned > 0 { parts.append("gave \(returned) borrowed tab\(returned == 1 ? "" : "s") back") }
        return .textOnly(parts.joined(separator: ", ") + ".")
    }
}
