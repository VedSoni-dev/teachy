//
//  ToolPolicy.swift
//  leanring-buddy
//
//  The permission gate's rule book. Every agent tool call is classified here
//  BEFORE it runs: safe, needsConsent, alwaysAsk or blocked. Pure logic: no
//  AppKit, no I/O, no clock. Tested by scripts/tests/run_agent_tests.sh.
//
//  The rules lean conservative: anything that cannot be shown to be read-only
//  needs a yes from the user, and anything that deletes, sends, pays, posts or
//  touches credentials asks every single time.
//

import Foundation

// MARK: - Risk

enum ToolRisk: Int, Comparable, Equatable {
    /// Read-only. Runs without asking.
    case safe = 0
    /// Changes something. Needs a yes (once, for the job, or always).
    case needsConsent = 1
    /// Deletes, sends, pays, posts or touches credentials. Asks every time.
    case alwaysAsk = 2
    /// Never runs.
    case blocked = 3

    static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .safe: return "safe"
        case .needsConsent: return "needsConsent"
        case .alwaysAsk: return "alwaysAsk"
        case .blocked: return "blocked"
        }
    }
}

struct ToolPolicyDecision: Equatable {
    let toolName: String
    let risk: ToolRisk
    /// Why it landed in this class. Shown to the model when refused, and in logs.
    let reason: String
    /// What the tool is about to do, as a verb phrase: "run a command in the shell".
    let summary: String
    /// The exact thing (command, path, URL) shown under the question. May be empty.
    let detail: String
    /// The app (or site host) the consent is scoped to. Empty = the tool as a whole.
    let appScope: String

    /// "Always allow" and "allow for this job" are remembered per tool + app.
    var grantKey: String { "\(toolName)|\(appScope.lowercased())" }
    /// "Not now" silences this exact request, not the whole tool.
    /// Saying not now to driving an app covers the whole app, whatever the next click would be.
    var requestKey: String {
        toolName == "drive" && risk == .needsConsent ? grantKey : "\(grantKey)|\(detail.lowercased())"
    }
}

/// What the user has switched on in settings.
struct ToolPolicySettings {
    /// Reading browser cookies and authenticated_fetch stay blocked unless this is on.
    var allowBrowserCookies: Bool = false
    var homeDirectory: String = NSHomeDirectory()
    /// Teachy's own bundle id: the agent may never drive Teachy itself.
    var ownBundleIdentifier: String = ""
    /// The working folder of the named agent this job runs as (`~/.teachy/agents/<slug>/files`),
    /// with symlinks resolved. Reading and writing inside it needs no yes. Empty = not an agent job.
    var agentFilesDirectory: String = ""
}

/// Facts about the live drive session, gathered by the gate and passed in as plain values.
struct ToolPolicyContext {
    var driveTargetAppName: String = ""
    var driveTargetBundleID: String = ""
    /// Role + label of the element a drive tool is about to touch, if known.
    var driveElementDescription: String = ""
    /// HTTP method of a connector tool, when it declares one.
    var connectorHTTPMethod: String = ""
    /// Facts about the page a browser tool is about to act on (see Browser/BrowserRisk.swift).
    var browser = BrowserRiskContext()

    init(
        driveTargetAppName: String = "",
        driveTargetBundleID: String = "",
        driveElementDescription: String = "",
        connectorHTTPMethod: String = ""
    ) {
        self.driveTargetAppName = driveTargetAppName
        self.driveTargetBundleID = driveTargetBundleID
        self.driveElementDescription = driveElementDescription
        self.connectorHTTPMethod = connectorHTTPMethod
    }
}

// MARK: - Policy

enum ToolPolicy {
    /// Tools a guided-walkthrough step may see: read-only tools plus Drive (which asks first).
    static let guidedStepToolNames: Set<String> = [
        "capture_screen", "web_search", "web_fetch", "read_file",
        "drive_snapshot", "drive_press", "drive_set_text", "drive_menu",
        "drive_key", "drive_scroll", "drive_click_point"
    ]

    /// A direct "open Spotify" / "close this tab" request: the guided-step set plus app and tab control.
    static let nativeControlToolNames: Set<String> = guidedStepToolNames.union([
        "control_app", "control_browser", "open_browser_tab"
    ])

    static let driveActionToolNames: Set<String> = [
        "drive_press", "drive_set_text", "drive_menu", "drive_key", "drive_scroll", "drive_click_point"
    ]

