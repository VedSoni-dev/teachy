//
//  Scene3DView.swift
//  leanring-buddy / Scene
//
//  What surrounds the SceneKit view: geometry and material factories, the
//  SwiftUI chrome (title, sliders, live plots, follow-up chips) and the
//  transparent window a 3D model floats in over the screen.
//

import AppKit
import SceneKit
import SwiftUI
import simd

// MARK: - Geometry, materials, textures

enum Scene3DAssets {

    static func geometry(for part: ScenePart) -> SCNGeometry? {
        let geometry: SCNGeometry?
        var doubleSided = false
        switch part.shape {
        case .group:
            return nil
        case .box(let size, let corner):
            geometry = SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: min(max(corner, 0), min(size.x, size.y, size.z) / 2))
        case .sphere(let radius):
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 48
            geometry = sphere
        case .cylinder(let radius, let height):
            let cylinder = SCNCylinder(radius: radius, height: height)
            cylinder.radialSegmentCount = 48
            geometry = cylinder
        case .cone(let bottom, let top, let height):
            let cone = SCNCone(topRadius: top, bottomRadius: bottom, height: height)
            cone.radialSegmentCount = 40
            geometry = cone
        case .torus(let ring, let pipe):
            let torus = SCNTorus(ringRadius: ring, pipeRadius: pipe)
            torus.ringSegmentCount = 72
            torus.pipeSegmentCount = 20
            geometry = torus
        case .capsule(let radius, let height):
            geometry = SCNCapsule(capRadius: radius, height: height)
        case .tube(let path, let radius, let closed):
            geometry = self.geometry(from: SceneGeometry.tubeMesh(path: path, radius: radius, sides: 14, closed: closed))
        case .lathe(let profile, let sweep):
            geometry = self.geometry(from: SceneGeometry.latheMesh(profile: profile, segments: 56, sweepDegrees: sweep))
            doubleSided = true
        case .extrude(let outline, let depth, let hole):
            guard outline.count >= 3 else { return nil }
            let path = NSBezierPath()
            path.move(to: outline[0].cgPoint)
            for point in outline.dropFirst() { path.line(to: point.cgPoint) }
            path.close()
            if hole > 0 {
                path.appendOval(in: CGRect(x: -hole, y: -hole, width: hole * 2, height: hole * 2))
                path.windingRule = .evenOdd
            }
            let extent = outline.map { max(abs($0.x), abs($0.y)) }.max() ?? 1
            path.flatness = max(extent * 0.004, 0.0005)
            let shape = SCNShape(path: path, extrusionDepth: depth)
            shape.chamferRadius = min(depth * 0.12, extent * 0.02)
            geometry = shape
        case .text(let text, let size):
            let (image, aspect) = textImage(text, color: part.color)
            let plane = SCNPlane(width: size * aspect, height: size)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image
            material.isDoubleSided = true
            plane.materials = [material]
            return plane
        }
        guard let geometry else { return nil }
        let material = self.material(color: part.color, opacity: part.opacity, kind: part.material)
        if doubleSided { material.isDoubleSided = true }
        geometry.materials = [material]
        return geometry
    }

    /// Geometry for one of hundreds of identical small pieces (a membrane's lipids): few segments,
    /// and one object shared by every piece of the same shape and colour, so they can be merged
    /// into a single draw. `cache` lives for one build.
    static func bulkGeometry(for part: ScenePart, cache: inout [String: SCNGeometry]) -> SCNGeometry? {
        let shapeKey: String
        switch part.shape {
        case .sphere(let radius): shapeKey = "s|\(radius)"
        case .cylinder(let radius, let height): shapeKey = "c|\(radius)|\(height)"
        default: return geometry(for: part)
        }
        let key = shapeKey + "|\(part.color.r),\(part.color.g),\(part.color.b)|\(part.opacity)|\(part.material.rawValue)"
        if let cached = cache[key] { return cached }
        let geometry: SCNGeometry
        switch part.shape {
        case .sphere(let radius):
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 14
            geometry = sphere
        case .cylinder(let radius, let height):
            let cylinder = SCNCylinder(radius: radius, height: height)
            cylinder.radialSegmentCount = 8
            geometry = cylinder
        default:
            return self.geometry(for: part)
        }
        geometry.materials = [material(color: part.color, opacity: part.opacity, kind: part.material)]
        cache[key] = geometry
        return geometry
    }

    static func geometry(from mesh: SceneMesh) -> SCNGeometry? {
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else { return nil }
        let vertices = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0) })
        let normals = SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0) })
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vertices, normals], elements: [element])
    }

    static func material(color: SceneColor, opacity: Double, kind: SceneMaterial) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color.with(alpha: 1).nsColor
        material.metalness.contents = 0.0
        material.roughness.contents = 0.42
        switch kind {
        case .plastic:
            // A thin glossy coat, like moulded plastic or enamel paint.
            material.clearCoat.contents = 0.35
            material.clearCoatRoughness.contents = 0.25
        case .metal:
            material.metalness.contents = 0.9
            material.roughness.contents = 0.3
        case .glass:
            material.roughness.contents = 0.12
            material.clearCoat.contents = 0.6
            material.clearCoatRoughness.contents = 0.1
            material.isDoubleSided = true
        case .glow:
            material.emission.contents = color.with(alpha: 1).nsColor
            material.emission.intensity = 0.7
            material.roughness.contents = 0.6
        case .matte:
            material.roughness.contents = 0.95
        case .rubber:
            material.roughness.contents = 0.82
        }
        // The see-through amount itself is set on the node (see Scene3DController.addNode):
        // material transparency leaves reflections at full strength, which made
        // "20% opaque" casings look solid.
        if opacity < 0.999 { material.writesToDepthBuffer = false }
        return material
    }

    // MARK: Textures

    private static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        return context.makeImage()
    }

    /// A soft studio: bright sky, warm horizon, darker floor and one big softbox. Gives metals something to reflect.
    static let environmentImage: CGImage? = bitmap(width: 512, height: 256) { context in
        let colors = [
            CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1), CGColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1),
            CGColor(red: 0.80, green: 0.78, blue: 0.74, alpha: 1), CGColor(red: 0.42, green: 0.41, blue: 0.42, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 0.42, 0.55, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 256), end: CGPoint(x: 0, y: 0), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.95), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 150, y: 200), startRadius: 0, endCenter: CGPoint(x: 150, y: 200), endRadius: 90, options: [])
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 180), startRadius: 0, endCenter: CGPoint(x: 400, y: 180), endRadius: 55, options: [])
    }

    static let shadowImage: CGImage? = bitmap(width: 256, height: 256) { context in
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0.20), CGColor(red: 0, green: 0, blue: 0, alpha: 0.07), CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                                  locations: [0, 0.5, 1])!
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: 128, y: 128), startRadius: 0, endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
    }

    private static func drawText(in context: CGContext, _ body: () -> Void) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A cream pill with handwritten text and an optional numbered dot. Returns the image and its width ÷ height.
    static func chipImage(text: String, number: Int?, accent: SceneColor) -> (CGImage?, CGFloat) {
        let scale: CGFloat = 3
        let font = SceneStyle.markerNSFont(22 * scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: SceneColor.ink.nsColor]
        let label = NSAttributedString(string: text, attributes: attributes)
        let textSize = label.size()
        let height = 40 * scale
        let dot = number == nil ? 0 : 28 * scale
        let padding = 14 * scale
        let width = textSize.width + padding * 2 + (number == nil ? 0 : dot + 6 * scale)
        let image = bitmap(width: Int(width.rounded(.up)), height: Int(height)) { context in
            let rect = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 2 * scale, dy: 2 * scale)
            let pill = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
            context.addPath(pill)
            context.setFillColor(CGColor(red: 1.0, green: 0.992, blue: 0.955, alpha: 0.97))
            context.fillPath()
            context.addPath(pill)
            context.setStrokeColor(SceneColor.ink.nsColor.cgColor)
            context.setLineWidth(1.6 * scale)
            context.strokePath()
            var textX = padding
            if let number {
                let circle = CGRect(x: 6 * scale, y: (height - dot) / 2, width: dot, height: dot)
                // A pale part (white, cream, silver) would give a dot nobody can read the number on.
                let luminance = 0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b
                let dotColor = luminance > 0.72 ? SceneColor.ink : accent
                context.setFillColor(dotColor.with(alpha: 1).nsColor.cgColor)
                context.fillEllipse(in: circle)
                drawText(in: context) {
                    let digits = NSAttributedString(string: "\(number)", attributes: [.font: NSFont.systemFont(ofSize: 16 * scale, weight: .bold), .foregroundColor: NSColor.white])
                    let size = digits.size()
                    digits.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
                }
                textX = circle.maxX + 7 * scale
            }
            drawText(in: context) {
                label.draw(at: CGPoint(x: textX, y: (height - textSize.height) / 2))
            }
        }
        return (image, width / height)
    }

    static func textImage(_ text: String, color: SceneColor) -> (CGImage?, CGFloat) {
        let scale: CGFloat = 3
        let label = NSAttributedString(string: text, attributes: [.font: SceneStyle.markerNSFont(26 * scale), .foregroundColor: color.with(alpha: 1).nsColor])
        let size = label.size()
        let width = size.width + 8 * scale, height = size.height + 4 * scale
        let image = bitmap(width: Int(width.rounded(.up)), height: Int(height.rounded(.up))) { context in
            drawText(in: context) { label.draw(at: CGPoint(x: 4 * scale, y: 2 * scale)) }
        }
        return (image, width / max(height, 1))
    }
}

