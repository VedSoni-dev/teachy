//
//  Scene3DController.swift
//  leanring-buddy / Scene
//
//  The 3D half of the drawing engine. Builds a SceneKit scene from scene
//  commands as they arrive: parts, the part library, label chips with leader
//  lines, motion, and simulation (SceneKit physics for bodies, joints and
//  collisions; kinematics for gears, orbits, pistons and flow).
//
//  Everything here runs on the main thread: commands, the 60 Hz tick that drives
//  motion, and slider changes. SceneKit renders and steps physics on its own thread.
//

import AppKit
import Combine
import SceneKit
import simd

// MARK: - UI state shown around the 3D view

@MainActor
final class Scene3DModel: ObservableObject {
    struct SliderState: Identifiable, Equatable {
        let id: String
        var label: String
        var minimum: Double
        var maximum: Double
        var value: Double
        var unit: String
    }

    struct PlotState: Identifiable, Equatable {
        let id: String
        var label: String
        var samples: [Double] = []
        var color: SceneColor
        var unit: String
    }

    @Published var title = ""
    @Published var sliders: [SliderState] = []
    @Published var plots: [PlotState] = []
    @Published var chips: [String] = []
    @Published var tappedLabel: String?
    /// The view is not the default one (zoomed on a part, or turned by hand): show "Recenter".
    @Published var canRecenter = false

    /// Sliders, plots or chips were added or removed, so the window should resize.
    var onLayoutChanged: (() -> Void)?
}

// MARK: - SceneKit view