    static func classify(
        toolName: String,
        arguments: [String: Any],
        settings: ToolPolicySettings = ToolPolicySettings(),
        context: ToolPolicyContext = ToolPolicyContext()
    ) -> ToolPolicyDecision {
        func decision(_ risk: ToolRisk, _ reason: String, summary: String, detail: String = "", app: String = "") -> ToolPolicyDecision {
            ToolPolicyDecision(toolName: toolName, risk: risk, reason: reason, summary: summary, detail: clipped(detail), appScope: app)
        }

        switch toolName {
        case "update_plan":
            return decision(.safe, "only updates the plan the user sees", summary: "update the plan")

        case "capture_screen":
            return decision(.safe, "takes a screenshot for Teachy only", summary: "look at the screen")

        case "web_search":
            return decision(.safe, "public web search", summary: "search the web", detail: string(arguments["query"]))

        case "web_fetch":
            let url = string(arguments["url"])
            if isPrivateNetworkURL(url) {
                return decision(.needsConsent, "the address is on this Mac or the local network", summary: "open a local network address", detail: url, app: host(of: url))
            }
            return decision(.safe, "reads a public page", summary: "read a web page", detail: url)

        case "list_browser_sessions":
            guard settings.allowBrowserCookies else {
                return decision(.blocked, "reading browser cookies is off in settings", summary: "look at browser sign-ins")
            }
            return decision(.safe, "lists browsers only; cookie access is on in settings", summary: "list browser sign-ins")

        case "authenticated_fetch":
            let url = string(arguments["url"])
            guard settings.allowBrowserCookies else {
                return decision(.blocked, "using browser cookies is off in settings", summary: "use your browser sign-in", detail: url)
            }
            let method = string(arguments["method"]).uppercased()
            if !method.isEmpty && method != "GET" {
                return decision(.alwaysAsk, "sends data to a signed-in site (\(method))", summary: "send something to \(host(of: url)) as you", detail: "\(method) \(url)", app: host(of: url))
            }
            return decision(.needsConsent, "reads a page using your sign-in", summary: "read \(host(of: url)) signed in as you", detail: url, app: host(of: url))

        case "remember":
            return decision(.safe, "adds a note to this agent's own memory file", summary: "remember a note", detail: string(arguments["note"]))

        case "list_routines":
            return decision(.safe, "only lists the routines", summary: "list your routines")

        case "pause_routine":
            // Pausing loses nothing and is undone with one tap. Resuming makes things run again, so that asks.
            let resumes = (arguments["resume"] as? Bool) == true
            return decision(
                resumes ? .needsConsent : .safe,
                resumes ? "makes a paused routine run again" : "stops a routine from running until you resume it",
                summary: resumes ? "resume a routine" : "pause a routine",
                detail: string(arguments["id"])
            )

        case "create_routine":
            // Show exactly what was asked for: the schedule as sent, then the task.
            var scheduleText = ""
            if let schedule = arguments["schedule"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: schedule, options: [.sortedKeys]) {
                scheduleText = (String(data: data, encoding: .utf8) ?? "") + " "
            }
            return decision(.needsConsent, "sets up work that runs later without you watching", summary: "set up a routine", detail: scheduleText + string(arguments["task"]))

        case "delete_routine":
            return decision(.alwaysAsk, "deletes a routine", summary: "delete a routine", detail: string(arguments["id"]))

        case "read_file":
            let path = string(arguments["path"])
            if PathPolicy.isInside(path: path, directory: settings.agentFilesDirectory, home: settings.homeDirectory),
               !PathPolicy.looksLikeCredentialPath(PathPolicy.relative(path: path, to: settings.agentFilesDirectory, home: settings.homeDirectory)) {
                return decision(.safe, "reads a file in this agent's own folder", summary: "read a file", detail: path)
            }
            switch PathPolicy.classifyRead(path: path, home: settings.homeDirectory) {
            case .plain:
                return decision(.safe, "reads a normal file in your home folder", summary: "read a file", detail: path)
            case .credential:
                return decision(.alwaysAsk, "the path looks like credentials or keys", summary: "read a file that may hold secrets", detail: path)
            case .privateArea:
                return decision(.needsConsent, "the file is hidden, in Library, or outside your home folder", summary: "read a file", detail: path)
            }

        case "write_file":
            let path = string(arguments["path"])
            // A named agent may write freely inside its own files folder. Only the part below the
            // folder is judged for secret-looking names, so the folder's own path cannot trip it.
            if PathPolicy.isInside(path: path, directory: settings.agentFilesDirectory, home: settings.homeDirectory) {
                let inner = PathPolicy.relative(path: path, to: settings.agentFilesDirectory, home: settings.homeDirectory)
                if !PathPolicy.looksLikeCredentialPath(inner), !PathPolicy.looksLikePersistencePath(inner) {
                    return decision(.safe, "writes inside this agent's own files folder", summary: "write a file in its own folder", detail: path)
                }
            }
            switch PathPolicy.classifyWrite(path: path, home: settings.homeDirectory) {
            case .credential:
                return decision(.alwaysAsk, "writing there can change sign-ins, keys or what runs at login", summary: "write a sensitive file", detail: path)
            case .plain, .privateArea:
                return decision(.needsConsent, "creates or overwrites a file", summary: "write a file", detail: path)
            }

        case "bash":
            let command = string(arguments["command"])
            let verdict = ShellCommandClassifier.classify(command)
            return decision(verdict.risk, verdict.reason, summary: "run a command", detail: command)

        case "run_applescript":
            let script = string(arguments["script"])
            let verdict = AppleScriptClassifier.classify(script)
            return decision(verdict.risk, verdict.reason, summary: "run an AppleScript", detail: script, app: AppleScriptClassifier.firstTargetApp(in: script))

        case "open_browser_tab":
            let url = string(arguments["url"])
            // Opening a page is visible and trivially undone, so it doesn't interrupt with a prompt.
            return decision(.safe, "opens a page in your browser", summary: "open \(host(of: url).isEmpty ? "a page" : host(of: url)) in your browser", detail: url, app: string(arguments["browser"]))

        case "control_app":
            let action = string(arguments["action"]).lowercased()
            let app = string(arguments["appName"])
            if isOwnOrProtectedApp(name: app, bundleID: "", settings: settings) == .own {
                return decision(.blocked, "Teachy does not control itself", summary: "\(action) Teachy")
            }
            // "Open Spotify" should just happen: opening, showing or hiding an app loses nothing.
            // Quitting can lose unsaved work, so that still asks.
            let harmlessAppActions: Set<String> = ["open", "launch", "activate", "focus", "show", "unhide", "hide"]
            let appRisk: ToolRisk = harmlessAppActions.contains(action) ? .safe : .needsConsent
            return decision(appRisk, "changes which apps are running or in front", summary: "\(action.isEmpty ? "control" : action) \(app.isEmpty ? "an app" : app)", app: app)

        case "control_browser":
            let action = string(arguments["action"]).lowercased()
            let closesALot = ["close_all_tabs", "close_other_tabs", "close_window"].contains(action)
            if closesALot {
                return decision(.alwaysAsk, "closes several tabs at once", summary: action.replacingOccurrences(of: "_", with: " "), detail: string(arguments["url"]), app: "browser")
            }
            return decision(.needsConsent, "changes your browser tabs", summary: action.isEmpty ? "change browser tabs" : action.replacingOccurrences(of: "_", with: " "), detail: string(arguments["url"]), app: "browser")

        case "drive_snapshot":
            let requestedApp = string(arguments["app"])
            if isOwnOrProtectedApp(name: requestedApp, bundleID: "", settings: settings) == .own {
                return decision(.blocked, "Teachy does not drive itself", summary: "read Teachy's own window")
            }
            return decision(.safe, "reads what is on screen in one app", summary: "read the window", app: requestedApp)

        case "computer":
            return classifyComputer(arguments: arguments, settings: settings, context: context)

        case _ where driveActionToolNames.contains(toolName):
            return classifyDrive(toolName: toolName, arguments: arguments, settings: settings, context: context)

        case _ where toolName.hasPrefix("browser_"):
            // One shared tool name so a single yes per site covers click, type and navigate.
            let verdict = BrowserRiskClassifier.classify(toolName: toolName, arguments: arguments, context: context.browser)
            return ToolPolicyDecision(toolName: "browser", risk: ToolRisk(rawValue: verdict.risk.rawValue) ?? .needsConsent, reason: verdict.reason, summary: verdict.summary, detail: verdict.detail, appScope: verdict.siteScope)

        default:
            return classifyUnknown(toolName: toolName, arguments: arguments, context: context)
        }
    }

    // MARK: Computer use (the real pointer and keyboard, anywhere on screen)

    /// Actions of the `computer` tool that only look.
    static let computerLookOnlyActions: Set<String> = ["screenshot", "cursor_position", "wait"]

    /// `computer` is judged by the app it would act on: the app under the point for pointer
    /// actions, the app in front for typing and keys (the gate fills that in as driveTarget…).
    private static func classifyComputer(arguments: [String: Any], settings: ToolPolicySettings, context: ToolPolicyContext) -> ToolPolicyDecision {
        let action = string(arguments["action"]).lowercased()
        let app = context.driveTargetAppName
        let appLabel = app.isEmpty ? "your Mac" : app
        func decision(_ risk: ToolRisk, _ reason: String, detail: String = "") -> ToolPolicyDecision {
            ToolPolicyDecision(toolName: "computer", risk: risk, reason: reason, summary: "use the mouse and keyboard in \(appLabel)", detail: clipped(detail), appScope: app)
        }
        if computerLookOnlyActions.contains(action) {
            return ToolPolicyDecision(toolName: "computer", risk: .safe, reason: "only looks", summary: "look at the screen", detail: "", appScope: "")
        }
        var detail = action
        if action == "type" { detail = "type \(string(arguments["text"]))" }
        if action == "key" { detail = "press \(string(arguments["key"]))" }
        if !context.driveElementDescription.isEmpty { detail += " on \(context.driveElementDescription)" }

        switch isOwnOrProtectedApp(name: app, bundleID: context.driveTargetBundleID, settings: settings) {
        case .own:
            // Teachy's own consent card is never clicked by the agent.
            return decision(.blocked, "Teachy does not click or type into itself", detail: detail)
        case .credentials:
            return decision(.alwaysAsk, "\(appLabel) holds passwords and keys", detail: detail)
        case .systemSettings:
            return decision(.alwaysAsk, "changes system settings", detail: detail)
        case .terminal:
            if action != "scroll" && action != "move" {
                return decision(.alwaysAsk, "typing or clicking in a terminal can run any command", detail: detail)
            }
        case .messaging, .ordinary:
            break
        }
        if action == "type", let word = SensitiveWords.firstMatch(in: context.driveElementDescription) {
            return decision(.alwaysAsk, "the field says \"\(word)\"", detail: detail)
        }
        if action == "key" {
            let combo = string(arguments["key"]).lowercased().replacingOccurrences(of: " ", with: "")
            // Sending in most apps, and quitting/closing without a look.
            if ["cmd+enter", "cmd+return", "cmd+q", "cmd+option+esc", "cmd+shift+delete", "cmd+delete"].contains(combo) {
                return decision(.alwaysAsk, "\(combo) can send, quit or delete", detail: detail)
            }
        }
        return decision(.needsConsent, "controls the mouse and keyboard in \(appLabel)", detail: detail)
    }

    // MARK: Drive

