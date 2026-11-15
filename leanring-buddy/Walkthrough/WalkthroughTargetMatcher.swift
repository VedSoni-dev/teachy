//
//  WalkthroughTargetMatcher.swift
//  leanring-buddy / Walkthrough
//
//  Finds a step's target in a FRESH accessibility snapshot (so a control that
//  moved, was renamed, or has twins is still found), and answers a step's
//  `check` from the snapshot alone, without a model call.
//
//  Pure: works on `AXSnapshotData` from Agent/Drive/AXSnapshotModel.swift.
//  Tested by scripts/tests/run_walk_tests.sh.
//

import CoreGraphics
import Foundation

struct WalkthroughResolvedTarget: Equatable {
    enum Source: Equatable {
        /// A live accessibility element.
        case element
        /// Only the planner's point in the screenshot.
        case point
    }

    /// Global CG coordinates (top-left origin), like accessibility frames and click locations.
    var frame: CGRect
    var source: Source
    /// The element's number in the snapshot, when `source` is `.element`.
    var elementIndex: Int?
    var name: String
    var role: String
}

enum WalkthroughTargetMatcher {
    /// Side of the square ringed around a bare fallback point.
    static let pointTargetSize: CGFloat = 64
    /// A control with a different name still counts if it sits this close to the planner's point.
    static let renamedSearchRadius: CGFloat = 48

