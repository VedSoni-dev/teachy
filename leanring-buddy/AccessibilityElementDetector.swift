//
//  AccessibilityElementDetector.swift
//  leanring-buddy
//
//  Walks the macOS Accessibility tree of the frontmost application and returns
//  a bounded list of actionable, labeled, on-screen elements with their true
//  global bounds. These are fed to the vision model so it can reference elements
//  by semantic id rather than guessing from screenshot pixels.
//
//  Coordinate system note:
//  - AX APIs return positions in *global Core Graphics* coordinates: top-left
//    origin, Y increasing downward.
//  - The rest of Teachy (NSEvent.mouseLocation, NSScreen.frame, OverlayWindow)
//    uses *global AppKit* coordinates: bottom-left origin of the *primary* screen,
//    Y increasing upward.
//  - `globalAppKitPoint(fromGlobalCGPoint:)` performs the standard macOS flip.
//  - On multi-monitor setups the primary screen's height is the only value used
//    for the flip — this is correct because AppKit's coordinate space has the
//    primary screen at Y=0 and secondary screens at negative or positive Y offsets
//    relative to that baseline. The flip formula is:
//        appKitY = primaryScreenHeight - cgY
//    which matches `WindowPositionManager.swift:410` and every other AX→AppKit
//    conversion in this project.
//

import AppKit
import Foundation

// MARK: - DetectedAXElement

/// A single actionable UI element detected in the frontmost app's AX tree.
struct DetectedAXElement: Identifiable {
    /// 1-based sequential id, stable for this capture. The model references it as `ax:ID`.
    let id: Int
    /// AX role string, e.g. "AXButton", "AXTextField", "AXLink".
    let role: String
    /// Human-readable label: AXTitle ?? AXDescription ?? AXValue, first non-empty,
    /// truncated to ~60 characters.
    let label: String
    /// Element bounds in **global Core Graphics** coordinates (top-left origin, Y down).
    /// Use `globalAppKitPoint(fromGlobalCGPoint:)` to convert the center to AppKit space.
    let globalCGFrame: CGRect
}

// MARK: - AccessibilityElementDetector

enum AccessibilityElementDetector {

    // MARK: - Role allow-list