    private static func classifyDrive(
        toolName: String,
        arguments: [String: Any],
        settings: ToolPolicySettings,
        context: ToolPolicyContext
    ) -> ToolPolicyDecision {
        let app = context.driveTargetAppName
        let appLabel = app.isEmpty ? "the app" : app
        func decision(_ risk: ToolRisk, _ reason: String, summary: String, detail: String = "") -> ToolPolicyDecision {
            ToolPolicyDecision(toolName: "drive", risk: risk, reason: reason, summary: summary, detail: clipped(detail), appScope: app)
        }

        let action: String
        var detail = ""
        switch toolName {
        case "drive_press":
            action = "press \(context.driveElementDescription.isEmpty ? "a control" : context.driveElementDescription)"
            detail = context.driveElementDescription
        case "drive_set_text":
            action = "type into \(context.driveElementDescription.isEmpty ? "a field" : context.driveElementDescription)"
            detail = string(arguments["text"])
        case "drive_menu":
            let path = (arguments["path"] as? [Any])?.map { "\($0)" } ?? []
            action = "choose \(path.joined(separator: " > "))"
            detail = path.joined(separator: " > ")
        case "drive_key":
            action = "press \(string(arguments["combo"]))"
            detail = string(arguments["combo"])
        case "drive_scroll":
            action = "scroll"
        default:
            action = "click \(context.driveElementDescription.isEmpty ? "a point" : context.driveElementDescription)"
            detail = context.driveElementDescription
        }
        let summary = "drive \(appLabel)"

        switch isOwnOrProtectedApp(name: app, bundleID: context.driveTargetBundleID, settings: settings) {
        case .own:
            return decision(.blocked, "Teachy does not drive itself", summary: summary, detail: action)
        case .credentials:
            return decision(.alwaysAsk, "\(appLabel) holds passwords and keys", summary: summary, detail: action)
        case .systemSettings:
            return decision(.alwaysAsk, "changes system settings", summary: summary, detail: action)
        case .terminal:
            if toolName != "drive_scroll" {
                return decision(.alwaysAsk, "typing or clicking in a terminal can run any command", summary: summary, detail: action)
            }
        case .messaging, .ordinary:
            break
        }

        if toolName == "drive_scroll" {
            return decision(.needsConsent, "scrolls inside \(appLabel)", summary: summary, detail: action)
        }

        // Words on the control or menu item that mean delete / send / pay / post.
        let wordsToCheck = (detail + " " + context.driveElementDescription)
        if toolName != "drive_set_text", toolName != "drive_key", let word = SensitiveWords.firstMatch(in: wordsToCheck) {
            return decision(.alwaysAsk, "the control says \"\(word)\"", summary: summary, detail: action)
        }

        if toolName == "drive_key" {
            let combo = string(arguments["combo"]).lowercased().replacingOccurrences(of: " ", with: "")
            let parts = Set(combo.split(separator: "+").map(String.init))
            let hasCommand = parts.contains("cmd") || parts.contains("command")
            let isDeleteKey = parts.contains("delete") || parts.contains("backspace") || parts.contains("forwarddelete")
            let isReturnKey = parts.contains("return") || parts.contains("enter")
            if hasCommand && isDeleteKey {
                return decision(.alwaysAsk, "that shortcut deletes", summary: summary, detail: action)
            }
            if hasCommand && isReturnKey {
                return decision(.alwaysAsk, "that shortcut sends or submits in most apps", summary: summary, detail: action)
            }
            if isReturnKey, isOwnOrProtectedApp(name: app, bundleID: context.driveTargetBundleID, settings: settings) == .messaging {
                return decision(.alwaysAsk, "Return sends a message in \(appLabel)", summary: summary, detail: action)
            }
        }

        return decision(.needsConsent, "controls \(appLabel) for you", summary: summary, detail: action)
    }

    enum AppKind: Equatable { case ordinary, own, credentials, systemSettings, terminal, messaging }

    static func isOwnOrProtectedApp(name: String, bundleID: String, settings: ToolPolicySettings) -> AppKind {
        let lowerName = name.lowercased().trimmingCharacters(in: .whitespaces)
        let lowerBundle = bundleID.lowercased()
        if !settings.ownBundleIdentifier.isEmpty, lowerBundle == settings.ownBundleIdentifier.lowercased() { return .own }
        if lowerName == "teachy" { return .own }

        let credentialBundles = ["com.apple.keychainaccess", "com.apple.passwords", "com.1password", "com.agilebits", "com.bitwarden", "com.lastpass", "com.dashlane"]
        let credentialNames = ["keychain access", "passwords", "1password", "bitwarden", "lastpass", "dashlane"]
        if credentialBundles.contains(where: { lowerBundle.hasPrefix($0) }) || credentialNames.contains(lowerName) { return .credentials }

        if lowerBundle == "com.apple.systempreferences" || lowerName == "system settings" || lowerName == "system preferences" { return .systemSettings }

        let terminalBundles = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]
        let terminalNames = ["terminal", "iterm", "iterm2", "warp", "kitty", "ghostty", "alacritty", "wezterm", "hyper"]
        if terminalBundles.contains(where: { lowerBundle.hasPrefix($0) }) || terminalNames.contains(lowerName) { return .terminal }

        let messagingBundles = ["com.apple.mobilesms", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.hnc.discord", "net.whatsapp.whatsapp", "ru.keepcoder.telegram", "com.microsoft.outlook", "com.microsoft.teams", "org.whispersystems.signal-desktop", "com.facebook.archon"]
        let messagingNames = ["messages", "mail", "slack", "discord", "whatsapp", "telegram", "outlook", "microsoft outlook", "microsoft teams", "teams", "signal", "messenger"]
        if messagingBundles.contains(where: { lowerBundle.hasPrefix($0) }) || messagingNames.contains(lowerName) { return .messaging }

        return .ordinary
    }

    // MARK: Connector and unknown tools

    private static func classifyUnknown(toolName: String, arguments: [String: Any], context: ToolPolicyContext) -> ToolPolicyDecision {
        let readable = toolName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let method = context.connectorHTTPMethod.uppercased()
        if method == "DELETE" {
            return ToolPolicyDecision(toolName: toolName, risk: .alwaysAsk, reason: "the connection deletes something", summary: "use \(readable)", detail: "", appScope: "")
        }
        if let word = SensitiveWords.firstMatch(in: readable) {
            return ToolPolicyDecision(toolName: toolName, risk: .alwaysAsk, reason: "the tool name says \"\(word)\"", summary: "use \(readable)", detail: "", appScope: "")
        }
        if toolName.hasPrefix("mcp__browser__") {
            return classifyBuiltInBrowser(toolName: toolName, arguments: arguments)
        }
        return ToolPolicyDecision(toolName: toolName, risk: .needsConsent, reason: "a connected app tool Teachy cannot prove is read-only", summary: "use \(readable)", detail: "", appScope: "")
    }

    /// The built-in Playwright browser. Its tools name the control they act on in plain words
    /// (`element`), so a click on "Place order" or "Send" is caught even in auto mode.
    private static func classifyBuiltInBrowser(toolName: String, arguments: [String: Any]) -> ToolPolicyDecision {
        let action = String(toolName.dropFirst("mcp__browser__browser_".count)).replacingOccurrences(of: "_", with: " ")
        func decision(_ risk: ToolRisk, _ reason: String, detail: String) -> ToolPolicyDecision {
            // One grant key for the whole browser: a "yes" covers browsing, not each tool.
            ToolPolicyDecision(toolName: "browser", risk: risk, reason: reason, summary: "use the browser (\(action))", detail: clipped(detail), appScope: "built-in browser")
        }
        let readOnly: Set<String> = ["snapshot", "take screenshot", "console messages", "network requests", "network request", "find", "wait for"]
        if readOnly.contains(action) {
            return decision(.safe, "only reads the page", detail: "")
        }
        if action == "file upload" || action == "run code unsafe" || action == "evaluate" {
            return decision(.alwaysAsk, action == "file upload" ? "uploads a file from this Mac" : "runs code inside the page", detail: string(arguments["paths"]) + string(arguments["function"]) + string(arguments["code"]))
        }
        var described = [string(arguments["element"]), string(arguments["text"]), string(arguments["key"])]
        if let fields = arguments["fields"] as? [[String: Any]] {
            described += fields.map { string($0["name"]) }
        }
        let detail = described.filter { !$0.isEmpty }.joined(separator: " · ")
        if let word = SensitiveWords.firstMatch(in: string(arguments["element"])) {
            return decision(.alwaysAsk, "the control says \"\(word)\"", detail: detail)
        }
        if let fields = arguments["fields"] as? [[String: Any]],
           let secret = fields.map({ string($0["name"]).lowercased() }).first(where: { name in SecretFieldDetector.fieldWords.contains(where: { name.contains($0) }) }) {
            return decision(.alwaysAsk, "fills in \(secret)", detail: detail)
        }
        if action == "type", SecretFieldDetector.fieldWords.contains(where: { string(arguments["element"]).lowercased().contains($0) }) {
            return decision(.alwaysAsk, "types into a password or code field", detail: detail)
        }
        if action == "navigate" {
            return decision(.needsConsent, "opens a page", detail: string(arguments["url"]))
        }
        return decision(.needsConsent, "acts on a web page", detail: detail)
    }

