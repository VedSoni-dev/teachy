//
//  AXSnapshot.swift
//  leanring-buddy
//
//  Reads ONE app's focused window through the Accessibility API, breadth-first,
//  and hands the raw elements to AXSnapshotBuilder (pure) for filtering,
//  numbering and text. Web content (AXWebArea and what is inside it) is walked
//  like any other element. Never touches the pointer or the keyboard.
//
//  All calls here are synchronous cross-process messages: call from DriveSession
//  (an actor), not from the main thread.
//

import AppKit
import ApplicationServices

/// Small typed helpers over the C Accessibility API.
enum AXRead {
    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        text(from: value(element, attribute))
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        frame(position: value(element, kAXPositionAttribute as String), size: value(element, kAXSizeAttribute as String))
    }

    static func frame(position: AnyObject?, size: AnyObject?) -> CGRect {
        var origin = CGPoint.zero
        var extent = CGSize.zero
        if let position, CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if let size, CFGetTypeID(size) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        return CGRect(origin: origin, size: extent)
    }

    static func text(from value: AnyObject?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// AXUIElementCopyMultipleAttributeValues puts an AXValue of type "error" where an attribute is missing.
    static func isMissing(_ value: AnyObject) -> Bool {
        if value is NSNull { return true }
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return true }
        return false
    }
}

struct AXWindowCapture {
    var appName: String
    var windowTitle: String
    var windowFrame: CGRect
    /// Raw elements in breadth-first order, and the live handle for each (same positions).
    var nodes: [AXRawNode]
    var handles: [AXUIElement]
}

enum AXSnapshotWalker {
    private static let attributeNames: [String] = [
        kAXRoleAttribute as String, kAXSubroleAttribute as String, kAXTitleAttribute as String,
        kAXDescriptionAttribute as String, kAXValueAttribute as String, kAXPlaceholderValueAttribute as String,
        kAXHelpAttribute as String, kAXIdentifierAttribute as String, kAXPositionAttribute as String,
        kAXSizeAttribute as String, kAXEnabledAttribute as String, kAXFocusedAttribute as String,
        kAXChildrenAttribute as String
    ]

    /// Containers that can hold thousands of rows: ask only for the visible ones.
    private static let bigContainerRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXGrid"]
    private static let chromiumBundlePrefixes = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera"]

    static let maximumVisitedNodes = 3000
    static let timeBudget: TimeInterval = 1.5

    /// Makes Chromium and Electron apps publish their web content to Accessibility.
    static func prepare(appElement: AXUIElement, bundleID: String) {
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        AXRead.element(appElement, kAXFocusedWindowAttribute as String)
            ?? AXRead.element(appElement, kAXMainWindowAttribute as String)
            ?? AXRead.elements(appElement, kAXWindowsAttribute as String).first
    }

    static func capture(appElement: AXUIElement, appName: String) -> AXWindowCapture {
        guard let window = focusedWindow(of: appElement) else {
            return AXWindowCapture(appName: appName, windowTitle: "", windowFrame: .zero, nodes: [], handles: [])
        }
        let windowTitle = AXRead.string(window, kAXTitleAttribute as String)
        let windowFrame = AXRead.frame(window)

        var nodes: [AXRawNode] = []
        var handles: [AXUIElement] = []
        var queue: [AXUIElement] = [window]
        var cursor = 0
        let deadline = Date().addingTimeInterval(timeBudget)

        while cursor < queue.count, cursor < maximumVisitedNodes, Date() < deadline {
            let element = queue[cursor]
            cursor += 1

            var rawValues: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &rawValues) == .success,
                  let values = rawValues as? [AnyObject], values.count == attributeNames.count else { continue }
            func item(_ position: Int) -> AnyObject? { AXRead.isMissing(values[position]) ? nil : values[position] }

            var node = AXRawNode()
            node.role = AXRead.text(from: item(0))
            node.subrole = AXRead.text(from: item(1))
            node.title = AXRead.text(from: item(2))
            node.label = AXRead.text(from: item(3))
            let isSecure = node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
            // Never even read what is in a password field.
            node.value = isSecure ? "" : String(AXRead.text(from: item(4)).prefix(400))
            node.placeholder = AXRead.text(from: item(5))
            node.help = AXRead.text(from: item(6))
            node.identifier = AXRead.text(from: item(7))
            node.frame = AXRead.frame(position: item(8), size: item(9))
            node.isEnabled = (item(10) as? NSNumber)?.boolValue ?? true
            node.isFocused = (item(11) as? NSNumber)?.boolValue ?? false

            nodes.append(node)
            handles.append(element)

            // Do not walk into parts that are scrolled or clipped out of the window.
            let isOffWindow = !node.frame.isEmpty && !windowFrame.isEmpty && !node.frame.intersects(windowFrame) && node.role != "AXMenu" && node.role != "AXMenuItem"
            if isOffWindow { continue }

            var children = (item(12) as? [AXUIElement]) ?? []
            if bigContainerRoles.contains(node.role) {
                let visible = AXRead.elements(element, kAXVisibleRowsAttribute as String)
                let visibleChildren = visible.isEmpty ? AXRead.elements(element, kAXVisibleChildrenAttribute as String) : visible
                if !visibleChildren.isEmpty { children = visibleChildren }
            }
            if !children.isEmpty, queue.count < maximumVisitedNodes * 2 {
                queue.append(contentsOf: children.prefix(400))
            }
        }

        return AXWindowCapture(appName: appName, windowTitle: windowTitle, windowFrame: windowFrame, nodes: nodes, handles: handles)
    }
}