    // MARK: Text

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "&", with: " and ")
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// 0…1: how alike two labels are. 1 = the same words, 0.85 = one starts the other or
    /// contains it whole, lower = shared words only.
    static func labelSimilarity(_ wanted: String, _ candidate: String) -> Double {
        let a = normalize(wanted), b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        if shorter.count >= 3, (" " + longer + " ").contains(" " + shorter + " ") {
            // "Save" inside "Save changes" is a strong match; inside a paragraph it is not.
            let coverage = Double(shorter.count) / Double(longer.count)
            return 0.6 + 0.25 * min(1, coverage * 2)
        }
        let wordsA = Set(a.split(separator: " ")), wordsB = Set(b.split(separator: " "))
        let shared = wordsA.intersection(wordsB).count
        guard shared > 0 else { return 0 }
        let overlap = Double(shared) / Double(wordsA.union(wordsB).count)
        return overlap >= 0.5 ? 0.3 + 0.3 * overlap : 0
    }

    /// The best similarity between a wanted label and any of an element's texts.
    static func labelScore(_ wanted: String, element: AXSnapshotElement) -> Double {
        var best = labelSimilarity(wanted, element.name)
        // Links and static text often carry their words in the value; an empty field shows its placeholder.
        if !element.isSecure, !AXSnapshotBuilder.textEntryRoles.contains(element.role) {
            best = max(best, labelSimilarity(wanted, element.value))
        }
        best = max(best, labelSimilarity(wanted, element.placeholder) * 0.95)
        return best
    }

    // MARK: Roles

    private static let clickableFamily: Set<String> = [
        "button", "link", "menu item", "menu", "menu button", "tab", "cell", "popup", "disclosure", "radio", "checkbox", "switch", "image", "close button", "zoom button", "minimize button", "row", "outline row"
    ]
    private static let typingFamily: Set<String> = ["text field", "text area", "search field", "secure field", "combo box", "date field", "time field", "datefield", "timefield"]
    private static let readingFamily: Set<String> = ["text", "heading", "web page"]

    static func normalizeRole(_ role: String) -> String {
        var value = role.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("AX") { value = AXSnapshotFormatter.friendlyRole(role: value, subrole: "") }
        value = value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        switch value {
        case "textfield", "input", "field", "text box", "textbox", "text input": return "text field"
        case "textarea": return "text area"
        case "searchfield", "search box", "search": return "search field"
        case "securefield", "password field", "password": return "secure field"
        case "menuitem": return "menu item"
        case "menubutton": return "menu button"
        case "menu bar item", "menubaritem": return "menu"
        case "tab button", "tabbutton": return "tab"
        case "popup button", "pop up button", "popupbutton", "dropdown", "drop down", "select": return "popup"
        case "check box": return "checkbox"
        case "radio button", "radiobutton": return "radio"
        case "toggle": return "switch"
        case "combobox": return "combo box"
        case "static text", "statictext", "label": return "text"
        case "icon": return "image"
        default: return value
        }
    }

    /// 1 = same role, 0.6 = same kind of control, 0.25 = different kind, 0.5 = the plan gave no role.
    static func roleScore(wanted: String, element: AXSnapshotElement) -> Double {
        let want = normalizeRole(wanted)
        guard !want.isEmpty else { return 0.5 }
        let have = AXSnapshotFormatter.friendlyRole(role: element.role, subrole: element.subrole)
        if want == have { return 1 }
        let families = [clickableFamily, typingFamily, readingFamily]
        for family in families where family.contains(want) && family.contains(have) {
            return 0.6
        }
        // A role the plan made up says nothing either way.
        return families.contains { $0.contains(want) } ? 0.25 : 0.5
    }

    // MARK: Geometry

    /// A 0–1000 screenshot point → global CG, on the display the plan was made on.
    static func globalPoint(for point: WalkthroughPoint?, displayFrame: CGRect) -> CGPoint? {
        guard let point, displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let x = min(max(point.x, 0), 1000), y = min(max(point.y, 0), 1000)
        return CGPoint(
            x: displayFrame.minX + CGFloat(x) / 1000 * displayFrame.width,
            y: displayFrame.minY + CGFloat(y) / 1000 * displayFrame.height
        )
    }

    /// 0 when the point is inside the rect, else the gap to its nearest edge.
    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    // MARK: Resolve

    /// Finds `target` in `snapshot`.
    /// - A control whose label matches wins, wherever it now is (moved elements are followed).
    /// - Several equally good matches: the one nearest the planner's point; without a point, the first.
    /// - No label match but a control of the same kind right at the planner's point: that one (renamed).
    /// - Otherwise the bare point, when there is one. Nil when there is nothing to ring.
    static func resolve(_ target: WalkthroughTarget?, in snapshot: AXSnapshotData?, displayFrame: CGRect) -> WalkthroughResolvedTarget? {
        guard let target else { return nil }
        let fallback = globalPoint(for: target.point, displayFrame: displayFrame)
        let elements = snapshot?.elements ?? []

        if !normalize(target.label).isEmpty {
            var scored: [(element: AXSnapshotElement, score: Double)] = []
            for element in elements where element.frame.width >= 1 && element.frame.height >= 1 {
                let label = labelScore(target.label, element: element)
                guard label >= 0.5 else { continue }
                let role = roleScore(wanted: target.role, element: element)
                // A different kind of control must carry the very same words: a "Password" field is
                // not the "Change password" link.
                if role <= 0.25, label < 0.95 { continue }
                scored.append((element, label * 0.75 + role * 0.25))
            }
            if let best = scored.map(\.score).max() {
                // Twins: everything within a whisker of the best.
                let finalists = scored.filter { best - $0.score < 0.04 }.map(\.element)
                let chosen: AXSnapshotElement
                if let fallback, finalists.count > 1 {
                    chosen = finalists.min { distance(from: fallback, to: $0.frame) < distance(from: fallback, to: $1.frame) } ?? finalists[0]
                } else {
                    chosen = finalists[0]
                }
                return resolved(from: chosen)
            }
        }

        if let fallback {
            // Renamed in place: same kind of control, at the spot the planner saw.
            let nearby = elements
                .filter { $0.frame.width >= 1 && $0.frame.height >= 1 }
                .filter { roleScore(wanted: target.role, element: $0) >= 0.6 }
                .filter { AXSnapshotBuilder.interactiveRoles.contains($0.role) || normalizeRole(target.role) == AXSnapshotFormatter.friendlyRole(role: $0.role, subrole: $0.subrole) }
                .map { (element: $0, gap: distance(from: fallback, to: $0.frame)) }
                .filter { $0.gap <= renamedSearchRadius }
                // Nearest first; among overlapping boxes the smallest is the control itself.
                .min { left, right in
                    if left.gap != right.gap { return left.gap < right.gap }
                    return left.element.frame.width * left.element.frame.height < right.element.frame.width * right.element.frame.height
                }
            if let nearby { return resolved(from: nearby.element) }

            let half = pointTargetSize / 2
            return WalkthroughResolvedTarget(
                frame: CGRect(x: fallback.x - half, y: fallback.y - half, width: pointTargetSize, height: pointTargetSize),
                source: .point,
                elementIndex: nil,
                name: target.label,
                role: normalizeRole(target.role)
            )
        }
        return nil
    }

    private static func resolved(from element: AXSnapshotElement) -> WalkthroughResolvedTarget {
        WalkthroughResolvedTarget(
            frame: element.frame,
            source: .element,
            elementIndex: element.index,
            name: element.name.isEmpty ? (element.placeholder.isEmpty ? element.value : element.placeholder) : element.name,
            role: AXSnapshotFormatter.friendlyRole(role: element.role, subrole: element.subrole)
        )
    }

    /// Everything a snapshot shows that matters for "did the screen change": the window title and
    /// each control's role, name and value. Frames are left out so scrolling a little is not a change.
    static func signature(of snapshot: AXSnapshotData?) -> String {
        guard let snapshot else { return "" }
        var parts = [snapshot.appName, snapshot.windowTitle]
        parts.reserveCapacity(snapshot.elements.count + 2)
        for element in snapshot.elements {
            parts.append("\(element.role)|\(element.name)|\(element.value)|\(element.isFocused ? "f" : "")")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Local "is it done?" checks

enum WalkthroughVerdict: Equatable {
    case satisfied
    case notSatisfied
    /// The snapshot cannot say. Ask the model once, or wait for the person.
    case undecidable
}

enum WalkthroughDoneCheck {
    /// A control "is there" at this label similarity or better.
    static let presenceThreshold = 0.8

    static func matches(_ element: AXSnapshotElement, role: String?, label: String) -> Bool {
        guard WalkthroughTargetMatcher.labelScore(label, element: element) >= presenceThreshold else { return false }
        guard let role, !role.isEmpty else { return true }
        // Only a clearly different kind of control rules it out; a role the plan made up does not.
        return WalkthroughTargetMatcher.roleScore(wanted: role, element: element) > 0.25
    }

    /// Answers `check` from the snapshot. `disappears` is only trusted once its subject has been
    /// seen during the step (`subjectWasSeen`): something that was never there has not "gone".
    static func evaluate(_ check: WalkthroughCheck?, in snapshot: AXSnapshotData?, subjectWasSeen: Bool = true) -> WalkthroughVerdict {
        guard let check, let snapshot else { return .undecidable }
        switch check.type {
        case .titleContains:
            guard let text = check.text ?? check.label, !WalkthroughTargetMatcher.normalize(text).isEmpty else { return .undecidable }
            let title = WalkthroughTargetMatcher.normalize(snapshot.windowTitle)
            return (" " + title + " ").contains(" " + WalkthroughTargetMatcher.normalize(text) + " ") ? .satisfied : .notSatisfied

        case .appears:
            guard let label = check.label ?? check.text, !label.isEmpty else { return .undecidable }
            if snapshot.elements.contains(where: { matches($0, role: check.role, label: label) }) { return .satisfied }
            // An empty or cut-off list cannot prove something is missing.
            return snapshot.elements.isEmpty || snapshot.truncated ? .undecidable : .notSatisfied

        case .disappears:
            guard let label = check.label ?? check.text, !label.isEmpty else { return .undecidable }
            if snapshot.elements.contains(where: { matches($0, role: check.role, label: label) }) { return .notSatisfied }
            if snapshot.elements.isEmpty || snapshot.truncated || !subjectWasSeen { return .undecidable }
            return .satisfied

        case .focused:
            guard let label = check.label ?? check.text, !label.isEmpty else { return .undecidable }
            guard let focused = snapshot.focusedElement else {
                return snapshot.elements.isEmpty ? .undecidable : .notSatisfied
            }
            return matches(focused, role: check.role, label: label) ? .satisfied : .notSatisfied

        case .valueContains:
            guard let label = check.label, !label.isEmpty, let text = check.text, !text.isEmpty else { return .undecidable }
            let fields = snapshot.elements.filter { matches($0, role: check.role, label: label) }
            guard !fields.isEmpty else { return snapshot.elements.isEmpty || snapshot.truncated ? .undecidable : .notSatisfied }
            // A password field's value is never read.
            if fields.allSatisfy(\.isSecure) { return .undecidable }
            let wanted = text.lowercased()
            return fields.contains { $0.value.lowercased().contains(wanted) } ? .satisfied : .notSatisfied
        }
    }

    /// True when the check's subject is on screen right now (used to arm `disappears`).
    static func subjectIsPresent(_ check: WalkthroughCheck?, in snapshot: AXSnapshotData?) -> Bool {
        guard let check, check.type == .disappears, let snapshot, let label = check.label ?? check.text else { return false }
        return snapshot.elements.contains { matches($0, role: check.role, label: label) }
    }
}
