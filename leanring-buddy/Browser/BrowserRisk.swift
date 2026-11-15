//
//  BrowserRisk.swift
//  leanring-buddy
//
//  How risky each browser tool call is, for the permission gate. Pure: no
//  AppKit, no I/O. Tested by scripts/tests/run_chrome_tests.sh.
//
//    safe          read / screenshot / wait / scroll / close the job's tabs
//    needsConsent  open / navigate / click / type / select / key on a site:
//                  asked once per job per site ("always allow" is per site too)
//    alwaysAsk     a click or submit whose control says buy / pay / order /
//                  send / post / delete…; every file upload; anything on a
//                  banking or payment site
//
//  The raw values match Agent/ToolPolicy.swift's ToolRisk so the gate can map
//  one to the other with `ToolRisk(rawValue:)`.
//

import Foundation

nonisolated enum BrowserRisk: Int, Comparable, Equatable, Sendable {
    case safe = 0
    case needsConsent = 1
    case alwaysAsk = 2

    static func < (lhs: BrowserRisk, rhs: BrowserRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Facts about the page and the control a call is about, gathered from the extension just before the call.
nonisolated struct BrowserRiskContext: Equatable, Sendable {
    /// Host of the page the tab is on now ("shop.example.com"). Empty when unknown.
    var siteHost: String = ""
    /// The control the call targets, as listed: `button "Place order"`. Empty when unknown.
    var elementLabel: String = ""
    /// The submit button of the form the control (or the focused field) belongs to.
    var submitLabel: String = ""
    /// The control is itself a submit button.
    var isSubmit: Bool = false

    init(siteHost: String = "", elementLabel: String = "", submitLabel: String = "", isSubmit: Bool = false) {
        self.siteHost = siteHost
        self.elementLabel = elementLabel
        self.submitLabel = submitLabel
        self.isSubmit = isSubmit
    }
}

nonisolated struct BrowserRiskDecision: Equatable, Sendable {
    let risk: BrowserRisk
    /// Why it landed there. Shown after "I ask every time for this:".
    let reason: String
    /// Completes "Want me to …?".
    let summary: String
    /// The exact thing, shown small under the question.
    let detail: String
    /// What a yes is remembered for: the site's host. Empty = the browser as a whole.
    let siteScope: String
}

nonisolated enum BrowserRiskClassifier {
    static let toolNames: [String] = [
        "browser_open", "browser_read", "browser_click", "browser_type", "browser_select", "browser_key",
        "browser_scroll", "browser_navigate", "browser_wait", "browser_screenshot", "browser_upload", "browser_close_job"
    ]

    /// The class a tool falls in before the page and the control are looked at.
    static func baseRisk(forTool toolName: String) -> BrowserRisk {
        switch toolName {
        case "browser_read", "browser_screenshot", "browser_wait", "browser_scroll", "browser_close_job":
            return .safe
        case "browser_upload":
            return .alwaysAsk
        default:
            return .needsConsent
        }
    }

    /// Tools that only look. Used for the guided-step tool set.
    static let readOnlyToolNames: Set<String> = ["browser_read", "browser_screenshot", "browser_wait", "browser_scroll"]

    static func classify(toolName: String, arguments: [String: Any], context: BrowserRiskContext = BrowserRiskContext()) -> BrowserRiskDecision {
        let urlArgument = string(arguments["url"])
        let goesSomewhere = toolName == "browser_open" || toolName == "browser_navigate"
        let usesCurrentTab = toolName == "browser_open" && (arguments["current_tab"] as? Bool == true)
        let site = goesSomewhere && !urlArgument.isEmpty ? host(of: urlArgument) : context.siteHost.lowercased()
        let siteLabel = site.isEmpty ? (usesCurrentTab ? "the tab you have open" : "your browser") : site
        let money = isFinancialHost(site)

        func decision(_ risk: BrowserRisk, _ reason: String, summary: String, detail: String = "") -> BrowserRiskDecision {
            BrowserRiskDecision(risk: risk, reason: reason, summary: summary, detail: clipped(detail), siteScope: site)
        }
        let workSummary = site.isEmpty && !usesCurrentTab ? "work in your browser" : "work on \(siteLabel) in your browser"

        switch toolName {
        case "browser_wait", "browser_scroll":
            return decision(.safe, "only waits or scrolls", summary: "look at \(siteLabel)")

        case "browser_close_job":
            return decision(.safe, "closes only the tabs this job opened", summary: "close the tabs I opened")

        case "browser_read", "browser_screenshot":
            if money {
                return decision(.alwaysAsk, "\(site) is a banking or payment site", summary: "read \(site) in your browser", detail: toolName == "browser_read" ? "read the page" : "take a picture of the page")
            }
            return decision(.safe, "reads a tab the job is working in", summary: "read \(siteLabel)")

        case "browser_open", "browser_navigate":
            let step = string(arguments["action"]).lowercased()
            let action = usesCurrentTab ? "use the tab you have open"
                : !urlArgument.isEmpty ? "open \(urlArgument)"
                : step == "reload" ? "reload the page" : step.isEmpty ? "open a page" : "go \(step)"
            if goesSomewhere && !usesCurrentTab && !urlArgument.isEmpty && !isWebURL(urlArgument) {
                // The extension refuses these too; asking is the conservative answer here.
                return decision(.alwaysAsk, "that is not a web address", summary: "open \(clipped(urlArgument, limit: 80)) in your browser", detail: action)
            }
            if money {
                return decision(.alwaysAsk, "\(site) is a banking or payment site", summary: "open \(site) in your browser", detail: action)
            }
            return decision(.needsConsent, "opens a site in your browser, signed in as you", summary: workSummary, detail: action)

        case "browser_upload":
            let path = string(arguments["path"])
            let name = (path as NSString).lastPathComponent
            let reason = looksLikeCredentialPath(path)
                ? "this file looks like keys or passwords, and it would leave this Mac"
                : "a file from this Mac would go to \(siteLabel)"
            return decision(.alwaysAsk, reason, summary: "send \(name.isEmpty ? "a file" : name) to \(siteLabel)", detail: path)

        case "browser_click":
            let target = context.elementLabel.isEmpty ? "a control" : context.elementLabel
            let action = "click \(target)"
            if money {
                return decision(.alwaysAsk, "\(site) is a banking or payment site", summary: "\(action) on \(site)", detail: action)
            }
            if arguments["accept_dialogs"] as? Bool == true {
                return decision(.alwaysAsk, "it would answer OK to whatever the page asks next", summary: "\(action) on \(siteLabel) and say OK to its question", detail: action)
            }
            let words = context.elementLabel + (context.isSubmit ? " " + context.submitLabel : "")
            if let word = SensitiveBrowserWords.firstMatch(in: words) {
                return decision(.alwaysAsk, "the control says \"\(word)\"", summary: "\(action) on \(siteLabel)", detail: action)
            }
            return decision(.needsConsent, "clicks on \(siteLabel) for you", summary: workSummary, detail: action)

        case "browser_type":
            let target = context.elementLabel.isEmpty ? "a field" : context.elementLabel
            let submits = arguments["submit"] as? Bool == true
            let action = "type into \(target)" + (submits ? " and press Return" : "")
            if money {
                return decision(.alwaysAsk, "\(site) is a banking or payment site", summary: "\(action) on \(site)", detail: string(arguments["text"]))
            }
            if submits, let word = SensitiveBrowserWords.firstMatch(in: context.submitLabel) {
                return decision(.alwaysAsk, "Return would press \"\(context.submitLabel)\" (\(word))", summary: "\(action) on \(siteLabel)", detail: string(arguments["text"]))
            }
            return decision(.needsConsent, "types on \(siteLabel) for you", summary: workSummary, detail: "\(action): \(string(arguments["text"]))")

        case "browser_select":
            let target = context.elementLabel.isEmpty ? "a list" : context.elementLabel
            let action = "choose \"\(string(arguments["option"]))\" in \(target)"
            if money {
                return decision(.alwaysAsk, "\(site) is a banking or payment site", summary: "\(action) on \(site)", detail: action)
            }
            return decision(.needsConsent, "changes a choice on \(siteLabel)", summary: workSummary, detail: action)

        case "browser_key":
            let combo = string(arguments["combo"])
            let parts = Set(combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init))
            let isReturn = parts.contains("enter") || parts.contains("return")
            let hasCommand = parts.contains("cmd") || parts.contains("command") || parts.contains("meta") || parts.contains("ctrl") || parts.contains("control")
            let action = "press \(combo)"
            if money {
                return decision(.alwaysAsk, "\(site) is a banking or payment site", summary: "\(action) on \(site)", detail: action)
            }
            if isReturn && hasCommand {
                return decision(.alwaysAsk, "that shortcut sends or submits on most sites", summary: "\(action) on \(siteLabel)", detail: action)
            }
            if isReturn, let word = SensitiveBrowserWords.firstMatch(in: context.submitLabel) {
                return decision(.alwaysAsk, "Return would press \"\(context.submitLabel)\" (\(word))", summary: "\(action) on \(siteLabel)", detail: action)
            }
            return decision(.needsConsent, "presses keys on \(siteLabel) for you", summary: workSummary, detail: action)

        default:
            return decision(.needsConsent, "a browser action Teachy cannot prove is read-only", summary: workSummary, detail: toolName)
        }
    }

    // MARK: Sites that move money

    /// A small list on purpose: the big banks, brokers, wallets and payment pages. Matched as the host or any subdomain.
    static let financialHosts: [String] = [
        // payments and wallets
        "paypal.com", "venmo.com", "cash.app", "wise.com", "revolut.com", "stripe.com", "squareup.com",
        "pay.google.com", "wallet.google.com", "payments.google.com", "pay.amazon.com", "klarna.com", "affirm.com",
        "razorpay.com", "paytm.com", "phonepe.com", "westernunion.com", "remitly.com", "zellepay.com",
        // banks
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "citibank.com", "capitalone.com",
        "usbank.com", "americanexpress.com", "discover.com", "ally.com", "sofi.com", "chime.com",
        "hsbc.com", "hsbc.co.uk", "barclays.co.uk", "lloydsbank.com", "natwest.com", "santander.co.uk", "monzo.com", "starlingbank.com",
        "rbcroyalbank.com", "td.com", "scotiabank.com", "bmo.com", "commbank.com.au", "anz.com.au", "westpac.com.au", "nab.com.au",
        "deutsche-bank.de", "ing.com", "bnpparibas.com", "n26.com",
        "hdfcbank.com", "icicibank.com", "onlinesbi.sbi", "sbi.co.in", "axisbank.com", "kotak.com",
        // brokers and crypto
        "fidelity.com", "schwab.com", "vanguard.com", "etrade.com", "robinhood.com", "interactivebrokers.com",
        "coinbase.com", "binance.com", "kraken.com", "gemini.com", "zerodha.com", "groww.in"
    ]

    static func isFinancialHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        guard !lower.isEmpty else { return false }
        return financialHosts.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }

    // MARK: Helpers

    static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let value { return "\(value)" }
        return ""
    }

    static func clipped(_ text: String, limit: Int = 300) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func host(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URLComponents(string: withScheme)?.host?.lowercased() ?? ""
    }

    static func isWebURL(_ urlString: String) -> Bool {
        let lower = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    static func looksLikeCredentialPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let markers = ["/.ssh", "id_rsa", "id_ed25519", "id_ecdsa", ".pem", ".p12", ".keystore", "keychain", "/.aws", "/.gnupg",
                       ".netrc", "credentials", "secrets", "wallet", "cookies", "login data", "1password", ".kdbx"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        return lower.range(of: #"(^|/)\.env($|[./])"#, options: .regularExpression) != nil
    }
}

/// Words on a button or link that mean money moves, something is sent or posted, or something is deleted.
nonisolated enum SensitiveBrowserWords {
    static let words: [String] = [
        "buy", "pay", "purchase", "checkout", "check out", "place order", "order", "confirm purchase", "confirm order",
        "confirm payment", "confirm and pay", "complete purchase", "subscribe", "donate", "transfer", "withdraw", "deposit", "bid",
        "send", "post", "publish", "tweet", "reply", "comment", "share", "submit",
        "delete", "remove", "erase", "discard", "destroy", "deactivate", "close account", "cancel subscription", "unsubscribe",
        "sign out", "log out", "revoke"
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