    // MARK: Helpers

    static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let value { return "\(value)" }
        return ""
    }

    static func clipped(_ text: String, limit: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func host(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URLComponents(string: withScheme)?.host?.lowercased() ?? ""
    }

    static func isPrivateNetworkURL(_ urlString: String) -> Bool {
        let hostName = host(of: urlString)
        if hostName.isEmpty { return true }
        if hostName == "localhost" || hostName.hasSuffix(".local") || hostName.hasSuffix(".internal") || hostName.hasSuffix(".localhost") { return true }
        if hostName.contains(":") { return true } // IPv6 literal: treat as local
        let octets = hostName.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, hostName.split(separator: ".").count == 4 {
            if octets[0] == 127 || octets[0] == 10 || octets[0] == 0 { return true }
            if octets[0] == 192 && octets[1] == 168 { return true }
            if octets[0] == 169 && octets[1] == 254 { return true }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        }
        if !hostName.contains(".") { return true } // bare intranet name
        return false
    }
}

// MARK: - Words that mean "ask every time"

enum SensitiveWords {
    /// Whole words (or phrases) on a button, menu item or tool name that delete, send, pay or post.
    static let words: [String] = [
        "delete", "remove", "erase", "trash", "empty trash", "discard", "destroy", "wipe", "format", "reset",
        "send", "reply", "forward", "post", "publish", "tweet", "share", "submit", "comment",
        "pay", "buy", "purchase", "checkout", "check out", "place order", "order", "subscribe", "donate", "transfer", "confirm payment",
        "sign out", "log out", "deactivate", "unsubscribe", "cancel subscription", "revoke"
    ]

    static func firstMatch(in text: String) -> String? {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }
        for word in words {
            let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![a-z])"
            if lower.range(of: pattern, options: .regularExpression) != nil { return word }
        }
        return nil
    }
}

// MARK: - Paths

enum PathPolicy {
    enum Kind: Equatable { case plain, privateArea, credential }

    static let credentialMarkers: [String] = [
        "/.ssh", ".ssh/", "id_rsa", "id_ed25519", "id_ecdsa", "authorized_keys", "known_hosts",
        "keychain", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc", ".kube/config", ".docker/config.json",
        "/cookies", "cookies.binarycookies", "login data", "credentials", "1password", ".git-credentials",
        "secrets", ".pem", ".p12", ".keystore", "wallet", "/etc/sudoers", "/etc/shadow", "master.passwd"
    ]

    /// Files that decide what runs at login or in every shell: writing them is as good as running code later.
    static let persistenceMarkers: [String] = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile",
        "launchagents", "launchdaemons", ".gitconfig", "/.config/fish", "crontab", ".ssh/config"
    ]

    static func looksLikeCredentialPath(_ text: String) -> Bool {
        let lower = text.lowercased()
        if credentialMarkers.contains(where: { lower.contains($0) }) { return true }
        // .env, .env.local — but not environment.swift
        if lower.range(of: #"(^|/)\.env($|[./])"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func looksLikePersistencePath(_ text: String) -> Bool {
        if text.hasPrefix("-") { return false }
        let lower = text.lowercased()
        return persistenceMarkers.contains { lower.contains($0) }
    }

    /// Expands ~ and squashes "." and ".." without touching the disk.
    static func normalize(_ path: String, home: String) -> String {
        var expanded = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if expanded == "~" { expanded = home } else if expanded.hasPrefix("~/") { expanded = home + String(expanded.dropFirst(1)) }
        if !expanded.hasPrefix("/") { expanded = home + "/" + expanded }
        var parts: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Where a path a tool was given really points: "~" is the home folder, and a relative path
    /// is taken from the job's working folder (a named agent's `files/`), or from home when the
    /// job has none. The file tools and the permission gate both use this, so they always agree.
    static func absolute(_ path: String, workingDirectory: String?, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") {
            return normalize(trimmed, home: home)
        }
        let base = workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? home
        return normalize((base.hasSuffix("/") ? base : base + "/") + trimmed, home: home)
    }

    /// True when `path` is strictly below `directory` once "~", "." and ".." are worked out.
    /// An empty directory never contains anything.
    static func isInside(path: String, directory: String, home: String) -> Bool {
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let base = normalize(trimmedDirectory, home: home)
        guard base != "/" else { return false }
        return normalize(path, home: home).hasPrefix(base + "/")
    }

    /// The part of `path` below `directory` ("" when it is not inside).
    static func relative(path: String, to directory: String, home: String) -> String {
        guard isInside(path: path, directory: directory, home: home) else { return "" }
        return String(normalize(path, home: home).dropFirst(normalize(directory, home: home).count + 1))
    }

    static func classifyRead(path: String, home: String) -> Kind {
        let normalized = normalize(path, home: home)
        if looksLikeCredentialPath(normalized) { return .credential }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard normalized.hasPrefix(homePrefix) else { return .privateArea }
        let relativeParts = normalized.dropFirst(homePrefix.count).split(separator: "/")
        if relativeParts.isEmpty { return .privateArea }
        if relativeParts.contains(where: { $0.hasPrefix(".") }) { return .privateArea }
        if relativeParts.first == "Library" { return .privateArea }
        return .plain
    }

    static func classifyWrite(path: String, home: String) -> Kind {
        let normalized = normalize(path, home: home)
        let lower = normalized.lowercased()
        if looksLikeCredentialPath(normalized) { return .credential }
        if persistenceMarkers.contains(where: { lower.contains($0) }) { return .credential }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if !normalized.hasPrefix(homePrefix) && !normalized.hasPrefix("/tmp/") && !normalized.hasPrefix("/private/tmp/") && !normalized.hasPrefix("/var/folders/") && !normalized.hasPrefix("/private/var/folders/") {
            return .credential // system locations: ask every time
        }
        return .plain
    }

    /// A shell argument that points somewhere private (hidden file, Library). Flags are ignored.
    static func argumentLooksPrivate(_ argument: String) -> Bool {
        if argument.hasPrefix("-") { return false }
        if argument.contains("Library/") || argument.hasSuffix("/Library") || argument == "~/Library" { return true }
        for part in argument.split(separator: "/") where part.hasPrefix(".") && part != "." && part != ".." {
            return true
        }
        return false
    }
}

// MARK: - AppleScript

enum AppleScriptClassifier {
    static func classify(_ script: String) -> (risk: ToolRisk, reason: String) {
        let lower = script.lowercased()
        if lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.needsConsent, "empty script")
        }
        if lower.contains("administrator privileges") {
            return (.blocked, "asks for administrator rights")
        }
        var worst: (risk: ToolRisk, reason: String) = (.needsConsent, "AppleScript can change things in your apps")

        // do shell script "…" is a shell command: judge it as one.
        let shellPattern = #"do shell script\s+"((?:[^"\\]|\\.)*)""#
        if let regex = try? NSRegularExpression(pattern: shellPattern, options: [.caseInsensitive]) {
            let range = NSRange(script.startIndex..., in: script)
            for match in regex.matches(in: script, range: range) {
                if let commandRange = Range(match.range(at: 1), in: script) {
                    let command = String(script[commandRange]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    let verdict = ShellCommandClassifier.classify(command)
                    if verdict.risk > worst.risk { worst = (verdict.risk, "runs a shell command: " + verdict.reason) }
                }
            }
        }
        if lower.contains("do shell script"), worst.risk < .alwaysAsk {
            // Built from variables, or we could not read it: we cannot know what it runs.
            let literalCount = (try? NSRegularExpression(pattern: shellPattern, options: [.caseInsensitive]))?.numberOfMatches(in: script, range: NSRange(script.startIndex..., in: script)) ?? 0
            let mentions = lower.components(separatedBy: "do shell script").count - 1
            if literalCount < mentions || script.contains("&") {
                worst = (.alwaysAsk, "runs a shell command Teachy cannot read ahead of time")
            }
        }

        let alwaysAskPhrases: [(String, String)] = [
            ("delete", "deletes something"), ("empty trash", "empties the Trash"), ("empty the trash", "empties the Trash"),
            ("move to trash", "moves something to the Trash"), ("to trash", "moves something to the Trash"), ("erase", "erases something"),
            ("send", "sends a message"), ("outgoing message", "writes an email"), ("post ", "posts something"),
            ("keychain", "touches the keychain"), ("password", "touches a password"), ("purchase", "buys something"),
            ("shut down", "shuts the Mac down"), ("restart", "restarts the Mac"), ("log out", "logs you out"),
            ("keystroke", "types keys into whatever app is in front"), ("key code", "types keys into whatever app is in front"),
            ("click", "clicks in an app"), ("system events", "controls the Mac through System Events"),
            ("system settings", "changes system settings"), ("system preferences", "changes system settings"),
            ("run script", "runs another script"), ("osascript", "runs another script")
        ]
        for (phrase, reason) in alwaysAskPhrases where lower.contains(phrase) {
            if worst.risk < .alwaysAsk { worst = (.alwaysAsk, reason) }
            break
        }
        return worst
    }

    static func firstTargetApp(in script: String) -> String {
        let pattern = #"tell application\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else { return "" }
        return String(script[range])
    }
}

