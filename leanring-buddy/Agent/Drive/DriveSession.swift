//
//  DriveSession.swift
//  leanring-buddy
//
//  Drive: accessibility-first control of ONE target app per session.
//
//  - Every action goes through the app's accessibility tree (press this
//    control, set this field, pick this menu item). The user's real pointer is
//    never moved; key and click events are posted to the target process only.
//  - After every action the window is read again and a short diff is returned,
//    so the model checks its work before the next step.
//  - A password, verification-code or card field on screen stops the session
//    and hands back to the user.
//
//  One DriveSession belongs to one AgentJob. The permission gate has already
//  said yes before any method that acts is called (see AgentToolRegistry).
//

import AppKit
import ApplicationServices

/// Thrown when Drive must stop and give the app back to the user.
struct DriveHandBack: Error {
    let spokenLine: String
}

struct DriveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct DriveTarget: Equatable {
    let processID: pid_t
    let appName: String
    let bundleID: String
}

actor DriveSession {
    /// Marks events Drive posts itself, so the takeover monitor does not mistake them for the user.
    static let syntheticEventMarker: Int64 = 0x7EAC_4D21

    private let jobID: String
    private(set) var target: DriveTarget?
    private var lastSnapshot: AXSnapshotData?
    private var handles: [Int: AXUIElement] = [:]
    private var indexByIdentity: [String: Int] = [:]
    private var nextFreeIndex = 1
    private var captures: [String: (geometry: DriveCaptureGeometry, takenAt: Date)] = [:]
    private var captureCounter = 0
    private var hasStartedDriving = false

    init(jobID: String) {
        self.jobID = jobID
    }

    // MARK: Facts for the permission gate

    var hasTarget: Bool { target != nil && lastSnapshot != nil }

    /// Where the driven window is, so capture_screen can look at the right display.
    var targetWindowFrameInGlobalCG: CGRect? { lastSnapshot?.windowFrame }

    /// What the gate needs to classify a drive call: the app, and the control about to be touched.
    func policyContext(toolName: String, arguments: [String: Any]) -> ToolPolicyContext {
        var context = ToolPolicyContext()
        context.driveTargetAppName = target?.appName ?? ""
        context.driveTargetBundleID = target?.bundleID ?? ""
        if let index = Self.int(arguments["index"]), let element = lastSnapshot?.element(at: index) {
            context.driveElementDescription = element.shortDescription
        } else if toolName == "drive_click_point", let point = try? resolveClickPoint(arguments: arguments).point, let target {
            let appElement = AXUIElementCreateApplication(target.processID)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit) == .success, let hit {
                context.driveElementDescription = Self.describe(hit)
            }
        }
        return context
    }

    // MARK: Captures (for drive_click_point)

    /// Remembers how a screenshot maps onto its display, and returns the id the model must quote.
    func registerCapture(screenshotWidth: Int, screenshotHeight: Int, displayFrameInAppKitPoints: CGRect, primaryDisplayHeight: CGFloat) -> String {
        captureCounter += 1
        let id = "cap-\(captureCounter)"
        captures[id] = (
            DriveCaptureGeometry(
                captureID: id,
                screenshotWidthInPixels: screenshotWidth,
                screenshotHeightInPixels: screenshotHeight,
                displayFrameInAppKitPoints: displayFrameInAppKitPoints,
                primaryDisplayHeightInPoints: primaryDisplayHeight
            ),
            Date()
        )
        return id
    }

    /// The geometry of a screenshot the model quoted, checked for age.
    private func capture(named captureID: String) throws -> DriveCaptureGeometry {
        guard !captureID.isEmpty else {
            throw DriveError("Give capture_id: the id of the screenshot the x,y came from (computer screenshot or capture_screen returns it).")
        }
        guard let capture = captures[captureID] else {
            throw DriveError("Unknown capture_id \"\(captureID)\". Known: \(captures.keys.sorted().joined(separator: ", ")). Take a fresh screenshot.")
        }
        guard Date().timeIntervalSince(capture.takenAt) < 180 else {
            throw DriveError("\(captureID) is more than three minutes old and the screen may have changed. Take a fresh screenshot.")
        }
        return capture.geometry
    }

    // MARK: Computer use (the computer tool)

    /// A screenshot point (x/y under the given keys, plus capture_id) → global CG point.
    func globalPoint(arguments: [String: Any], xKey: String, yKey: String) throws -> CGPoint {
        guard let x = Self.double(arguments[xKey]), let y = Self.double(arguments[yKey]) else {
            throw DriveError("This action needs \(xKey) and \(yKey) in screenshot pixels, plus capture_id.")
        }
        let geometry = try capture(named: ToolPolicy.string(arguments["capture_id"]))
        guard let point = DriveCoordinates.globalCGPoint(screenshotX: x, screenshotY: y, in: geometry) else {
            throw DriveError("(\(Int(x)), \(Int(y))) is outside \(geometry.captureID), which is \(geometry.screenshotWidthInPixels)x\(geometry.screenshotHeightInPixels) pixels.")
        }
        return point
    }

    /// Starts the takeover watch for real pointer use. False when it could not start.
    func beginComputerUse() async -> Bool {
        if hasStartedDriving { return true }
        let started = await DriveTakeoverMonitor.shared.beginDriving(jobID: jobID, appName: "your Mac")
        if started { hasStartedDriving = true }
        return started
    }

    // MARK: Snapshot

    /// drive_snapshot: read the target app's focused window. Sets (or switches) the target app.
    func snapshot(appName requestedApp: String?) async throws -> String {
        guard AXIsProcessTrusted() else {
            throw DriveError("Teachy needs Accessibility permission (System Settings > Privacy & Security > Accessibility) before it can read or drive apps. Tell the user.")
        }
        let resolved = try await Self.resolveTarget(named: requestedApp, current: target)
        if resolved != target {
            target = resolved
            lastSnapshot = nil
            handles = [:]
            indexByIdentity = [:]
            nextFreeIndex = 1
        }
        let snapshot = try takeSnapshot()
        if hasStartedDriving {
            // Mid-drive: a password, code or card field means stop and hand back, now.
            try handBackIfSecret(in: snapshot)
        } else if let reason = SecretFieldDetector.reasonToHandBack(in: snapshot) {
            // Only looking so far (nothing has been driven): say so, and refuse to act here.
            return AXSnapshotFormatter.text(for: snapshot)
                + "\n\nNOTE: \(reason). Teachy will not press, type or click in this window: that part is the user's. You can explain what to do, but any drive_ action here ends the job and hands back to them."
        }
        return AXSnapshotFormatter.text(for: snapshot)
            + "\n\nUse the [number] with drive_press, drive_set_text or drive_scroll. Numbers stay the same between snapshots for controls that are still there."
    }

    @discardableResult
    private func takeSnapshot() throws -> AXSnapshotData {
        guard let target else { throw DriveError("Call drive_snapshot first so Teachy knows which app to work in.") }
        guard NSRunningApplication(processIdentifier: target.processID)?.isTerminated == false else {
            throw DriveError("\(target.appName) is no longer running.")
        }
        let appElement = AXUIElementCreateApplication(target.processID)
        AXSnapshotWalker.prepare(appElement: appElement, bundleID: target.bundleID)
        let capture = AXSnapshotWalker.capture(appElement: appElement, appName: target.appName)
        let built = AXSnapshotBuilder.build(
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            windowFrame: capture.windowFrame,
            nodes: capture.nodes,
            previousIndexByIdentity: indexByIdentity,
            nextFreeIndex: nextFreeIndex
        )
        // Keep old numbers reserved: a control that scrolls away and back gets its number again.
        indexByIdentity.merge(built.indexByIdentity) { _, new in new }
        nextFreeIndex = built.nextFreeIndex
        handles = built.sourcePositions.mapValues { capture.handles[$0] }
        lastSnapshot = built.snapshot
        return built.snapshot
    }

    private func handBackIfSecret(in snapshot: AXSnapshotData) throws {
        if let reason = SecretFieldDetector.reasonToHandBack(in: snapshot) {
            throw DriveHandBack(spokenLine: SecretFieldDetector.spokenHandBack(appName: snapshot.appName, reason: reason))
        }
    }

    // MARK: Actions

    /// drive_press
    func press(index: Int) async throws -> String {
        try await perform(note: "pressing \(describe(index))") {
            let (element, info) = try self.handle(index)
            try self.refuseIfControlTurnedSensitive(element: element, snapshotInfo: info)
            let actions = AXRead.actions(element)
            if let action = [kAXPressAction as String, "AXPick", "AXOpen", kAXConfirmAction as String].first(where: actions.contains) {
                try Self.check(AXUIElementPerformAction(element, action as CFString), doing: "press \(info.shortDescription)")
                return "pressed [\(index)] \(info.shortDescription)"
            }
            if AXSnapshotBuilder.textEntryRoles.contains(info.role) {
                try Self.check(AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue), doing: "focus \(info.shortDescription)")
                return "focused [\(index)] \(info.shortDescription)"
            }
            // A label inside a button or row: press the nearest pressable parent.
            var parent = AXRead.element(element, kAXParentAttribute as String)
            for _ in 0..<3 {
                guard let candidate = parent else { break }
                if AXRead.actions(candidate).contains(kAXPressAction as String) {
                    try Self.check(AXUIElementPerformAction(candidate, kAXPressAction as CFString), doing: "press \(info.shortDescription)")
                    return "pressed the control around [\(index)] \(info.shortDescription)"
                }
                if AXRead.string(candidate, kAXRoleAttribute as String) == "AXRow" {
                    if AXUIElementSetAttributeValue(candidate, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                        return "selected the row holding [\(index)] \(info.shortDescription)"
                    }
                }
                parent = AXRead.element(candidate, kAXParentAttribute as String)
            }
            throw DriveError("[\(index)] \(info.shortDescription) cannot be pressed through accessibility. As a last resort call drive_click_point with index \(index).")
        }
    }

    /// drive_set_text: set a field's text and read it back.
    func setText(index: Int, text: String) async throws -> String {
        try await perform(note: "typing into \(describe(index))") {
            let (element, info) = try self.handle(index)
            if info.isSecure {
                throw DriveHandBack(spokenLine: SecretFieldDetector.spokenHandBack(appName: self.target?.appName ?? "the app", reason: "that is a password field"))
            }
            guard let target = self.target else { throw DriveError("No target app.") }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

            func readBack() -> String { AXRead.string(element, kAXValueAttribute as String) }
            func matches(_ value: String) -> Bool {
                value == text || value.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // 1. Set the value outright.
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success {
                usleep(120_000)
                if matches(readBack()) { return "set [\(index)] \(info.shortDescription) to \"\(AXSnapshotBuilder.clean(text))\" (read back and it matches)" }
            }
            // 2. Select everything in the field and replace the selection.
            let existingLength = (readBack() as NSString).length
            var wholeRange = CFRange(location: 0, length: existingLength)
            if let rangeValue = AXValueCreate(.cfRange, &wholeRange) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            }
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                usleep(120_000)
                if matches(readBack()) { return "set [\(index)] \(info.shortDescription) to \"\(AXSnapshotBuilder.clean(text))\" (read back and it matches)" }
            }
            // 3. Type it as keystrokes sent to this app only (web and Electron fields often need this).
            if existingLength > 0, let selectAll = DriveKeyCombo.parse("cmd+a") {
                Self.postKey(selectAll, to: target.processID)
                usleep(80_000)
            }
            Self.typeText(text, to: target.processID)
            usleep(250_000)
            let finalValue = readBack()
            if matches(finalValue) { return "typed \"\(AXSnapshotBuilder.clean(text))\" into [\(index)] \(info.shortDescription) (read back and it matches)" }
            return "typed into [\(index)] \(info.shortDescription) but could NOT confirm it: the field reads back \"\(AXSnapshotBuilder.clean(finalValue))\". Check with a snapshot or a screenshot before going on."
        }
    }

    /// drive_menu: walk the menu bar by title.
    func chooseMenu(path: [String]) async throws -> String {
        guard !path.isEmpty else { throw DriveError("drive_menu needs a path like [\"File\", \"Export…\"].") }
        return try await perform(note: "choosing \(path.joined(separator: " > "))") {
            guard let target = self.target else { throw DriveError("No target app.") }
            let appElement = AXUIElementCreateApplication(target.processID)
            guard let menuBar = AXRead.element(appElement, kAXMenuBarAttribute as String) else {
                throw DriveError("\(target.appName) has no menu bar Teachy can read.")
            }
            var level = AXRead.elements(menuBar, kAXChildrenAttribute as String)
            var chosen: AXUIElement?
            for (depth, wanted) in path.enumerated() {
                guard let match = level.first(where: { Self.menuTitlesMatch(AXRead.string($0, kAXTitleAttribute as String), wanted) }) else {
                    let available = level.map { AXRead.string($0, kAXTitleAttribute as String) }.filter { !$0.isEmpty }
                    throw DriveError("No menu item \"\(wanted)\" under \(depth == 0 ? "the menu bar" : path[..<depth].joined(separator: " > ")). There: \(available.prefix(40).joined(separator: ", ")).")
                }
                chosen = match
                if depth < path.count - 1 {
                    // A menu bar item or submenu holds one AXMenu, whose children are the items.
                    let inner = AXRead.elements(match, kAXChildrenAttribute as String)
                    if let menu = inner.first(where: { AXRead.string($0, kAXRoleAttribute as String) == "AXMenu" }) {
                        level = AXRead.elements(menu, kAXChildrenAttribute as String)
                    } else {
                        level = inner
                    }
                }
            }
            guard let item = chosen else { throw DriveError("Menu item not found.") }
            if AXRead.bool(item, kAXEnabledAttribute as String) == false {
                throw DriveError("\(path.joined(separator: " > ")) is greyed out right now.")
            }
            try Self.check(AXUIElementPerformAction(item, kAXPressAction as CFString), doing: "choose \(path.joined(separator: " > "))")
            return "chose \(path.joined(separator: " > "))"
        }
    }

    /// drive_key: a key or shortcut, posted to the target app's process only.
    func pressKey(combo: String) async throws -> String {
        guard let parsed = DriveKeyCombo.parse(combo) else {
            throw DriveError("\"\(combo)\" is not a key Teachy knows. Use forms like return, tab, escape, cmd+s, cmd+shift+z, option+left.")
        }
        return try await perform(note: "pressing \(parsed.display)") {
            guard let target = self.target else { throw DriveError("No target app.") }
            Self.postKey(parsed, to: target.processID)
            return "pressed \(parsed.display) in \(target.appName)"
        }
    }

    /// drive_scroll
    func scroll(index: Int?, direction: String, pages: Double) async throws -> String {
        let direction = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw DriveError("direction must be up, down, left or right.")
        }
        return try await perform(note: "scrolling \(direction)") {
            guard let target = self.target, let snapshot = self.lastSnapshot else { throw DriveError("Call drive_snapshot first.") }
            var start: AXUIElement?
            var anchorFrame = snapshot.windowFrame
            if let index {
                let (element, info) = try self.handle(index)
                start = element
                anchorFrame = info.frame
            } else {
                start = AXSnapshotWalker.focusedWindow(of: AXUIElementCreateApplication(target.processID))
            }
            // Nearest scroll area at or above the element.
            var scrollArea: AXUIElement?
            var candidate = start
            for _ in 0..<14 {
                guard let current = candidate else { break }
                if AXRead.string(current, kAXRoleAttribute as String) == "AXScrollArea" { scrollArea = current; break }
                candidate = AXRead.element(current, kAXParentAttribute as String)
            }
            let vertical = direction == "up" || direction == "down"
            if let scrollArea,
               let bar = AXRead.element(scrollArea, (vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute) as String),
               let current = (AXRead.value(bar, kAXValueAttribute as String) as? NSNumber)?.doubleValue {
                let step = 0.25 * max(0.25, min(pages, 4))
                let forward = direction == "down" || direction == "right"
                let next = max(0, min(1, current + (forward ? step : -step)))
                if AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next)) == .success {
                    if next == current { return "already at the \(forward ? "end" : "start"); nothing to scroll" }
                    return "scrolled \(direction)"
                }
            }
            // No scroll bar to set: send a wheel event to this app at that spot (the pointer does not move).
            let lines = Int32(max(1, min(pages, 4)) * 8)
            let deltaY: Int32 = direction == "down" ? -lines : (direction == "up" ? lines : 0)
            let deltaX: Int32 = direction == "right" ? -lines : (direction == "left" ? lines : 0)
            guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
                throw DriveError("Could not scroll.")
            }
            event.location = DriveCoordinates.center(of: anchorFrame)
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.postToPid(target.processID)
            return "sent a scroll \(direction) to \(target.appName) (no scroll bar to read, so check the result)"
        }
    }

    /// drive_click_point: last resort. A point from a named capture, or the centre of a numbered element.
    func clickPoint(arguments: [String: Any]) async throws -> String {
        let resolved = try resolveClickPoint(arguments: arguments)
        return try await perform(note: "clicking \(resolved.label)") {
            guard let target = self.target else { throw DriveError("No target app.") }
            let appElement = AXUIElementCreateApplication(target.processID)
            // Scoped to the target window: never click somewhere else on screen.
            let windowFrame = AXSnapshotWalker.focusedWindow(of: appElement).map(AXRead.frame) ?? self.lastSnapshot?.windowFrame ?? .zero
            guard windowFrame.insetBy(dx: -2, dy: -2).contains(resolved.point) else {
                throw DriveError("That point (\(Int(resolved.point.x)), \(Int(resolved.point.y))) is outside \(target.appName)'s window, so Teachy will not click it. Take a new capture_screen and check the coordinates, or use drive_snapshot.")
            }
            // Prefer pressing whatever accessibility says is under the point.
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(appElement, Float(resolved.point.x), Float(resolved.point.y), &hit) == .success, let hit {
                var candidate: AXUIElement? = hit
                for _ in 0..<4 {
                    guard let current = candidate else { break }
                    if AXRead.actions(current).contains(kAXPressAction as String), AXRead.frame(current).insetBy(dx: -2, dy: -2).contains(resolved.point) {
                        let description = Self.describe(current)
                        if AXUIElementPerformAction(current, kAXPressAction as CFString) == .success {
                            return "pressed \(description) at \(resolved.label)"
                        }
                        break
                    }
                    candidate = AXRead.element(current, kAXParentAttribute as String)
                }
            }
            // Otherwise a click event delivered to this app only. The real pointer stays where it is.
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: resolved.point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: resolved.point, mouseButton: .left) else {
                throw DriveError("Could not create the click.")
            }
            for event in [down, up] {
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                event.postToPid(target.processID)
                usleep(40_000)
            }
            return "clicked at \(resolved.label) in \(target.appName) (sent to the app only; some apps ignore that, so check the result)"
        }
    }

    private func resolveClickPoint(arguments: [String: Any]) throws -> (point: CGPoint, label: String) {
        if let index = Self.int(arguments["index"]) {
            let (_, info) = try handle(index)
            return (DriveCoordinates.center(of: info.frame), "[\(index)] \(info.shortDescription)")
        }
        guard let x = Self.double(arguments["x"]), let y = Self.double(arguments["y"]) else {
            throw DriveError("drive_click_point needs either index, or x and y plus capture_id.")
        }
        let captureID = ToolPolicy.string(arguments["capture_id"])
        guard !captureID.isEmpty else {
            throw DriveError("drive_click_point needs capture_id: the id of the screenshot the x,y came from (capture_screen returns it). Without it Teachy cannot map the point to the screen.")
        }
        guard let capture = captures[captureID] else {
            throw DriveError("Unknown capture_id \"\(captureID)\". Known: \(captures.keys.sorted().joined(separator: ", ")). Call capture_screen for a fresh one.")
        }
        guard Date().timeIntervalSince(capture.takenAt) < 180 else {
            throw DriveError("\(captureID) is more than three minutes old and the screen may have changed. Call capture_screen again.")
        }
        guard let point = DriveCoordinates.globalCGPoint(screenshotX: x, screenshotY: y, in: capture.geometry) else {
            throw DriveError("(\(Int(x)), \(Int(y))) is outside \(captureID), which is \(capture.geometry.screenshotWidthInPixels)x\(capture.geometry.screenshotHeightInPixels) pixels.")
        }
        return (point, "(\(Int(x)), \(Int(y))) of \(captureID)")
    }

    // MARK: The shared act → re-read → diff step

    private func perform(note: String, _ action: () throws -> String) async throws -> String {
        guard AXIsProcessTrusted() else {
            throw DriveError("Teachy needs Accessibility permission before it can drive apps. Tell the user.")
        }
        guard let target, let before = lastSnapshot else {
            throw DriveError("Call drive_snapshot first so Teachy knows which app and what is on screen.")
        }
        try Task.checkCancellation()
        try handBackIfSecret(in: before)

        if !hasStartedDriving {
            // The takeover watch must be running before the first action, or Teachy does not drive.
            let started = await DriveTakeoverMonitor.shared.beginDriving(jobID: jobID, appName: target.appName)
            guard started else {
                throw DriveError("Teachy could not start watching for Escape and mouse movement, so it will not drive. The user needs to allow Accessibility for Teachy.")
            }
            hasStartedDriving = true
            await MainActor.run {
                _ = NSRunningApplication(processIdentifier: target.processID)?.activate()
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        await DriveTakeoverMonitor.shared.setNote(note, jobID: jobID)

        let line = try action()

        try await Task.sleep(nanoseconds: 350_000_000)
        try Task.checkCancellation()
        let after = try takeSnapshot()
        try handBackIfSecret(in: after)
        return AXSnapshotDiff.describe(action: line, before: before, after: after)
    }

    /// Called when the job ends, however it ends.
    func end() async {
        if hasStartedDriving {
            await DriveTakeoverMonitor.shared.endDriving(jobID: jobID)
            hasStartedDriving = false
        }
    }

    // MARK: Helpers

    private func handle(_ index: Int) throws -> (AXUIElement, AXSnapshotElement) {
        guard let snapshot = lastSnapshot else { throw DriveError("Call drive_snapshot first.") }
        guard let info = snapshot.element(at: index), let element = handles[index] else {
            throw DriveError("There is no element [\(index)] in the latest snapshot of \(snapshot.appName). Call drive_snapshot to see the current numbers.")
        }
        return (element, info)
    }

    private func describe(_ index: Int) -> String {
        lastSnapshot?.element(at: index)?.shortDescription ?? "element \(index)"
    }

    /// The gate approved a control by its label at snapshot time. If the label has since turned
    /// into Delete / Send / Pay, stop: that is not what the user said yes to.
    private func refuseIfControlTurnedSensitive(element: AXUIElement, snapshotInfo: AXSnapshotElement) throws {
        let liveName = Self.describe(element)
        if SensitiveWords.firstMatch(in: liveName) != nil, SensitiveWords.firstMatch(in: snapshotInfo.shortDescription) == nil {
            throw DriveError("That control now reads \(liveName), which is not what it said in the snapshot. Call drive_snapshot again.")
        }
    }

    private static func describe(_ element: AXUIElement) -> String {
        var node = AXRawNode()
        node.role = AXRead.string(element, kAXRoleAttribute as String)
        node.subrole = AXRead.string(element, kAXSubroleAttribute as String)
        node.title = AXRead.string(element, kAXTitleAttribute as String)
        node.label = AXRead.string(element, kAXDescriptionAttribute as String)
        let role = AXSnapshotFormatter.friendlyRole(role: node.role, subrole: node.subrole)
        let name = AXSnapshotBuilder.bestName(node)
        return name.isEmpty ? role : "\(role) \"\(name)\""
    }

    private static func check(_ error: AXError, doing what: String) throws {
        switch error {
        case .success:
            return
        case .cannotComplete:
            // Common when the press opens a sheet or dialog: the app is busy showing it. The diff will tell.
            return
        case .actionUnsupported, .attributeUnsupported:
            throw DriveError("Could not \(what): the control does not support that through accessibility.")
        case .invalidUIElement:
            throw DriveError("Could not \(what): that control is gone. Call drive_snapshot again.")
        case .apiDisabled, .notImplemented:
            throw DriveError("Could not \(what): the app does not allow accessibility control.")
        default:
            throw DriveError("Could not \(what) (accessibility error \(error.rawValue)).")
        }
    }

    private static func menuTitlesMatch(_ title: String, _ wanted: String) -> Bool {
        func normal(_ text: String) -> String {
            var result = text.lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
            while result.hasSuffix(".") { result.removeLast() }
            return result
        }
        let left = normal(title), right = normal(wanted)
        if left.isEmpty || right.isEmpty { return false }
        return left == right || (right == "apple" && title == "Apple")
    }

    private static func cgFlags(_ modifiers: DriveKeyCombo.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private static func postKey(_ combo: DriveKeyCombo, to processID: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: isDown) else { continue }
            event.flags = cgFlags(combo.modifiers)
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.postToPid(processID)
            usleep(15_000)
        }
    }

    private static func typeText(_ text: String, to processID: pid_t) {
        let source = CGEventSource(stateID: .privateState)
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
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                event.postToPid(processID)
            }
            usleep(12_000)
            offset = end
        }
    }

    @MainActor
    private static func resolveTarget(named requested: String?, current: DriveTarget?) throws -> DriveTarget {
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let wanted = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let application: NSRunningApplication?
        if !wanted.isEmpty {
            let lower = wanted.lowercased()
            let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            application = regular.first { ($0.localizedName ?? "").lowercased() == lower || ($0.bundleIdentifier ?? "").lowercased() == lower }
                ?? regular.first { ($0.localizedName ?? "").lowercased().contains(lower) }
            if application == nil {
                throw DriveError("\(wanted) is not running. Open it first (control_app), then snapshot again.")
            }
        } else if let current, NSRunningApplication(processIdentifier: current.processID)?.isTerminated == false {
            return current
        } else {
            application = NSWorkspace.shared.frontmostApplication
        }
        guard let application else { throw DriveError("There is no app in front to read.") }
        if application.bundleIdentifier == ownBundleID || application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            throw DriveError("Teachy does not drive itself. Name the app you mean.")
        }
        return DriveTarget(
            processID: application.processIdentifier,
            appName: application.localizedName ?? application.bundleIdentifier ?? "the app",
            bundleID: application.bundleIdentifier ?? ""
        )
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
