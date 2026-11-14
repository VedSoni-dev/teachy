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

    /// Sliders, plots or chips were added or removed, so the window should resize.
    var onLayoutChanged: (() -> Void)?
}

// MARK: - SceneKit view

final class Scene3DSCNView: SCNView {
    var onTap: ((CGPoint) -> Void)?
    var onInteraction: (() -> Void)?
    private var mouseDownPoint: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let start = mouseDownPoint, hypot(point.x - start.x, point.y - start.y) < 4 {
            onTap?(point)
        }
        mouseDownPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        onInteraction?()
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onInteraction?()
        super.magnify(with: event)
    }
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
    private struct Flow { var markers: [String]; var path: [SceneVec3]; var speed: Double; var phase: Double; var length: Double }
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
    /// SCNPhysicsBody.velocity read from the main thread is stale, so speeds are
    /// measured from how far each moving body travelled since the last tick.
    private var movingIDs: Set<String> = []
    private var lastPositions: [String: simd_float3] = [:]
    private var measuredVelocity: [String: simd_float3] = [:]

    // Camera
    private var azimuth = 0.5
    private var baseAzimuth = 0.5
    private var swayPhase = 0.0
    private var elevation = 0.30
    private var fitCenter = simd_float3(0, 0, 0)
    private var fitRadius: Float = 2
    private var shownCenter = simd_float3(0, 0, 0)
    private var shownDistance: Float = 9
    private var hasFit = false
    private var userTookCamera = false
    private var cameraPinned = false
    private var autoRotate = true
    private var fitCountdown = 0.0

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var plotCountdown = 0.0

    static let fieldOfView: CGFloat = 30

    override init() {
        view = Scene3DSCNView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        super.init()
        configureView()
        configureScene()
        startTicking()
    }

    var partCount: Int { parts.values.filter { if case .group = $0.shape { return false } else { return true } }.count }
    var hasContent: Bool { !nodes.isEmpty }

    // MARK: Setup

    private func configureView() {
        view.scene = scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.autoenablesDefaultLighting = false
        view.isPlaying = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.onInteraction = { [weak self] in self?.userTouchedCamera() }
        view.onTap = { [weak self] point in self?.handleTap(at: point) }
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
        key.intensity = 640
        key.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 5
        key.shadowSampleCount = 12
        key.shadowColor = NSColor.black.withAlphaComponent(0.32)
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdEulerAngles = simd_float3(-0.62, -0.5, 0)
        cameraNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 260
        fill.color = NSColor(calibratedRed: 0.82, green: 0.90, blue: 1.0, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdEulerAngles = simd_float3(-0.2, 0.9, 0)
        cameraNode.addChildNode(fillNode)

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
        timer?.invalidate()
        timer = nil
        view.isPlaying = false
    }

    /// Empties the scene, keeping the view.
    func reset() {
        for node in contentRoot.childNodes { node.removeFromParentNode() }
        for node in labelRoot.childNodes { node.removeFromParentNode() }
        scene.physicsWorld.removeAllBehaviors()
        scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
        scene.physicsWorld.speed = 1
        builder = ScenePartBuilder()
        nodes = [:]; parts = [:]; baseOrientation = [:]; order = []
        spins = [:]; spinAngles = [:]; solvedRPM = [:]; flows = [:]; pistons = [:]; orbits = [:]; coils = [:]; explodedOffsets = [:]
        labels = [:]; chipTargets = [:]; springVelocity = [:]; bodyMass = [:]; joints = [:]; forces = [:]; sliderBindings = [:]; plotSources = [:]; plotBuffers = [:]
        isSimulation = false; speed = 1; movingIDs = []; lastPositions = [:]; measuredVelocity = [:]; labelBoxes = [:]
        azimuth = 0.5; baseAzimuth = 0.5; swayPhase = 0; elevation = 0.30; hasFit = false; userTookCamera = false; cameraPinned = false; autoRotate = true
        fitCenter = .zero; fitRadius = 2; shownCenter = .zero; shownDistance = 9
        shadowNode.isHidden = true
        view.pointOfView = cameraNode
        model.title = ""; model.sliders = []; model.plots = []; model.chips = []; model.tappedLabel = nil
        placeCamera()
    }

    // MARK: Commands

    func apply(_ original: SceneCommand) {
        var c = original
        c.verb = SceneRouter.verbIn3D(original)
        switch c.verb {
        case .scene3d:
            model.title = c.string("title") ?? c.freeText ?? model.title
            if c.flag("still") { autoRotate = false }
        case .label:
            if let target = c.string("on"), let text = c.freeText {
                addLabel(to: target, text: text, number: c.number("n", "num").map { Int($0) }, side: c.string("side"))
            }
        case .chip:
            if let text = c.freeText, !model.chips.contains(text), model.chips.count < 4 {
                model.chips.append(text)
                model.onLayoutChanged?()
            }
        case .spin:
            spins[c.id] = Spin(axis: c.axis(), rpm: Self.watchable(c.number("rpm", "speed") ?? 20))
            if let piston = pistons[c.id] { pistons[c.id]?.rpm = c.number("rpm", "speed") ?? piston.rpm; spins[c.id] = nil }
            solvedRPM = [:]
        case .move: move(c)
        case .pulse: pulse(c.id, times: Int(c.number("times", "n") ?? 3))
        case .explode: explode(c)
        case .camera: moveCamera(c)
        case .orbit: addOrbit(c)
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
            if let value = c.number("value", "to", "v") { setSlider(c.id, value: value, fromUser: false) }
        case .plot: addPlot(c)
        case .remove: remove(c.id)
        case .hide: nodes[c.id]?.runAction(.fadeOut(duration: 0.3))
        case .show:
            if let node = nodes[c.id] { node.runAction(.fadeOpacity(to: CGFloat(parts[c.id]?.opacity ?? 1), duration: 0.3)) }
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
        settleUntil = CACurrentMediaTime() + 1.2
    }

    private func addNode(for part: ScenePart) {
        nodes[part.id]?.removeFromParentNode()
        let node = SCNNode()
        node.name = part.id
        node.geometry = Scene3DAssets.geometry(for: part)
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
        node.opacity = 0
        node.runAction(.fadeOpacity(to: CGFloat(part.opacity), duration: 0.28))
        if part.opacity < 0.999 { node.renderingOrder = 10 }
        nodes[part.id] = node
        parts[part.id] = part
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
        var text = text, number = number
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 2, let leading = Int(digits) {
            let rest = text.dropFirst(digits.count)
            if let separator = rest.first, " .:)·-".contains(separator), number == nil || number == leading {
                let stripped = rest.drop(while: { " .:)·-".contains($0) })
                if !stripped.isEmpty {
                    text = String(stripped)
                    number = leading
                }
            }
        }
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

        chip.opacity = 0
        leader.opacity = 0
        chip.runAction(.sequence([.wait(duration: 0.15), .fadeIn(duration: 0.3)]))
        leader.runAction(.sequence([.wait(duration: 0.15), .fadeOpacity(to: 0.85, duration: 0.3)]))
        labelRoot.addChildNode(leader)
        labelRoot.addChildNode(chip)
        labels[partID] = LabelChip(partID: partID, chip: chip, leader: leader, index: labels[partID]?.index ?? labels.count, side: side)
        labelBoxes[partID] = nil
        updateLabels()
    }

    /// The world-space box around a node and its children, from each geometry's own
    /// box corners. (SCNNode.boundingBox grows with every rotated parent, which made
    /// models look small in the frame.)
    private func tightBounds(of root: SCNNode) -> (low: simd_float3, high: simd_float3)? {
        var low = simd_float3(repeating: .greatestFiniteMagnitude), high = simd_float3(repeating: -.greatestFiniteMagnitude)
        var found = false
        func visit(_ node: SCNNode) {
            if let name = node.name, name.hasPrefix("_") { return }
            if node.isHidden { return }
            if let geometry = node.geometry {
                let (minimum, maximum) = geometry.boundingBox
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

    private func updateLabels(refresh: Bool = false) {
        guard !labels.isEmpty else { return }
        let radius = max(fitRadius, 0.05)
        let modelTop = boundsHigh.y
        let toCamera = simd_normalize(cameraNode.simdWorldPosition - shownCenter)
        let right = simd_normalize(simd_cross(simd_float3(0, 1, 0), toCamera))
        let up = simd_cross(toCamera, right)
        let chipHeight = radius * 0.11
        var placed: [(x: Float, y: Float, halfWidth: Float)] = []
        var top = -Float.greatestFiniteMagnitude

        for label in labels.values.sorted(by: { $0.index < $1.index }) {
            guard let node = nodes[label.partID], let (low, high) = labelBox(for: label.partID, node: node, refresh: refresh) else { continue }
            let center = (low + high) / 2
            let halfHeight = (high.y - low.y) / 2
            let halfWidth = max(high.x - low.x, high.z - low.z) / 2
            var target: simd_float3
            switch label.side?.lowercased() {
            case "down", "below", "bottom":
                target = simd_float3(center.x, min(low.y - radius * 0.2, boundsLow.y - radius * 0.06), center.z)
            case "left":
                target = center - right * (halfWidth + radius * 0.5)
            case "right":
                target = center + right * (halfWidth + radius * 0.5)
            default:
                let near = high.y + radius * 0.2
                let clear = min(modelTop + radius * 0.1, high.y + radius * 0.9)
                // A chip rides just above a moving body; otherwise it clears the whole model.
                target = simd_float3(center.x, movingIDs.contains(label.partID) || orbits[label.partID] != nil ? near : max(near, clear), center.z)
            }
            // Keep chips from covering each other, judged in the camera's plane.
            let aspect = Float((label.chip.geometry as? SCNPlane)?.width ?? 3)
            let half = aspect * chipHeight / 2
            let direction: Float = ["down", "below", "bottom"].contains(label.side?.lowercased() ?? "") ? -1 : 1
            var attempts = 0
            while attempts < 12 {
                let x = simd_dot(target, right), y = simd_dot(target, up)
                let collides = placed.contains { abs($0.x - x) < ($0.halfWidth + half) * 1.04 && abs($0.y - y) < chipHeight * 1.12 }
                if !collides { break }
                target.y += direction * chipHeight * 1.2
                attempts += 1
            }
            placed.append((simd_dot(target, right), simd_dot(target, up), half))

            // Ease toward the target so chips glide instead of jumping as the view sways.
            let previous = chipTargets[label.partID] ?? target
            let position = previous + (target - previous) * 0.2
            chipTargets[label.partID] = position
            label.chip.simdPosition = position
            label.chip.simdScale = simd_float3(repeating: chipHeight)
            top = max(top, position.y + chipHeight * 0.7)

            let sideways = label.side.map { ["left", "right"].contains($0.lowercased()) } ?? false
            let anchor = sideways ? center : simd_float3(center.x, center.y + direction * halfHeight * 0.55, center.z)
            let toChip = position - anchor
            let distance = simd_length(toChip)
            guard distance > 1e-4 else { continue }
            let along = toChip / distance
            let reach = sideways ? half : chipHeight * 0.5
            let end = position - along * min(reach, distance * 0.5)
            let span = simd_length(end - anchor)
            label.leader.simdPosition = (anchor + end) / 2
            label.leader.simdOrientation = simd_quatf(SceneOrientation.aligning(SceneVec3(0, 1, 0), to: SceneVec3(along)))
            let thickness = radius * 0.0045
            label.leader.simdScale = simd_float3(thickness, span, thickness)
        }
        if top > -Float.greatestFiniteMagnitude { labelsTop = top }
    }

    // MARK: Motion

    private func move(_ c: SceneCommand) {
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
            node.runAction(.repeatForever(.sequence([action, .wait(duration: 0.25), back, .wait(duration: 0.25)])), forKey: "move")
        } else {
            node.runAction(action, forKey: "move")
        }
    }

    private func pulse(_ id: String, times: Int) {
        guard let node = nodes[id] else { return }
        flash(node, times: max(1, min(times, 8)))
    }

    private struct Flash { var materials: [SCNMaterial]; var start: CFTimeInterval; var duration: Double; var times: Int }
    private var flashes: [Flash] = []

    private func flash(_ node: SCNNode, times: Int) {
        var materials: [SCNMaterial] = []
        node.enumerateHierarchy { child, _ in materials += child.geometry?.materials ?? [] }
        for material in materials { material.emission.contents = NSColor.white; material.emission.intensity = 0 }
        flashes.append(Flash(materials: materials, start: CACurrentMediaTime(), duration: 0.42 * Double(times), times: times))
    }

    private func updateFlashes(now: CFTimeInterval) {
        guard !flashes.isEmpty else { return }
        for flash in flashes {
            let elapsed = now - flash.start
            let wave = elapsed >= flash.duration ? 0 : 0.5 - 0.5 * cos(elapsed / flash.duration * Double(flash.times) * 2 * Double.pi)
            for material in flash.materials { material.emission.intensity = CGFloat(wave * 0.55) }
        }
        flashes.removeAll { now - $0.start >= $0.duration }
    }

    /// Pulls the top-level parts (or one group's children) apart along an axis. `dist=0` puts them back.
    private func explode(_ c: SceneCommand) {
        let axis = c.axis() ?? SceneVec3(1, 0, 0)
        let distance = c.number("dist", "by", "d") ?? Double(fitRadius) * 0.6
        let duration = c.number("dur", "t") ?? 0.9
        let targets: [SCNNode]
        if c.hasExplicitID, let group = nodes[c.id], !group.childNodes.isEmpty {
            targets = group.childNodes.filter { $0.name != nil }
        } else {
            targets = contentRoot.childNodes.filter { node in
                guard let name = node.name, let part = parts[name] else { return false }
                if flows[name] != nil || node.physicsBody != nil { return false }
                if case .text = part.shape { return false }
                return true
            }
        }
        guard !targets.isEmpty else { return }
        // Undo any earlier explode first, so offsets don't pile up.
        let homes: [simd_float3] = targets.map { node in
            node.simdPosition - (explodedOffsets[node.name ?? ""] ?? .zero)
        }
        let centers = zip(targets, homes).map { node, home -> SceneVec3 in
            let (low, high) = node.boundingBox
            let local = (simd_float3(low) + simd_float3(high)) / 2
            return SceneVec3(home + node.simdOrientation.act(local * node.simdScale))
        }
        let offsets = SceneGeometry.explodeOffsets(positions: centers, axis: axis, distance: distance)
        for (index, node) in targets.enumerated() {
            let offset = simd_float3(offsets[index])
            explodedOffsets[node.name ?? ""] = offset
            let action = SCNAction.move(to: SCNVector3(homes[index] + offset), duration: duration)
            action.timingMode = .easeInEaseOut
            node.runAction(action, forKey: "explode")
        }
        fitCountdown = duration
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
        let look = c.vec3("look").map { simd_float3($0) } ?? shownCenter
        var position = c.vec3("to").map { simd_float3($0) } ?? cameraNode.simdPosition
        if let zoom = c.number("zoom"), zoom > 0 {
            position = look + (position - look) / Float(zoom)
        }
        guard simd_length(position - look) > 1e-4 else { return }
        cameraPinned = true
        view.pointOfView = cameraNode
        SCNTransaction.begin()
        SCNTransaction.animationDuration = c.number("dur", "t") ?? 1.0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.simdPosition = position
        cameraNode.simdLook(at: look)
        SCNTransaction.commit()
        shownCenter = look
        shownDistance = simd_length(position - look)
    }

    // MARK: Simulation

    private func enterSimulation() {
        guard !isSimulation else { return }
        isSimulation = true
        // Simulations are easiest to read nearly face-on and holding still.
        autoRotate = false
        azimuth = 0.22
        baseAzimuth = 0.22
        elevation = 0.14
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

    private func applyBinding(_ binding: String, value: Double) {
        let (target, property) = splitBinding(binding)
        switch property {
        case "gravity", "g":
            scene.physicsWorld.gravity = SCNVector3(0, -abs(value), 0)
        case "speed", "time", "timescale":
            speed = max(value, 0)
            scene.physicsWorld.speed = CGFloat(speed)
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
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        for hit in hits {
            if let id = tappablePartID(for: hit.node) {
                tapPart(id)
                return
            }
        }
    }

    private func tappablePartID(for node: SCNNode) -> String? {
        var current: SCNNode? = node
        var fallback: String?
        while let candidate = current {
            if let name = candidate.name {
                if name.hasPrefix("_label:") { return String(name.dropFirst("_label:".count)) }
                if name.hasPrefix("_") { return nil }
                if let part = parts[name] {
                    if part.isTappable { return name }
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

    private func userTouchedCamera() {
        guard !userTookCamera else { return }
        userTookCamera = true
        view.defaultCameraController.target = SCNVector3(shownCenter)
    }

    // MARK: Per-frame

    private func tick() {
        let now = CACurrentMediaTime()
        let wall = min(now - lastTick, 0.1)
        lastTick = now
        let dt = wall * speed
        guard hasContent else { return }

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
            flow.phase = SceneGeometry.fraction(flow.phase + flow.speed * dt / flow.length)
            flows[id] = flow
            for (index, markerID) in flow.markers.enumerated() {
                guard let marker = nodes[markerID] else { continue }
                let t = SceneGeometry.fraction(flow.phase + Double(index) / Double(flow.markers.count))
                let placement = SceneGeometry.pointAlong(flow.path, t: t)
                marker.simdPosition = simd_float3(placement.position)
                marker.simdOrientation = simd_quatf(SceneOrientation.aligning(SceneVec3(0, 1, 0), to: placement.direction))
                let edge = min(t, 1 - t) / 0.1
                marker.simdScale = simd_float3(repeating: Float(min(max(edge, 0.01), 1)))
            }
        }

        for id in Array(pistons.keys) {
            let pistonRPM = pistons[id]?.rpm ?? 0
            pistons[id]?.angle += pistonRPM * dt * 2 * Double.pi / 60
            updatePiston(id)
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
            let mesh = SceneGeometry.tubeMesh(path: SceneGeometry.springPoints(from: SceneVec3(start), to: SceneVec3(end), coils: coil.coils, radius: coil.radius, samplesPerCoil: 12),
                                              radius: coil.wire, sides: 6)
            let materials = node.geometry?.materials ?? []
            node.geometry = Scene3DAssets.geometry(from: mesh)
            node.geometry?.materials = materials
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
        if fitCountdown <= 0 {
            fitCountdown = 0.25
            refit()
            refreshed = true
        }
        updateCamera(dt: wall)
        updateLabels(refresh: refreshed)

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

    private func refit() {
        guard let (minimum, maximum) = tightBounds(of: contentRoot) else { return }
        guard minimum.x.isFinite, maximum.x.isFinite, simd_length(maximum - minimum) > 1e-5 else { return }
        var center = (minimum + maximum) / 2
        var radius = max(simd_length(maximum - minimum) / 2, 0.05)
        if isSimulation, hasFit, CACurrentMediaTime() > settleUntil {
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
            shownCenter = lookCenter
            shownDistance = targetDistance
            placeCamera()
        }
        shadowNode.isHidden = isSimulation
        shadowNode.simdPosition = simd_float3(center.x, minimum.y - radius * 0.04, center.z)
        let footprint = max(maximum.x - minimum.x, maximum.z - minimum.z, radius) * 1.35
        shadowNode.simdScale = simd_float3(footprint, footprint, 1)
    }

    private var boundsLow = simd_float3(-1, -1, -1)
    private var boundsHigh = simd_float3(1, 1, 1)

    private func cameraDirection(azimuth: Double) -> simd_float3 {
        simd_float3(Float(sin(azimuth) * cos(elevation)), Float(sin(elevation)), Float(cos(azimuth) * cos(elevation)))
    }

    /// Where the camera looks: the middle of the model, lifted to leave room for label chips.
    private var lookCenter: simd_float3 {
        fitCenter + simd_float3(0, labels.isEmpty ? 0 : labelHeadroom / 2, 0)
    }

    /// How far the stacked chips rise above the model, so the camera keeps them in frame.
    private var labelHeadroom: Float {
        guard !labels.isEmpty else { return 0 }
        return min(max(labelsTop - boundsHigh.y, fitRadius * 0.3), fitRadius * 1.4)
    }
    private var labelsTop: Float = 0

    /// The distance at which the model's box (plus label headroom) just fills the view,
    /// taken as the worst case across the sway so the zoom doesn't breathe.
    private var targetDistance: Float {
        let halfVertical = Float(Self.fieldOfView) * .pi / 360
        let aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
        let tanVertical = tan(halfVertical), tanHorizontal = tan(halfVertical) * aspect
        let center = lookCenter
        var low = boundsLow, high = boundsHigh
        high.y += labelHeadroom
        if isSimulation {
            // Bodies move: fit the sphere instead of the box.
            return (fitRadius + labelHeadroom * 0.5) / sin(min(halfVertical, atan(tanHorizontal))) * 1.05
        }
        var needed: Float = 0.1
        let angles = autoRotate && !userTookCamera ? [baseAzimuth - 0.3, baseAzimuth, baseAzimuth + 0.3] : [azimuth]
        for angle in angles {
            let toCamera = cameraDirection(azimuth: angle)
            let right = simd_normalize(simd_cross(simd_float3(0, 1, 0), toCamera))
            let up = simd_cross(toCamera, right)
            for corner in 0..<8 {
                let point = simd_float3(corner & 1 == 0 ? low.x : high.x, corner & 2 == 0 ? low.y : high.y, corner & 4 == 0 ? low.z : high.z) - center
                let depth = simd_dot(point, toCamera)
                needed = max(needed, abs(simd_dot(point, right)) / tanHorizontal + depth, abs(simd_dot(point, up)) / tanVertical + depth)
            }
        }
        return needed * 1.1
    }

    private func updateCamera(dt: Double) {
        guard !userTookCamera, !cameraPinned else { return }
        if autoRotate {
            // A slow sway either side of the opening view, so the model never ends up edge-on.
            swayPhase += dt * 0.42
            azimuth = baseAzimuth + 0.3 * sin(swayPhase)
        }
        let blend = Float(min(dt * 4, 1))
        shownCenter += (lookCenter - shownCenter) * blend
        shownDistance += (targetDistance - shownDistance) * blend
        placeCamera()
    }

    private func placeCamera() {
        cameraNode.simdPosition = shownCenter + cameraDirection(azimuth: azimuth) * shownDistance
        cameraNode.simdLook(at: shownCenter)
    }

    /// Sets the turntable angle (radians) and stops auto-rotation; used for repeatable snapshots.
    func freezeCamera(azimuth: Double? = nil, elevation: Double? = nil) {
        if let azimuth { self.azimuth = azimuth; baseAzimuth = azimuth }
        if let elevation { self.elevation = elevation }
        autoRotate = false
        refit()
        shownCenter = lookCenter
        shownDistance = targetDistance
        placeCamera()
        updateLabels()
    }

    /// Renders the scene off-screen at twice the view's size.
    func snapshot() -> NSImage {
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = view.pointOfView
        renderer.autoenablesDefaultLighting = false
        let size = CGSize(width: max(view.bounds.width, 320) * 2, height: max(view.bounds.height, 240) * 2)
        return renderer.snapshot(atTime: view.sceneTime, with: size, antialiasingMode: .multisampling4X)
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
