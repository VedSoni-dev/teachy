// Live annotation anchoring. No screenshots, OCR, model calls or permission prompts.
// Unresolvable marks keep their original placement; a bound mark hides when its target is lost.
import AppKit
import ApplicationServices

/// Pure display/command geometry; all target rectangles are global CG points.
enum SceneAnnotationTrackingGeometry {
    nonisolated static func displayCG(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func targetPoint(_ command: SceneCommand, display: CGRect) -> CGPoint? {
        let p: SceneVec2?
        switch command.verb {
        case .ring: p = command.vec2("at")
        case .arrow: p = command.vec2("to")
        case .rect, .highlight:
            if let from = command.vec2("from"), let to = command.vec2("to") { p = (from + to) / 2 }
            else if command.numbers("box").count == 4 {
                let b = command.numbers("box"); p = SceneVec2((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
            } else { p = command.vec2("at") }
        default: return nil
        }
        guard let p, p.x.isFinite, p.y.isFinite, (0...1000).contains(p.x), (0...1000).contains(p.y), display.width > 0, display.height > 0 else { return nil }
        return CGPoint(x: display.minX + p.x / 1000 * display.width, y: display.minY + p.y / 1000 * display.height)
    }

    /// Translate from the original geometry, never from the previous tick (no drift).
    static func translated(_ original: SceneCommand, from: CGRect, to: CGRect, display: CGRect) -> SceneCommand {
        guard display.width > 0, display.height > 0 else { return original }
        let delta = SceneVec2((to.midX - from.midX) / display.width * 1000, (to.midY - from.midY) / display.height * 1000)
        var result = original
        for key in ["at", "from", "to"] {
            if let point = original.vec2(key) { let moved = point + delta; result.args[key] = "\(moved.x),\(moved.y)" }
        }
        let box = original.numbers("box")
        if box.count == 4 { result.args["box"] = "\(box[0] + delta.x),\(box[1] + delta.y),\(box[2] + delta.x),\(box[3] + delta.y)" }
        return result
    }

    static func acceptsTarget(_ target: CGRect, command: SceneCommand, display: CGRect) -> Bool {
        guard target.width <= min(400, display.width * 0.4), target.height <= min(120, display.height * 0.2) else { return false }
        var width: Double?, height: Double?
        if command.verb == .ring {
            let scale = sqrt(display.width * display.height) / 1000
            width = command.number("rx").map { $0 * display.width / 500 } ?? (command.number("r") ?? 40) * scale * 2
            height = command.number("ry").map { $0 * display.height / 500 } ?? (command.number("r") ?? 40) * scale * 2
        } else if command.verb == .rect || command.verb == .highlight {
            if let a = command.vec2("from"), let b = command.vec2("to") {
                width = abs(b.x - a.x) * display.width / 1000; height = abs(b.y - a.y) * display.height / 1000
            } else if let size = command.vec2("size") {
                width = abs(size.x) * display.width / 1000; height = abs(size.y) * display.height / 1000
            } else {
                let box = command.numbers("box")
                if box.count == 4 { width = abs(box[2] - box[0]) * display.width / 1000; height = abs(box[3] - box[1]) * display.height / 1000 }
            }
        }
        if let width, let height { return target.width <= max(24, width * 2) && target.height <= max(24, height * 2) }
        return true
    }

    nonisolated static func isVisible(_ frame: CGRect, inside clips: [CGRect]) -> Bool {
        guard frame.width >= 1, frame.height >= 1, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return false }
        let visible = clips.reduce(frame) { $0.intersection($1) }
        return !visible.isNull && visible.width * visible.height >= frame.width * frame.height * 0.98
    }
}

/// All synchronous AX IPC stays off the main actor. Handles never leave this actor.
nonisolated protocol SceneAnnotationTargetReading: Sendable {
    func bind(id: UUID, pid: pid_t, point: CGPoint) async -> CGRect?
    func currentFrame(id: UUID, display: CGRect) async -> CGRect?
    func release(_ ids: [UUID]) async
}

actor SceneAnnotationAXReader: SceneAnnotationTargetReading {
    private struct Binding {
        let element: AXUIElement
        let window: AXUIElement
        let clips: [AXUIElement]
        // Virtualized rows may recycle the same handle for a different name.
        // Ephemeral only: never logged or persisted.
        let identity: [String]
    }
    private var bindings: [UUID: Binding] = [:]

    private func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private func identity(_ element: AXUIElement) -> [String]? {
        guard let role = value(element, kAXRoleAttribute as String) as? String,
              role != "AXSecureTextField",
              (value(element, kAXSubroleAttribute as String) as? String) != "AXSecureTextField" else { return nil }
        return [role] + [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map {
            (value(element, $0 as String) as? String) ?? ""
        }
    }
    private func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(source, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute as String), let s = value(element, kAXSizeAttribute as String), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width >= 1, size.height >= 1 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func bind(id: UUID, pid: pid_t, point: CGPoint) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.08)
        let role = value(hit, kAXRoleAttribute as String) as? String ?? ""
        // Never claim a document/window is a text/control anchor: it will not follow scrolling.
        let targetRoles: Set<String> = ["AXButton", "AXLink", "AXStaticText", "AXHeading", "AXImage", "AXTextField", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXCell", "AXTab", "AXTabButton"]
        guard targetRoles.contains(role),
              (value(hit, kAXSubroleAttribute as String) as? String) != "AXSecureTextField",
              let signature = identity(hit), let initial = frame(hit), initial.contains(point),
              let window = element(hit, kAXWindowAttribute as String) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.08)
        var clips: [AXUIElement] = []
        var parent = element(hit, kAXParentAttribute as String)
        for _ in 0..<12 {
            guard let current = parent else { break }
            AXUIElementSetMessagingTimeout(current, 0.08)
            let ancestorRole = value(current, kAXRoleAttribute as String) as? String ?? ""
            if ["AXScrollArea", "AXWebArea", "AXClipView"].contains(ancestorRole) { clips.append(current) }
            if CFEqual(current, window) { break }
            parent = element(current, kAXParentAttribute as String)
        }
        bindings[id] = Binding(element: hit, window: window, clips: clips, identity: signature)
        return initial
    }

    func currentFrame(id: UUID, display: CGRect) -> CGRect? {
        guard AXIsProcessTrusted(), let binding = bindings[id],
              identity(binding.element) == binding.identity,
              (value(binding.window, kAXMinimizedAttribute as String) as? NSNumber)?.boolValue != true,
              let current = frame(binding.element), let window = frame(binding.window) else { return nil }
        var bounds = [display, window]
        for clip in binding.clips { guard let rect = frame(clip) else { return nil }; bounds.append(rect) }
        return SceneAnnotationTrackingGeometry.isVisible(current, inside: bounds) ? current : nil
    }
    func release(_ ids: [UUID]) { for id in ids { bindings.removeValue(forKey: id) } }
}

@MainActor
final class SceneAnnotationTracker {
    private struct Entry {
        let token: UUID
        let original: SceneCommand
        let createdAt: Date
        let windowID: CGWindowID
        let pid: pid_t
        let initial: CGRect
    }
    private weak var model: SceneOverlayModel?
    private let display: CGRect
    private let reader: any SceneAnnotationTargetReading
    private let windowProvider: (() -> [Window])?
    private let appVisible: (pid_t) -> Bool
    private var entries: [String: Entry] = [:]
    private var pending: [String: UUID] = [:]
    private var generation = 0
    private var poll: Task<Void, Never>?

