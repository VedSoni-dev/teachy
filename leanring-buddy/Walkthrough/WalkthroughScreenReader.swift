//
//  WalkthroughScreenReader.swift
//  leanring-buddy / Walkthrough
//
//  The walkthrough's eyes and ears. Read-only: it never moves the pointer,
//  presses a key or blocks an event.
//
//  - WalkthroughScreenReader reads the front app's focused window through
//    Accessibility (the same walker and builder Drive uses), adds the menu bar
//    and any open menu (many Mac steps are "File, then Export"), and waits for
//    the screen to stop changing before it reports.
//  - WalkthroughClickMonitor is a listen-only event tap for mouse-downs, so a
//    click on the ringed control moves the walkthrough on.
//

import AppKit
import ApplicationServices
import CoreGraphics

struct WalkthroughScreenReading {
    var snapshot: AXSnapshotData
    var appName: String
    var bundleID: String
    /// True when the snapshot stopped changing before the wait ran out.
    var settled: Bool
}

actor WalkthroughScreenReader {
    struct App: Equatable, Sendable {
        var processID: pid_t
        var appName: String
        var bundleID: String
    }

    static let menuElementCap = 160

    private var currentApp: App?
    private var handles: [Int: AXUIElement] = [:]
    private var indexByIdentity: [String: Int] = [:]
    private var nextFreeIndex = 1

    /// One read of `app`'s focused window, menu bar and open menu. Nil without Accessibility permission.
    func read(_ app: App) -> WalkthroughScreenReading? {
        guard AXIsProcessTrusted() else { return nil }
        if app != currentApp {
            currentApp = app
            handles = [:]
            indexByIdentity = [:]
            nextFreeIndex = 1
        }
        let appElement = AXUIElementCreateApplication(app.processID)
        AXSnapshotWalker.prepare(appElement: appElement, bundleID: app.bundleID)
        let capture = AXSnapshotWalker.capture(appElement: appElement, appName: app.appName)
        let built = AXSnapshotBuilder.build(
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            windowFrame: capture.windowFrame,
            nodes: capture.nodes,
            previousIndexByIdentity: indexByIdentity,
            nextFreeIndex: nextFreeIndex
        )
        indexByIdentity.merge(built.indexByIdentity) { _, new in new }
        nextFreeIndex = built.nextFreeIndex
        var freshHandles = built.sourcePositions.mapValues { capture.handles[$0] }
        var snapshot = built.snapshot

        // The menu bar is not part of any window, so the window walk never sees it.
        var occurrences: [String: Int] = [:]
        for item in Self.menuItems(of: appElement) {
            let base = "menu\u{1}\(item.role)\u{1}\(item.title)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let identity = base + "#\(occurrence)"
            let index: Int
            if let known = indexByIdentity[identity] {
                index = known
            } else {
                index = nextFreeIndex
                nextFreeIndex += 1
                indexByIdentity[identity] = index
            }
            guard freshHandles[index] == nil else { continue }
            freshHandles[index] = item.element
            snapshot.elements.append(AXSnapshotElement(
                index: index,
                role: item.role,
                subrole: "",
                name: item.title,
                value: "",
                placeholder: "",
                frame: item.frame,
                isFocused: false,
                isSecure: false,
                identifier: ""
            ))
        }

        handles = freshHandles
        return WalkthroughScreenReading(snapshot: snapshot, appName: app.appName, bundleID: app.bundleID, settled: true)
    }

    /// Reads until two reads in a row, at least `stableFor` apart, show the same thing (a page
    /// that is still loading keeps changing), or until `maximumWait` has passed.
    func settledRead(_ app: App, stableFor: TimeInterval = 0.4, maximumWait: TimeInterval = 4) async -> WalkthroughScreenReading? {
        let deadline = Date().addingTimeInterval(maximumWait)
        guard var latest = read(app) else { return nil }
        var signature = WalkthroughTargetMatcher.signature(of: latest.snapshot)
        var unchangedSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { break }
            guard let next = read(app) else { break }
            let nextSignature = WalkthroughTargetMatcher.signature(of: next.snapshot)
            if nextSignature != signature {
                signature = nextSignature
                unchangedSince = Date()
            }
            latest = next
            if Date().timeIntervalSince(unchangedSince) >= stableFor { return latest }
        }
        latest.settled = false
        return latest
    }

    /// Where the element with this number is right now (global CG), for keeping the ring on it.
    func frame(ofElement index: Int) -> CGRect? {
        guard let handle = handles[index] else { return nil }
        let frame = AXRead.frame(handle)
        return frame.width >= 1 && frame.height >= 1 ? frame : nil
    }

    // MARK: Menu bar

    private struct MenuItem {
        var role: String
        var title: String
        var frame: CGRect
        var element: AXUIElement
    }

    /// The menu bar's titles, plus the items of whichever menu (and submenu) is open.
    private static func menuItems(of appElement: AXUIElement) -> [MenuItem] {
        guard let menuBar = AXRead.element(appElement, kAXMenuBarAttribute as String) else { return [] }
        var items: [MenuItem] = []
        for barItem in AXRead.elements(menuBar, kAXChildrenAttribute as String) {
            let title = AXSnapshotBuilder.clean(AXRead.string(barItem, kAXTitleAttribute as String))
            let frame = AXRead.frame(barItem)
            guard !title.isEmpty, frame.width >= 1 else { continue }
            items.append(MenuItem(role: "AXMenuBarItem", title: title, frame: frame, element: barItem))
            if AXRead.bool(barItem, kAXSelectedAttribute as String) == true {
                appendOpenMenu(under: barItem, into: &items, depth: 0)
            }
            if items.count >= menuElementCap { break }
        }
        return items
    }

    private static func appendOpenMenu(under parent: AXUIElement, into items: inout [MenuItem], depth: Int) {
        guard depth < 3 else { return }
        for menu in AXRead.elements(parent, kAXChildrenAttribute as String) where AXRead.string(menu, kAXRoleAttribute as String) == "AXMenu" {
            for entry in AXRead.elements(menu, kAXChildrenAttribute as String) {
                guard items.count < menuElementCap else { return }
                let title = AXSnapshotBuilder.clean(AXRead.string(entry, kAXTitleAttribute as String))
                let frame = AXRead.frame(entry)
                // Separators have no title; an item that is not on screen has no size.
                guard !title.isEmpty, frame.width >= 1, frame.height >= 1 else { continue }
                guard AXRead.bool(entry, kAXEnabledAttribute as String) != false else { continue }
                items.append(MenuItem(role: "AXMenuItem", title: title, frame: frame, element: entry))
                if AXRead.bool(entry, kAXSelectedAttribute as String) == true {
                    appendOpenMenu(under: entry, into: &items, depth: depth + 1)
                }
            }
        }
    }
}