// MARK: - SwiftUI

private struct Scene3DRepresentable: NSViewRepresentable {
    let view: Scene3DSCNView
    func makeNSView(context: Context) -> Scene3DSCNView { view }
    func updateNSView(_ nsView: Scene3DSCNView, context: Context) {}
}

/// Dragging this moves the window (the 3D view itself uses drags to turn the model).
private struct SceneWindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}

/// The name of the model, on a small floating pill at its top left.
private struct Scene3DTitleTile: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DS.Fonts.title)
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .teachyTile(cornerRadius: DS.CornerRadius.pill)
    }
}

struct Scene3DView: View {
    @ObservedObject var model: Scene3DModel
    let controller: Scene3DController
    var onChipTapped: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    static let viewSize = CGSize(width: 640, height: 470)

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                Scene3DRepresentable(view: controller.view)
                HStack(alignment: .top) {
                    if !model.title.isEmpty {
                        Scene3DTitleTile(title: model.title)
                            .overlay(SceneWindowDragHandle())
                    }
                    Spacer()
                    if model.canRecenter {
                        // The view is zoomed on a part or was turned by hand: one click back to the whole model.
                        Button(action: { controller.recenter() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "scope")
                                    .font(DS.Fonts.sans(10, weight: .semibold))
                                Text("Recenter")
                            }
                        }
                        .teachyButton(.quiet, size: .compact)
                        // Like the close button beside it: its own glass capsule, because the model floats over the screen.
                        .teachyTile(cornerRadius: DS.CornerRadius.pill)
                        .help("Show the whole model again (Esc)")
                        .transition(.opacity)
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .teachyIconButton(sideLength: 22)
                    // The model floats over whatever is on screen, so the button sits on its own round tile.
                    .teachyTile(cornerRadius: DS.CornerRadius.pill)
                }
                .padding(10)
            }
            .frame(width: Self.viewSize.width, height: Self.viewSize.height)

            Scene3DChrome(model: model, controller: controller, onChipTapped: onChipTapped)
        }
        .frame(width: Self.viewSize.width)
    }
}

