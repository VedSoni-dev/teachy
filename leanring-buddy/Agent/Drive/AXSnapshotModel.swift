//
//  AXSnapshotModel.swift
//  leanring-buddy
//
//  The plain-data half of Drive's accessibility snapshot: which raw elements
//  are worth showing, how they are numbered so a number keeps meaning the same
//  control from one snapshot to the next, the text the model reads, the diff
//  after an action, and the check for password / code / card fields.
//  Pure: no AppKit, no Accessibility calls. The walker lives in AXSnapshot.swift.
//

import CoreGraphics
import Foundation

/// One element as the walker read it, before filtering.
struct AXRawNode: Equatable {
    var role: String = ""
    var subrole: String = ""
    var title: String = ""
    var label: String = ""        // AXDescription
    var value: String = ""
    var placeholder: String = ""
    var help: String = ""
    var identifier: String = ""
    /// Global CG coordinates (top-left origin).
    var frame: CGRect = .zero
    var isEnabled: Bool = true
    var isFocused: Bool = false
}

struct AXSnapshotElement: Equatable {
    let index: Int
    let role: String
    let subrole: String
    /// The best human name: title, else description, else help.
    let name: String
    let value: String
    let placeholder: String
    let frame: CGRect
    let isFocused: Bool
    let isSecure: Bool
    let identifier: String

    /// `[12] button "Export…"`
    var line: String {
        var text = "[\(index)] \(AXSnapshotFormatter.friendlyRole(role: role, subrole: subrole))"
        if !name.isEmpty { text += " \"\(name)\"" }
        if isSecure {
            text += " (hidden)"
        } else if !value.isEmpty, value != name {
            text += " = \"\(value)\""
        }
        if !placeholder.isEmpty, value.isEmpty { text += " (placeholder \"\(placeholder)\")" }
        if isFocused { text += " (focused)" }
        return text
    }

    /// Short form for diffs and consent text: `button "Export…"`.
    var shortDescription: String {
        let role = AXSnapshotFormatter.friendlyRole(role: role, subrole: subrole)
        if !name.isEmpty { return "\(role) \"\(name)\"" }
        if !placeholder.isEmpty { return "\(role) \"\(placeholder)\"" }
        return role
    }
}

struct AXSnapshotData: Equatable {
    var appName: String
    var windowTitle: String
    var windowFrame: CGRect
    var elements: [AXSnapshotElement]
    /// True when the window had more elements than the cap.
    var truncated: Bool

    func element(at index: Int) -> AXSnapshotElement? {
        elements.first { $0.index == index }
    }

    var focusedElement: AXSnapshotElement? { elements.first(where: \.isFocused) }
}

// MARK: - Building

