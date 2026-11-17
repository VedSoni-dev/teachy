import AppKit

actor FakeTargets: SceneAnnotationTargetReading {
    var rect: CGRect? = CGRect(x: 300, y: 400, width: 100, height: 40)
    var calls = 0
    var bindCalls = 0
    var delay: UInt64 = 0
    init(delay: UInt64 = 0) { self.delay = delay }
    var released = 0
    func bind(id: UUID, pid: pid_t, point: CGPoint) async -> CGRect? {
        bindCalls += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return rect
    }
    func currentFrame(id: UUID, display: CGRect) -> CGRect? { calls += 1; return rect }
    func release(_ ids: [UUID]) { released += ids.count }
    func move(_ value: CGRect?) { rect = value }
}

@main struct Harness {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }; count += 1
        }
        let display = CGRect(x: -1000, y: -200, width: 1000, height: 800)
        check(SceneAnnotationTrackingGeometry.displayCG(CGRect(x: -1000, y: 400, width: 1000, height: 800), primaryHeight: 1000) == display, "secondary display uses primary flip")
        let ring = SceneCommand(verb: .ring, id: "r", args: ["at": "300,400", "rx": "60", "ry": "30", "for": "10"])
        check(SceneAnnotationTrackingGeometry.targetPoint(ring, display: display) == CGPoint(x: -700, y: 120), "normalized point on secondary")
        let arrow = SceneCommand(verb: .arrow, id: "a", args: ["from": "10,20", "to": "300,400"])
        check(SceneAnnotationTrackingGeometry.targetPoint(arrow, display: display) == CGPoint(x: -700, y: 120), "arrow binds tip")
        let old = CGRect(x: 10, y: 10, width: 40, height: 30)
        let next = old.offsetBy(dx: 100, dy: 80)
        check(SceneAnnotationTrackingGeometry.translated(ring, from: old, to: next, display: display).vec2("at") == SceneVec2(400, 500), "translation independent of screen origin")
        check(!SceneAnnotationTrackingGeometry.isVisible(old, inside: [CGRect(x: 30, y: 0, width: 100, height: 100)]), "clipped target hides")
        check(SceneAnnotationTrackingGeometry.isVisible(old, inside: [CGRect(x: 0, y: 0, width: 100, height: 100)]), "visible target accepted")
        check(!SceneAnnotationTrackingGeometry.acceptsTarget(CGRect(x: 0, y: 0, width: 900, height: 600), command: ring, display: display), "whole editor rejected")
        check(!SceneAnnotationTrackingGeometry.acceptsTarget(CGRect(x: 0, y: 0, width: 300, height: 40), command: ring, display: display), "target far larger than mark rejected")
        let model = SceneOverlayModel()
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        model.clock = { now }
        model.apply(ring)
        let created = model.items[0].createdAt, fade = model.items[0].fadeStart
        let resolver = FakeTargets()
        var covering = false
        let tracker = SceneAnnotationTracker(model: model, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), primaryHeight: 1000, reader: resolver, windowProvider: {
            let base = SceneAnnotationTracker.Window(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
            return covering ? [.init(id: 2, pid: 2, frame: CGRect(x: 495, y: 500, width: 20, height: 40)), base] : [base]
        }, appVisible: { _ in true })
        tracker.register(ring)
        try? await Task.sleep(nanoseconds: 180_000_000)
        await resolver.move(CGRect(x: 400, y: 500, width: 100, height: 40))
        try? await Task.sleep(nanoseconds: 180_000_000)
        check(model.items[0].command.vec2("at") == SceneVec2(400, 500), "retained target moves mark")
        check(model.items[0].createdAt == created && model.items[0].fadeStart == fade, "moving preserves reveal and expiry")
        await resolver.move(nil)
        try? await Task.sleep(nanoseconds: 180_000_000)
        check(model.items[0].hiddenByTracking, "lost target hides")
        await resolver.move(CGRect(x: 400, y: 500, width: 100, height: 40))
        try? await Task.sleep(nanoseconds: 180_000_000)
        check(!model.items[0].hiddenByTracking, "valid target recovers")
        covering = true
        try? await Task.sleep(nanoseconds: 180_000_000)
        check(model.items[0].hiddenByTracking, "partial corner occlusion hides even with center uncovered")
        now = now.addingTimeInterval(10)
        try? await Task.sleep(nanoseconds: 180_000_000)
        let calls = await resolver.calls
        try? await Task.sleep(nanoseconds: 180_000_000)
        check(await resolver.calls == calls, "fade stops resolver polling")
        tracker.stop()
        model.updateTrackedGeometry(id: "r", createdAt: created, command: arrow)
        check(model.items[0].command.verb == .ring, "late geometry cannot resurrect fading mark")
        model.apply(ring)
        let privateResolver = FakeTargets()
        let privateTracker = SceneAnnotationTracker(model: model, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), primaryHeight: 1000, reader: privateResolver, windowProvider: {
            [.init(id: 9, pid: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isPrivate: true),
             .init(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))]
        }, appVisible: { _ in true })
        privateTracker.register(ring)
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(await privateResolver.bindCalls == 0, "private preview prevents inspecting underlying target")
        privateTracker.stop()
        let delayed = FakeTargets(delay: 180_000_000)
        let delayedTracker = SceneAnnotationTracker(model: model, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), primaryHeight: 1000, reader: delayed, windowProvider: {
            [.init(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))]
        }, appVisible: { _ in true })
        delayedTracker.register(ring)
        try? await Task.sleep(nanoseconds: 40_000_000)
        delayedTracker.stop()
        try? await Task.sleep(nanoseconds: 240_000_000)
        check(await delayed.calls == 0, "canceled pending bind never starts polling")
        check(await delayed.released >= 1, "canceled pending handle released")
        print("Passed \(count) annotation tracking checks (fake AX; no permissions/captures)")
    }
}