    /// Only elements with these roles are considered actionable/meaningful.
    private static let actionableRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXMenuItem",
        "AXTabButton",
        "AXTab",
        "AXSlider",
        "AXCell",
        "AXImage",
        "AXStaticText",
        "AXMenuBarItem",
    ]

    // MARK: - Traversal limits

    /// Maximum AX tree depth to traverse. Deeper elements are almost never primary targets.
    private static let maximumTraversalDepth = 12
    /// Maximum total elements to collect before stopping early.
    private static let maximumElementCount = 150
    /// Wall-clock budget for the entire traversal. Bail and return what's collected if exceeded.
    private static let traversalBudgetSeconds: TimeInterval = 0.25

    // MARK: - Public API

    /// Detects actionable elements in the frontmost application's AX tree.
    ///
    /// Called off the main thread (AX calls are synchronous and can be slow).
    /// Guards on `AXIsProcessTrusted()` — if accessibility permission is not
    /// granted, returns an empty list immediately (never prompts; the app already
    /// handles permission flow separately).
    ///
    /// The result list is bounded: max `maximumElementCount` elements, max depth
    /// `maximumTraversalDepth`, and hard wall-clock budget `traversalBudgetSeconds`.
    /// Returning early means the list may be incomplete — that is acceptable; the
    /// model falls back to grid/pixel pointing for any element it can't find.
    static func detectActionableElements() -> [DetectedAXElement] {
        // Guard: accessibility permission required
        guard AXIsProcessTrusted() else {
            return []
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return []
        }

        let appPID = frontmostApp.processIdentifier
        let appElement = AXUIElementCreateApplication(appPID)

        // Best-effort: enable AXManualAccessibility so Chromium/Electron apps
        // expose their accessibility tree. Failure is silently ignored — native
        // apps don't need it and the attribute may not exist on all apps.
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        var collectedElements: [DetectedAXElement] = []
        let traversalStartTime = Date()

        traverseAXElement(
            element: appElement,
            depth: 0,
            nextID: 1,
            collectedElements: &collectedElements,
            traversalStartTime: traversalStartTime
        )

        return collectedElements
    }

    // MARK: - Coordinate conversion

    /// Converts a global Core Graphics point (top-left origin) to global AppKit
    /// point (bottom-left origin of the primary screen).
    ///
    /// This is the standard macOS coordinate flip. All downstream Teachy code
    /// (NSEvent.mouseLocation, NSScreen.frame, OverlayWindow placement) uses
    /// AppKit coordinates. The primary screen's height is the flip constant —
    /// secondary monitors are offset relative to this baseline in both systems,
    /// so the formula works correctly on multi-monitor setups.
    static func globalAppKitPoint(fromGlobalCGPoint cgPoint: CGPoint) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(
            x: cgPoint.x,
            y: primaryScreenHeight - cgPoint.y
        )
    }

    /// Finds the NSScreen (AppKit display frame) that contains the center of a
    /// given global CG frame. Used to set `detectedElementDisplayFrame` so
    /// `OverlayWindow`'s `isDisplayFrameOnThisScreen` guard fires on the correct
    /// display when the user's target is on a secondary monitor.
    ///
    /// Converts the element's center from CG to AppKit coordinates, then finds
    /// the screen whose AppKit frame contains that point. Falls back to
    /// `NSScreen.main?.frame` if no match is found (should not happen in practice).
    static func appKitDisplayFrame(containingGlobalCGFrame cgFrame: CGRect) -> CGRect? {
        // Convert the element center from CG (top-left) to AppKit (bottom-left)
        let cgCenter = CGPoint(
            x: cgFrame.midX,
            y: cgFrame.midY
        )
        let appKitCenter = globalAppKitPoint(fromGlobalCGPoint: cgCenter)

        // Find the NSScreen whose AppKit frame contains this point
        for screen in NSScreen.screens {
            if screen.frame.contains(appKitCenter) {
                return screen.frame
            }
        }

        // Fallback: return the main screen frame
        return NSScreen.main?.frame
    }

    // MARK: - Recursive traversal

    /// Recursively walks the AX tree, collecting elements that pass the filter.
    ///
    /// Uses inout parameters so the collector and id counter are shared across
    /// the entire recursion stack without heap allocation overhead.
    private static func traverseAXElement(
        element: AXUIElement,
        depth: Int,
        nextID: Int,
        collectedElements: inout [DetectedAXElement],
        traversalStartTime: Date
    ) {
        // Depth + count + time budget checks
        guard depth <= maximumTraversalDepth else { return }
        guard collectedElements.count < maximumElementCount else { return }
        guard Date().timeIntervalSince(traversalStartTime) < traversalBudgetSeconds else { return }

        // Read this element's role
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            // Can't read role — still recurse into children so we don't miss sub-trees
            recurseIntoChildren(
                of: element,
                depth: depth,
                nextID: nextID,
                collectedElements: &collectedElements,
                traversalStartTime: traversalStartTime
            )
            return
        }

        // Check if this element is in the actionable role set
        if actionableRoles.contains(role) {
            // Try to extract frame
            if let frame = readGlobalCGFrame(of: element), frame.width > 0, frame.height > 0 {
                // Try to extract a human-readable label
                if let label = readLabel(of: element), !label.isEmpty {
                    let newID = collectedElements.count + 1
                    let truncatedLabel = label.count > 60 ? String(label.prefix(60)) + "…" : label
                    collectedElements.append(DetectedAXElement(
                        id: newID,
                        role: role,
                        label: truncatedLabel,
                        globalCGFrame: frame
                    ))
                }
            }
        }

        // Always recurse into children (even if this element was collected or filtered)
        recurseIntoChildren(
            of: element,
            depth: depth,
            nextID: nextID,
            collectedElements: &collectedElements,
            traversalStartTime: traversalStartTime
        )
    }

    private static func recurseIntoChildren(
        of element: AXUIElement,
        depth: Int,
        nextID: Int,
        collectedElements: inout [DetectedAXElement],
        traversalStartTime: Date
    ) {
        guard collectedElements.count < maximumElementCount else { return }
        guard Date().timeIntervalSince(traversalStartTime) < traversalBudgetSeconds else { return }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return
        }

        for child in children {
            guard collectedElements.count < maximumElementCount else { return }
            guard Date().timeIntervalSince(traversalStartTime) < traversalBudgetSeconds else { return }

            traverseAXElement(
                element: child,
                depth: depth + 1,
                nextID: collectedElements.count + 1,
                collectedElements: &collectedElements,
                traversalStartTime: traversalStartTime
            )
        }
    }

    // MARK: - AX attribute helpers

    /// Reads an element's position + size from AX, returning a global CG frame.
    /// AX stores position as an AXValue of type .cgPoint and size as .cgSize.
    private static func readGlobalCGFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        guard let axPositionValue = positionValue,
              let axSizeValue = sizeValue else {
            return nil
        }

        var cgPosition = CGPoint.zero
        var cgSize = CGSize.zero

        guard AXValueGetValue(axPositionValue as! AXValue, .cgPoint, &cgPosition),
              AXValueGetValue(axSizeValue as! AXValue, .cgSize, &cgSize) else {
            return nil
        }

        return CGRect(origin: cgPosition, size: cgSize)
    }

    /// Extracts a human-readable label from an element, trying AXTitle first,
    /// then AXDescription, then AXValue. Returns the first non-empty string found.
    private static func readLabel(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var labelValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &labelValue) == .success,
               let label = labelValue as? String,
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - Situational awareness (companion prompt context, not tool use)

extension AccessibilityElementDetector {
    /// Frontmost app name + focused window title, formatted for injection into a
    /// system prompt (e.g. "Claude" or "Claude — window: some title"). Reuses the
    /// exact AX pattern already proven in `AgentMacNativeTools.describeFrontmostApplication()`,
    /// but that helper's output is a full tool-result sentence — this returns just the
    /// app/window fragment so the caller controls the surrounding prompt phrasing.
    /// Returns nil when there's no frontmost application to report.
    static func frontmostApplicationContext() -> String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
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
                windowTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if windowTitle.isEmpty {
            return appName
        }
        return "\(appName) — window: \(windowTitle)"
    }
}