enum AXSnapshotBuilder {
    static let defaultCap = 300
    /// Plain text can crowd out controls on a busy page, so it gets a smaller share.
    static let staticTextShare = 110

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXComboBox", "AXSlider", "AXCell", "AXDisclosureTriangle", "AXIncrementor",
        "AXColorWell", "AXTab", "AXTabButton", "AXSwitch", "AXToggle", "AXSearchField", "AXSecureTextField", "AXDateField", "AXTimeField", "AXStepper", "AXMenuBarItem"
    ]
    static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField", "AXDateField", "AXTimeField"]
    static let readableRoles: Set<String> = ["AXStaticText", "AXHeading", "AXImage", "AXWebArea"]

    /// Visible + enabled + on-screen, and worth a line.
    static func isWorthShowing(_ node: AXRawNode, windowFrame: CGRect) -> Bool {
        guard node.frame.width >= 1, node.frame.height >= 1 else { return false }
        let isMenuItem = node.role == "AXMenuItem"
        // An open menu can hang outside its window; everything else must touch it.
        if !isMenuItem, !windowFrame.isEmpty, !node.frame.intersects(windowFrame) { return false }
        let hasName = !bestName(node).isEmpty || !node.value.isEmpty || !node.placeholder.isEmpty
        if interactiveRoles.contains(node.role) {
            guard node.isEnabled else { return false }
            // A nameless cell or radio is noise; a nameless text field is still a place to type.
            return hasName || textEntryRoles.contains(node.role) || node.role == "AXButton" || node.role == "AXCheckBox" || node.role == "AXPopUpButton" || node.role == "AXSlider"
        }
        if readableRoles.contains(node.role) {
            if node.role == "AXWebArea" { return true }
            return hasName
        }
        return false
    }

    static func bestName(_ node: AXRawNode) -> String {
        for candidate in [node.title, node.label, node.help] {
            let cleaned = clean(candidate)
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    static func clean(_ text: String, limit: Int = 80) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened
    }

    static func isSecure(_ node: AXRawNode) -> Bool {
        node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
    }

    struct Result {
        var snapshot: AXSnapshotData
        /// For each kept element, its position in the `nodes` array (so the walker can keep the live handle).
        var sourcePositions: [Int: Int]
        /// identity key → index, to feed into the next build.
        var indexByIdentity: [String: Int]
        var nextFreeIndex: Int
    }

    /// Filters `nodes` (already in breadth-first order) and numbers what is kept.
    /// An element that was in the previous snapshot keeps its number; new ones get fresh numbers.
    static func build(
        appName: String,
        windowTitle: String,
        windowFrame: CGRect,
        nodes: [AXRawNode],
        previousIndexByIdentity: [String: Int] = [:],
        nextFreeIndex: Int = 1,
        cap: Int = defaultCap
    ) -> Result {
        var kept: [(position: Int, node: AXRawNode, identity: String)] = []
        var occurrenceCount: [String: Int] = [:]
        var staticTextCount = 0
        var truncated = false

        for (position, node) in nodes.enumerated() {
            guard isWorthShowing(node, windowFrame: windowFrame) else { continue }
            if kept.count >= cap { truncated = true; break }
            if node.role == "AXStaticText" || node.role == "AXImage" {
                if staticTextCount >= staticTextShare { truncated = true; continue }
                staticTextCount += 1
            }
            // Identity: role + name (+ placeholder, identifier), and which one of its twins it is.
            // Not the value and not the frame: typing or scrolling must not renumber a control.
            let base = [node.role, node.subrole, bestName(node), clean(node.placeholder), node.identifier].joined(separator: "\u{1}")
            let occurrence = occurrenceCount[base, default: 0]
            occurrenceCount[base] = occurrence + 1
            kept.append((position, node, base + "#\(occurrence)"))
        }

        var free = nextFreeIndex
        var usedIndices = Set<Int>()
        var indexByIdentity: [String: Int] = [:]
        var elements: [AXSnapshotElement] = []
        var sourcePositions: [Int: Int] = [:]

        for item in kept {
            let index: Int
            if let previous = previousIndexByIdentity[item.identity], !usedIndices.contains(previous) {
                index = previous
            } else {
                while usedIndices.contains(free) || previousIndexByIdentity.values.contains(free) { free += 1 }
                index = free
                free += 1
            }
            usedIndices.insert(index)
            indexByIdentity[item.identity] = index
            sourcePositions[index] = item.position
            let secure = isSecure(item.node)
            elements.append(AXSnapshotElement(
                index: index,
                role: item.node.role,
                subrole: item.node.subrole,
                name: bestName(item.node),
                value: secure ? "" : clean(item.node.value),
                placeholder: clean(item.node.placeholder),
                frame: item.node.frame,
                isFocused: item.node.isFocused,
                isSecure: secure,
                identifier: item.node.identifier
            ))
        }

        return Result(
            snapshot: AXSnapshotData(appName: appName, windowTitle: clean(windowTitle, limit: 120), windowFrame: windowFrame, elements: elements, truncated: truncated),
            sourcePositions: sourcePositions,
            indexByIdentity: indexByIdentity,
            nextFreeIndex: max(free, (usedIndices.max() ?? 0) + 1)
        )
    }
}

// MARK: - Text for the model

enum AXSnapshotFormatter {
    static func friendlyRole(role: String, subrole: String) -> String {
        switch subrole {
        case "AXSecureTextField": return "secure field"
        case "AXSearchField": return "search field"
        case "AXTabButton": return "tab"
        case "AXSwitch", "AXToggle": return "switch"
        case "AXCloseButton": return "close button"
        case "AXMinimizeButton": return "minimize button"
        case "AXZoomButton", "AXFullScreenButton": return "zoom button"
        default: break
        }
        switch role {
        case "AXButton": return "button"
        case "AXLink": return "link"
        case "AXTextField": return "text field"
        case "AXSecureTextField": return "secure field"
        case "AXTextArea": return "text area"
        case "AXStaticText": return "text"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "popup"
        case "AXMenuButton": return "menu button"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXComboBox": return "combo box"
        case "AXSlider": return "slider"
        case "AXCell": return "cell"
        case "AXImage": return "image"
        case "AXWebArea": return "web page"
        case "AXHeading": return "heading"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXIncrementor", "AXStepper": return "stepper"
        case "AXColorWell": return "color well"
        default:
            let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return stripped.lowercased()
        }
    }