/// Sliders, plots and chips under the model. Separate so a snapshot can render it without the SceneKit view.
struct Scene3DChrome: View {
    @ObservedObject var model: Scene3DModel
    let controller: Scene3DController?
    var onChipTapped: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            if !model.sliders.isEmpty || !model.plots.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.sliders) { slider in
                        HStack(spacing: 10) {
                            Text(slider.label)
                                .font(DS.Fonts.bodyEmphasized)
                                .foregroundColor(DS.Colors.textPrimary)
                                .frame(width: 110, alignment: .leading)
                            TeachySlider(value: Binding(get: { slider.value }, set: { controller?.setSlider(slider.id, value: $0, fromUser: true) }),
                                         in: slider.minimum...slider.maximum)
                            Text(Self.format(slider.value) + slider.unit)
                                .font(DS.Fonts.data)
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(width: 58, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    ForEach(model.plots) { plot in
                        Scene3DPlotView(plot: plot)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(width: 460)
                .teachyTile(cornerRadius: DS.CornerRadius.group)
            }
            if !model.chips.isEmpty {
                // The follow-ups float over the screen too, so they sit on their own tile.
                SceneChipRow(chips: model.chips, onTap: onChipTapped)
                    .padding(8)
                    .teachyTile(cornerRadius: DS.CornerRadius.group)
                    .frame(maxWidth: 560)
            }
        }
        .padding(.bottom, 10)
    }

    static func format(_ value: Double) -> String {
        abs(value) >= 100 ? String(format: "%.0f", value) : (abs(value) >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value))
    }
}

struct Scene3DPlotView: View {
    var plot: Scene3DModel.PlotState