final class Scene3DSCNView: SCNView {
    /// A click on the view that was not a drag or the first half of a double-click.
    var onViewportChanged: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { onViewportChanged?() }
    }

    var onTap: ((CGPoint) -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    /// A drag began, turned the model (dx, dy in points), slid it, ended.
    var onDragBegan: (() -> Void)?
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Zoom by a factor (above 1 moves in) about a point of the view.
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    /// Escape was pressed.
    var onEscape: (() -> Void)?

    private var mouseDownPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var dragStarted = false
    private var dragPans = false
    private var pendingTap: DispatchWorkItem?
    /// A press that moves less than this many points is a click on a part, not a turn of the model.
    static let clickSlop: CGFloat = 4
    /// A click waits this long to see whether it is the first half of a double-click
    /// (which focuses the part instead of asking about it). Zero reports clicks at once.
    var tapDelay: TimeInterval = min(NSEvent.doubleClickInterval, 0.3)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The model's panel only becomes key when the person clicks the model itself (it is a
    /// non-activating panel, so their app stays the active one). From then on Escape reaches
    /// this view; a click back in their app gives the keyboard back to it.
    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginPress(event, pans: event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) { continueDrag(event) }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let wasDrag = dragStarted
        let start = mouseDownPoint
        endPress()
        guard !wasDrag, let start, hypot(point.x - start.x, point.y - start.y) < Self.clickSlop else { return }
        if event.clickCount >= 2 {
            pendingTap?.cancel()
            pendingTap = nil
            onDoubleTap?(point)
        } else if tapDelay <= 0 {
            onTap?(point)
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingTap = nil
                self?.onTap?(point)
            }
            pendingTap?.cancel()
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + tapDelay, execute: work)
        }
    }

    // The right button (or the middle one) slides the model.
    override func rightMouseDown(with event: NSEvent) { beginPress(event, pans: true) }
    override func rightMouseDragged(with event: NSEvent) { continueDrag(event) }
    override func rightMouseUp(with event: NSEvent) { endPress() }
    override func otherMouseDown(with event: NSEvent) { beginPress(event, pans: true) }
    override func otherMouseDragged(with event: NSEvent) { continueDrag(event) }
    override func otherMouseUp(with event: NSEvent) { endPress() }

    private func beginPress(_ event: NSEvent, pans: Bool) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = mouseDownPoint
        dragStarted = false
        dragPans = pans
    }

    /// Only a real drag takes the camera. A plain click on a part must not.
    private func continueDrag(_ event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragStarted {
            guard hypot(point.x - start.x, point.y - start.y) >= Self.clickSlop else { return }
            dragStarted = true
            if event.modifierFlags.contains(.option) { dragPans = true }
            onDragBegan?()
        }
        let last = lastDragPoint ?? start
        lastDragPoint = point
        if dragPans { onPan?(point.x - last.x, point.y - last.y) } else { onOrbit?(point.x - last.x, point.y - last.y) }
    }

    private func endPress() {
        if dragStarted { onDragEnded?() }
        mouseDownPoint = nil
        lastDragPoint = nil
        dragStarted = false
        dragPans = false
    }

    /// Scrolling zooms toward the cursor, whatever does the scrolling: a mouse wheel, two fingers
    /// on a trackpad, a Magic Mouse. With Shift held it slides the model instead (so does
    /// option-drag or right-drag). A pinch zooms too.
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            // A wheel scrolls by lines, a trackpad by points. (Shift turns a wheel's turn into a sideways scroll.)
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            onPan?(event.scrollingDeltaX * scale, -event.scrollingDeltaY * scale)
            return
        }
        let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.09
        guard amount != 0 else { return }
        onZoom?(CGFloat(exp(Double(max(min(amount, 1.2), -1.2)))), point)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0.05 else { return }
        onZoom?(factor, convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    /// Escape as AppKit's "cancel" (what it sends when something else in the panel has the keyboard).
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Controller

@MainActor
final class Scene3DController: NSObject {
    let scene = SCNScene()
    let view: Scene3DSCNView
    let model = Scene3DModel()

    /// (part id, the part's label or name).
    var onPartTapped: ((String, String) -> Void)?
    /// The person dragged a slider (id, value). Used to record the change for replay.
    var onSliderChanged: ((String, Double) -> Void)?

    private let contentRoot = SCNNode()
    private let labelRoot = SCNNode()
    private let cameraNode = SCNNode()
    private let shadowNode = SCNNode()

    private var builder = ScenePartBuilder()
    private var nodes: [String: SCNNode] = [:]
    private var parts: [String: ScenePart] = [:]
    private var baseOrientation: [String: simd_quatf] = [:]
    private var order: [String] = []

    // Motion
    private struct Spin { var axis: SceneVec3?; var rpm: Double }
    private var spins: [String: Spin] = [:]
    private var spinAngles: [String: Double] = [:]
    private var solvedRPM: [String: Double] = [:]
    private struct Flow {
        var markers: [String]; var path: [SceneVec3]; var speed: Double; var phase: Double; var length: Double
        /// A closed loop (a chain): markers keep their size all the way round.
        var loops = false
        /// The gear whose rim speed the markers follow, and its radius.
        var driver: String?
        var driveRadius = 0.0
        /// Links keep this side facing along the gear's axle.
        var facing: SceneVec3?
    }
    private struct Beat { var bpm: Double; var amount: Double; var phase: Double }
    private var beats: [String: Beat] = [:]
    private var flows: [String: Flow] = [:]
    private struct Piston { var crank: Double; var rod: Double; var headHeight: Double; var rpm: Double; var angle: Double }
    private var pistons: [String: Piston] = [:]
    private struct Orbit { var around: String?; var center: SceneVec3; var radius: Double; var period: Double; var tilt: Double; var angle: Double }
    private var orbits: [String: Orbit] = [:]
    private struct Coil { var a: String; var b: String; var coils: Double; var radius: Double; var wire: Double; var stiffness: Double; var rest: Double; var damping: Double }
    private var coils: [String: Coil] = [:]
    private var explodedOffsets: [String: simd_float3] = [:]

    // Labels
    private struct LabelChip { var partID: String; var chip: SCNNode; var leader: SCNNode; var index: Int; var side: String? }
    /// The box round every chip in the camera plane (relative to the model's middle), so the camera keeps chips in frame.
    private var chipExtent: (low: SceneVec2, high: SceneVec2)?
    private var labels: [String: LabelChip] = [:]

    // Simulation
    private struct Joint {
        var kind: String
        var a: String?
        var b: String
        var anchorInA: simd_float3
        var axis: simd_float3
        var behavior: SCNPhysicsBehavior?
        var rod: SCNNode?
    }
    private var joints: [String: Joint] = [:]
    private var forces: [String: simd_float3] = [:]
    private var sliderBindings: [String: String] = [:]
    private struct PlotSource { var target: String; var property: String }
    private var plotSources: [String: PlotSource] = [:]
    private var plotBuffers: [String: [Double]] = [:]
    private var isSimulation = false
    private var speed = 1.0
    private(set) var resumeMotionRate = 1.0
    var motionRate: Double { speed }
    /// SCNPhysicsBody.velocity read from the main thread is stale, so speeds are
    /// measured from how far each moving body travelled since the last tick.
    private var movingIDs: Set<String> = []
    private var lastPositions: [String: simd_float3] = [:]
    private var measuredVelocity: [String: simd_float3] = [:]

    // Camera
    /// The view the camera eases between, without the gentle sway that is added when it is drawn.
    private var pose = SceneCameraPose(center: .zero, azimuth: 0.5, elevation: 0.30, distance: 9)
    /// The opening view of the whole model.
    private var baseAzimuth = 0.5
    private var baseElevation = 0.30
    private var swayPhase = 0.0
    private var swayAmount = Scene3DController.wholeSway
    static let wholeSway = 0.3
    static let focusSway = 0.05
    enum CameraMode: Equatable {
        /// Framing the whole model, following it as it is built.
        case whole
        /// Resting on the parts in `focusIDs`.
        case focus
        /// Put somewhere by a `camera` line.
        case pinned
        /// In the person's hands.
        case user
    }
    private(set) var cameraMode = CameraMode.whole
    private struct CameraMove {
        var from: SceneCameraPose
        var to: SceneCameraPose
        var start: CFTimeInterval
        var duration: Double
        var toSway: Double
        /// Extra turn on top of the way from `from` to `to`, radians (an `orbit`).
        var turn = 0.0
        var then: CameraMode
    }
    private var cameraMove: CameraMove?
    /// The parts the camera is on (empty: the whole model).
    private(set) var focusIDs: [String] = []
    private var focusBox: SceneBox?
    private var fitCenter = simd_float3(0, 0, 0)
    private var fitRadius: Float = 2
    private var hasFit = false
    private var autoRotate = false
    private var fitCountdown = 0.0
    private var shownCenter: simd_float3 { simd_float3(pose.center) }
    private var shownDistance: Float { Float(pose.distance) }
    private var userTookCamera: Bool { cameraMode == .user }
    private var cameraPinned: Bool { cameraMode == .pinned }

    /// Calm movement: dwell, one move per sentence, no fidgeting.
    var policy = SceneCameraPolicy()
    /// The person always wins: automatic moves wait until they have been idle this long.
    var gesturePause = SceneGesturePause()
    /// False: `focus`, `frame`, `orbit`, `ghost`, `highlight` and automatic focus are ignored and the
    /// camera only ever frames the whole model (how the engine behaved before; used to compare).
    var directsCamera = true
    enum CommandOrigin { case narration, person, replay }
    /// Who is behind the lines being applied: the narration (held back while the person steers),
    /// the person's own request (always obeyed), or a replay (always obeyed).
    var commandOrigin = CommandOrigin.narration
    /// A line the engine wrote itself (automatic focus, a double-click, Recenter). The session
    /// draws and records it, so replays and saved videos repeat it. Nil: applied directly.
    var onDirectorCommand: ((SceneCommand) -> Void)?

    // What is shown how
    private struct Ghost { var opacity: Double; var auto: Bool }
    private var ghosts: [String: Ghost] = [:]
    private var hiddenIDs: Set<String> = []
    private struct Highlight { var materials: [SCNMaterial]; var start: CFTimeInterval }
    private var highlights: [String: Highlight] = [:]
    private var detailed: Set<String> = []
    /// The line that made each part, and the whole object it belongs to (for `detail` and for describing the scene).
    private var sources: [String: SceneCommand] = [:]
    private var macroOf: [String: SceneVerb] = [:]
    private var labelTexts: [String: String] = [:]
    /// Building hundreds of identical small pieces (a membrane's lipids): they share geometry and are merged into one node.
    private var bulkBuild = false
    /// Parts with geometry beyond this are not added (small unnamed pieces are dropped first).
    static let maximumNodes = 3200
    private struct PendingAuto { var ids: [String]; var sentence: Int?; var notBefore: CFTimeInterval; var expires: CFTimeInterval; var wholeIfEmpty: Bool }
    private var pendingAuto: PendingAuto?
    /// `label a on=j.fan`: the label's own id stands for the part it names.
    private var labelIDs: [String: String] = [:]
    /// The labels `detail` added, by the part it detailed. They are put away by `frame all` (and so by
    /// "go back" and Recenter), and come back when the part is detailed again.
    private var detailLabels: [String: [String]] = [:]
    private var suppressedLabels: Set<String> = []
    private var bulkGeometries: [String: SCNGeometry] = [:]
    private var bulkBoxes: [String: (low: simd_float3, high: simd_float3)] = [:]
    private var coilEnds: [String: (simd_float3, simd_float3)] = [:]

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var plotCountdown = 0.0
    private var renderUntil: CFTimeInterval = 0
    private var isStopped = false
    private var spatialLayoutDirty = true
    private var previouslyHadTransformMotion = false
    private var actionNodeIDs: Set<String> = []
    private var hitTestingNeedsFlush = true

    private final class LocalGeometryBounds: NSObject {
        let low: SCNVector3
        let high: SCNVector3
        init(_ bounds: (min: SCNVector3, max: SCNVector3)) {
            low = bounds.min
            high = bounds.max
        }
    }
    // Geometry is immutable after construction. Weak keys release replaced spring meshes.
    private let geometryBounds = NSMapTable<SCNGeometry, LocalGeometryBounds>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory
    )
    private(set) var geometryBoundsReadCount = 0
    private(set) var hitTestFlushCount = 0
    var isRenderingContinuously: Bool { timer != nil }

    private func localBounds(of geometry: SCNGeometry) -> (SCNVector3, SCNVector3) {
        if let cached = geometryBounds.object(forKey: geometry) { return (cached.low, cached.high) }
        let bounds = geometry.boundingBox
        geometryBoundsReadCount += 1
        geometryBounds.setObject(LocalGeometryBounds(bounds), forKey: geometry)
        return bounds
    }

    private func invalidateSpatialLayout() {
        spatialLayoutDirty = true
        hitTestingNeedsFlush = true
        labelBoxes.removeAll(keepingCapacity: true)
        leaderOffsets.removeAll(keepingCapacity: true)
        fitCountdown = 0
    }

    private func requestFrames(for duration: Double = 2) {
        guard !isHeadless, !isStopped else { return }
        renderUntil = max(renderUntil, now + duration)
        if timer == nil { startTicking() }
        view.isPlaying = true
        view.rendersContinuously = true
        view.needsDisplay = true
    }

    func resume() {
        isStopped = false
        invalidateSpatialLayout()
        requestFrames()
    }

    private func pauseRendering() {
        timer?.invalidate()
        timer = nil
        view.rendersContinuously = false
        view.isPlaying = false
        view.needsDisplay = true
    }

    private var hasTransformMotion: Bool {
        guard speed > 1e-6 else { return false }
        if !actionNodeIDs.isEmpty { return true }
        return spins.values.contains { abs($0.rpm) > 1e-6 }
            || solvedRPM.values.contains { abs($0) > 1e-6 }
            || pistons.values.contains { abs($0.rpm) > 1e-6 }
            || beats.values.contains { $0.amount > 1e-6 }
            || flows.values.contains { flow in
                if let driver = flow.driver { return abs(solvedRPM[driver] ?? spins[driver]?.rpm ?? 0) > 1e-6 }
                return abs(flow.speed) > 1e-6
            }
            || !orbits.isEmpty
            || coils.values.contains { $0.stiffness > 0 }
            || movingIDs.contains { nodes[$0]?.physicsBody?.isResting == false }
    }

    static let fieldOfView: CGFloat = 30

    /// Headless: nothing ticks by itself and nothing fades in. The owner moves time on with
    /// `advance(by:)` and takes pictures with `renderFrame`, so the same log always gives
    /// the same frames (used for saving a drawing as a video and for thumbnails).
    let isHeadless: Bool
    private var manualClock: CFTimeInterval = 0
    private var offscreenRenderer: SCNRenderer?
    private var now: CFTimeInterval { isHeadless ? manualClock : CACurrentMediaTime() }

    init(headless: Bool = false) {
        isHeadless = headless
        view = Scene3DSCNView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        super.init()
        configureView()
        configureScene()
        if headless {
            view.isPlaying = false
            view.rendersContinuously = false
        } else {
            requestFrames()
        }
    }

    var partCount: Int { parts.values.filter { if case .group = $0.shape { return false } else { return true } }.count }
    var hasContent: Bool { !nodes.isEmpty }

    // MARK: Setup

    private func configureView() {
        view.scene = scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        // The engine moves the camera itself (so it can ease to a part, and so the person's
        // drags, scrolls and pinches are clamped and never fight an automatic move).
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isPlaying = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.onViewportChanged = { [weak self] in
            self?.invalidateSpatialLayout()
            self?.requestFrames()
        }
        view.onTap = { [weak self] point in self?.handleTap(at: point) }
        view.onDoubleTap = { [weak self] point in self?.handleDoubleTap(at: point) }
        view.onDragBegan = { [weak self] in self?.userBeganDrag() }
        view.onOrbit = { [weak self] dx, dy in self?.userOrbit(dx: dx, dy: dy) }
        view.onPan = { [weak self] dx, dy in self?.userPan(dx: dx, dy: dy) }
        view.onDragEnded = { [weak self] in self?.userEndedDrag() }
        view.onZoom = { [weak self] factor, point in self?.userZoom(by: factor, at: point) }
        view.onEscape = { [weak self] in self?.recenter() }
    }

    private func configureScene() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Scene3DAssets.environmentImage
        scene.lightingEnvironment.intensity = 0.95
        scene.rootNode.addChildNode(contentRoot)
        scene.rootNode.addChildNode(labelRoot)

        let camera = SCNCamera()
        camera.fieldOfView = Self.fieldOfView
        camera.automaticallyAdjustsZRange = true
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.name = "_camera"
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        // Key light rides with the camera so the model is always lit from over the viewer's shoulder.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 760
        key.color = NSColor(calibratedRed: 1.0, green: 0.965, blue: 0.91, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 6
        key.shadowSampleCount = 16
        key.shadowColor = NSColor.black.withAlphaComponent(0.34)
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdEulerAngles = simd_float3(-0.66, -0.55, 0)
        cameraNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 240
        fill.color = NSColor(calibratedRed: 0.80, green: 0.89, blue: 1.0, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdEulerAngles = simd_float3(-0.15, 0.95, 0)
        cameraNode.addChildNode(fillNode)

        // A rim light from behind and above picks out edges, so parts of one colour don't merge.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 420
        rim.color = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.simdEulerAngles = simd_float3(-2.35, 0.5, 0)
        cameraNode.addChildNode(rimNode)

        // Contact shading in the creases between parts.
        camera.screenSpaceAmbientOcclusionIntensity = 0.55
        camera.screenSpaceAmbientOcclusionRadius = 0.6
        camera.screenSpaceAmbientOcclusionBias = 0.03
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3

        // A soft blob under the model so it sits on something even over a busy screen.
        let plane = SCNPlane(width: 1, height: 1)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Scene3DAssets.shadowImage
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.blendMode = .alpha
        plane.materials = [material]
        shadowNode.geometry = plane
        shadowNode.simdEulerAngles = simd_float3(-.pi / 2, 0, 0)
        shadowNode.renderingOrder = -10
        shadowNode.isHidden = true
        shadowNode.name = "_shadow"
        scene.rootNode.addChildNode(shadowNode)

        scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
        placeCamera()
    }

    private func startTicking() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if let self { self.tick() } else { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isStopped = true
        pauseRendering()
    }

    /// Empties the scene, keeping the view.
    func reset() {
        geometryBounds.removeAllObjects()
        actionNodeIDs.removeAll()
        previouslyHadTransformMotion = false
        invalidateSpatialLayout()
        requestFrames()
        for node in contentRoot.childNodes { node.removeFromParentNode() }
        for node in labelRoot.childNodes { node.removeFromParentNode() }
        scene.physicsWorld.removeAllBehaviors()
        scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
        scene.physicsWorld.speed = 1
        resumeMotionRate = 1
        builder = ScenePartBuilder()
        nodes = [:]; parts = [:]; baseOrientation = [:]; order = []
        spins = [:]; spinAngles = [:]; solvedRPM = [:]; flows = [:]; pistons = [:]; orbits = [:]; coils = [:]; explodedOffsets = [:]
        beats = [:]; chipExtent = nil; leaderOffsets = [:]; labelRowsDecidedFor = ""
        labels = [:]; chipTargets = [:]; springVelocity = [:]; bodyMass = [:]; joints = [:]; forces = [:]; sliderBindings = [:]; plotSources = [:]; plotBuffers = [:]
        isSimulation = false; speed = 1; movingIDs = []; lastPositions = [:]; measuredVelocity = [:]; labelBoxes = [:]
        pose = SceneCameraPose(center: .zero, azimuth: 0.5, elevation: 0.30, distance: 9)
        baseAzimuth = 0.5; baseElevation = 0.30; swayPhase = 0; swayAmount = Self.wholeSway; hasFit = false; autoRotate = false
        cameraMode = .whole; cameraMove = nil; focusIDs = []; focusBox = nil; pendingAuto = nil
        fitCenter = .zero; fitRadius = 2
        ghosts = [:]; hiddenIDs = []; highlights = [:]; flashes = []; detailed = []; sources = [:]; macroOf = [:]; labelTexts = [:]; bulkBuild = false
        labelIDs = [:]; detailLabels = [:]; suppressedLabels = []; bulkGeometries = [:]; bulkBoxes = [:]; coilEnds = [:]; emissionOriginals = [:]
        policy.reset(); gesturePause.resume(); model.canRecenter = false
        shadowNode.isHidden = true
        model.title = ""; model.sliders = []; model.plots = []; model.chips = []; model.tappedLabel = nil
        placeCamera()
    }

    // MARK: Commands

    func apply(_ original: SceneCommand) {
        invalidateSpatialLayout()
        requestFrames()
        if let expansion = SceneMacros.expand(original) {
            // A whole object (jet, rocket, heart…): draw the simpler commands it stands for.
            let bulk = expansion.count > 120
            if bulk { bulkBuild = true }
            for command in expansion {
                macroOf[command.id] = original.verb
                apply(command)
            }
            if bulk {
                bulkBuild = false
                mergeBulkPieces(under: original.id)
            }
            return
        }
        var c = original
        c.verb = SceneRouter.verbIn3D(original)
        switch c.verb {
        case .beat:
            beats[c.id] = Beat(bpm: min(max(c.number("bpm", "rate", "rpm") ?? 60, 1), 240), amount: min(max(c.number("amount", "by") ?? 0.08, 0), 0.5),
                               phase: c.number("phase") ?? 0)
        case .scene3d:
            model.title = c.string("title") ?? c.freeText ?? model.title
            if c.flag("still") { autoRotate = false }
        case .label:
            if let target = c.string("on"), let text = c.freeText {
                addLabel(to: target, text: text, number: c.number("n", "num").map { Int($0) }, side: c.string("side"))
                if c.hasExplicitID, nodes[target] != nil { labelIDs[c.id] = target }
            }
        case .chip:
            if let text = c.freeText, !model.chips.contains(text), model.chips.count < 4 {
                model.chips.append(text)
                model.onLayoutChanged?()
            }
        case .spin:
            // A piece of a ready-made object that already turns keeps its own axle: the script cannot
            // know which way the object lies, and a wrong axis would swing the piece round.
            let keepsAxle = macroOf[c.id] != nil && spins[c.id] != nil && spins[c.id]?.axis == nil
            spins[c.id] = Spin(axis: keepsAxle ? nil : c.axis(), rpm: Self.watchable(c.number("rpm", "speed") ?? 20))
            if let piston = pistons[c.id] { pistons[c.id]?.rpm = c.number("rpm", "speed") ?? piston.rpm; spins[c.id] = nil }
            if setEngineSpeed(c.id, rpm: Self.watchable(c.number("rpm", "speed") ?? 20, limit: 150)) { spins[c.id] = nil }
            solvedRPM = [:]
        case .move: move(c)
        case .pulse: pulse(c.id, times: Int(c.number("times", "n") ?? 3))
        case .explode: explode(c)
        case .camera: moveCamera(c)
        case .orbit:
            if c.isCameraOrbit { orbitCamera(c) } else { addOrbit(c) }
        case .focus: focus(c)
        case .frame: frame(c)
        case .ghost: ghost(c)
        case .detail: detail(c)
        case .highlight: highlight(c)
        case .gravity: setGravity(c)
        case .body: addBody(c, dynamic: true)
        case .fixed: addBody(c, dynamic: false)
        case .ground:
            add(builder.build(c))
            if let node = nodes[c.id] {
                node.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
                node.physicsBody?.restitution = CGFloat(c.number("bounce") ?? 0.95)
                node.physicsBody?.friction = CGFloat(c.number("friction") ?? 0.6)
            }
            enterSimulation()
        case .joint: addJoint(c)
        case .force:
            if let force = c.vec3("f") ?? c.vec3("v") ?? c.vec3("by") { forces[c.id] = simd_float3(force) }
            enterSimulation()
        case .impulse:
            if let impulse = c.vec3("v") ?? c.vec3("f") ?? c.vec3("by"), let body = nodes[c.id]?.physicsBody {
                body.applyForce(SCNVector3(simd_float3(impulse)), asImpulse: true)
            }
        case .mesh:
            if let a = c.string("a"), let b = c.string("b") {
                builder.coupleGears(a, b, ratio: c.number("ratio"))
                solvedRPM = [:]
            }
        case .slider: addSlider(c)
        case .set:
            if let value = c.number("value", "to", "v"), value.isFinite {
                // Explicit global binding also works without a visible slider. Kept as a normal
                // command so live adjustments replay exactly like other person actions.
                if c.string("bind") == "timescale" {
                    applyBinding("timescale", value: min(max(value, 0), 4))
                } else {
                    setSlider(c.id, value: value, fromUser: false)
                }
            }
        case .plot: addPlot(c)
        case .remove: remove(c.id)
        case .hide:
            for id in resolve(c.targetIDs) { setHidden(id, true) }
        case .show:
            if c.names("all") || c.names("everything") {
                for id in Array(hiddenIDs) { setHidden(id, false) }
                for id in Array(ghosts.keys) { setGhost(id, opacity: nil, auto: false) }
            } else {
                for id in resolve(c.targetIDs) {
                    setHidden(id, false)
                    setGhost(id, opacity: nil, auto: false)
                }
            }
        case .spring:
            let build = builder.build(c)
            add(build)
            if let a = c.string("a"), let b = c.string("b"), c.numbers("a").count < 2, var coil = coils[c.id] {
                coil.stiffness = c.number("k", "stiffness") ?? 0
                coil.damping = c.number("damp", "damping") ?? 0.15
                let distance = simd_length(worldPosition(a) - worldPosition(b))
                coil.rest = c.number("rest", "length") ?? Double(distance) * 0.8
                coils[c.id] = coil
                if coil.stiffness > 0 {
                    // The engine moves this body itself (see tick), so SceneKit must not.
                    ensureBody(b, dynamic: true)
                    nodes[b]?.physicsBody?.type = .kinematic
                    movingIDs.remove(b)
                    enterSimulation()
                }
            }
        default:
            guard c.verb.makes3DPart || c.verb == .group else { return }
            sources[c.id] = c
            add(builder.build(c))
        }
    }

    /// Real engines turn thousands of rpm; on screen that is a blur (or looks frozen).
    /// Scripted speeds are capped to something the eye can follow. Sliders are not capped.
    private static func watchable(_ rpm: Double, limit: Double = 240) -> Double {
        min(max(rpm, -limit), limit)
    }

    // MARK: Building nodes

    private func add(_ build: SceneBuild) {
        for part in build.parts { addNode(for: part) }
        for animator in build.animators { register(animator) }
        fitCountdown = min(fitCountdown, 0.06)
        settleUntil = now + 1.2
    }

    private func addNode(for part: ScenePart) {
        invalidateSpatialLayout()
        nodes[part.id]?.removeFromParentNode()
        // A scene past the node budget keeps its named parts and drops further small unnamed pieces.
        if nodes.count >= Self.maximumNodes, nodes[part.id] == nil, part.id.contains("."), part.label == nil, part.name == nil { return }
        let node = SCNNode()
        node.name = part.id
        node.geometry = bulkBuild ? Scene3DAssets.bulkGeometry(for: part, cache: &bulkGeometries) : Scene3DAssets.geometry(for: part)
        node.simdPosition = simd_float3(part.position)
        let orientation = simd_quatf(part.resolvedOrientation)
        node.simdOrientation = orientation
        node.simdScale = simd_float3(part.scale)
        if case .text = part.shape {
            let constraint = SCNBillboardConstraint()
            constraint.freeAxes = .all
            node.constraints = [constraint]
        }
        let parent = part.parent.flatMap { nodes[$0] } ?? contentRoot
        parent.addChildNode(node)
        if isHeadless {
            node.opacity = CGFloat(part.opacity)
        } else {
            node.opacity = 0
            node.runAction(.fadeOpacity(to: CGFloat(part.opacity), duration: 0.28))
        }
        if part.opacity < 0.999 { node.renderingOrder = 10 }
        nodes[part.id] = node
        parts[part.id] = part
        hasUnpreparedGeometry = true
        baseOrientation[part.id] = orientation
        if !order.contains(part.id) { order.append(part.id) }
        if let label = part.label, !label.isEmpty {
            addLabel(to: part.id, text: label, number: part.number, side: nil)
        }
    }

    private func register(_ animator: SceneAnimator) {
        switch animator {
        case .spin(let target, let axis, let rpm):
            spins[target] = Spin(axis: axis, rpm: Self.watchable(rpm))
            solvedRPM = [:]
        case .flow(let group, let markers, let path, let speed):
            flows[group] = Flow(markers: markers, path: path, speed: speed, phase: 0, length: max(SceneGeometry.pathLength(path), 1e-6))
        case .belt(let group, let markers, let path, let gear, let radius, let axis):
            flows[group] = Flow(markers: markers, path: path, speed: 0, phase: 0, length: max(SceneGeometry.pathLength(path), 1e-6),
                                loops: true, driver: gear, driveRadius: radius, facing: axis)
            solvedRPM = [:]
        case .piston(let group, let crank, let rod, let headHeight, let rpm, let phase):
            pistons[group] = Piston(crank: crank, rod: rod, headHeight: headHeight, rpm: Self.watchable(rpm, limit: 150), angle: phase)
            updatePiston(group)
        case .orbit(let target, let around, let center, let radius, let period, let tilt, let phase):
            orbits[target] = Orbit(around: around, center: center, radius: radius, period: period, tilt: tilt, angle: phase)
        case .spring(let target, let a, let b, let coilCount, let radius, let wire):
            coils[target] = Coil(a: a, b: b, coils: coilCount, radius: radius, wire: wire, stiffness: 0, rest: 0, damping: 0.15)
        }
    }

    private func remove(_ id: String) {
        guard let node = nodes[id] else { return }
        let doomed = [id] + nodes.keys.filter { $0.hasPrefix(id + ".") }
        node.runAction(.sequence([.fadeOut(duration: 0.25), .removeFromParentNode()]))
        for key in doomed {
            nodes[key] = nil; parts[key] = nil; spins[key] = nil; flows[key] = nil; pistons[key] = nil; orbits[key] = nil; coils[key] = nil
            beats[key] = nil
            if let label = labels[key] {
                label.chip.removeFromParentNode()
                label.leader.removeFromParentNode()
                labels[key] = nil
            }
        }
        solvedRPM = [:]
    }

    // MARK: Labels

    private func addLabel(to partID: String, text: String, number: Int?, side: String?) {
        guard nodes[partID] != nil else { return }
        // "1 Fan" with n=1, or "1. Fan" with no n: the number belongs in the dot, once.
        let (text, number) = SceneLabelText.split(text, number: number)
        labelTexts[partID] = text
        if let existing = labels[partID] {
            existing.chip.removeFromParentNode()
            existing.leader.removeFromParentNode()
        }
        let accent = parts[partID]?.color ?? .marker
        let (image, aspect) = Scene3DAssets.chipImage(text: text, number: number, accent: accent)
        let plane = SCNPlane(width: aspect, height: 1)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.mipFilter = .linear
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.materials = [material]
        let chip = SCNNode(geometry: plane)
        chip.name = "_label:" + partID
        chip.renderingOrder = 1000
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        chip.constraints = [billboard]

        let cylinder = SCNCylinder(radius: 1, height: 1)
        cylinder.radialSegmentCount = 8
        let ink = SCNMaterial()
        ink.lightingModel = .constant
        ink.diffuse.contents = SceneColor.ink.nsColor
        ink.readsFromDepthBuffer = false
        ink.writesToDepthBuffer = false
        cylinder.materials = [ink]
        let leader = SCNNode(geometry: cylinder)
        leader.name = "_leader:" + partID
        leader.renderingOrder = 990

        if isHeadless {
            leader.opacity = 0.85
        } else {
            chip.opacity = 0
            leader.opacity = 0
            chip.runAction(.sequence([.wait(duration: 0.15), .fadeIn(duration: 0.3)]))
            leader.runAction(.sequence([.wait(duration: 0.15), .fadeOpacity(to: 0.85, duration: 0.3)]))
        }
        labelRoot.addChildNode(leader)
        labelRoot.addChildNode(chip)
        labels[partID] = LabelChip(partID: partID, chip: chip, leader: leader, index: labels[partID]?.index ?? labels.count, side: side)
        labelBoxes[partID] = nil
        leaderOffsets[partID] = nil
        chipTargets[partID] = nil
        updateLabels()
    }

    /// The world-space box around a node and its children, from each geometry's own
    /// box corners. (SCNNode.boundingBox grows with every rotated parent, which made
    /// models look small in the frame.)
    private func tightBounds(of root: SCNNode) -> (low: simd_float3, high: simd_float3)? {
        var low = simd_float3(repeating: .greatestFiniteMagnitude), high = simd_float3(repeating: -.greatestFiniteMagnitude)
        var found = false
        func visit(_ node: SCNNode) {
            if let name = node.name, name.hasPrefix("_") || hiddenIDs.contains(name) { return }
            if node.isHidden { return }
            if let geometry = node.geometry {
                // (A merged node's own box is not reliable, so the box of the pieces it was made from is kept.)
                let (minimum, maximum) = bulkBoxes[node.name ?? ""].map { (SCNVector3($0.low), SCNVector3($0.high)) } ?? localBounds(of: geometry)
                let a = simd_float3(minimum), b = simd_float3(maximum)
                // Only physics moves a node without us setting its transform; reading
                // `presentation` takes SceneKit's lock, so skip it for everything else.
                let transform = movingIDs.contains(node.name ?? "") ? node.presentation.simdWorldTransform : node.simdWorldTransform
                for corner in 0..<8 {
                    let local = simd_float4(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z, 1)
                    let world = transform * local
                    let point = simd_float3(world.x, world.y, world.z)
                    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                    found = true
                }
            }
            for child in node.childNodes { visit(child) }
        }
        visit(root)
        return found ? (low, high) : nil
    }

    private func worldBounds(of node: SCNNode) -> (center: simd_float3, radius: Float) {
        guard let (low, high) = tightBounds(of: node) else { return (node.presentation.simdWorldPosition, 0) }
        return ((low + high) / 2, simd_length(high - low) / 2)
    }

    private var chipTargets: [String: simd_float3] = [:]
    private var springVelocity: [String: simd_float3] = [:]
    /// Masses as scripted (a kinematic body reports none).
    private var bodyMass: [String: Double] = [:]
    /// While parts are still arriving the camera follows freely; after this it only widens.
    private var settleUntil: CFTimeInterval = 0
    /// Each labelled part's box and where the part was when it was measured.
    /// Measuring walks the node tree, so it happens at refit rate, not every frame.
    private var labelBoxes: [String: (low: simd_float3, high: simd_float3, origin: simd_float3)] = [:]

    private func labelBox(for id: String, node: SCNNode, refresh: Bool) -> (low: simd_float3, high: simd_float3)? {
        if refresh || labelBoxes[id] == nil {
            guard let (low, high) = tightBounds(of: node) else { return nil }
            labelBoxes[id] = (low, high, currentPosition(of: id, node: node))
            return (low, high)
        }
        guard let cached = labelBoxes[id] else { return nil }
        let isMoving = movingIDs.contains(id) || orbits[id] != nil || node.hasActions || node.physicsBody?.type == .kinematic
        guard isMoving else { return (cached.low, cached.high) }
        let shift = currentPosition(of: id, node: node) - cached.origin
        return (cached.low + shift, cached.high + shift)
    }

    private func currentPosition(of id: String, node: SCNNode) -> simd_float3 {
        movingIDs.contains(id) ? node.presentation.simdWorldPosition : node.simdWorldPosition
    }

    /// The direction from the model to the camera that chips are laid out for: the opening
    /// view while the model sways by itself, the view being moved to when the camera is on a
    /// part, the real view once the person turns it.
    private var layoutDirection: simd_float3 {
        if usesFocusLayout { return simd_float3((cameraMode == .user ? pose : (cameraMove?.to ?? pose)).direction) }
        if userTookCamera || cameraPinned { return simd_float3(pose.direction) }
        return wholeDirection
    }

    /// The opening view of the whole model.
    private var wholeDirection: simd_float3 { cameraDirection(azimuth: baseAzimuth) }

    /// The camera is on some parts: chips are laid out round those parts, for that view.
    private var usesFocusLayout: Bool { !focusIDs.isEmpty && focusBox != nil }

    /// Where on a part its leader line lands, as an offset from the part's position. Found by
    /// hit-testing at refit rate, because the middle of a part's box is often thin air (a
    /// cable's curve, a hollow casing, a row of hangers).
    /// Where each leader lands, in the part's own space, so it stays on the part however the part
    /// moves or turns.
    private var leaderOffsets: [String: simd_float3] = [:]

    /// The axle a part turns on, in world space, when it (or something it hangs from) spins.
    private func spinAxle(of id: String) -> (origin: simd_float3, axis: simd_float3, spinner: String)? {
        for name in lineage(of: id) {
            guard abs(solvedRPM[name] ?? spins[name]?.rpm ?? 0) > 1e-6, let node = nodes[name], let base = baseOrientation[name] else { continue }
            let local: simd_float3
            if let explicit = spins[name]?.axis {
                local = simd_float3(simd_normalize(explicit))
            } else {
                local = base.act(simd_float3(parts[name]?.shape.naturalAxis ?? SceneVec3(0, 1, 0)))
            }
            let axis = (node.parent ?? contentRoot).simdConvertVector(local, to: nil)
            guard simd_length(axis) > 1e-6 else { continue }
            return (node.simdWorldPosition, simd_normalize(axis), name)
        }
        return nil
    }

    /// Where a part's leader lands right now, if it has been worked out.
    private func leaderLanding(_ id: String) -> simd_float3? {
        guard let local = leaderOffsets[id], let node = nodes[id] else { return nil }
        return node.simdConvertPosition(local, to: nil)
    }

    private func leaderAnchor(for id: String, chipEnd: simd_float3, center: simd_float3, halfExtent: simd_float3, refresh: Bool) -> simd_float3 {
        guard let node = nodes[id], !isMovingPart(id) else { return center }
        // A part that turns (a fan, a rotor): the leader lands on its axle, which stays put while
        // the blades go round. Landing on a blade made the line jump every time it was measured again.
        // A piece of something that turns (one blade of a fan) keeps the spot it was given, in its
        // own space, so the line goes round with it frame by frame instead of hopping to another blade.
        let axle = spinAxle(of: id)
        if let axle, axle.spinner == id {
            return axle.origin + axle.axis * simd_dot(center - axle.origin, axle.axis)
        }
        if let landing = leaderLanding(id) { return landing }
        // Aim at the nearest piece of the part, then stop where the line first touches it.
        prepareForHitTesting()
        var aim = center
        var best = Float.greatestFiniteMagnitude
        node.enumerateHierarchy { child, _ in
            guard child.geometry != nil, !(child.name ?? "").hasPrefix("_") else { return }
            var point = child.simdWorldPosition
            if let name = child.name, let part = parts[name], case .tube(let path, _, _) = part.shape, !path.isEmpty {
                point = child.simdConvertPosition(simd_float3(path[path.count / 2]), to: nil)
            } else if let geometry = child.geometry {
                let (low, high) = self.localBounds(of: geometry)
                point = child.simdConvertPosition((simd_float3(low) + simd_float3(high)) / 2, to: nil)
            }
            let distance = simd_length(point - chipEnd)
            if distance < best { best = distance; aim = point }
        }
        var anchor = aim
        let overshoot = aim + (aim - chipEnd) * 0.02
        let hits = contentRoot.hitTestWithSegment(from: SCNVector3(chipEnd), to: SCNVector3(overshoot),
                                                  options: [SCNHitTestOption.rootNode.rawValue: node, SCNHitTestOption.backFaceCulling.rawValue: false,
                                                            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
        if let first = hits.min(by: { simd_length(simd_float3($0.worldCoordinates) - chipEnd) < simd_length(simd_float3($1.worldCoordinates) - chipEnd) }) {
            let surface = simd_float3(first.worldCoordinates)
            // A touch inside the surface, so the line visibly lands on the part.
            anchor = surface + (aim - surface) * 0.12
        }
        leaderOffsets[id] = node.simdConvertPosition(anchor, from: nil)
        return anchor
    }

    private var labelRows = false
    private var labelRowsDecidedFor = ""

    private func isMovingPart(_ id: String) -> Bool {
        movingIDs.contains(id) || orbits[id] != nil || nodes[id]?.physicsBody?.type == .kinematic
    }

    private func updateLabels(refresh: Bool = false) {
        guard !labels.isEmpty else {
            chipExtent = nil
            return
        }
        let focusLayout = usesFocusLayout
        let viewPose = cameraMode == .user ? pose : (cameraMove?.to ?? pose)
        let radius = max(fitRadius, 0.05)
        let toCamera = layoutDirection
        var right = simd_cross(simd_float3(0, 1, 0), toCamera)
        right = simd_length(right) > 1e-5 ? simd_normalize(right) : simd_float3(1, 0, 0)
        let up = simd_cross(toCamera, right)
        let origin = focusLayout ? simd_float3(viewPose.center) : fitCenter
        let tanVertical = tan(Float(Self.fieldOfView) * .pi / 360)
        var chipHeight = radius * 0.115
        if isSimulation {
            // A simulation is framed by the space its bodies move in, which can be much bigger
            // than the bodies; size chips by the picture so they stay readable.
            chipHeight = max(chipHeight, shownDistance * tanVertical * 0.085)
        }
        if focusLayout {
            // Zoomed on a part: chips keep the same size in the picture at every zoom.
            chipHeight = Float(viewPose.distance) * tanVertical * 0.095
        }
        func flat(_ point: simd_float3) -> SceneVec2 { SceneVec2(Double(simd_dot(point - origin, right)), Double(simd_dot(point - origin, up))) }
        func world(_ point: SceneVec2) -> simd_float3 { origin + right * Float(point.x) + up * Float(point.y) }

        // The box chips are laid out round, as the camera sees it: the model's, or the focused parts'.
        var low = SceneVec2(repeating: .greatestFiniteMagnitude), high = SceneVec2(repeating: -.greatestFiniteMagnitude)
        let corners: [simd_float3] = focusLayout ? (focusBox?.corners.map { simd_float3($0) } ?? []) : (0..<8).map { corner in
            simd_float3(corner & 1 == 0 ? boundsLow.x : boundsHigh.x, corner & 2 == 0 ? boundsLow.y : boundsHigh.y, corner & 4 == 0 ? boundsLow.z : boundsHigh.z)
        }
        for corner in corners {
            let point = flat(corner)
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        let lens = self.lens
        if focusLayout {
            // Zoomed in, the model fills the picture: chips go toward the picture's edges, clear of
            // the subject in the middle, not right beside the subject on top of its neighbours.
            let reach = SceneVec2(Double(viewPose.distance) * lens.tanHorizontal * 0.58, Double(viewPose.distance) * lens.tanVertical * 0.50)
            let middle = flat(simd_float3(viewPose.center))
            low = simd_min(low, middle - reach)
            high = simd_max(high, middle + reach)
        }

        struct Entry { var label: LabelChip; var center: simd_float3; var halfExtent: simd_float3; var size: SceneVec2 }
        var fixed: [Entry] = [], riding: [Entry] = []
        var neighbours: [(entry: Entry, offCentre: Double)] = []
        for label in labels.values.sorted(by: { $0.index < $1.index }) {
            let id = label.partID
            // A part that is hidden or ghosted keeps no label; neither does one that is out of the picture.
            var shown = !isEffectivelyHidden(id) && !isEffectivelyGhosted(id) && !suppressedLabels.contains(id)
            guard shown, let node = nodes[id], let (boxLow, boxHigh) = labelBox(for: id, node: node, refresh: refresh) else {
                label.chip.isHidden = true
                label.leader.isHidden = true
                continue
            }
            let aspect = Double((label.chip.geometry as? SCNPlane)?.width ?? 3)
            let entry = Entry(label: label, center: (boxLow + boxHigh) / 2, halfExtent: (boxHigh - boxLow) / 2,
                              size: SceneVec2(aspect * Double(chipHeight), Double(chipHeight)))
            if focusLayout {
                let isFocused = focusIDs.contains { id == $0 || isDescendant(id, of: $0) }
                if !isFocused {
                    // A neighbour keeps its label only while it is well inside the picture.
                    let (ndc, depth) = SceneFraming.project(SceneVec3(entry.center), pose: viewPose, lens: lens)
                    shown = depth > 0 && abs(ndc.x) < 0.62 && abs(ndc.y) < 0.58
                    if shown {
                        neighbours.append((entry, simd_length(ndc)))
                        continue
                    }
                }
            }
            if !shown {
                label.chip.isHidden = true
                label.leader.isHidden = true
                continue
            }
            if isMovingPart(id) { riding.append(entry) } else { fixed.append(entry) }
        }
        // At most a few neighbours, nearest the middle first, so the subject is not crowded.
        let keptNeighbours = neighbours.sorted { $0.offCentre < $1.offCentre }.prefix(max(0, 4 - fixed.count - riding.count))
        for neighbour in neighbours where !keptNeighbours.contains(where: { $0.entry.label.partID == neighbour.entry.label.partID }) {
            neighbour.entry.label.chip.isHidden = true
            neighbour.entry.label.leader.isHidden = true
        }
        for neighbour in keptNeighbours {
            if isMovingPart(neighbour.entry.label.partID) { riding.append(neighbour.entry) } else { fixed.append(neighbour.entry) }
        }
        fixed.sort { $0.label.index < $1.label.index }

        var targets: [String: (position: simd_float3, side: SceneLabelLayout.Side)] = [:]
        let items = fixed.map { entry -> SceneLabelLayout.Item in
            // Order chips by where their leader lands (it can be far from the middle of a long part), so leaders don't cross.
            let landing = leaderLanding(entry.label.partID) ?? entry.center
            return SceneLabelLayout.Item(id: entry.label.partID, anchor: flat(landing), size: entry.size,
                                         side: SceneLabelLayout.Side(script: entry.label.side))
        }
        // Rows or columns is decided when the set of labels changes, not every frame: a spinning
        // part changes the model's box a little all the time, and chips must not hop about.
        let layoutKey = "\(labels.count)|\(fixed.count)|\(focusIDs.joined(separator: ","))"
        if labelRowsDecidedFor != layoutKey {
            labelRowsDecidedFor = layoutKey
            labelRows = SceneLabelLayout.prefersRows(low: low, high: high)
        }
        let margin = focusLayout ? Double(chipHeight) * 0.7 : Double(radius) * 0.14
        let placements = SceneLabelLayout.place(items, low: low, high: high, gap: Double(chipHeight) * 0.3, margin: margin, rows: labelRows)
        // Zoomed in, a chip must stay in the picture (and clear of the title in the top corner).
        let halfWidth = Double(viewPose.distance) * lens.tanHorizontal, halfHeight = Double(viewPose.distance) * lens.tanVertical
        let viewCentre = flat(simd_float3(viewPose.center))
        var spots: [(id: String, spot: SceneVec2, size: SceneVec2, side: SceneLabelLayout.Side)] = []
        for item in items {
            guard let placement = placements[item.id] else { continue }
            var spot = placement.center
            if focusLayout {
                let limitX = max(halfWidth * 0.95 - item.size.x / 2, 0), limitTop = max(halfHeight * (model.title.isEmpty ? 0.93 : 0.72) - item.size.y / 2, 0)
                let limitBottom = max(halfHeight * 0.93 - item.size.y / 2, 0)
                spot.x = min(max(spot.x, viewCentre.x - limitX), viewCentre.x + limitX)
                spot.y = min(max(spot.y, viewCentre.y - limitBottom), viewCentre.y + limitTop)
            }
            spots.append((item.id, spot, item.size, placement.side))
        }
        if focusLayout {
            // Pulling chips into the picture can push two in one row together: slide them apart again.
            let gap = Double(chipHeight) * 0.3
            let limit = halfWidth * 0.95
            for side in [SceneLabelLayout.Side.up, .down] {
                var row = spots.indices.filter { spots[$0].side == side }.sorted { spots[$0].spot.x < spots[$1].spot.x }
                // Chips more than a chip apart in height are different rows.
                while !row.isEmpty {
                    let height = spots[row[0]].spot.y
                    let same = row.filter { abs(spots[$0].spot.y - height) < Double(chipHeight) * 0.9 }
                    row.removeAll { same.contains($0) }
                    for (previous, index) in zip(same, same.dropFirst()) {
                        let needed = spots[previous].spot.x + (spots[previous].size.x + spots[index].size.x) / 2 + gap
                        if spots[index].spot.x < needed { spots[index].spot.x = needed }
                    }
                    if let last = same.last, spots[last].spot.x + spots[last].size.x / 2 > viewCentre.x + limit {
                        spots[last].spot.x = viewCentre.x + limit - spots[last].size.x / 2
                        for (next, index) in zip(same.reversed(), same.reversed().dropFirst()) {
                            let allowed = spots[next].spot.x - (spots[next].size.x + spots[index].size.x) / 2 - gap
                            if spots[index].spot.x > allowed { spots[index].spot.x = allowed }
                        }
                    }
                }
            }
        }
        for entry in spots { targets[entry.id] = (world(entry.spot), entry.side) }
        // A chip on a moving body rides just above it.
        var taken: [(center: SceneVec2, size: SceneVec2)] = spots.map { ($0.spot, $0.size) }
        for entry in riding {
            var spot = flat(entry.center) + SceneVec2(0, Double(entry.halfExtent.y) + Double(focusLayout ? chipHeight : radius * 0.2))
            var attempts = 0
            while attempts < 12, taken.contains(where: { abs($0.center.x - spot.x) < ($0.size.x + entry.size.x) / 2 * 1.04 && abs($0.center.y - spot.y) < Double(chipHeight) * 1.12 }) {
                spot.y += Double(chipHeight) * 1.2
                attempts += 1
            }
            taken.append((spot, entry.size))
            // Keep the chip at the body's own depth so it reads as attached.
            targets[entry.label.partID] = (entry.center + right * Float(spot.x - flat(entry.center).x) + up * Float(spot.y - flat(entry.center).y), .up)
        }

        var extentLow = SceneVec2(repeating: .greatestFiniteMagnitude), extentHigh = SceneVec2(repeating: -.greatestFiniteMagnitude)
        var top = -Float.greatestFiniteMagnitude
        for entry in fixed + riding {
            let id = entry.label.partID
            guard let target = targets[id] else {
                entry.label.chip.isHidden = true
                entry.label.leader.isHidden = true
                continue
            }
            // Ease toward the target so chips glide instead of jumping. A chip that was out of sight starts in place.
            let wasHidden = entry.label.chip.isHidden
            entry.label.chip.isHidden = false
            entry.label.leader.isHidden = false
            let previous = wasHidden ? target.position : (chipTargets[id] ?? target.position)
            let position = isHeadless ? target.position : previous + (target.position - previous) * 0.2
            chipTargets[id] = position
            entry.label.chip.simdPosition = position
            // A chip riding on a body nearer the camera would look bigger than the rest; undo the perspective.
            var chipScale = chipHeight
            if isMovingPart(id) {
                let cameraPosition = cameraNode.simdWorldPosition
                let reference = simd_dot(cameraPosition - origin, toCamera)
                let depth = simd_dot(cameraPosition - position, toCamera)
                if reference > 1e-4, depth > 1e-4 { chipScale *= min(max(depth / reference, 0.4), 2.5) }
            }
            entry.label.chip.simdScale = simd_float3(repeating: chipScale)
            top = max(top, position.y + chipHeight * 0.7)
            let spot = flat(target.position)
            extentLow = simd_min(extentLow, spot - entry.size / 2)
            extentHigh = simd_max(extentHigh, spot + entry.size / 2)

            // The leader runs from just inside the part to the middle of the chip's nearest edge.
            let halfWidth = Float(entry.size.x / 2), halfHeight = chipHeight / 2
            let end: simd_float3
            switch target.side {
            case .up: end = position - up * halfHeight
            case .down: end = position + up * halfHeight
            case .left: end = position + right * halfWidth
            case .right: end = position - right * halfWidth
            }
            let anchor = leaderAnchor(for: id, chipEnd: end, center: entry.center, halfExtent: entry.halfExtent, refresh: refresh)
            let span = simd_length(end - anchor)
            guard span > 1e-4 else { continue }
            let along = (end - anchor) / span
            entry.label.leader.simdPosition = (anchor + end) / 2
            entry.label.leader.simdOrientation = simd_quatf(SceneOrientation.aligning(SceneVec3(0, 1, 0), to: SceneVec3(along)))
            let thickness = chipHeight * 0.039
            entry.label.leader.simdScale = simd_float3(thickness, span, thickness)
        }
        // The whole-model view is fitted round the chips of the whole-model layout only.
        guard !focusLayout else { return }
        if top > -Float.greatestFiniteMagnitude { labelsTop = top }
        chipExtent = extentLow.x <= extentHigh.x ? (extentLow, extentHigh) : nil
    }

    // MARK: Motion

    private func move(_ c: SceneCommand) {
        actionNodeIDs.insert(c.id)
        guard let node = nodes[c.id] else { return }
        let duration = max(c.number("dur", "t", "time") ?? 1.2, 0.01)
        let action: SCNAction
        var back: SCNAction
        if let to = c.vec3("to") {
            let from = node.simdPosition
            action = .move(to: SCNVector3(simd_float3(to)), duration: duration)
            back = .move(to: SCNVector3(from), duration: duration)
        } else if let by = c.vec3("by") {
            action = .move(by: SCNVector3(simd_float3(by)), duration: duration)
            back = action.reversed()
        } else {
            return
        }
        action.timingMode = .easeInEaseOut
        back.timingMode = .easeInEaseOut
        if node.physicsBody?.type == .dynamic { node.physicsBody?.type = .kinematic }
        if c.flag("loop") || c.flag("repeat") {
            let loop = SCNAction.repeatForever(.sequence([action, .wait(duration: 0.25), back, .wait(duration: 0.25)]))
            loop.speed = CGFloat(speed)
            node.runAction(loop, forKey: "move")
        } else {
            action.speed = CGFloat(speed)
            node.runAction(action, forKey: "move")
        }
    }

    private func pulse(_ id: String, times: Int) {
        guard let node = nodes[id] else { return }
        flash(node, times: max(1, min(times, 8)))
    }

    private struct Flash { var materials: [SCNMaterial]; var start: CFTimeInterval; var duration: Double; var times: Int }
    private var flashes: [Flash] = []
    /// What each material's glow was before a flash or a highlight borrowed it.
    private var emissionOriginals: [ObjectIdentifier: (material: SCNMaterial, contents: Any?, intensity: CGFloat)] = [:]

    private func borrowEmission(of node: SCNNode) -> [SCNMaterial] {
        var materials: [SCNMaterial] = []
        node.enumerateHierarchy { child, _ in
            if let name = child.name, name.hasPrefix("_") { return }
            materials += child.geometry?.materials ?? []
        }
        for material in materials where emissionOriginals[ObjectIdentifier(material)] == nil {
            emissionOriginals[ObjectIdentifier(material)] = (material, material.emission.contents, material.emission.intensity)
        }
        return materials
    }

    /// Gives materials their own glow back once no flash or highlight is using them.
    private func returnEmission(of materials: [SCNMaterial]) {
        for material in materials {
            let key = ObjectIdentifier(material)
            let inUse = flashes.contains { $0.materials.contains { $0 === material } } || highlights.values.contains { $0.materials.contains { $0 === material } }
            guard !inUse, let original = emissionOriginals[key] else { continue }
            material.emission.contents = original.contents
            material.emission.intensity = original.intensity
            emissionOriginals[key] = nil
        }
    }

    private func flash(_ node: SCNNode, times: Int) {
        let materials = borrowEmission(of: node)
        let highlighted = highlights.values.flatMap(\.materials)
        for material in materials where !highlighted.contains(where: { $0 === material }) {
            material.emission.contents = NSColor.white
            material.emission.intensity = 0
        }
        flashes.append(Flash(materials: materials, start: now, duration: 0.42 * Double(times), times: times))
    }

    private func updateFlashes(now: CFTimeInterval) {
        // The part being talked about glows softly, breathing about once every second and a half.
        for highlight in highlights.values {
            let wave = 0.5 - 0.5 * cos(min(now - highlight.start, 3) / 1.5 * 2 * Double.pi)
            for material in highlight.materials { material.emission.intensity = CGFloat(0.14 + 0.3 * wave) }
        }
        guard !flashes.isEmpty else { return }
        let highlighted = highlights.values.flatMap(\.materials)
        for flash in flashes {
            let elapsed = now - flash.start
            let wave = elapsed >= flash.duration ? 0 : 0.5 - 0.5 * cos(elapsed / flash.duration * Double(flash.times) * 2 * Double.pi)
            for material in flash.materials where !highlighted.contains(where: { $0 === material }) { material.emission.intensity = CGFloat(wave * 0.55) }
        }
        let finished = flashes.filter { now - $0.start >= $0.duration }
        flashes.removeAll { now - $0.start >= $0.duration }
        for flash in finished { returnEmission(of: flash.materials) }
    }

    /// Pulls the top-level parts (or one group's children) apart along an axis. `dist=0` puts them back.
    ///
    /// The axis is a world direction (it is turned into the space the parts live in, so a
    /// model lying on its side still comes apart the way the script said). With no axis the
    /// parts go the way they are spread; parts sitting on a base (components on a board,
    /// layers on a plate) lift off it instead of half of them being pushed through it.
    private func explode(_ c: SceneCommand) {
        let duration = c.number("dur", "t") ?? 0.9
        func movable(_ node: SCNNode) -> Bool {
            guard let name = node.name, let part = parts[name] else { return false }
            if flows[name] != nil || node.physicsBody != nil { return false }
            if case .text = part.shape { return false }
            return true
        }
        var container: SCNNode = contentRoot
        var targets: [SCNNode]
        if c.hasExplicitID, let group = nodes[c.id], !group.childNodes.isEmpty {
            container = group
            targets = group.childNodes.filter(movable)
        } else {
            targets = contentRoot.childNodes.filter(movable)
            // A scene that is one object (a board with its parts, or one ready-made model): open that object.
            if targets.count == 1, targets[0].childNodes.filter(movable).count >= 2 {
                container = targets[0]
                targets = container.childNodes.filter(movable)
            }
        }
        guard !targets.isEmpty else { return }
        // Undo any earlier explode first, so offsets don't pile up.
        let homes: [simd_float3] = targets.map { node in
            node.simdPosition - (explodedOffsets[node.name ?? ""] ?? .zero)
        }
        var extents: [SceneVec3] = []
        let centers = zip(targets, homes).map { node, home -> SceneVec3 in
            let (low, high) = node.boundingBox
            let local = (simd_float3(low) + simd_float3(high)) / 2
            let size = node.simdOrientation.act((simd_float3(high) - simd_float3(low)) * node.simdScale)
            extents.append(SceneVec3(simd_abs(size)))
            return SceneVec3(home + node.simdOrientation.act(local * node.simdScale))
        }
        // The container's own shape is a base the parts sit on.
        var base: (center: SceneVec3, size: SceneVec3)?
        if container !== contentRoot, let geometry = container.geometry {
            let (low, high) = self.localBounds(of: geometry)
            base = (SceneVec3((simd_float3(low) + simd_float3(high)) / 2), SceneVec3(simd_float3(high) - simd_float3(low)))
        }
        var axis: SceneVec3
        if let worldAxis = c.axis() {
            let local = container.simdConvertVector(simd_float3(worldAxis), from: nil)
            axis = simd_length(local) > 1e-6 ? SceneVec3(simd_normalize(local)) : worldAxis
        } else if let base {
            // Off the base's flat face.
            let thickness = [base.size.x, base.size.y, base.size.z]
            let thin = thickness.firstIndex(of: thickness.min() ?? 0) ?? 1
            axis = [SceneVec3(1, 0, 0), SceneVec3(0, 1, 0), SceneVec3(0, 0, 1)][thin]
        } else {
            axis = SceneGeometry.explodeAxis(positions: centers, extents: extents)
        }
        // `dist` is in world units; the parts may live in a scaled group.
        let worldScale = max(simd_length(container.simdConvertVector(simd_float3(axis), to: nil)), 1e-6)
        let distance = (c.number("dist", "by", "d") ?? Double(fitRadius) * 0.6) / Double(worldScale)
        let offsets: [SceneVec3]
        if let base, abs(simd_dot(axis, simd_normalize(SceneVec3(base.size.x < base.size.y && base.size.x < base.size.z ? 1 : 0,
                                                                  base.size.y <= base.size.x && base.size.y <= base.size.z ? 1 : 0,
                                                                  base.size.z < base.size.x && base.size.z < base.size.y ? 1 : 0)))) > 0.7 {
            offsets = SceneGeometry.explodeOffsets(positions: centers, axis: axis, distance: distance, base: base.center)
        } else {
            offsets = SceneGeometry.explodeOffsets(positions: centers, axis: axis, distance: distance)
        }
        for (index, node) in targets.enumerated() {
            let offset = simd_float3(offsets[index])
            explodedOffsets[node.name ?? ""] = offset
            let action = SCNAction.move(to: SCNVector3(homes[index] + offset), duration: duration)
            action.timingMode = .easeInEaseOut
            if let name = node.name { actionNodeIDs.insert(name) }
            action.speed = CGFloat(speed)
            node.runAction(action, forKey: "explode")
        }
        labelBoxes = [:]
        fitCountdown = duration
        refitUntil = now + duration + 0.3
    }

    /// Models often name the orbit instead of the planet ("orbit earthPath around=sun").
    /// Find the part that was meant: an explicit one, a part the id starts with, or the newest sphere.
    private func orbitTarget(_ c: SceneCommand) -> String? {
        if nodes[c.id] != nil { return c.id }
        if let named = c.string("part", "body", "of", "target"), nodes[named] != nil { return named }
        let lowered = c.id.lowercased()
        if let match = order.filter({ lowered.hasPrefix($0.lowercased()) && orbits[$0] == nil }).max(by: { $0.count < $1.count }) { return match }
        let around = c.string("around", "about", "center")
        return order.last { $0 != around && orbits[$0] == nil && !$0.contains(".") && nodes[$0]?.geometry != nil }
    }

    private func addOrbit(_ original: SceneCommand) {
        guard let targetID = orbitTarget(original) else { return }
        var c = original
        c.id = targetID
        guard let node = nodes[c.id] else { return }
        let around = c.string("around", "about", "center")
        let aroundNode = around.flatMap { nodes[$0] }
        let center = aroundNode == nil ? (c.vec3("around") ?? c.vec3("center") ?? .zero) : .zero
        let start = SceneVec3(node.simdPosition) - (aroundNode.map { SceneVec3($0.simdPosition) } ?? center)
        let radius = c.number("r") ?? max(simd_length(SceneVec3(start.x, 0, start.z)), 0.1)
        let period = max(abs(c.number("period", "t", "dur") ?? 6), 0.05)
        orbits[c.id] = Orbit(around: aroundNode == nil ? nil : around, center: center, radius: radius, period: period,
                             tilt: c.number("tilt") ?? 0, angle: (c.number("phase").map { $0 * Double.pi / 180 }) ?? atan2(start.z, start.x))
        // A faint ring showing the path.
        if !c.flag("nopath") {
            var ring = ScenePart(id: c.id + ".orbit", shape: .torus(ring: radius, pipe: max(radius * 0.004, Double(fitRadius) * 0.002)), color: parts[c.id]?.color ?? .ink)
            ring.opacity = 0.35
            ring.material = .matte
            ring.isTappable = false
            ring.eulerDegrees = SceneVec3(c.number("tilt") ?? 0, 0, 0)
            ring.position = center
            ring.parent = aroundNode == nil ? nil : around
            addNode(for: ring)
            if aroundNode != nil { nodes[ring.id]?.simdScale = simd_float3(repeating: 1) / (aroundNode?.simdScale ?? simd_float3(repeating: 1)) }
        }
    }

    private func moveCamera(_ c: SceneCommand) {
        if commandOrigin == .narration, gesturePause.isPaused(now: now) { return }
        let look = c.vec3("look").map { simd_float3($0) } ?? shownCenter
        var position = c.vec3("to").map { simd_float3($0) } ?? cameraNode.simdPosition
        if let zoom = c.number("zoom"), zoom > 0 {
            position = look + (position - look) / Float(zoom)
        }
        guard simd_length(position - look) > 1e-4 else { return }
        var target = SceneCameraPose(center: SceneVec3(look), direction: SceneVec3(position - look), distance: Double(simd_length(position - look)))
        target.elevation = min(max(target.elevation, -SceneCameraPose.maximumElevation), SceneCameraPose.maximumElevation)
        if c.number("zoom") != nil, c.vec3("to") == nil {
            let limits = zoomLimits
            target.distance = min(max(target.distance, limits.minimumDistance), limits.maximumDistance)
        }
        startMove(to: target, duration: c.number("dur", "t") ?? 1.0, sway: 0, then: .pinned)
        policy.noteMove(now: now, sentence: c.cue)
    }

    // MARK: Simulation

    private func enterSimulation() {
        guard !isSimulation else { return }
        isSimulation = true
        // Simulations are easiest to read nearly face-on and holding still.
        autoRotate = false
        baseAzimuth = 0.22
        baseElevation = 0.14
    }

    private func setGravity(_ c: SceneCommand) {
        let values = c.numbers("g")
        if values.count >= 3 {
            scene.physicsWorld.gravity = SCNVector3(values[0], values[1], values[2])
        } else if let g = values.first {
            scene.physicsWorld.gravity = SCNVector3(0, -abs(g), 0)
        }
    }

    private func addBody(_ c: SceneCommand, dynamic: Bool) {
        if nodes[c.id] == nil { add(builder.build(c)) }
        guard let node = nodes[c.id] else { return }
        let body = SCNPhysicsBody(type: dynamic ? .dynamic : .static, shape: nil)
        if dynamic {
            body.mass = CGFloat(max(c.number("mass", "m") ?? 1, 0.001))
            bodyMass[c.id] = Double(body.mass)
            body.damping = CGFloat(c.number("damping", "drag") ?? 0.005)
            body.angularDamping = 0.05
            if let velocity = c.vec3("vel") ?? c.vec3("v") { body.velocity = SCNVector3(simd_float3(velocity)) }
        }
        body.restitution = CGFloat(c.number("bounce", "restitution") ?? 0.55)
        body.friction = CGFloat(c.number("friction") ?? 0.5)
        body.allowsResting = false
        node.physicsBody = body
        if dynamic { movingIDs.insert(c.id) }
        enterSimulation()
    }

    private func ensureBody(_ id: String, dynamic: Bool) {
        guard let node = nodes[id], node.physicsBody == nil else { return }
        let body = SCNPhysicsBody(type: dynamic ? .dynamic : .static, shape: nil)
        body.damping = 0.005
        body.allowsResting = false
        node.physicsBody = body
        if dynamic { movingIDs.insert(id) }
    }

    private func worldPosition(_ id: String) -> simd_float3 {
        guard let node = nodes[id] else { return .zero }
        return currentPosition(of: id, node: node)
    }

    private func addJoint(_ c: SceneCommand) {
        guard let b = c.string("b") ?? c.string("a"), nodes[b] != nil else { return }
        let a = c.string("b") == nil ? nil : c.string("a").flatMap { nodes[$0] == nil ? nil : $0 }
        if let a { ensureBody(a, dynamic: false) }
        ensureBody(b, dynamic: true)
        let anchorWorld = c.vec3("at").map { simd_float3($0) } ?? a.map { worldPosition($0) } ?? (worldPosition(b) + simd_float3(0, 2, 0))
        let anchorInA = a.flatMap { nodes[$0] }?.simdConvertPosition(anchorWorld, from: nil) ?? anchorWorld
        var joint = Joint(kind: (c.string("type") ?? "ball").lowercased(), a: a, b: b, anchorInA: anchorInA,
                          axis: simd_float3(c.axis() ?? SceneVec3(0, 0, 1)), behavior: nil, rod: nil)
        if !(c.args["rod"].map { ["no", "false", "0", "off"].contains($0.lowercased()) } ?? false), joint.kind != "slider" {
            let cylinder = SCNCylinder(radius: 1, height: 1)
            cylinder.radialSegmentCount = 10
            cylinder.materials = [Scene3DAssets.material(color: c.color() ?? SceneColor.named["darkgray"]!, opacity: 1, kind: .matte)]
            let rod = SCNNode(geometry: cylinder)
            rod.name = "_rod:" + c.id
            contentRoot.addChildNode(rod)
            joint.rod = rod
        }
        joints[c.id] = joint
        connect(c.id)
        if let length = c.number("length", "len") { setJointLength(c.id, length: length) }
        enterSimulation()
        updateRods()
    }

    private func anchorWorld(of joint: Joint) -> simd_float3 {
        if let a = joint.a, let node = nodes[a] { return node.presentation.simdConvertPosition(joint.anchorInA, to: nil) }
        return joint.anchorInA
    }

    /// (Re)creates the physics behaviour for a joint from where its bodies are now.
    private func connect(_ id: String) {
        guard var joint = joints[id], let bNode = nodes[joint.b], let bBody = bNode.physicsBody else { return }
        if let old = joint.behavior { scene.physicsWorld.removeBehavior(old) }
        let anchor = anchorWorld(of: joint)
        let anchorInB = SCNVector3(bNode.simdConvertPosition(anchor, from: nil))
        let axisInB = SCNVector3(bNode.simdConvertVector(joint.axis, from: nil))
        let aBody = joint.a.flatMap { nodes[$0]?.physicsBody }
        let anchorInA = SCNVector3(joint.anchorInA)
        let behavior: SCNPhysicsBehavior
        switch joint.kind {
        case "hinge":
            if let aBody {
                behavior = SCNPhysicsHingeJoint(bodyA: aBody, axisA: SCNVector3(joint.axis), anchorA: anchorInA, bodyB: bBody, axisB: axisInB, anchorB: anchorInB)
            } else {
                behavior = SCNPhysicsHingeJoint(body: bBody, axis: axisInB, anchor: anchorInB)
            }
        case "slider":
            if let aBody {
                behavior = SCNPhysicsSliderJoint(bodyA: aBody, axisA: SCNVector3(joint.axis), anchorA: anchorInA, bodyB: bBody, axisB: axisInB, anchorB: anchorInB)
            } else {
                behavior = SCNPhysicsSliderJoint(body: bBody, axis: axisInB, anchor: anchorInB)
            }
        default:
            if let aBody {
                behavior = SCNPhysicsBallSocketJoint(bodyA: aBody, anchorA: anchorInA, bodyB: bBody, anchorB: anchorInB)
            } else {
                behavior = SCNPhysicsBallSocketJoint(body: bBody, anchor: anchorInB)
            }
        }
        scene.physicsWorld.addBehavior(behavior)
        joint.behavior = behavior
        joints[id] = joint
    }

    /// Moves the hanging body so it sits `length` from the joint's anchor, keeping its direction.
    private func setJointLength(_ id: String, length: Double) {
        guard let joint = joints[id], let bNode = nodes[joint.b], let body = bNode.physicsBody else { return }
        if let old = joint.behavior { scene.physicsWorld.removeBehavior(old) }
        joints[id]?.behavior = nil
        let anchor = anchorWorld(of: joint)
        let current = bNode.presentation.simdWorldPosition
        var direction = current - anchor
        direction = simd_length(direction) > 1e-4 ? simd_normalize(direction) : simd_float3(0, -1, 0)
        let v = measuredVelocity[joint.b] ?? .zero
        bNode.simdTransform = bNode.presentation.simdTransform
        bNode.simdWorldPosition = anchor + direction * Float(max(length, 0.05))
        body.resetTransform()
        // Keep only the swing (tangential) part of the velocity.
        body.velocity = SCNVector3(v - direction * simd_dot(v, direction))
        lastPositions[joint.b] = nil
        connect(id)
    }

    private func updateRods() {
        for joint in joints.values {
            guard let rod = joint.rod, let bNode = nodes[joint.b] else { continue }
            let start = anchorWorld(of: joint)
            let end = currentPosition(of: joint.b, node: bNode)
            let span = simd_length(end - start)
            guard span > 1e-4 else { continue }
            rod.simdPosition = (start + end) / 2
            rod.simdOrientation = simd_quatf(SceneOrientation.aligning(SceneVec3(0, 1, 0), to: SceneVec3((end - start) / span)))
            let thickness = max(fitRadius * 0.008, 0.012)
            rod.simdScale = simd_float3(thickness, span, thickness)
        }
    }

    // MARK: Sliders and plots

    private func addSlider(_ c: SceneCommand) {
        let binding = c.string("bind") ?? c.id
        let minimum = c.number("min") ?? 0
        var maximum = c.number("max") ?? 10
        if maximum <= minimum { maximum = minimum + 1 }
        let value = min(max(c.number("value", "v") ?? currentValue(of: binding) ?? (minimum + maximum) / 2, minimum), maximum)
        let state = Scene3DModel.SliderState(id: c.id, label: c.string("label") ?? c.freeText ?? c.id, minimum: minimum, maximum: maximum, value: value, unit: c.string("unit") ?? "")
        if let index = model.sliders.firstIndex(where: { $0.id == c.id }) {
            model.sliders[index] = state
        } else {
            model.sliders.append(state)
        }
        sliderBindings[c.id] = binding
        applyBinding(binding, value: value)
        model.onLayoutChanged?()
    }

    func setSlider(_ id: String, value: Double, fromUser: Bool) {
        invalidateSpatialLayout()
        requestFrames()
        guard let index = model.sliders.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, model.sliders[index].minimum), model.sliders[index].maximum)
        if model.sliders[index].value != clamped { model.sliders[index].value = clamped }
        if let binding = sliderBindings[id] { applyBinding(binding, value: clamped) }
        if fromUser { onSliderChanged?(id, clamped) }
    }

    private func splitBinding(_ binding: String) -> (target: String, property: String) {
        let lowered = binding.lowercased()
        if ["gravity", "g", "speed", "time", "timescale"].contains(lowered) { return ("", lowered) }
        if let dot = binding.lastIndex(of: "."), nodes[binding] == nil, joints[binding] == nil {
            return (String(binding[..<dot]), String(binding[binding.index(after: dot)...]).lowercased())
        }
        // No property named: pick the obvious one for what the id is.
        if joints[binding] != nil { return (binding, "length") }
        if orbits[binding] != nil { return (binding, "period") }
        if coils[binding] != nil { return (binding, "k") }
        if nodes[binding]?.physicsBody?.type == .dynamic { return (binding, "mass") }
        return (binding, "rpm")
    }

    /// A ready-made pendulum's id names its joint; its mass, bounce and plots belong to the bob.
    private func bodyID(_ id: String) -> String {
        if nodes[id] == nil, let joint = joints[id] { return joint.b }
        return id
    }

    /// Sets every piston of a ready-made engine. False when `id` is not one.
    @discardableResult
    private func setEngineSpeed(_ id: String, rpm: Double) -> Bool {
        let members = pistons.keys.filter { $0.hasPrefix(id + ".") }
        guard pistons[id] == nil, !members.isEmpty else { return false }
        for member in members { pistons[member]?.rpm = rpm }
        for key in spins.keys where key.hasPrefix(id + ".") { spins[key]?.rpm = rpm }
        solvedRPM = [:]
        return true
    }

    private func applyBinding(_ binding: String, value: Double) {
        var (target, property) = splitBinding(binding)
        if ["mass", "m", "bounce", "restitution"].contains(property) { target = bodyID(target) }
        switch property {
        case "gravity", "g":
            scene.physicsWorld.gravity = SCNVector3(0, -abs(value), 0)
        case "speed", "time", "timescale":
            guard value.isFinite else { return }
            speed = max(value, 0)
            if speed > 0 { resumeMotionRate = speed }
            scene.physicsWorld.speed = CGFloat(speed)
            // SceneKit move/loop actions use their own clock; scale them too. Camera and
            // narration keep their wall clock so a paused model can still be inspected.
            for id in actionNodeIDs {
                for key in ["move", "explode"] { nodes[id]?.action(forKey: key)?.speed = CGFloat(speed) }
            }
        case "length", "len", "l":
            if joints[target] != nil { setJointLength(target, length: value) }
        case "mass", "m":
            nodes[target]?.physicsBody?.mass = CGFloat(max(value, 0.001))
            bodyMass[target] = max(value, 0.001)
        case "bounce", "restitution":
            nodes[target]?.physicsBody?.restitution = CGFloat(value)
        case "rpm", "spin":
            if pistons[target] != nil {
                pistons[target]?.rpm = value
            } else if setEngineSpeed(target, rpm: value) {
                break
            } else {
                spins[target] = Spin(axis: spins[target]?.axis, rpm: value)
                solvedRPM = [:]
            }
        case "period":
            orbits[target]?.period = max(abs(value), 0.05)
        case "r", "radius":
            orbits[target]?.radius = value
        case "k", "stiffness":
            coils[target]?.stiffness = max(value, 0)
        case "rest":
            coils[target]?.rest = max(value, 0)
        case "x", "y", "z":
            guard let node = nodes[target] else { return }
            var position = node.simdPosition
            if property == "x" { position.x = Float(value) } else if property == "y" { position.y = Float(value) } else { position.z = Float(value) }
            node.simdPosition = position
            node.physicsBody?.resetTransform()
        case "scale", "size":
            nodes[target]?.simdScale = simd_float3(repeating: Float(max(value, 0.01)))
        case "opacity":
            nodes[target]?.opacity = CGFloat(min(max(value, 0), 1))
        case "flow":
            flows[target]?.speed = value
        default:
            break
        }
    }

    private func currentValue(of binding: String) -> Double? {
        let (target, property) = splitBinding(binding)
        switch property {
        case "gravity", "g": return abs(Double(scene.physicsWorld.gravity.y))
        case "speed", "time", "timescale": return speed
        case "length", "len", "l":
            guard let joint = joints[target] else { return nil }
            return Double(simd_length(worldPosition(joint.b) - anchorWorld(of: joint)))
        case "mass", "m": return bodyMass[target] ?? nodes[target]?.physicsBody.map { Double($0.mass) }
        case "rpm", "spin": return pistons[target]?.rpm ?? spins[target]?.rpm
        case "period": return orbits[target]?.period
        default: return nil
        }
    }

    private func addPlot(_ c: SceneCommand) {
        guard let source = c.string("of") else { return }
        var target = source, property = "y"
        if let dot = source.lastIndex(of: "."), nodes[source] == nil {
            target = String(source[..<dot])
            property = String(source[source.index(after: dot)...]).lowercased()
        }
        if property != "rpm" { target = bodyID(target) }
        plotSources[c.id] = PlotSource(target: target, property: property)
        plotBuffers[c.id] = []
        let unit = ["angle": "°", "rpm": " rpm"][property] ?? ""
        let state = Scene3DModel.PlotState(id: c.id, label: c.string("label") ?? c.freeText ?? source, samples: [], color: c.color() ?? .marker, unit: unit)
        if let index = model.plots.firstIndex(where: { $0.id == c.id }) {
            model.plots[index] = state
        } else {
            model.plots.append(state)
        }
        model.onLayoutChanged?()
    }

    private func sample(_ source: PlotSource) -> Double? {
        guard let node = nodes[source.target] else { return nil }
        let position = node.presentation.simdWorldPosition
        switch source.property {
        case "x": return Double(position.x)
        case "y", "height": return Double(position.y)
        case "z": return Double(position.z)
        case "speed", "v":
            return Double(simd_length(measuredVelocity[source.target] ?? .zero))
        case "angle":
            if let joint = joints.values.first(where: { $0.b == source.target }) {
                return SceneGeometry.pendulumAngle(pivot: SceneVec3(anchorWorld(of: joint)), bob: SceneVec3(position))
            }
            return (spinAngles[source.target] ?? 0) * 180 / Double.pi
        case "rpm":
            return solvedRPM[source.target] ?? spins[source.target]?.rpm
        default:
            return nil
        }
    }

    // MARK: Tapping

    private func handleTap(at point: CGPoint) {
        if let id = partID(at: point) { tapPart(id) }
    }

    /// The part under a point of the view. Ghosted and hidden parts are clicked through.
    private func partID(at point: CGPoint) -> String? {
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        for hit in hits {
            if let name = hit.node.name, !name.hasPrefix("_"), isEffectivelyGhosted(name) || isEffectivelyHidden(name) { continue }
            if let id = tappablePartID(for: hit.node) { return id }
        }
        return nil
    }

    /// A double-click on a part puts the camera on it; on empty space it goes back to the whole model.
    private func handleDoubleTap(at point: CGPoint) {
        gesturePause.touched(now: now)
        if let id = partID(at: point) {
            emitDirector("focus \(id) zoom=medium", origin: .person)
        } else {
            emitDirector("frame all", origin: .person)
        }
    }

    /// Reports a double-click on a part, as if the person had double-clicked it.
    func doubleTapPart(_ id: String) {
        guard nodes[id] != nil else { return }
        gesturePause.touched(now: now)
        emitDirector("focus \(id) zoom=medium", origin: .person)
    }

    private func tappablePartID(for node: SCNNode) -> String? {
        var current: SCNNode? = node
        var fallback: String?
        while let candidate = current {
            if let name = candidate.name {
                if name.hasPrefix("_label:") { return String(name.dropFirst("_label:".count)) }
                if name.hasPrefix("_") { return nil }
                if let part = parts[name] {
                    // An unnamed piece of a ready-made object stands for the object.
                    let isAnonymousPiece = name.contains(".") && part.label == nil && part.name == nil
                    if part.isTappable, !isAnonymousPiece { return name }
                    if fallback == nil, part.name != nil { fallback = name }
                }
            }
            current = candidate.parent
        }
        return fallback
    }

    /// Reports a tap on a part, as if the person had clicked it.
    func tapPart(_ id: String) {
        guard let node = nodes[id], let part = parts[id] else { return }
        flash(node, times: 1)
        model.tappedLabel = part.displayName
        onPartTapped?(id, part.displayName)
    }

    /// Hit-tests the view at the centre of a part, to check the click path end to end.
    func simulateTap(onPart id: String) {
        guard let node = nodes[id] else { return }
        let (center, _) = worldBounds(of: node)
        let projected = view.projectPoint(SCNVector3(center))
        handleTap(at: CGPoint(x: projected.x, y: projected.y))
    }

    /// Where the middle of a part is in the view (the view's own coordinates), for aiming a click at it.
    func viewPoint(ofPart id: String) -> CGPoint? {
        guard let node = nodes[id] else { return nil }
        let (center, _) = worldBounds(of: node)
        let projected = view.projectPoint(SCNVector3(center))
        guard projected.x.isFinite, projected.y.isFinite else { return nil }
        return CGPoint(x: projected.x, y: projected.y)
    }

    /// True once the person has dragged, scrolled or pinched the view: the camera is theirs until
    /// they recenter or the next move they ask for.
    var cameraWasTakenByUser: Bool { userTookCamera }

    // MARK: Per-frame

    private func tick() {
        let time = CACurrentMediaTime()
        let wall = min(time - lastTick, 0.1)
        lastTick = time
        processPendingAuto()
        step(wall: wall)
        let highlightAnimating = highlights.values.contains { time - $0.start < 3 }
        if time >= renderUntil, !hasTransformMotion, cameraMove == nil,
           pendingAuto == nil, flashes.isEmpty, !highlightAnimating {
            pauseRendering()
        }
    }

    /// Headless only: moves motion, simulation and the camera on by `seconds`.
    func advance(by seconds: Double) {
        guard isHeadless, seconds > 0 else { return }
        // Before the clock moves, so a move the engine starts itself begins on the same frame
        // when the recorded scene is played back.
        processPendingAuto()
        manualClock += seconds
        step(wall: seconds)
    }

    /// A new request about the model that is already up: the camera rules start afresh and the
    /// person's lines are obeyed even if they were steering a moment ago.
    func beginRefinement() {
        requestFrames()
        policy.reset()
        gesturePause.resume()
        pendingAuto = nil
        commandOrigin = .person
    }

    private func step(wall: Double) {
        let now = self.now
        let dt = wall * speed
        actionNodeIDs = actionNodeIDs.filter { nodes[$0]?.hasActions == true }
        guard hasContent else {
            updateFlashes(now: now)
            return
        }
        let transformMotion = hasTransformMotion
        if previouslyHadTransformMotion && !transformMotion { invalidateSpatialLayout() }
        previouslyHadTransformMotion = transformMotion
        if transformMotion { hitTestingNeedsFlush = true }

        if dt > 1e-5 {
            for id in movingIDs {
                guard let node = nodes[id] else { continue }
                let position = node.presentation.simdWorldPosition
                if let last = lastPositions[id] { measuredVelocity[id] = (position - last) / Float(dt) }
                lastPositions[id] = position
            }
        }

        // Spins, with gears driven through the train.
        if solvedRPM.isEmpty, !spins.isEmpty {
            solvedRPM = builder.train.solve(drivers: spins.mapValues(\.rpm))
        }
        for (id, rpm) in solvedRPM {
            guard let node = nodes[id], let base = baseOrientation[id] else { continue }
            let angle = (spinAngles[id] ?? 0) + rpm * dt * 2 * Double.pi / 60
            spinAngles[id] = angle
            let axis: simd_float3
            if let explicit = spins[id]?.axis {
                axis = simd_float3(simd_normalize(explicit))
            } else if let part = parts[id] {
                axis = base.act(simd_float3(part.shape.naturalAxis))
            } else {
                axis = simd_float3(0, 1, 0)
            }
            node.simdOrientation = simd_quatf(angle: Float(angle), axis: axis) * base
        }

        for id in Array(flows.keys) {
            guard var flow = flows[id] else { continue }
            if let driver = flow.driver {
                flow.speed = (solvedRPM[driver] ?? spins[driver]?.rpm ?? 0) * 2 * Double.pi / 60 * flow.driveRadius
            }
            flow.phase = SceneGeometry.fraction(flow.phase + flow.speed * dt / flow.length)
            flows[id] = flow
            for (index, markerID) in flow.markers.enumerated() {
                guard let marker = nodes[markerID] else { continue }
                let t = SceneGeometry.fraction(flow.phase + Double(index) / Double(flow.markers.count))
                let placement = SceneGeometry.pointAlong(flow.path, t: t)
                marker.simdPosition = simd_float3(placement.position)
                if let facing = flow.facing {
                    marker.simdOrientation = simd_quatf(SceneOrientation.frame(along: placement.direction, facing: facing))
                } else {
                    marker.simdOrientation = simd_quatf(SceneOrientation.aligning(SceneVec3(0, 1, 0), to: placement.direction))
                }
                let edge = flow.loops ? 1 : min(t, 1 - t) / 0.1
                marker.simdScale = simd_float3(repeating: Float(min(max(edge, 0.01), 1)))
            }
        }

        for id in Array(pistons.keys) {
            let pistonRPM = pistons[id]?.rpm ?? 0
            pistons[id]?.angle += pistonRPM * dt * 2 * Double.pi / 60
            updatePiston(id)
        }

        // Beats: a quick squeeze, then rest (a heart, a pulsing cell).
        for id in Array(beats.keys) {
            guard var beat = beats[id], let node = nodes[id], let part = parts[id] else { continue }
            beat.phase = SceneGeometry.fraction(beat.phase + beat.bpm / 60 * dt)
            beats[id] = beat
            let squeeze = beat.phase < 0.35 ? sin(beat.phase / 0.35 * Double.pi) : 0
            node.simdScale = simd_float3(part.scale * (1 - beat.amount * squeeze))
        }

        for id in Array(orbits.keys) {
            guard var orbit = orbits[id], let node = nodes[id] else { continue }
            orbit.angle += 2 * Double.pi / orbit.period * dt
            orbits[id] = orbit
            let center = orbit.around.flatMap { nodes[$0] }.map { SceneVec3($0.simdPosition) } ?? orbit.center
            node.simdPosition = simd_float3(SceneGeometry.orbitPosition(center: center, radius: orbit.radius, angle: orbit.angle, tiltDegrees: orbit.tilt))
        }

        // Springs: redraw the coil, and pull on the bodies if it has a stiffness.
        for (id, coil) in coils {
            guard let node = nodes[id], let a = nodes[coil.a], let b = nodes[coil.b] else { continue }
            let start = worldPosition(coil.a), end = worldPosition(coil.b)
            // The coil's mesh is rebuilt only when one of its ends has moved.
            let unmoved = coilEnds[id].map { simd_length($0.0 - start) < 1e-5 && simd_length($0.1 - end) < 1e-5 } ?? false
            if !unmoved {
                coilEnds[id] = (start, end)
                let mesh = SceneGeometry.tubeMesh(path: SceneGeometry.springPoints(from: SceneVec3(start), to: SceneVec3(end), coils: coil.coils, radius: coil.radius, samplesPerCoil: 12),
                                                  radius: coil.wire, sides: 6)
                let materials = node.geometry?.materials ?? []
                node.geometry = Scene3DAssets.geometry(from: mesh)
                hasUnpreparedGeometry = true
                hitTestingNeedsFlush = true
                node.geometry?.materials = materials
            }
            if coil.stiffness > 0, dt > 0 {
                // A stiff spring driven through SceneKit's solver gains energy (it sees
                // positions a frame late), so the hanging body is integrated here instead:
                // semi-implicit Euler in small steps, which stays stable and repeatable.
                let mass = Float(max(bodyMass[coil.b] ?? 1, 0.001))
                let gravity = simd_float3(scene.physicsWorld.gravity)
                var position = end
                var velocity = springVelocity[id] ?? .zero
                let steps = 8
                let h = Float(dt) / Float(steps)
                for _ in 0..<steps {
                    let delta = position - start
                    let distance = max(simd_length(delta), 1e-4)
                    let direction = delta / distance
                    let pull = -Float(coil.stiffness) * (distance - Float(coil.rest)) - Float(coil.damping) * simd_dot(velocity, direction)
                    let acceleration = gravity + direction * (pull / mass) + (forces[coil.b] ?? .zero) / mass
                    velocity += acceleration * h
                    position += velocity * h
                }
                springVelocity[id] = velocity
                measuredVelocity[coil.b] = velocity
                b.simdWorldPosition = position
            }
        }
        for (id, force) in forces {
            nodes[id]?.physicsBody?.applyForce(SCNVector3(force * Float(dt)), asImpulse: true)
        }
        updateRods()
        updateFlashes(now: now)

        fitCountdown -= wall
        var refreshed = false
        if spatialLayoutDirty || (fitCountdown <= 0 && (transformMotion || now < refitUntil)) {
            spatialLayoutDirty = false
            // While parts are flying apart the frame follows them closely.
            fitCountdown = now < refitUntil ? 0.05 : 0.25
            refit()
            followFocus()
            refreshed = true
            if transformMotion {
                // Rigid transforms preserve an anchor in the part's local coordinates;
                // moving children and rebuilt spring meshes change the enclosing surface.
                let changingIDs = Set(spins.keys).union(movingIDs).union(actionNodeIDs)
                    .union(beats.keys).union(orbits.keys).union(pistons.keys)
                    .union(flows.values.flatMap(\.markers))
                for id in changingIDs {
                    for ancestor in lineage(of: id) where ancestor != id { leaderOffsets[ancestor] = nil }
                }
                for id in coils.keys {
                    for ancestor in lineage(of: id) { leaderOffsets[ancestor] = nil }
                }
            }
        }
        updateCamera(dt: wall)
        updateLabels(refresh: refreshed)
        publishCameraState()

        plotCountdown -= wall
        if plotCountdown <= 0, !plotSources.isEmpty {
            plotCountdown = 1.0 / 20
            for (id, source) in plotSources {
                guard let value = sample(source), value.isFinite else { continue }
                var buffer = plotBuffers[id] ?? []
                buffer.append(value)
                if buffer.count > 200 { buffer.removeFirst(buffer.count - 200) }
                plotBuffers[id] = buffer
                if let index = model.plots.firstIndex(where: { $0.id == id }) { model.plots[index].samples = buffer }
            }
        }
    }

    private func updatePiston(_ id: String) {
        guard let piston = pistons[id] else { return }
        let height = SceneGeometry.pistonHeight(angle: piston.angle, crank: piston.crank, rod: piston.rod)
        let crankPin = simd_float3(Float(piston.crank * sin(piston.angle)), Float(piston.crank * cos(piston.angle)), 0)
        let wrist = simd_float3(0, Float(height), 0)
        nodes[id + ".head"]?.simdPosition = simd_float3(0, Float(height + piston.headHeight * 0.2), 0)
        if let rod = nodes[id + ".rod"] {
            rod.simdPosition = (crankPin + wrist) / 2
            rod.simdOrientation = simd_quatf(SceneOrientation.aligning(SceneVec3(0, 1, 0), to: SceneVec3(wrist - crankPin)))
        }
        if let pin = nodes[id + ".pin"] {
            pin.simdPosition = crankPin
        }
    }

    // MARK: Camera

    private var contentHalfHeight: Float = 1
    private var refitUntil: CFTimeInterval = 0

    private func refit() {
        guard let (minimum, maximum) = tightBounds(of: contentRoot) else { return }
        guard minimum.x.isFinite, maximum.x.isFinite, simd_length(maximum - minimum) > 1e-5 else { return }
        var center = (minimum + maximum) / 2
        var radius = max(simd_length(maximum - minimum) / 2, 0.05)
        if isSimulation, hasFit, now > settleUntil {
            // Don't breathe with every bounce: only ever widen.
            radius = max(radius, fitRadius)
            center = fitCenter + (center - fitCenter) * 0.05
        }
        fitCenter = center
        fitRadius = radius
        boundsLow = minimum
        boundsHigh = maximum
        contentHalfHeight = (maximum.y - minimum.y) / 2
        if !hasFit {
            hasFit = true
            pose = wholePose
            placeCamera()
        }
        shadowNode.isHidden = isSimulation
        shadowNode.simdPosition = simd_float3(center.x, minimum.y - radius * 0.04, center.z)
        let footprint = max(maximum.x - minimum.x, maximum.z - minimum.z, radius) * 1.35
        shadowNode.simdScale = simd_float3(footprint, footprint, 1)
    }

    private var boundsLow = simd_float3(-1, -1, -1)
    private var boundsHigh = simd_float3(1, 1, 1)

    /// The direction from the model to the camera for the whole-model view turned to `azimuth`.
    private func cameraDirection(azimuth: Double) -> simd_float3 {
        simd_float3(SceneCameraPose.direction(azimuth: azimuth, elevation: baseElevation))
    }

    /// Where the camera looks: the middle of the model and its label chips together.
    private var lookCenter: simd_float3 {
        if isSimulation { return fitCenter + simd_float3(0, labels.isEmpty ? 0 : labelHeadroom / 2, 0) }
        guard let frame = framedBox else { return fitCenter }
        let toCamera = wholeDirection
        var right = simd_cross(simd_float3(0, 1, 0), toCamera)
        right = simd_length(right) > 1e-5 ? simd_normalize(right) : simd_float3(1, 0, 0)
        let up = simd_cross(toCamera, right)
        let middle = (frame.low + frame.high) / 2
        return fitCenter + right * Float(middle.x) + up * Float(middle.y)
    }

    /// The model's box joined with the chips' box, in the camera plane, relative to the model's middle.
    private var framedBox: (low: SceneVec2, high: SceneVec2)? {
        guard let chips = chipExtent, !labels.isEmpty else { return nil }
        let toCamera = wholeDirection
        var right = simd_cross(simd_float3(0, 1, 0), toCamera)
        right = simd_length(right) > 1e-5 ? simd_normalize(right) : simd_float3(1, 0, 0)
        let up = simd_cross(toCamera, right)
        var low = chips.low, high = chips.high
        for corner in 0..<8 {
            let point = simd_float3(corner & 1 == 0 ? boundsLow.x : boundsHigh.x, corner & 2 == 0 ? boundsLow.y : boundsHigh.y, corner & 4 == 0 ? boundsLow.z : boundsHigh.z) - fitCenter
            let flat = SceneVec2(Double(simd_dot(point, right)), Double(simd_dot(point, up)))
            low = simd_min(low, flat)
            high = simd_max(high, flat)
        }
        // Room for the title pill in the top-left corner of the view.
        if !model.title.isEmpty { high.y += (high.y - low.y) * 0.13 }
        return (low, high)
    }

    /// How far chips riding on moving bodies rise above the model (simulations only).
    private var labelHeadroom: Float {
        guard !labels.isEmpty else { return 0 }
        return min(max(labelsTop - boundsHigh.y, fitRadius * 0.3), fitRadius * 1.4)
    }
    private var labelsTop: Float = 0

    /// The size of the picture: the view's, or the frame being rendered when headless.
    var viewportSize: CGSize? {
        didSet {
            guard viewportSize != oldValue else { return }
            invalidateSpatialLayout()
            requestFrames()
        }
    }
    private var viewportAspect: Float {
        let size = viewportSize ?? view.bounds.size
        return Float(max(size.width, 1) / max(size.height, 1))
    }

    /// The distance at which the model's box and its chips just fill the view,
    /// taken as the worst case across the sway so the zoom doesn't breathe.
    private var targetDistance: Float {
        let halfVertical = Float(Self.fieldOfView) * .pi / 360
        let aspect = viewportAspect
        let tanVertical = tan(halfVertical), tanHorizontal = tan(halfVertical) * aspect
        let center = lookCenter
        if isSimulation {
            // Bodies move: fit the sphere instead of the box.
            return (fitRadius + labelHeadroom * 0.5) / sin(min(halfVertical, atan(tanHorizontal))) * 1.05
        }
        var needed: Float = 0.1
        // Keep the established opening frame even when idle sway is disabled.
        // Narration uses this envelope to decide whether a part deserves a closer view.
        let angles = [baseAzimuth - Self.wholeSway, baseAzimuth, baseAzimuth + Self.wholeSway]
        for angle in angles {
            let toCamera = cameraDirection(azimuth: angle)
            let right = simd_normalize(simd_cross(simd_float3(0, 1, 0), toCamera))
            let up = simd_cross(toCamera, right)
            for corner in 0..<8 {
                let point = simd_float3(corner & 1 == 0 ? boundsLow.x : boundsHigh.x, corner & 2 == 0 ? boundsLow.y : boundsHigh.y, corner & 4 == 0 ? boundsLow.z : boundsHigh.z) - center
                let depth = simd_dot(point, toCamera)
                needed = max(needed, abs(simd_dot(point, right)) / tanHorizontal + depth, abs(simd_dot(point, up)) / tanVertical + depth)
            }
        }
        // Chips sit in the plane through the model's middle, facing the opening view.
        if let chips = chipExtent, let frame = framedBox {
            let middle = (frame.low + frame.high) / 2
            let halfWidth = Float(max(chips.high.x - middle.x, middle.x - chips.low.x))
            let halfHeight = Float(max(max(chips.high.y, frame.high.y) - middle.y, middle.y - chips.low.y))
            needed = max(needed, halfWidth / tanHorizontal * 1.04, halfHeight / tanVertical * 1.04)
        }
        return needed * 1.1
    }

    private var lens: SceneLens { SceneLens(fieldOfView: Double(Self.fieldOfView), aspect: Double(viewportAspect)) }

    /// The whole model, framed from the opening view.
    private var wholePose: SceneCameraPose {
        SceneCameraPose(center: SceneVec3(lookCenter), azimuth: baseAzimuth, elevation: baseElevation, distance: Double(targetDistance))
    }

    /// The turn the camera is drawn at: the pose's, plus the gentle sway.
    private var displayedAzimuth: Double { pose.azimuth + (autoRotate ? swayAmount * sin(swayPhase) : 0) }

    /// The view as drawn right now.
    var displayedPose: SceneCameraPose {
        SceneCameraPose(center: pose.center, azimuth: displayedAzimuth, elevation: pose.elevation, distance: pose.distance)
    }

    /// True while the camera is easing somewhere.
    var isCameraMoving: Bool { cameraMove != nil }

    private func updateCamera(dt: Double) {
        // A slow sway either side of the view, so the model never looks frozen. It stops while the person holds the camera.
        if autoRotate, cameraMode != .user, cameraMode != .pinned { swayPhase += dt * 0.42 }
        if let move = cameraMove {
            let progress = move.duration <= 1e-6 ? 1 : (now - move.start) / move.duration
            let eased = SceneEasing.easeInOut(progress)
            // Going back to the whole model follows it if it is still being built.
            let target = move.then == .whole ? wholePose : move.to
            var next = SceneCameraPose.interpolate(move.from, target, eased)
            next.azimuth = move.from.azimuth + (SceneCameraPose.shortestTurn(from: move.from.azimuth, to: target.azimuth) + move.turn) * eased
            pose = next
            swayAmount = move.toSway * eased
            if progress >= 1 {
                cameraMove = nil
                cameraMode = move.then
                if move.then == .whole { baseAzimuth = pose.azimuth }
            }
        } else if cameraMode == .whole {
            let target = wholePose
            let blend = min(dt * 4, 1)
            pose.center += (target.center - pose.center) * blend
            pose.distance += (target.distance - pose.distance) * blend
            pose.azimuth = target.azimuth
            pose.elevation = target.elevation
            swayAmount = Self.wholeSway
        }
        placeCamera()
    }

    private func placeCamera() {
        // The camera's frame is set outright: right, up, and back along the line of sight.
        // (`look(at:)` turns the node the shortest way from wherever it was, which lets the
        // horizon tilt a little more with every move.)
        let shown = displayedPose
        let direction = shown.direction
        let (right, up) = SceneCameraPose.basis(direction: direction)
        cameraNode.simdTransform = simd_float4x4(columns: (simd_float4(simd_float3(right), 0), simd_float4(simd_float3(up), 0),
                                                           simd_float4(simd_float3(direction), 0), simd_float4(simd_float3(shown.position), 1)))
    }

    /// Eases the camera to `target` (ease in, ease out). The sway is folded into the start so nothing jumps.
    private func startMove(to target: SceneCameraPose, duration: Double, sway: Double, then: CameraMode, turn: Double = 0) {
        requestFrames(for: max(duration, 0) + 2)
        var from = pose
        from.azimuth = displayedAzimuth
        pose = from
        swayAmount = 0
        cameraMove = CameraMove(from: from, to: target, start: now, duration: max(duration, 0), toSway: sway, turn: turn, then: then)
        if duration <= 1e-6 { updateCamera(dt: 0) }
        publishCameraState()
    }

    /// Long enough to feel calm, short enough not to drag: longer for a bigger change of view.
    private func moveDuration(to target: SceneCameraPose) -> Double {
        0.85 + 0.6 * min(displayedPose.difference(from: target, scale: Double(max(fitRadius, 0.05))), 1.6)
    }

    private func publishCameraState() {
        let away = (cameraMove?.then ?? cameraMode) != .whole
        if model.canRecenter != away { model.canRecenter = away }
    }

    /// Sets the turntable angle (radians) and stops auto-rotation; used for repeatable snapshots of the whole model.
    func freezeCamera(azimuth: Double? = nil, elevation: Double? = nil) {
        invalidateSpatialLayout()
        requestFrames()
        if let azimuth { baseAzimuth = azimuth }
        if let elevation { baseElevation = elevation }
        autoRotate = false
        cameraMove = nil
        cameraMode = .whole
        refit()
        pose = wholePose
        placeCamera()
        updateLabels()
        publishCameraState()
    }

    // MARK: Parts by id

    /// The parts a line names, forgiving how a model writes them: the exact id, a different case,
    /// the last piece of a dotted id (`turbine` for `j.turbine`), a label's own id, or the label's words.
    private func resolve(_ ids: [String]) -> [String] {
        var result: [String] = []
        for raw in ids {
            var found: String?
            let lowered = raw.lowercased()
            if nodes[raw] != nil {
                found = raw
            } else if let target = labelIDs[raw], nodes[target] != nil {
                found = target
            } else if let exact = order.first(where: { nodes[$0] != nil && $0.lowercased() == lowered }) {
                found = exact
            } else if let piece = order.filter({ nodes[$0] != nil && $0.lowercased().hasSuffix("." + lowered) }).min(by: { $0.count < $1.count }) {
                found = piece
            } else if let named = order.first(where: { nodes[$0] != nil && (labelTexts[$0] ?? parts[$0]?.label ?? parts[$0]?.name)?.lowercased() == lowered }) {
                found = named
            } else {
                found = SceneSubjectMatcher.match(sentence: raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " "), parts: subjectCandidates, limit: 1).first
            }
            if let found, !result.contains(found) { result.append(found) }
        }
        return result
    }

    /// The parts a sentence or a request could be about: everything with a label or a name, and every top-level part.
    var subjectCandidates: [SceneSubjectCandidate] {
        order.compactMap { id in
            guard nodes[id] != nil, !id.hasPrefix("_"), !id.hasSuffix("._bulk"), let part = parts[id] else { return nil }
            if case .text = part.shape { return nil }
            let label = labelTexts[id] ?? part.label
            if label == nil, flows[id] != nil || flows[part.parent ?? ""] != nil { return nil }
            guard label != nil || part.name != nil || !id.contains(".") else { return nil }
            return SceneSubjectCandidate(id: id, label: label, name: part.name)
        }
    }

    private func isDescendant(_ id: String, of ancestor: String) -> Bool {
        guard let top = nodes[ancestor] else { return false }
        var current = nodes[id]?.parent
        while let node = current {
            if node === top { return true }
            current = node.parent
        }
        return false
    }

    /// The part and the parts it hangs from, nearest first.
    private func lineage(of id: String) -> [String] {
        var result: [String] = []
        var current = nodes[id]
        while let node = current {
            if let name = node.name, parts[name] != nil { result.append(name) }
            current = node.parent
        }
        return result.isEmpty ? [id] : result
    }

    private func isEffectivelyHidden(_ id: String) -> Bool {
        if hiddenIDs.isEmpty { return false }
        return lineage(of: id).contains(where: hiddenIDs.contains)
    }

    private func isEffectivelyGhosted(_ id: String) -> Bool {
        if ghosts.isEmpty { return false }
        if lineage(of: id).contains(where: { ghosts[$0] != nil }) { return true }
        // A group is ghosted when every solid piece of it is (`ghost others` ghosts piece by piece).
        guard let node = nodes[id], node.geometry == nil else { return false }
        var pieces = 0, ghosted = 0
        node.enumerateHierarchy { child, _ in
            guard child.geometry != nil, let name = child.name, parts[name] != nil else { return }
            pieces += 1
            if ghosts[name] != nil { ghosted += 1 }
        }
        return pieces > 0 && ghosted == pieces
    }

    /// How see-through a part is drawn, 0…1, counting what it hangs from.
    private func effectiveOpacity(_ id: String) -> Double {
        var opacity = 1.0
        for name in lineage(of: id) {
            if hiddenIDs.contains(name) { return 0 }
            opacity *= min(parts[name]?.opacity ?? 1, ghosts[name]?.opacity ?? 1)
        }
        return opacity
    }

    private func bounds(ofParts ids: [String]) -> SceneBox? {
        var box: SceneBox?
        for id in ids {
            guard let node = nodes[id], let (low, high) = tightBounds(of: node) else { continue }
            let own = SceneBox(low: SceneVec3(low), high: SceneVec3(high))
            box = box.map { $0.union(own) } ?? own
        }
        return box
    }

    private var modelBox: SceneBox { SceneBox(low: SceneVec3(boundsLow), high: SceneVec3(boundsHigh)) }

    /// Parts with a shape of their own (not groups, not floating text).
    private var solidPartIDs: [String] {
        order.filter { id in
            guard let node = nodes[id], node.geometry != nil, let part = parts[id] else { return false }
            if case .text = part.shape { return false }
            return true
        } + nodes.keys.filter { $0.hasSuffix("._bulk") }.sorted()
    }

    // MARK: Looking at a part

    /// The part a geometry node belongs to.
    private func partID(owning node: SCNNode) -> String? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name {
                if name.hasPrefix("_") { return nil }
                if parts[name] != nil { return name }
            }
            current = candidate.parent
        }
        return nil
    }

    private var hitTestRenderer: SCNRenderer?
    private var hasUnpreparedGeometry = true

    /// SceneKit only answers "what does this line hit" for geometry it has prepared for drawing.
    /// A part that was just added (or a scene that is built off screen and never drawn) is prepared here first.
    private func prepareForHitTesting() {
        // What was moved this turn of the run loop is hit where it is now, not where it was last drawn.
        if hitTestingNeedsFlush {
            SCNTransaction.flush()
            hitTestFlushCount += 1
            hitTestingNeedsFlush = false
        }
        guard hasUnpreparedGeometry else { return }
        hasUnpreparedGeometry = false
        let renderer: SCNRenderer
        if let existing = offscreenRenderer ?? hitTestRenderer {
            renderer = existing
        } else {
            renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = scene
            hitTestRenderer = renderer
        }
        _ = renderer.prepare(contentRoot, shouldAbortBlock: nil)
    }

    /// How much of `box` is hidden from `eye` (0 clear … 1 hidden) by parts other than `targets`,
    /// and which parts do the hiding. Asks SceneKit what a few lines of sight really hit, so hollow
    /// shells and cutaways count for what they are.
    private func sightBlockage(from eye: SceneVec3, to box: SceneBox, targets: [String], direction: SceneVec3) -> (amount: Double, blockers: [String]) {
        let (right, up) = SceneCameraPose.basis(direction: direction)
        let size = box.size
        let across = (abs(right.x) * size.x + abs(right.y) * size.y + abs(right.z) * size.z) * 0.2
        let along = (abs(up.x) * size.x + abs(up.y) * size.y + abs(up.z) * size.z) * 0.2
        var samples = [box.center, box.center + right * across, box.center - right * across, box.center + up * along, box.center - up * along]
        let targetNodes = targets.compactMap { nodes[$0] }
        // The middle of a part's box is often thin air (a curved pipe, a ring of blades), so a few
        // points that are on the part itself are looked at as well.
        var anchors: [SceneVec3] = []
        for node in targetNodes {
            node.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry, let name = child.name, !name.hasPrefix("_"), let part = parts[name] else { return }
                if case .text = part.shape { return }
                if case .tube(let path, _, _) = part.shape, !path.isEmpty {
                    anchors.append(SceneVec3(child.simdConvertPosition(simd_float3(path[path.count / 2]), to: nil)))
                } else {
                    let (low, high) = bulkBoxes[name].map { (SCNVector3($0.low), SCNVector3($0.high)) } ?? localBounds(of: geometry)
                    anchors.append(SceneVec3(child.simdConvertPosition((simd_float3(low) + simd_float3(high)) / 2, to: nil)))
                }
            }
        }
        if anchors.count > 5 {
            let stride = Double(anchors.count - 1) / 4
            anchors = (0..<5).map { anchors[Int((Double($0) * stride).rounded())] }
        }
        samples += anchors
        func isTarget(_ node: SCNNode) -> Bool {
            var current: SCNNode? = node
            while let candidate = current {
                if targetNodes.contains(where: { $0 === candidate }) { return true }
                current = candidate.parent
            }
            return false
        }
        var total = 0.0
        var counted = 0
        var weights: [String: Double] = [:]
        let start = simd_float3(eye)
        let reach = Float(box.radius) * 0.6
        prepareForHitTesting()
        for sample in samples {
            // The line of sight runs on a little past the point, to where it meets the part.
            let toward = simd_float3(sample) - start
            let length = simd_length(toward)
            guard length > 1e-6 else { continue }
            let end = simd_float3(sample) + toward / length * reach
            let hits = contentRoot.hitTestWithSegment(from: SCNVector3(start), to: SCNVector3(end),
                                                      options: [SCNHitTestOption.backFaceCulling.rawValue: false,
                                                                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
                .sorted { simd_length(simd_float3($0.worldCoordinates) - start) < simd_length(simd_float3($1.worldCoordinates) - start) }
            var blocked = 0.0
            var seen: Set<String> = []
            var inFront: [(id: String, weight: Double)] = []
            var reachedSubject = false
            for hit in hits {
                // What is behind the subject's own front surface is not in front of it.
                if isTarget(hit.node) {
                    reachedSubject = true
                    break
                }
                guard let id = partID(owning: hit.node), seen.insert(id).inserted, let part = parts[id] else { continue }
                if case .text = part.shape { continue }
                if flows[part.parent ?? ""] != nil { continue }
                let opacity = effectiveOpacity(id)
                let weight = opacity >= 0.85 ? 1 : opacity * 0.5
                blocked += weight
                inFront.append((id, weight))
            }
            // A line that never meets the subject says nothing about whether the subject can be seen.
            guard reachedSubject else { continue }
            counted += 1
            for entry in inFront where entry.weight >= 0.3 { weights[entry.id, default: 0] += entry.weight }
            total += min(blocked, 1)
        }
        guard counted > 0 else { return (0, []) }
        // Worth ghosting: what stands in front of a good half of the subject, not a blade that crosses one line of sight.
        let main = weights.filter { $0.value >= Double(counted) * 0.5 }
        return (total / Double(counted), main.keys.sorted { (main[$0] ?? 0) > (main[$1] ?? 0) })
    }

    /// The view that shows `box` best: the usual 3/4 view unless something stands in front of the
    /// subject, in which case the clearest of a handful of other sides. `blockers` are the parts
    /// still in the way from there (worth ghosting), when the subject is mostly hidden from everywhere.
    private func bestView(of box: SceneBox, targets: [String], fill: Double) -> (pose: SceneCameraPose, blockers: [String]) {
        let lens = self.lens
        let candidates = SceneFraming.candidateDirections(azimuth: baseAzimuth, elevation: baseElevation)
        var poses: [SceneCameraPose] = [], blocked: [Double] = [], found: [[String]] = [], edgeOn: [Double] = []
        for candidate in candidates {
            let direction = SceneCameraPose.direction(azimuth: candidate.azimuth, elevation: candidate.elevation)
            let view = SceneFraming.pose(framing: box, direction: direction, lens: lens, fill: fill)
            let sight = sightBlockage(from: view.position, to: box, targets: targets, direction: direction)
            poses.append(view)
            blocked.append(sight.amount)
            found.append(sight.blockers)
            // A part toward one end of the model is looked at from its own end (a fan from the intake,
            // a nozzle from behind), not from across the model: its front is the side facing outward.
            edgeOn.append(SceneFraming.edgeOnPenalty(for: box, direction: direction)
                + SceneFraming.facingPenalty(direction: direction, part: box.center, model: modelBox))
            if poses.count == 1, sight.amount < 0.05, edgeOn[0] < 0.05 { break }
        }
        var index = SceneFraming.chooseDirection(blocked: blocked, extra: edgeOn)
        // The view sways a little either side of where it rests. A side that is only clear dead on
        // (the edge of a wall just out of the way) is not clear: look again from both ends of the sway.
        for _ in 0..<3 where blocked[index] <= 0.45 && candidates.count == poses.count {
            var worst = blocked[index]
            for offset in [-Self.focusSway, Self.focusSway] {
                let direction = SceneCameraPose.direction(azimuth: candidates[index].azimuth + offset, elevation: candidates[index].elevation)
                let view = SceneCameraPose(center: poses[index].center, direction: direction, distance: poses[index].distance)
                worst = max(worst, sightBlockage(from: view.position, to: box, targets: targets, direction: direction).amount)
            }
            guard worst > 0.45 else { break }
            blocked[index] = worst
            index = SceneFraming.chooseDirection(blocked: blocked, extra: edgeOn)
        }
        if ProcessInfo.processInfo.environment["TEACHY_SCENE_DEBUG"] != nil {
            print("🎥 view of \(targets): blocked \(blocked.map { String(format: "%.2f", $0) }) → candidate \(index)")
        }
        return (poses[index], blocked[index] > 0.4 ? found[index] : [])
    }

    /// Who a line is treated as coming from. Lines the engine wrote for the narration are held back while the person steers.
    private func origin(of c: SceneCommand) -> CommandOrigin {
        if commandOrigin == .replay { return .replay }
        return c.flag("auto") ? .narration : commandOrigin
    }

    /// `focus id[,id] zoom=tight|medium|wide dur=`: ease the camera onto those parts.
    private func focus(_ c: SceneCommand) {
        guard directsCamera else { return }
        let ids = resolve(c.targetIDs).filter { !isEffectivelyHidden($0) }
        guard !ids.isEmpty, let box = bounds(ofParts: ids) else { return }
        if origin(of: c) == .narration, gesturePause.isPaused(now: now) { return }
        let zoomWord = c.string("zoom") ?? c.words.first(where: { !$0.quoted && ["tight", "medium", "wide", "close", "far"].contains($0.text.lowercased()) })?.text
        let zoom = SceneZoom(script: zoomWord)
        clearHighlights()
        restoreAutoGhosts()
        var (target, blockers) = bestView(of: box, targets: ids, fill: zoom.fill)
        // A focus never stands further back than the view of the whole model.
        target.distance = min(target.distance, Double(targetDistance))
        // Something the subject sits inside is in the way from every side: make it see-through.
        if !c.flag("solid") {
            for id in blockers where ghosts[id] == nil { setGhost(id, opacity: 0.14, auto: true) }
        }
        focusIDs = ids
        focusBox = box
        labelRowsDecidedFor = ""
        let duration = c.number("dur", "t").map { min(max($0, 0), 10) } ?? moveDuration(to: target)
        startMove(to: target, duration: duration, sway: Self.focusSway, then: .focus)
        policy.noteMove(now: now, sentence: c.cue)
        if c.flag("auto") {
            for id in ids { if let node = nodes[id] { flash(node, times: 2) } }
        }
    }

    /// The camera is resting on parts that have since moved (an exploded view, a part on a crank):
    /// it follows, but only when they have moved a fair way, so a spinning fan does not make it fidget.
    private func followFocus() {
        guard cameraMode == .focus, cameraMove == nil, !focusIDs.isEmpty, let old = focusBox, let box = bounds(ofParts: focusIDs) else { return }
        let shift = simd_length(box.center - old.center), growth = abs(box.radius - old.radius)
        guard shift > old.radius * 0.3 || growth > old.radius * 0.3 else { return }
        if gesturePause.isPaused(now: now) { return }
        focusBox = box
        let fill = SceneProjectionFill.current(old, pose: pose, lens: lens)
        var target = SceneFraming.pose(framing: box, direction: pose.direction, lens: lens, fill: fill)
        target.azimuth = pose.azimuth
        target.elevation = pose.elevation
        startMove(to: target, duration: 0.9, sway: Self.focusSway, then: .focus)
    }

    /// `frame all`: back to the whole model. `frame id…` is a wide focus.
    private func frame(_ c: SceneCommand) {
        guard directsCamera else { return }
        if !c.names("all"), !resolve(c.targetIDs).isEmpty {
            var wide = c
            if wide.args["zoom"] == nil { wide.args["zoom"] = "wide" }
            focus(wide)
            return
        }
        if origin(of: c) == .narration, gesturePause.isPaused(now: now) { return }
        clearHighlights()
        restoreAutoGhosts()
        // The finer pieces stay; their names go, so the whole model is not crowded with them.
        for labels in detailLabels.values { suppressedLabels.formUnion(labels) }
        focusIDs = []
        focusBox = nil
        labelRowsDecidedFor = ""
        guard cameraMode != .whole || cameraMove != nil else { return }
        let target = wholePose
        let duration = c.number("dur", "t").map { min(max($0, 0), 10) } ?? moveDuration(to: target)
        startMove(to: target, duration: duration, sway: autoRotate ? Self.wholeSway : 0, then: .whole)
        policy.noteMove(now: now, sentence: c.cue)
    }

    /// `orbit id deg=120 dur=4`: a slow arc round a part (no id, or `all`: round the whole model).
    private func orbitCamera(_ c: SceneCommand) {
        guard directsCamera else { return }
        if origin(of: c) == .narration, gesturePause.isPaused(now: now) { return }
        let degrees = c.number("deg", "degrees", "angle") ?? 120
        let turn = min(max(degrees, -720), 720) * Double.pi / 180
        let duration = c.number("dur", "t").map { min(max($0, 0), 20) } ?? max(3, abs(degrees) / 40)
        let ids = c.names("all") ? [] : resolve(c.targetIDs).filter { !isEffectivelyHidden($0) }
        if !ids.isEmpty, let box = bounds(ofParts: ids) {
            var target = cameraMove?.to ?? pose
            if focusIDs != ids {
                clearHighlights()
                restoreAutoGhosts()
                let view = bestView(of: box, targets: ids, fill: SceneZoom.medium.fill)
                target = view.pose
                for id in view.blockers where ghosts[id] == nil { setGhost(id, opacity: 0.14, auto: true) }
                focusIDs = ids
                focusBox = box
                labelRowsDecidedFor = ""
            }
            startMove(to: target, duration: duration, sway: 0, then: .focus, turn: turn)
        } else if !focusIDs.isEmpty, !c.names("all") {
            startMove(to: cameraMove?.to ?? pose, duration: duration, sway: 0, then: .focus, turn: turn)
        } else {
            focusIDs = []
            focusBox = nil
            labelRowsDecidedFor = ""
            startMove(to: wholePose, duration: duration, sway: autoRotate ? Self.wholeSway : 0, then: .whole, turn: turn)
        }
        policy.noteMove(now: now, sentence: c.cue)
    }

    // MARK: Ghosting, hiding, highlighting

    private func fade(_ node: SCNNode, to opacity: Double) {
        if isHeadless {
            node.opacity = CGFloat(opacity)
        } else {
            node.removeAction(forKey: "fade")
            node.runAction(.fadeOpacity(to: CGFloat(opacity), duration: 0.35), forKey: "fade")
        }
    }

    /// A see-through part must not hide what is inside it, so it stops writing depth and is drawn after solid parts.
    private func setSolid(_ root: SCNNode, _ solid: Bool) {
        root.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry, let name = child.name, !name.hasPrefix("_") else { return }
            let opaque = (parts[name]?.opacity ?? 1) >= 0.999
            for material in geometry.materials { material.writesToDepthBuffer = solid && opaque }
            child.renderingOrder = solid && opaque ? 0 : 10
        }
    }

    /// Makes a part see-through (`opacity` nil: solid again). A ghost the script asked for is not undone by an automatic one.
    private func setGhost(_ id: String, opacity: Double?, auto: Bool) {
        guard let node = nodes[id] else { return }
        let base = parts[id]?.opacity ?? 1
        if let opacity {
            if let existing = ghosts[id], !existing.auto, auto { return }
            ghosts[id] = Ghost(opacity: opacity, auto: auto)
            fade(node, to: hiddenIDs.contains(id) ? 0 : min(base, opacity))
            setSolid(node, false)
        } else {
            guard ghosts[id] != nil else { return }
            ghosts[id] = nil
            fade(node, to: hiddenIDs.contains(id) ? 0 : base)
            setSolid(node, true)
        }
        labelRowsDecidedFor = ""
    }

    private func restoreAutoGhosts() {
        for (id, ghost) in ghosts where ghost.auto { setGhost(id, opacity: nil, auto: true) }
    }

    /// `ghost id id… opacity=0.15`, `ghost others` (everything but the focused parts), `ghost none`.
    private func ghost(_ c: SceneCommand) {
        guard directsCamera else { return }
        if c.names("none") {
            for id in Array(ghosts.keys) { setGhost(id, opacity: nil, auto: false) }
            return
        }
        let opacity = min(max(c.number("opacity", "alpha", "to") ?? 0.14, 0.03), 1)
        var ids = resolve(c.targetIDs)
        if c.names("others") || c.names("other") || c.names("rest") || c.names("all") {
            let keep = ids.isEmpty ? focusIDs : ids
            ids = solidPartIDs.filter { id in
                !keep.contains { id == $0 || isDescendant(id, of: $0) || isDescendant($0, of: id) }
            }
        }
        for id in ids { setGhost(id, opacity: opacity >= 0.999 ? nil : opacity, auto: false) }
    }

    private func setHidden(_ id: String, _ hidden: Bool) {
        guard let node = nodes[id] else { return }
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
        fade(node, to: hidden ? 0 : min(parts[id]?.opacity ?? 1, ghosts[id]?.opacity ?? 1))
        labelBoxes = [:]
        labelRowsDecidedFor = ""
        fitCountdown = 0
    }

    /// `highlight id color=yellow`: a soft glow that breathes on the part being talked about.
    /// It clears on the next `focus` or `frame`, or with `highlight none`.
    private func highlight(_ c: SceneCommand) {
        guard directsCamera else { return }
        let ids = resolve(c.targetIDs)
        if c.names("none") || ids.isEmpty {
            clearHighlights()
            return
        }
        let color = (c.color() ?? SceneColor(hex: 0xFFC53D)).with(alpha: 1).nsColor
        for id in ids {
            guard let node = nodes[id], highlights[id] == nil else { continue }
            let materials = borrowEmission(of: node)
            for material in materials { material.emission.contents = color }
            highlights[id] = Highlight(materials: materials, start: now)
        }
        updateFlashes(now: now)
    }

    private func clearHighlights() {
        guard !highlights.isEmpty else { return }
        let all = highlights.values.flatMap(\.materials)
        highlights = [:]
        returnEmission(of: all)
    }

    /// Parts that glow right now.
    var highlightedIDs: [String] { highlights.keys.sorted() }
    /// Parts that are see-through right now.
    var ghostedIDs: [String] { ghosts.keys.sorted() }
    var hiddenPartIDs: [String] { hiddenIDs.sorted() }

    // MARK: Detail on demand

    private func detailSubject(_ id: String) -> SceneDetailSubject {
        var subject = SceneDetailSubject(id: id, source: sources[id], macro: macroOf[id])
        subject.parent = parts[id]?.parent
        subject.children = order.compactMap { child in parts[child]?.parent == id ? sources[child] : nil }
        if let geometry = nodes[id]?.geometry {
            let (low, high) = self.localBounds(of: geometry)
            subject.localSize = SceneVec3(simd_float3(high) - simd_float3(low))
        }
        return subject
    }

    /// `detail id`: a richer sub-assembly for the commonest ready-made parts. Anything else: nothing happens.
    private func detail(_ c: SceneCommand) {
        guard directsCamera else { return }
        for id in resolve(c.targetIDs) {
            if detailed.contains(id) {
                // Detailed before and put away since: its labels come back.
                for label in detailLabels[id] ?? [] { suppressedLabels.remove(label) }
                labelRowsDecidedFor = ""
                continue
            }
            let commands = SceneDetail.commands(for: detailSubject(id))
            guard !commands.isEmpty else { continue }
            detailed.insert(id)
            for var command in commands {
                command.cue = c.cue
                apply(command)
                if command.verb == .label, let target = command.string("on") { detailLabels[id, default: []].append(target) }
            }
        }
    }

    /// True when `detail id` has added its pieces.
    func isDetailed(_ id: String) -> Bool { detailed.contains(id) }

    // MARK: Many small pieces

    /// Hundreds of identical unnamed pieces (a membrane's lipids) become one node: one draw per
    /// colour instead of one per piece. They keep counting as parts, but cannot be addressed one by one.
    private func mergeBulkPieces(under groupID: String) {
        bulkGeometries = [:]
        guard let group = nodes[groupID] else { return }
        let pieces = group.childNodes.filter { child in
            guard let name = child.name, let part = parts[name], child.childNodes.isEmpty, child.geometry != nil else { return false }
            return part.label == nil && part.name == nil && labels[name] == nil && spins[name] == nil && beats[name] == nil
                && child.physicsBody == nil && part.opacity >= 0.999
        }
        guard pieces.count >= 60 else { return }
        let holder = SCNNode()
        var low = simd_float3(repeating: .greatestFiniteMagnitude), high = simd_float3(repeating: -.greatestFiniteMagnitude)
        for piece in pieces {
            piece.removeAllActions()
            piece.opacity = 1
            if let geometry = piece.geometry {
                let (minimum, maximum) = localBounds(of: geometry)
                let a = simd_float3(minimum), b = simd_float3(maximum)
                for corner in 0..<8 {
                    let point = piece.simdTransform * simd_float4(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z, 1)
                    low = simd_min(low, simd_float3(point.x, point.y, point.z))
                    high = simd_max(high, simd_float3(point.x, point.y, point.z))
                }
            }
            holder.addChildNode(piece)
        }
        let merged = holder.flattenedClone()
        let id = groupID + "._bulk"
        merged.name = id
        // The pieces shared their materials; the merged node gets its own so a glow or a ghost touches nothing else.
        if let geometry = merged.geometry { geometry.materials = geometry.materials.map { $0.copy() as? SCNMaterial ?? $0 } }
        for piece in pieces {
            if let name = piece.name { nodes[name] = nil }
        }
        group.addChildNode(merged)
        if !isHeadless {
            merged.opacity = 0
            merged.runAction(.fadeIn(duration: 0.28))
        }
        var part = ScenePart(id: id, shape: .group, color: .ink)
        part.parent = groupID
        part.isTappable = false
        nodes[id] = merged
        hasUnpreparedGeometry = true
        invalidateSpatialLayout()
        bulkBoxes[id] = (low, high)
        parts[id] = part
        baseOrientation[id] = merged.simdOrientation
    }

    // MARK: The camera directing itself

    /// Asks for an automatic move onto `ids` for sentence `sentence` (empty: back to the whole model).
    /// The move happens when the calm-movement rules allow it; it is written as a `focus … auto` or
    /// `frame all auto` line through `onDirectorCommand`, so it is recorded and replayed like any other.
    /// `after`: seconds to hold the present view first (the opening sentence shows the whole model for a moment before going in).
    func requestAutoFocus(_ ids: [String], sentence: Int?, wholeIfEmpty: Bool = true, after delay: Double = 0) {
        guard directsCamera, commandOrigin != .replay else { return }
        requestFrames(for: max(delay, 0) + 6)
        pendingAuto = PendingAuto(ids: ids, sentence: sentence, notBefore: now + max(delay, 0), expires: now + max(delay, 0) + 4, wholeIfEmpty: wholeIfEmpty)
        processPendingAuto()
    }

    private func processPendingAuto() {
        guard let pending = pendingAuto else { return }
        if now > pending.expires || !hasFit || now < pending.notBefore - 1e-9 {
            if now > pending.expires { pendingAuto = nil }
            return
        }
        var ids = resolve(pending.ids).filter { !isEffectivelyHidden($0) }
        var box = ids.isEmpty ? nil : bounds(ofParts: ids)
        // Parts that are most of the model are the model.
        if let found = box, found.radius > Double(fitRadius) * 0.9 { box = nil }
        // So are parts that a focus would not bring noticeably closer than the whole-model view already is.
        // (Unless they are hidden in that view: then going to them is what uncovers them.)
        if let found = box, SceneFraming.distance(for: found, direction: SceneVec3(wholeDirection), lens: lens, fill: SceneZoom.medium.fill) > Double(targetDistance) * 0.92 {
            let view = wholePose
            if sightBlockage(from: view.position, to: found, targets: ids, direction: view.direction).amount < 0.45 { box = nil }
        }
        let named = ids.first
        if ProcessInfo.processInfo.environment["TEACHY_SCENE_DEBUG"] != nil {
            print("🎥 sentence \(pending.sentence.map(String.init) ?? "-") asked for \(pending.ids) → \(ids) \(box == nil ? "(the whole model)" : "")")
        }
        if box == nil { ids = [] }
        let whole = ids.isEmpty
        if whole, !pending.wholeIfEmpty {
            pendingAuto = nil
            return
        }
        let headed = cameraMove?.to ?? pose
        let framed: Bool
        if whole {
            framed = (cameraMove?.then ?? cameraMode) == .whole
        } else if let box {
            // In view at a sensible size, and not hidden behind something.
            framed = focusIDs == ids || (SceneFraming.isWellFramed(box, pose: headed, lens: lens, zoom: .medium)
                && sightBlockage(from: headed.position, to: box, targets: ids, direction: headed.direction).amount < 0.45)
        } else {
            framed = true
        }
        switch policy.decide(now: now, sentence: pending.sentence, alreadyFramed: framed, paused: gesturePause.isPaused(now: now)) {
        case .move:
            pendingAuto = nil
            emitDirector(whole ? "frame all auto" : "focus \(ids.joined(separator: ",")) zoom=medium auto", cue: pending.sentence, origin: .narration)
        case .wait:
            break
        case .skipFramed:
            pendingAuto = nil
            // Already in view: a blink on the part says "this one" without moving.
            if focusIDs != ids || whole, let named, bounds(ofParts: [named]).map({ $0.radius < Double(fitRadius) * 0.9 }) ?? false {
                emitDirector("pulse \(named) times=2 auto", cue: pending.sentence, origin: .narration)
            }
        case .skipSentence, .skipPaused:
            pendingAuto = nil
        }
    }

    private func emitDirector(_ line: String, cue: Int? = nil, origin: CommandOrigin) {
        guard var command = SceneScriptParser.parse(line).first else { return }
        command.cue = cue
        let previous = commandOrigin
        if previous != .replay { commandOrigin = origin }
        if let onDirectorCommand { onDirectorCommand(command) } else { apply(command) }
        commandOrigin = previous
    }

    /// Recenter (the button, or Escape): the whole model again, and the camera directs itself again.
    func recenter() {
        gesturePause.resume()
        emitDirector("frame all", origin: .person)
    }

    // MARK: The person's hands on the camera

    /// The camera is the person's from now on: whatever move was running stops where it is.
    private func takeCamera() {
        guard cameraMode != .user || cameraMove != nil else { return }
        pose.azimuth = displayedAzimuth
        swayAmount = 0
        cameraMove = nil
        cameraMode = .user
        pendingAuto = nil
        publishCameraState()
    }

    private func userBeganDrag() {
        requestFrames()
        gesturePause.began(now: now)
        takeCamera()
    }

    private func userEndedDrag() {
        gesturePause.ended(now: now)
    }

    /// Drag: turn the model. Points of mouse travel.
    private func userOrbit(dx: CGFloat, dy: CGFloat) {
        requestFrames()
        takeCamera()
        gesturePause.touched(now: now)
        pose = SceneFraming.turn(pose, azimuth: -Double(dx) * 0.008, elevation: -Double(dy) * 0.008)
        placeCamera()
    }

    private var zoomLimits: SceneFraming.ZoomLimits {
        SceneFraming.zoomLimits(model: modelBox, wholeDistance: Double(targetDistance), pose: pose, lens: lens, surfaceAhead: nil)
    }

    /// Option-drag, right-drag or two fingers: slide the model with the hand.
    private func userPan(dx: CGFloat, dy: CGFloat) {
        requestFrames()
        takeCamera()
        gesturePause.touched(now: now)
        let size = viewportSize ?? view.bounds.size
        let delta = SceneVec2(Double(dx) / max(Double(size.width) / 2, 1), Double(dy) / max(Double(size.height) / 2, 1))
        pose = SceneFraming.pan(pose, by: delta, lens: lens, limits: zoomLimits)
        placeCamera()
    }

    /// Wheel or pinch: zoom toward the point under the cursor, never through the model and never out of sight of it.
    private func userZoom(by factor: CGFloat, at point: CGPoint) {
        requestFrames()
        takeCamera()
        gesturePause.touched(now: now)
        let size = viewportSize ?? view.bounds.size
        let cursor = SceneVec2((Double(point.x) - Double(size.width) / 2) / max(Double(size.width) / 2, 1),
                               (Double(point.y) - Double(size.height) / 2) / max(Double(size.height) / 2, 1))
        var surfaceAhead: Double?
        if factor > 1 {
            // The first solid thing between the camera and what it looks at.
            prepareForHitTesting()
            let eye = simd_float3(pose.position)
            let hits = contentRoot.hitTestWithSegment(from: SCNVector3(eye), to: SCNVector3(simd_float3(pose.center)),
                                                      options: [SCNHitTestOption.backFaceCulling.rawValue: false,
                                                                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                guard let id = partID(owning: hit.node), effectiveOpacity(id) >= 0.5 else { continue }
                let distance = Double(simd_length(simd_float3(hit.worldCoordinates) - eye))
                surfaceAhead = min(surfaceAhead ?? distance, distance)
            }
        }
        let limits = SceneFraming.zoomLimits(model: modelBox, wholeDistance: Double(targetDistance), pose: pose, lens: lens, surfaceAhead: surfaceAhead)
        pose = SceneFraming.zoom(pose, by: Double(factor), toward: cursor, lens: lens, limits: limits)
        placeCamera()
    }

    // MARK: Describing and measuring the view

    /// The model on screen in words, for a refine request.
    var liveState: SceneLiveState {
        var state = SceneLiveState(title: model.title.isEmpty ? nil : model.title)
        let candidates = subjectCandidates
        var boxes: [(id: String, box: SceneBox)] = []
        for candidate in candidates {
            if let box = bounds(ofParts: [candidate.id]) { boxes.append((candidate.id, box)) }
        }
        // Shells that can hide things: parts with a shape of their own.
        let shells = boxes.filter { nodes[$0.id]?.geometry != nil }
        func colour(of id: String) -> String? {
            guard let part = parts[id] else { return nil }
            if case .group = part.shape {
                // A ready-made part is the colour of its biggest piece.
                let child = order.first { parts[$0]?.parent == id && nodes[$0]?.geometry != nil && !$0.hasSuffix(".hub") }
                return child.flatMap { parts[$0]?.color.nearestName }
            }
            return part.color.nearestName
        }
        let labelled = candidates.filter { $0.label != nil }, others = candidates.filter { $0.label == nil }
        for candidate in labelled + others {
            let id = candidate.id
            var part = SceneLivePart(id: id, title: candidate.label ?? candidate.name, colour: colour(of: id))
            if let box = boxes.first(where: { $0.id == id })?.box {
                part.inside = SceneContainment.containers(of: id, subject: box, among: shells).first { !isDescendant(id, of: $0) && !isDescendant($0, of: id) }
            }
            part.isGhosted = ghosts[id] != nil
            part.isHidden = hiddenIDs.contains(id)
            part.canDetail = (!detailed.contains(id) && SceneDetail.kind(of: detailSubject(id)) != nil)
                || (detailLabels[id] ?? []).contains(where: suppressedLabels.contains)
            state.parts.append(part)
        }
        state.focus = focusIDs
        state.isExploded = explodedOffsets.values.contains { simd_length($0) > 1e-4 }
        return state
    }

    /// Where the given parts land in the picture right now, measured with the real camera node.
    func projectedBounds(ofParts ids: [String]) -> SceneProjection? {
        guard let box = bounds(ofParts: resolve(ids)) else { return nil }
        let lens = self.lens
        var low = SceneVec2(repeating: .greatestFiniteMagnitude), high = SceneVec2(repeating: -.greatestFiniteMagnitude)
        var behind = false
        for corner in box.corners {
            let local = cameraNode.simdConvertPosition(simd_float3(corner), from: nil)
            let depth = Double(-local.z)
            if depth <= 1e-6 { behind = true }
            let safe = max(depth, 1e-9)
            let ndc = SceneVec2(Double(local.x) / (safe * lens.tanHorizontal), Double(local.y) / (safe * lens.tanVertical))
            low = simd_min(low, ndc)
            high = simd_max(high, ndc)
        }
        let widthShare = (high.x - low.x) / 2 * (lens.aspect >= 1 ? lens.aspect : 1)
        let heightShare = (high.y - low.y) / 2 * (lens.aspect >= 1 ? 1 : 1 / lens.aspect)
        return SceneProjection(low: low, high: high, behindCamera: behind, fill: max(widthShare, heightShare))
    }

    /// The world-space box round the given parts right now.
    func boundingBox(ofParts ids: [String]) -> SceneBox? { bounds(ofParts: resolve(ids)) }

    /// How hidden the given parts are from the camera right now (0 clear … 1 hidden).
    func occlusion(ofParts ids: [String]) -> Double {
        let resolved = resolve(ids)
        guard let box = bounds(ofParts: resolved) else { return 0 }
        let shown = displayedPose
        return sightBlockage(from: shown.position, to: box, targets: resolved, direction: shown.direction).amount
    }

    /// Label chips that are showing, and where each is in the picture (−1…1), for checking they stay in view.
    var visibleLabels: [(part: String, ndc: SceneVec2)] {
        let lens = self.lens
        return labels.values.filter { !$0.chip.isHidden }.sorted { $0.index < $1.index }.map { label in
            let local = cameraNode.simdConvertPosition(label.chip.simdWorldPosition, from: nil)
            let depth = max(Double(-local.z), 1e-9)
            return (label.partID, SceneVec2(Double(local.x) / (depth * lens.tanHorizontal), Double(local.y) / (depth * lens.tanVertical)))
        }
    }

    /// The distance from the camera to the nearest solid surface straight ahead, as a share of the model's radius.
    /// Near zero means the camera is inside or against geometry.
    var clearanceAhead: Double {
        let shown = displayedPose
        let eye = simd_float3(shown.position)
        prepareForHitTesting()
        let hits = contentRoot.hitTestWithSegment(from: SCNVector3(eye), to: SCNVector3(simd_float3(shown.center)),
                                                  options: [SCNHitTestOption.backFaceCulling.rawValue: false,
                                                            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
        var nearest = shown.distance
        for hit in hits {
            guard let id = partID(owning: hit.node), effectiveOpacity(id) >= 0.5 else { continue }
            nearest = min(nearest, Double(simd_length(simd_float3(hit.worldCoordinates) - eye)))
        }
        return nearest / Double(max(fitRadius, 0.05))
    }

    /// The model's radius (for scaling test thresholds).
    var modelRadius: Double { Double(fitRadius) }

    /// Renders the scene off-screen at twice the view's size.
    func snapshot() -> NSImage {
        if isHeadless { return renderFrame(size: CGSize(width: max(view.bounds.width, 320) * 2, height: max(view.bounds.height, 240) * 2)) }
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = view.pointOfView
        renderer.autoenablesDefaultLighting = false
        let size = CGSize(width: max(view.bounds.width, 320) * 2, height: max(view.bounds.height, 240) * 2)
        return renderer.snapshot(atTime: view.sceneTime, with: size, antialiasingMode: .multisampling4X)
    }

    /// Headless: the picture at the current time, `size` in pixels. One renderer is kept for
    /// the controller's life, so SceneKit's own actions and physics move on with `advance(by:)`.
    func renderFrame(size: CGSize) -> NSImage {
        let renderer: SCNRenderer
        if let offscreenRenderer {
            renderer = offscreenRenderer
        } else {
            renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = scene
            renderer.autoenablesDefaultLighting = false
            offscreenRenderer = renderer
        }
        renderer.pointOfView = cameraNode
        return renderer.snapshot(atTime: manualClock, with: size, antialiasingMode: .multisampling4X)
    }

    /// Names of the parts a person can ask about, labelled ones first (for follow-up questions).
    var describedParts: [String] {
        var names: [String] = []
        for id in order {
            guard let part = parts[id], let name = part.label ?? part.name, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// Numbers for checking a simulation without watching it.
    func debugState(of id: String) -> (position: SceneVec3, speed: Double)? {
        guard let node = nodes[id] else { return nil }
        return (SceneVec3(node.presentation.simdWorldPosition), Double(simd_length(measuredVelocity[id] ?? .zero)))
    }

    func debugSpinAngle(of id: String) -> Double? { spinAngles[id] }
}

// MARK: - Small conversions

extension simd_quatf {
    init(_ q: simd_quatd) {
        self.init(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
    }
}