// MARK: - Shell commands

enum ShellCommandClassifier {
    typealias Verdict = (risk: ToolRisk, reason: String)

    static func classify(_ command: String) -> Verdict {
        classify(command, depth: 0)
    }

    private static func classify(_ command: String, depth: Int) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (.needsConsent, "empty command") }
        if depth > 6 { return (.alwaysAsk, "the command is nested too deeply to read") }

        let scan = ShellLexer.scan(trimmed)
        var worst: Verdict = (.safe, "read-only command")
        func raise(_ verdict: Verdict) { if verdict.risk > worst.risk { worst = verdict } }

        if scan.unbalanced { raise((.needsConsent, "the quoting is unbalanced, so Teachy cannot be sure what runs")) }
        if scan.hasSubstitution { raise((.needsConsent, "runs another command inside it")) }
        if scan.hasExpansion { raise((.needsConsent, "uses a variable Teachy cannot see the value of")) }
        if scan.hasHeredoc { raise((.needsConsent, "feeds text in with a heredoc")) }
        if scan.hasBackground { raise((.needsConsent, "starts something in the background")) }
        if scan.hasGrouping { raise((.needsConsent, "uses a subshell or a function")) }
        for target in scan.redirectOutTargets where target != "/dev/null" {
            raise((.needsConsent, "writes to \(target)"))
        }

        // Anything the command runs inside $(…), backticks or <(…) is judged as its own command.
        for nested in scan.nested {
            let verdict = classify(nested, depth: depth + 1)
            if verdict.risk > .needsConsent { raise(verdict) }
        }

        // Credentials anywhere in the words, including redirect targets.
        for word in scan.allWords + scan.redirectOutTargets + scan.redirectInTargets where PathPolicy.looksLikeCredentialPath(word) {
            raise((.alwaysAsk, "touches credentials or keys (\(word))"))
        }

        // Redirecting into a file that runs at login or in every shell is as good as running code later.
        for target in scan.redirectOutTargets where PathPolicy.looksLikePersistencePath(target) {
            raise((.alwaysAsk, "writes to \(target), which runs at login or in every shell"))
        }

        // Text fed to a shell or interpreter with << or <<< is code Teachy cannot fully read.
        if scan.hasHeredoc, scan.segments.contains(where: { segment in
            segment.words.contains { shells.contains(commandBaseName($0)) || interpreters.contains(commandBaseName($0)) }
        }) {
            raise((.alwaysAsk, "feeds text straight into a shell or interpreter"))
        }

        if scan.segments.isEmpty && scan.nested.isEmpty { raise((.needsConsent, "nothing Teachy recognises")) }

        for segment in scan.segments {
            raise(classifySegment(words: segment.words, pipedInto: segment.pipedInto, depth: depth))
        }
        return worst
    }

    private static let controlKeywords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "select", "!", "{", "}", "time", "coproc"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
    private static let interpreters: Set<String> = ["python", "python2", "python3", "perl", "ruby", "node", "deno", "bun", "php", "osascript", "swift", "lua", "tclsh", "awk"]
    private static let blockedCommands: Set<String> = ["sudo", "su", "doas"]
    private static let wrappers: Set<String> = ["env", "command", "builtin", "exec", "nohup", "nice", "ionice", "caffeinate", "xargs", "timeout", "gtimeout", "stdbuf", "arch", "noglob", "nocorrect", "watch", "parallel"]

    private static let alwaysAskCommands: [String: String] = [
        "rm": "deletes files", "rmdir": "deletes folders", "unlink": "deletes a file", "shred": "destroys files", "srm": "destroys files",
        "trash": "moves files to the Trash", "dd": "can overwrite disks and files", "truncate": "empties files",
        "diskutil": "changes disks", "newfs": "formats a disk", "fdisk": "changes disks", "gpt": "changes disks",
        "shutdown": "shuts the Mac down", "reboot": "restarts the Mac", "halt": "halts the Mac",
        "security": "touches the keychain", "ssh": "uses your SSH keys", "scp": "uses your SSH keys", "sftp": "uses your SSH keys",
        "ssh-add": "touches your SSH keys", "ssh-keygen": "touches your SSH keys", "ssh-copy-id": "touches your SSH keys", "rsync": "can delete and send files",
        "mail": "sends email", "sendmail": "sends email", "mailx": "sends email", "msmtp": "sends email",
        "passwd": "changes a password", "dscl": "changes user accounts", "csrutil": "changes system security", "spctl": "changes system security",
        "nvram": "changes firmware settings", "pmset": "changes power settings", "systemsetup": "changes system settings", "networksetup": "changes network settings",
        "scutil": "changes system settings", "tccutil": "resets privacy permissions", "launchctl": "changes what runs in the background",
        "crontab": "changes scheduled jobs", "at": "schedules a command", "chflags": "changes file protection", "mkfs": "formats a disk",
        "nc": "opens a raw network connection", "ncat": "opens a raw network connection", "netcat": "opens a raw network connection", "telnet": "opens a raw network connection",
        "gpg": "uses your keys", "op": "reads your password manager", "pass": "reads your password manager", "pbpaste": "reads your clipboard, which may hold a password"
    ]

    /// Read-only commands. An entry's closure may veto specific arguments.
    private static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "pwd", "which", "whoami", "date", "echo", "printf", "wc", "file", "stat", "du", "df",
        "uname", "sw_vers", "hostname", "id", "basename", "dirname", "realpath", "readlink", "grep", "egrep", "fgrep", "rg",
        "sort", "uniq", "cut", "tr", "diff", "cmp", "md5", "shasum", "cksum", "true", "false", "test", "[", "type", "whereis",
        "mdfind", "mdls", "uptime", "jq", "tree", "nl", "rev", "fold", "column", "expr", "seq", "cal", "locale", "arch", "groups", "tty", "find", "git", "sleep"
    ]

    private static let versionFlags: Set<String> = ["--version", "-v", "-V", "-version", "version"]

    /// "/bin/rm", "\\rm", "=rm" (zsh) → "rm"
    static func commandBaseName(_ word: String) -> String {
        var name = word
        while name.hasPrefix("\\") || name.hasPrefix("=") { name.removeFirst() }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return name.lowercased()
    }

    private static let destructiveCodeHints: [String] = [
        "remove", "unlink", "rmtree", "rmdir", "rm -", "delete", "truncate", "shutil", "system(", "subprocess", "popen", "exec(", "spawn", "child_process",
        "smtplib", "sendmail", ".post(", "requests.put", "requests.delete", "urlopen", "fetch(", "keychain", "password", "os.kill", "fs.rm", "writefile", "open("
    ]

    private static func classifySegment(words: [String], pipedInto: Bool, depth: Int) -> Verdict {
        let verdict = classifySegmentCore(words: words, pipedInto: pipedInto, depth: depth)
        guard verdict.risk == .needsConsent else { return verdict }
        // Any command that is not a plain reader and names a login / shell-profile file: ask every time.
        let isPlainReader = words.first.map { readOnlyCommands.contains(commandBaseName($0)) && commandBaseName($0) != "git" } ?? false
        if !isPlainReader, let target = words.dropFirst().first(where: PathPolicy.looksLikePersistencePath) {
            return (.alwaysAsk, "touches \(target), which runs at login or in every shell")
        }
        return verdict
    }

    private static func classifySegmentCore(words rawWords: [String], pipedInto: Bool, depth: Int) -> Verdict {
        var words = rawWords
        var floor: Verdict = (.safe, "read-only command")
        func floorAt(_ verdict: Verdict) { if verdict.risk > floor.risk { floor = verdict } }
        func result(_ verdict: Verdict) -> Verdict { verdict.risk >= floor.risk ? verdict : floor }

        // Strip control keywords and VAR=value prefixes; neither is ever "provably read-only".
        while let first = words.first {
            if controlKeywords.contains(first) {
                floorAt((.needsConsent, "uses shell control flow"))
                words.removeFirst()
            } else if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil {
                floorAt((.needsConsent, "sets an environment variable for the command"))
                words.removeFirst()
            } else {
                break
            }
        }
        guard let rawName = words.first else { return floor }
        let arguments = Array(words.dropFirst())

        if rawName.contains(ShellLexer.substitutionMarker) || rawName.contains("$") {
            return (.alwaysAsk, "the command name is worked out at run time")
        }
        let name = commandBaseName(rawName)
        let hasComputedArgument = arguments.contains { $0.contains(ShellLexer.substitutionMarker) }

        if blockedCommands.contains(name) { return (.blocked, "\(name) runs things as an administrator") }

        if wrappers.contains(name) {
            // The wrapper runs whatever follows: judge that, and never call it read-only.
            var inner = arguments
            if name == "arch" && inner.isEmpty { return result((.safe, "read-only command")) }
            while let first = inner.first, first.hasPrefix("-") || first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil || Double(first) != nil {
                inner.removeFirst()
            }
            floorAt((.needsConsent, "\(name) runs another command"))
            if inner.isEmpty { return floor }
            // Options with values (xargs -I {} rm {}) can hide where the real command starts:
            // any word that names a dangerous command counts.
            if arguments.contains(where: { blockedCommands.contains(commandBaseName($0)) }) {
                return (.blocked, "\(name) runs something as an administrator")
            }
            if let dangerous = arguments.first(where: { alwaysAskCommands[commandBaseName($0)] != nil }) {
                return (.alwaysAsk, "\(name) runs \(commandBaseName(dangerous)): \(alwaysAskCommands[commandBaseName(dangerous)] ?? "")")
            }
            return result(classifySegment(words: inner, pipedInto: pipedInto, depth: depth))
        }

        if shells.contains(name) {
            if pipedInto { return (.alwaysAsk, "pipes text straight into a shell") }
            if hasComputedArgument { return (.alwaysAsk, "runs a script that is worked out at run time") }
            if let flagIndex = arguments.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }), flagIndex + 1 < arguments.count {
                let verdict = classify(arguments[flagIndex + 1], depth: depth + 1)
                return verdict.risk > .needsConsent ? verdict : (.needsConsent, "runs a shell command")
            }
            return (.needsConsent, "runs a shell script")
        }

        if name == "eval" || name == "source" || name == "." {
            if hasComputedArgument { return (.alwaysAsk, "runs text that is worked out at run time") }
        }
        if name == "alias" {
            // alias x='rm -rf ~' : judge what the alias would run.
            var worstAlias: Verdict = (.needsConsent, "defines a shell alias")
            for argument in arguments {
                guard let equals = argument.firstIndex(of: "=") else { continue }
                let verdict = classify(String(argument[argument.index(after: equals)...]), depth: depth + 1)
                if verdict.risk > worstAlias.risk { worstAlias = verdict }
            }
            return worstAlias
        }
        if name == "eval" {
            let verdict = classify(arguments.joined(separator: " "), depth: depth + 1)
            return verdict.risk > .needsConsent ? verdict : (.needsConsent, "eval runs text as a command")
        }
        if name == "source" || name == "." {
            return (.needsConsent, "runs a script in this shell")
        }

        if name == "osascript" {
            var scriptLines: [String] = []
            var index = 0
            while index < arguments.count {
                if arguments[index] == "-e", index + 1 < arguments.count { scriptLines.append(arguments[index + 1]); index += 2 } else { index += 1 }
            }
            if scriptLines.isEmpty { return (pipedInto ? .alwaysAsk : .needsConsent, "runs an AppleScript Teachy cannot read ahead of time") }
            let verdict = AppleScriptClassifier.classify(scriptLines.joined(separator: "\n"))
            return (verdict.risk, "AppleScript: " + verdict.reason)
        }

        if interpreters.contains(name) {
            if arguments.count == 1, versionFlags.contains(arguments[0]) { return result((.safe, "asks a tool for its version")) }
            if pipedInto && (arguments.isEmpty || arguments == ["-"]) { return (.alwaysAsk, "pipes text straight into \(name)") }
            if hasComputedArgument { return (.alwaysAsk, "runs \(name) code that is worked out at run time") }
            // Inline code (-c, -e): Teachy cannot read a programming language, but it can spot the obvious.
            if let flagIndex = arguments.firstIndex(where: { ["-c", "-e", "-E", "--eval", "-p", "--print", "-r"].contains($0) }), flagIndex + 1 < arguments.count {
                let code = arguments[flagIndex + 1].lowercased()
                if let hint = destructiveCodeHints.first(where: { code.contains($0) }) {
                    return (.alwaysAsk, "the \(name) code mentions \(hint.trimmingCharacters(in: CharacterSet(charactersIn: "( ")))")
                }
            }
            return (.needsConsent, "runs \(name) code")
        }

        if let reason = alwaysAskCommands[name] { return (.alwaysAsk, reason) }
        if name.hasPrefix("mkfs") { return (.alwaysAsk, "formats a disk") }

        switch name {
        case "git":
            return result(classifyGit(arguments))
        case "gh":
            return result(classifyGitHubCLI(arguments))
        case "curl", "wget", "http", "https", "xh":
            return result(classifyHTTPClient(name: name, arguments: arguments))
        case "find":
            let dangerous = arguments.first(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) || $0.hasPrefix("-fprint") || $0 == "-fls" })
            if let dangerous {
                if dangerous == "-delete" { return (.alwaysAsk, "find -delete removes files") }
                if let execIndex = arguments.firstIndex(of: dangerous), execIndex + 1 < arguments.count {
                    let innerWords = Array(arguments[(execIndex + 1)...]).filter { $0 != "{}" && $0 != ";" && $0 != "+" && $0 != "\\;" }
                    let verdict = classifySegment(words: innerWords, pipedInto: false, depth: depth)
                    return verdict.risk > .needsConsent ? verdict : (.needsConsent, "find runs a command on each match")
                }
                return (.needsConsent, "find runs a command or writes a file")
            }
        case "defaults":
            let sub = arguments.first?.lowercased() ?? ""
            if sub == "read" || sub == "domains" || sub == "find" || sub == "read-type" { return result((.needsConsent, "reads app preferences")) }
            return (.alwaysAsk, "changes app or system preferences")
        case "kill", "killall", "pkill":
            return (.needsConsent, "stops a running program")
        case "npm", "pnpm", "yarn", "bun", "cargo", "twine", "pod", "vercel", "netlify", "fly", "flyctl", "wrangler", "firebase", "heroku", "docker", "kubectl", "terraform", "aws", "gcloud", "az", "supabase", "stripe":
            if arguments.count == 1, versionFlags.contains(arguments[0]) { return result((.safe, "asks a tool for its version")) }
            let joined = " " + arguments.joined(separator: " ").lowercased() + " "
            let publishing = [" publish", " deploy", " push", " release", " login", " logout", " destroy", " delete", " rm ", " remove ", " apply", " prune", " token", " secret", " --prod", " unpublish", " yank", " owner ", " adduser"]
            if let hit = publishing.first(where: { joined.contains($0) }) {
                return (.alwaysAsk, "\(name)\(hit.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " " + hit.trimmingCharacters(in: .whitespaces)) publishes, deletes or signs in")
            }
            return (.needsConsent, "runs \(name)")
        case "brew", "pip", "pip3", "port", "apt", "apt-get", "mas", "gem", "conda", "uv", "pipx":
            if arguments.count == 1, versionFlags.contains(arguments[0]) { return result((.safe, "asks a tool for its version")) }
            if let sub = arguments.first(where: { !$0.hasPrefix("-") })?.lowercased(), ["uninstall", "remove", "rm", "cleanup", "autoremove", "purge", "zap", "untap"].contains(sub) {
                return (.alwaysAsk, "\(name) \(sub) removes software")
            }
            return (.needsConsent, "\(name) installs or changes software")
        case "open", "say", "pbcopy", "mv", "cp", "mkdir", "touch", "ln", "chmod", "chown", "tee", "sed", "tar", "zip", "unzip", "make", "xcodebuild", "swiftc", "go", "rustc", "java", "javac", "screencapture", "history", "env", "printenv", "set", "export", "alias", "cd", "pushd", "popd", "less", "more", "vi", "vim", "nano", "emacs", "top", "ps", "lsof", "ifconfig", "ping", "dig", "nslookup", "whois":
            if arguments.count == 1, versionFlags.contains(arguments[0]) { return result((.safe, "asks a tool for its version")) }
            if let target = arguments.first(where: PathPolicy.looksLikePersistencePath) {
                return (.alwaysAsk, "\(name) touches \(target), which runs at login or in every shell")
            }
            return (.needsConsent, "\(name) is not on the read-only list")
        default:
            break
        }

        guard readOnlyCommands.contains(name) else {
            if let target = arguments.first(where: PathPolicy.looksLikePersistencePath) {
                return (.alwaysAsk, "\(name) touches \(target), which runs at login or in every shell")
            }
            return (.needsConsent, "\(name) is not on the read-only list")
        }

        // Read-only command: still not safe when pointed at private places.
        if name == "sort", arguments.contains(where: { $0 == "-o" || $0.hasPrefix("--output") }) {
            return (.needsConsent, "sort -o writes a file")
        }
        if name == "tree", arguments.contains("-o") { return (.needsConsent, "tree -o writes a file") }
        if name == "rg", arguments.contains(where: { $0.hasPrefix("--pre") }) { return (.needsConsent, "rg --pre runs a command") }
        if name == "date", arguments.contains(where: { !$0.hasPrefix("-") && !$0.hasPrefix("+") }) { return (.needsConsent, "date with a value sets the clock") }
        if name == "hostname", !arguments.isEmpty { return (.needsConsent, "hostname with a value changes it") }
        if let privateArgument = arguments.first(where: PathPolicy.argumentLooksPrivate) {
            return (.needsConsent, "reads a hidden or Library path (\(privateArgument))")
        }
        return result((.safe, "read-only command"))
    }

    private static func classifyGit(_ arguments: [String]) -> Verdict {
        var rest = arguments
        // Only -C <dir> is allowed before the subcommand; -c can run commands through config.
        while rest.first == "-C", rest.count >= 2 { rest.removeFirst(2) }
        guard let sub = rest.first else { return (.safe, "read-only command") }
        if sub == "--version" { return (.safe, "asks a tool for its version") }
        if sub.hasPrefix("-") { return (.needsConsent, "git with options Teachy cannot check") }
        let subArguments = Array(rest.dropFirst())
        let joined = subArguments.joined(separator: " ")

        switch sub {
        case "push":
            return (.alwaysAsk, "git push publishes commits")
        case "clean":
            return (.alwaysAsk, "git clean deletes untracked files")
        case "reset":
            return joined.contains("--hard") ? (.alwaysAsk, "git reset --hard throws away changes") : (.needsConsent, "changes the git index")
        case "checkout", "restore", "switch":
            if sub != "switch", subArguments.contains("--") || subArguments.contains(".") || sub == "restore" || subArguments.contains("-f") || subArguments.contains("--force") {
                return (.alwaysAsk, "git \(sub) can throw away changes")
            }
            return (.needsConsent, "changes the working tree")
        case "branch":
            if subArguments.contains(where: { $0 == "-d" || $0 == "-D" || $0 == "--delete" }) { return (.alwaysAsk, "deletes a branch") }
            let readOnlyFlags: Set<String> = ["-a", "-r", "-v", "-vv", "--list", "--show-current", "--all", "--remotes"]
            return subArguments.allSatisfy(readOnlyFlags.contains) ? (.safe, "read-only command") : (.needsConsent, "changes branches")
        case "tag":
            if subArguments.contains(where: { $0 == "-d" || $0 == "--delete" }) { return (.alwaysAsk, "deletes a tag") }
            return subArguments.isEmpty || subArguments == ["-l"] || subArguments == ["--list"] ? (.safe, "read-only command") : (.needsConsent, "changes tags")
        case "stash":
            if subArguments.first == "list" || subArguments.first == "show" { return (.safe, "read-only command") }
            if subArguments.first == "drop" || subArguments.first == "clear" { return (.alwaysAsk, "throws away stashed changes") }
            return (.needsConsent, "changes the stash")
        case "remote":
            return subArguments.isEmpty || subArguments == ["-v"] || subArguments.first == "show" || subArguments.first == "get-url" ? (.safe, "read-only command") : (.needsConsent, "changes git remotes")
        case "status", "log", "diff", "show", "rev-parse", "describe", "ls-files", "blame", "shortlog", "ls-tree", "cat-file", "merge-base", "rev-list", "grep", "reflog", "whatchanged", "name-rev", "show-ref":
            if sub == "reflog", let first = subArguments.first, first == "expire" || first == "delete" { return (.alwaysAsk, "deletes reflog entries") }
            if subArguments.contains(where: { $0.hasPrefix("--output") || $0 == "--ext-diff" || $0.hasPrefix("--exec") || $0 == "-O" || $0.hasPrefix("--open-files-in-pager") }) {
                return (.needsConsent, "git \(sub) with an option that writes or runs something")
            }
            if let privateArgument = subArguments.first(where: PathPolicy.argumentLooksPrivate) {
                return (.needsConsent, "reads a hidden or Library path (\(privateArgument))")
            }
            return (.safe, "read-only command")
        case "filter-branch", "gc", "prune", "rm", "update-ref", "worktree":
            if sub == "worktree", subArguments.first == "list" { return (.safe, "read-only command") }
            return (.alwaysAsk, "git \(sub) can delete history or files")
        case "credential", "credential-osxkeychain":
            return (.alwaysAsk, "touches stored git credentials")
        default:
            return (.needsConsent, "git \(sub) changes the repository")
        }
    }

    private static func classifyGitHubCLI(_ arguments: [String]) -> Verdict {
        let joined = arguments.joined(separator: " ").lowercased()
        if arguments.count == 1, versionFlags.contains(arguments[0]) { return (.safe, "asks a tool for its version") }
        let risky = ["create", "merge", "close", "delete", "comment", "review", "release", "auth", "secret", "api", "edit", "reopen", "fork", "sync", "run rerun", "workflow run", "gist", "ssh-key", "gpg-key", "transfer", "archive", "rename"]
        if risky.contains(where: { joined.contains($0) }) { return (.alwaysAsk, "gh posts, changes or deletes things on GitHub") }
        return (.needsConsent, "talks to GitHub as you")
    }

    private static func classifyHTTPClient(name: String, arguments: [String]) -> Verdict {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let lower = argument.lowercased()
            let next = index + 1 < arguments.count ? arguments[index + 1].uppercased() : ""
            if argument == "-X" || lower == "--request" || lower == "--method" {
                if next != "GET" && next != "HEAD" { return (.alwaysAsk, "\(name) sends data (\(next.isEmpty ? "custom method" : next))") }
            }
            if argument.hasPrefix("-X"), argument.count > 2 {
                let method = String(argument.dropFirst(2)).uppercased()
                if method != "GET" && method != "HEAD" { return (.alwaysAsk, "\(name) sends data (\(method))") }
            }
            if lower.hasPrefix("--request=") || lower.hasPrefix("--method=") {
                let method = String(lower.split(separator: "=", maxSplits: 1).last ?? "").uppercased()
                if method != "GET" && method != "HEAD" { return (.alwaysAsk, "\(name) sends data (\(method))") }
            }
            let sendingFlags = ["-d", "-F", "-T", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii", "--form", "--form-string", "--upload-file", "--json", "--post-data", "--post-file", "--body-data", "--body-file", "-u", "--user", "--oauth2-bearer", "--netrc", "-n", "-K", "--config", "-b", "--cookie"]
            if sendingFlags.contains(argument) || sendingFlags.contains(where: { $0.hasPrefix("--") && lower.hasPrefix($0 + "=") }) {
                return (.alwaysAsk, "\(name) sends data or sign-in details")
            }
            // Short flags glued to a value: -d'x=1', -Ffile=@x
            if argument.count > 2, argument.hasPrefix("-"), !argument.hasPrefix("--"), ["d", "F", "T", "u", "b", "K"].contains(String(argument.dropFirst().prefix(1))) {
                return (.alwaysAsk, "\(name) sends data or sign-in details")
            }
            if lower.contains("authorization:") || lower.contains("cookie:") || lower.contains("x-api-key") || lower.contains("api_key=") || lower.contains("token=") {
                return (.alwaysAsk, "\(name) sends sign-in details")
            }
            if (name == "http" || name == "https" || name == "xh"), ["POST", "PUT", "PATCH", "DELETE"].contains(argument.uppercased()) {
                return (.alwaysAsk, "\(name) sends data (\(argument.uppercased()))")
            }
            index += 1
        }
        return (.needsConsent, "\(name) talks to the network and can write files")
    }
}