    var body: some View {
        HStack(spacing: 10) {
            Text(plot.label)
                .font(DS.Fonts.bodyEmphasized)
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 110, alignment: .leading)
            Canvas { context, size in
                let samples = plot.samples
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: size.height / 2))
                axis.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(axis, with: .color(DS.Colors.hairlineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                guard samples.count > 1 else { return }
                let extent = max(samples.map { abs($0) }.max() ?? 1, 1e-6)
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(200 - 1, 1))
                    let y = size.height / 2 - CGFloat(sample / extent) * (size.height / 2 - 4)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(plot.color.color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                if let last = samples.last {
                    let x = size.width * CGFloat(samples.count - 1) / 199
                    let y = size.height / 2 - CGFloat(last / extent) * (size.height / 2 - 4)
                    context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(plot.color.color))
                }
            }
            .frame(height: 54)
            Text((plot.samples.last.map { Scene3DChrome.format($0) } ?? "–") + plot.unit)
                .font(DS.Fonts.data)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 58, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

// MARK: - Window

/// A borderless, transparent window: the model floats over whatever is on screen.
@MainActor
final class Scene3DWindow {
    let controller: Scene3DController
    var onChipTapped: ((String) -> Void)?
    var onClosed: (() -> Void)?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<Scene3DView>?

    /// Headless: the model is built and rendered in-process and no window is ever shown.
    let isHeadless: Bool

    init(headless: Bool = false) {
        isHeadless = headless
        controller = Scene3DController(headless: headless)
        controller.view.frame = CGRect(origin: .zero, size: Scene3DView.viewSize)
        controller.model.onLayoutChanged = { [weak self] in
            DispatchQueue.main.async { self?.resize() }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    func show(topLeft: CGPoint) {
        guard !isHeadless else { return }
        if panel == nil {
            let panel = SceneFloatingPanel(
                contentRect: CGRect(origin: .zero, size: Scene3DView.viewSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let root = Scene3DView(model: controller.model, controller: controller,
                                   onChipTapped: { [weak self] in self?.onChipTapped?($0) },
                                   onClose: { [weak self] in self?.close(); self?.onClosed?() })
            let hosting = NSHostingView(rootView: root)
            panel.contentView = hosting
            hostingView = hosting
            self.panel = panel
            panel.setFrameTopLeftPoint(topLeft)
        }
        resize()
        panel?.orderFrontRegardless()
    }

    func close() {
        controller.stop()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func resize() {
        guard let panel, let hostingView else { return }
        let fitting = hostingView.fittingSize
        let top = panel.frame.maxY
        let frame = CGRect(x: panel.frame.minX, y: top - fitting.height, width: Scene3DView.viewSize.width, height: max(fitting.height, Scene3DView.viewSize.height))
        if abs(frame.height - panel.frame.height) > 0.5 { panel.setFrame(frame, display: true) }
    }

    /// The model and its controls drawn over a backdrop, without needing screen-recording permission.
    func snapshot(backdrop: NSColor = NSColor(calibratedWhite: 0.94, alpha: 1)) -> NSImage? {
        let scale: CGFloat = 2
        let model3D = controller.snapshot()
        let chromeRenderer = ImageRenderer(content: Scene3DChrome(model: controller.model, controller: nil).frame(width: Scene3DView.viewSize.width)
            .environment(\.teachyIsDrawnIntoPicture, true))
        chromeRenderer.scale = scale
        let chrome = chromeRenderer.nsImage
        let titleRenderer = ImageRenderer(content: Scene3DTitleTile(title: controller.model.title).environment(\.teachyIsDrawnIntoPicture, true))
        titleRenderer.scale = scale
        let chromeHeight = chrome?.size.height ?? 0
        let size = CGSize(width: Scene3DView.viewSize.width, height: Scene3DView.viewSize.height + chromeHeight)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = { bitmap.size = size; return NSGraphicsContext(bitmapImageRep: bitmap) }() else { return nil }
        let image = NSImage(size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        backdrop.setFill()
        CGRect(origin: .zero, size: size).fill()
        model3D.draw(in: CGRect(x: 0, y: chromeHeight, width: Scene3DView.viewSize.width, height: Scene3DView.viewSize.height))
        chrome?.draw(in: CGRect(x: 0, y: 0, width: size.width, height: chromeHeight))
        if !controller.model.title.isEmpty, let title = titleRenderer.nsImage {
            title.draw(in: CGRect(x: 10, y: size.height - 10 - title.size.height, width: title.size.width, height: title.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        return image
    }
}