    init(model: SceneOverlayModel, displayFrame: CGRect, primaryHeight: CGFloat,
         reader: any SceneAnnotationTargetReading = SceneAnnotationAXReader(),
         windowProvider: (() -> [Window])? = nil,
         appVisible: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isHidden == false }) {
        self.reader = reader
        self.windowProvider = windowProvider
        self.appVisible = appVisible
        self.model = model
        display = SceneAnnotationTrackingGeometry.displayCG(displayFrame, primaryHeight: primaryHeight)
    }

    func stop() {
        generation += 1
        poll?.cancel(); poll = nil
        let ids = entries.values.map(\.token) + Array(pending.values)
        entries.removeAll(); pending.removeAll()
        Task { await reader.release(ids) }
    }

    struct Window { let id: CGWindowID; let pid: pid_t; let frame: CGRect; var isPrivate = false }
    private func windows() -> [Window] {
        if let windowProvider { return windowProvider() }
        let ownWindows = NSApp?.windows.filter { $0.windowNumber > 0 } ?? []
        let excluded = Set(ownWindows.filter(\.ignoresMouseEvents).map { CGWindowID($0.windowNumber) })
        // Private windows still occlude marks; they are only forbidden as binding targets.
        let privateIDs = Set(ownWindows.filter { $0.sharingType == .none }.map { CGWindowID($0.windowNumber) })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !(pid == ownPID && excluded.contains(id)),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary), frame.width > 1, frame.height > 1 else { return nil }
            return Window(id: id, pid: pid, frame: frame, isPrivate: pid == ownPID && privateIDs.contains(id))
        }
    }

    func register(_ command: SceneCommand) {
        guard let model, let item = model.items.first(where: { $0.id == command.id }),
              let point = SceneAnnotationTrackingGeometry.targetPoint(command, display: display),
              entries.count + pending.count < 24,
              let window = windows().first(where: { $0.frame.contains(point) }), !window.isPrivate else { return }
        if let old = entries.removeValue(forKey: command.id) { Task { await reader.release([old.token]) } }
        let token = UUID(), run = generation
        pending[command.id] = token
        Task { [weak self] in
            guard let self else { return }
            let initial = await self.reader.bind(id: token, pid: window.pid, point: point)
            guard run == self.generation, self.pending[command.id] == token else {
                await self.reader.release([token]); return
            }
            self.pending.removeValue(forKey: command.id)
            guard self.model?.isTrackingActive(id: command.id, createdAt: item.createdAt) == true else {
                await self.reader.release([token]); return
            }
            guard let initial else { return }
            // A hit on a whole editor/paragraph must not masquerade as tracking one word.
            guard SceneAnnotationTrackingGeometry.acceptsTarget(initial, command: command, display: self.display) else {
                await self.reader.release([token]); return
            }
            self.entries[command.id] = Entry(token: token, original: command, createdAt: item.createdAt, windowID: window.id, pid: window.pid, initial: initial)
            self.startPolling()
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        let run = generation
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, run == self.generation, let model = self.model else { return }
                let windows = self.windows()
                for (id, entry) in self.entries {
                    guard model.isTrackingActive(id: id, createdAt: entry.createdAt) else {
                        self.entries.removeValue(forKey: id); await self.reader.release([entry.token]); continue
                    }
                    let current = await self.reader.currentFrame(id: entry.token, display: self.display)
                    guard !Task.isCancelled, run == self.generation, self.entries[id]?.token == entry.token,
                          model.isTrackingActive(id: id, createdAt: entry.createdAt) else { continue }
                    let visible = current.flatMap { frame -> CGRect? in
                        guard let windowIndex = windows.firstIndex(where: { $0.id == entry.windowID }),
                              !windows[windowIndex].isPrivate,
                              !windows.prefix(windowIndex).contains(where: { $0.frame.intersects(frame) }),
                              self.appVisible(entry.pid) else { return nil }
                        return frame
                    }
                    let command = visible.map { SceneAnnotationTrackingGeometry.translated(entry.original, from: entry.initial, to: $0, display: self.display) }
                    model.updateTrackedGeometry(id: id, createdAt: entry.createdAt, command: command)
                }
                if self.entries.isEmpty { self.poll = nil; return }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}