// MARK: - Shell lexer

/// A small, deliberately conservative shell reader. It does not try to be zsh: it splits a
/// command line into simple commands and reports every construct it cannot see through.
enum ShellLexer {
    static let substitutionMarker = "\u{1}SUB\u{1}"

    struct Segment: Equatable {
        var words: [String]
        var pipedInto: Bool
    }

    struct Scan {
        var segments: [Segment] = []
        var nested: [String] = []
        var redirectOutTargets: [String] = []
        var redirectInTargets: [String] = []
        var hasSubstitution = false
        var hasExpansion = false
        var hasHeredoc = false
        var hasBackground = false
        var hasGrouping = false
        var unbalanced = false

        var allWords: [String] { segments.flatMap(\.words) }
    }

    private enum PendingRedirect { case none, out, input, discard }

    static func scan(_ text: String) -> Scan {
        var scan = Scan()
        let characters = Array(text)
        var index = 0
        var word = ""
        var wordStarted = false
        var words: [String] = []
        var nextSegmentIsPiped = false
        var currentSegmentIsPiped = false
        var pending: PendingRedirect = .none

        func endWord() {
            guard wordStarted else { return }
            switch pending {
            case .out: scan.redirectOutTargets.append(word)
            case .input: scan.redirectInTargets.append(word)
            case .discard: break
            case .none: words.append(word)
            }
            pending = .none
            word = ""
            wordStarted = false
        }
        func endSegment(pipe: Bool = false) {
            endWord()
            if pending != .none { scan.unbalanced = true; pending = .none }
            if !words.isEmpty { scan.segments.append(Segment(words: words, pipedInto: currentSegmentIsPiped)) }
            words = []
            currentSegmentIsPiped = pipe
            nextSegmentIsPiped = false
        }
        func peek(_ offset: Int = 1) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }
        /// Reads a balanced (...) starting just after the opening paren; returns its content.
        func readParenthesised() -> String {
            var depth = 1
            var content = ""
            var inSingle = false
            var inDouble = false
            while index < characters.count {
                let character = characters[index]
                if inSingle {
                    if character == "'" { inSingle = false }
                } else if character == "\\" && index + 1 < characters.count {
                    content.append(character); index += 1; content.append(characters[index]); index += 1; continue
                } else if inDouble {
                    if character == "\"" { inDouble = false }
                } else if character == "'" {
                    inSingle = true
                } else if character == "\"" {
                    inDouble = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 { index += 1; return content }
                }
                content.append(character)
                index += 1
            }
            scan.unbalanced = true
            return content
        }
        func readBacktick() -> String {
            var content = ""
            while index < characters.count {
                let character = characters[index]
                if character == "\\" && index + 1 < characters.count {
                    index += 1; content.append(characters[index]); index += 1; continue
                }
                if character == "`" { index += 1; return content }
                content.append(character)
                index += 1
            }
            scan.unbalanced = true
            return content
        }
        func handleDollar() {
            // characters[index] == "$"
            // $HOME and ${HOME} are the one expansion with a known value: read them as ~.
            for spelling in ["$HOME", "${HOME}"] {
                let end = index + spelling.count
                guard end <= characters.count, String(characters[index..<end]) == spelling else { continue }
                let next: Character? = end < characters.count ? characters[end] : nil
                if spelling == "$HOME", let next, next.isLetter || next.isNumber || next == "_" { continue }
                word += "~"
                wordStarted = true
                index = end
                return
            }
            if peek() == "(" {
                index += 2
                scan.nested.append(readParenthesised())
                scan.hasSubstitution = true
                word += substitutionMarker
            } else if peek() == "'" && !wordStarted {
                // $'…' ANSI quoting: can hide any character, so treat as opaque.
                scan.hasExpansion = true
                word += "$"
                index += 1
            } else {
                scan.hasExpansion = true
                word += "$"
                index += 1
            }
            wordStarted = true
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                if let next = peek() {
                    if next != "\n" { word.append(next); wordStarted = true }
                    index += 2
                } else {
                    index += 1
                }
            case "'":
                wordStarted = true
                index += 1
                var closed = false
                while index < characters.count {
                    if characters[index] == "'" { closed = true; index += 1; break }
                    word.append(characters[index])
                    index += 1
                }
                if !closed { scan.unbalanced = true }
            case "\"":
                wordStarted = true
                index += 1
                var closed = false
                while index < characters.count {
                    let inner = characters[index]
                    if inner == "\"" { closed = true; index += 1; break }
                    if inner == "\\", let next = peek() {
                        if "\"\\$`\n".contains(next) { if next != "\n" { word.append(next) } } else { word.append(inner); word.append(next) }
                        index += 2
                    } else if inner == "$" {
                        handleDollar()
                    } else if inner == "`" {
                        index += 1
                        scan.nested.append(readBacktick())
                        scan.hasSubstitution = true
                        word += substitutionMarker
                    } else {
                        word.append(inner)
                        index += 1
                    }
                }
                if !closed { scan.unbalanced = true }
            case "$":
                handleDollar()
            case "`":
                index += 1
                scan.nested.append(readBacktick())
                scan.hasSubstitution = true
                word += substitutionMarker
                wordStarted = true
            case " ", "\t":
                endWord()
                index += 1
            case "\n", ";":
                endSegment()
                index += 1
            case "#":
                if wordStarted {
                    word.append(character); index += 1
                } else {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                }
            case "&":
                if peek() == "&" {
                    endSegment(); index += 2
                } else if peek() == ">" {
                    // &> file : both streams to a file
                    endWord(); pending = .out; index += 2
                    if index < characters.count, characters[index] == ">" { index += 1 }
                } else {
                    scan.hasBackground = true
                    endSegment(); index += 1
                }
            case "|":
                if peek() == "|" {
                    endSegment(); index += 2
                } else {
                    endSegment(pipe: true); index += 1
                    if index < characters.count, characters[index] == "&" { index += 1 }
                }
            case ">":
                // A bare number just before > is a file descriptor, not an argument.
                if wordStarted, !word.isEmpty, word.allSatisfy(\.isNumber) { word = ""; wordStarted = false } else { endWord() }
                if peek() == "(" {
                    index += 2
                    scan.nested.append(readParenthesised())
                    scan.hasSubstitution = true
                    word += substitutionMarker
                    wordStarted = true
                    break
                }
                index += 1
                if index < characters.count, characters[index] == ">" || characters[index] == "|" { index += 1 }
                if index < characters.count, characters[index] == "&" {
                    // >&2, >&- duplicate a descriptor; >&file writes a file.
                    index += 1
                    var descriptor = ""
                    while index < characters.count, characters[index].isNumber || characters[index] == "-" { descriptor.append(characters[index]); index += 1 }
                    if descriptor.isEmpty { pending = .out }
                } else {
                    pending = .out
                }
            case "<":
                if wordStarted, !word.isEmpty, word.allSatisfy(\.isNumber) { word = ""; wordStarted = false } else { endWord() }
                if peek() == "(" {
                    index += 2
                    scan.nested.append(readParenthesised())
                    scan.hasSubstitution = true
                    word += substitutionMarker
                    wordStarted = true
                } else if peek() == "<" {
                    scan.hasHeredoc = true
                    index += 2
                    if index < characters.count, characters[index] == "<" || characters[index] == "-" { index += 1 }
                    pending = .discard
                } else {
                    index += 1
                    if index < characters.count, characters[index] == "&" { index += 1 }
                    pending = .input
                }
            case "(", ")":
                if wordStarted && character == "(" {
                    // name() { … } or a glob qualifier: either way, not something we can read through.
                    scan.hasGrouping = true
                    endSegment(); index += 1
                } else {
                    scan.hasGrouping = true
                    endSegment(); index += 1
                }
            default:
                word.append(character)
                wordStarted = true
                index += 1
            }
        }
        endSegment()
        _ = nextSegmentIsPiped
        return scan
    }
}