    static func text(for snapshot: AXSnapshotData) -> String {
        var lines: [String] = []
        let window = snapshot.windowTitle.isEmpty ? "(untitled window)" : "\"\(snapshot.windowTitle)\""
        lines.append("\(snapshot.appName) — window \(window) — \(snapshot.elements.count) elements")
        if snapshot.elements.isEmpty {
            lines.append("(no readable controls: the app may not expose accessibility, or the window is empty. Use capture_screen, then drive_click_point as a last resort.)")
        }
        lines.append(contentsOf: snapshot.elements.map(\.line))
        if snapshot.truncated { lines.append("(more elements exist than are listed; scroll or open the part you need, then snapshot again)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Diff after an action

enum AXSnapshotDiff {
    /// A short account of what changed, so the model can verify before its next step.
    static func describe(action: String, before: AXSnapshotData?, after: AXSnapshotData) -> String {
        guard let before else {
            return "\(action). Now showing:\n\(AXSnapshotFormatter.text(for: after))"
        }
        var parts: [String] = [action]

        if before.appName != after.appName {
            parts.append("front app is now \(after.appName)")
        }
        if before.windowTitle != after.windowTitle {
            parts.append("window title changed to \"\(after.windowTitle)\"")
        }

        let beforeByIndex = Dictionary(uniqueKeysWithValues: before.elements.map { ($0.index, $0) })
        let afterByIndex = Dictionary(uniqueKeysWithValues: after.elements.map { ($0.index, $0) })

        let added = after.elements.filter { beforeByIndex[$0.index] == nil }
        let removed = before.elements.filter { afterByIndex[$0.index] == nil }
        let changed = after.elements.compactMap { element -> String? in
            guard let old = beforeByIndex[element.index] else { return nil }
            guard old.value != element.value, !element.isSecure else { return nil }
            return "[\(element.index)] \(element.shortDescription): \"\(old.value)\" → \"\(element.value)\""
        }

        if !changed.isEmpty {
            parts.append("changed: " + summarize(changed, limit: 8))
        }
        if !added.isEmpty {
            parts.append("new elements: " + summarize(added.map(\.line), limit: 14))
        }
        if !removed.isEmpty {
            parts.append("gone: " + summarize(removed.map { "[\($0.index)] \($0.shortDescription)" }, limit: 6))
        }

        let oldFocus = before.focusedElement?.index
        let newFocus = after.focusedElement?.index
        if oldFocus != newFocus, let focused = after.focusedElement {
            parts.append("focus is on [\(focused.index)] \(focused.shortDescription)")
        }

        if parts.count == 1 {
            parts.append("nothing visible changed (check it worked before going on; a snapshot or screenshot will tell)")
        }
        return parts.joined(separator: "; ")
    }

    private static func summarize(_ items: [String], limit: Int) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(shown), and \(items.count - limit) more (drive_snapshot lists them)" : shown
    }
}

// MARK: - Secrets

enum SecretFieldDetector {
    static let fieldWords: [String] = [
        "password", "passcode", "passphrase", "pin code", "2fa", "two-factor", "two factor", "verification code",
        "security code", "one-time", "one time code", "otp", "authenticator", "auth code", "sms code",
        "card number", "credit card", "debit card", "cvv", "cvc", "expiry", "expiration date", "iban", "routing number",
        "account number", "social security", "ssn", "recovery key", "seed phrase", "private key", "secret key", "api key"
    ]

    /// Why Drive must stop and hand back, or nil when the window is fine to drive.
    static func reasonToHandBack(in snapshot: AXSnapshotData) -> String? {
        if let focused = snapshot.focusedElement, focused.isSecure {
            return "the cursor is in a password field"
        }
        for element in snapshot.elements {
            if element.isSecure { return "there is a password field on screen" }
            guard AXSnapshotBuilder.textEntryRoles.contains(element.role) else { continue }
            let haystack = (element.name + " " + element.placeholder + " " + element.identifier).lowercased()
            if let word = fieldWords.first(where: { haystack.contains($0) }) {
                return "there is a field asking for a \(word)"
            }
        }
        return nil
    }

    /// The line Teachy says out loud when it hands back.
    static func spokenHandBack(appName: String, reason: String) -> String {
        "I've stopped in \(appName) because \(reason). That part is yours to type. Tell me when you're done and I'll carry on."
    }
}