// MARK: - Clicks

/// Listen-only: the event is always passed through untouched, so nothing the person does is
/// ever delayed or swallowed. Same pattern as DriveTakeoverMonitor.
@MainActor
final class WalkthroughClickMonitor {
    /// Called on the main thread with the click's global CG location.
    var onMouseDown: ((CGPoint) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { eventTap != nil }

    /// False when the tap could not be installed (no Accessibility permission). The walkthrough
    /// still works then: steps move on when the screen shows they are done, or on "next".
    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }
        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<WalkthroughClickMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            let marker = event.getIntegerValueField(.eventSourceUserData)
            let location = event.location
            // The tap's source is on the main run loop, so this is the main thread.
            MainActor.assumeIsolated {
                monitor.handle(type: type, marker: marker, location: location)
            }
            return Unmanaged.passUnretained(event)
        }

        var created: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            created = CGEvent.tapCreate(
                tap: location,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            if created != nil { break }
        }
        guard let tap = created, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            if let created { CFMachPortInvalidate(created) }
            print("⚠️ Walkthrough: could not create the click event tap (Accessibility permission?)")
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handle(type: CGEventType, marker: Int64, location: CGPoint) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        // Clicks Drive posts itself are not the person.
        if marker == DriveSession.syntheticEventMarker { return }
        guard type == .leftMouseDown else { return }
        onMouseDown?(location)
    }
}
