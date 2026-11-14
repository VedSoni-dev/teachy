//
//  SceneCardWindow.swift
//  leanring-buddy / Scene
//
//  Explainer cards: a small floating window of cream grid paper with handwritten
//  text, formula boxes, step chains, charts, photos and follow-up chips. Lines
//  appear one at a time as the script streams in.
//

import AppKit
import Charts
import Combine
import SwiftUI

// MARK: - Model

@MainActor
final class SceneCardModel: ObservableObject {
    struct ChartSpec: Equatable {
        var kind: String
        var values: [Double]
        var labels: [String]
        var title: String?
        var color: SceneColor
        var xTitle: String?
        var yTitle: String?
    }

    enum Kind: Equatable {
        case text, bullet, formula
        case steps([String])
        case chart(ChartSpec)
        case image(query: String)
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var kind: Kind
        var text: String
        var color: SceneColor?
        var image: NSImage?
        var imageFailed = false
    }

    @Published var title = ""
    @Published private(set) var items: [Item] = []
    @Published private(set) var chips: [String] = []

    var onChipTapped: ((String) -> Void)?
    var imageFetcher: ((String) async -> NSImage?)?
    /// Called after content changes so the window can grow to fit.
    var onContentChanged: (() -> Void)?

    func apply(_ c: SceneCommand) {
        switch c.verb {
        case .card:
            title = c.string("title") ?? c.freeText ?? title
        case .text:
            upsert(Item(id: c.id, kind: .text, text: c.freeText ?? "", color: c.color()))
        case .bullet:
            upsert(Item(id: c.id, kind: .bullet, text: c.freeText ?? "", color: c.color()))
        case .formula:
            upsert(Item(id: c.id, kind: .formula, text: c.freeText ?? "", color: c.color()))
        case .steps:
            upsert(Item(id: c.id, kind: .steps(Array(c.textItems().prefix(8))), text: "", color: c.color()))
        case .chart:
            let values = Array(c.numbers("data").prefix(60))
            var labels = (c.string("labels") ?? "").split(whereSeparator: { $0 == "|" || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
            if labels.count < values.count, let raw = c.string("labels"), !raw.contains("|"), raw.contains(",") {
                labels = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let spec = ChartSpec(kind: (c.string("type") ?? "bar").lowercased(), values: values, labels: labels, title: c.string("title"),
                                 color: c.color() ?? SceneColor.named["blue"]!, xTitle: c.string("x", "xlabel"), yTitle: c.string("y", "ylabel", "unit"))
            upsert(Item(id: c.id, kind: .chart(spec), text: c.string("title") ?? "", color: c.color()))
        case .image:
            let query = c.string("query") ?? c.freeText ?? ""
            upsert(Item(id: c.id, kind: .image(query: query), text: c.string("caption") ?? query, color: nil))
            loadImage(id: c.id, query: query)
        case .chip:
            if let text = c.freeText, !chips.contains(text), chips.count < 4 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { chips.append(text) }
            }
        default:
            break
        }
        onContentChanged?()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        onContentChanged?()
    }

    func reset() {
        title = ""
        items = []
        chips = []
    }

    private func upsert(_ item: Item) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        }
    }

    private func loadImage(id: String, query: String) {
        guard let imageFetcher else {
            markImage(id: id, image: nil)
            return
        }
        Task { [weak self] in
            let image = await imageFetcher(query)
            self?.markImage(id: id, image: image)
        }
    }

    private func markImage(id: String, image: NSImage?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].image = image
        items[index].imageFailed = image == nil
        onContentChanged?()
    }
}

// MARK: - View

struct SceneGridPaper: View {
    var spacing: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SceneStyle.paper))
            var lines = Path()
            var x = spacing
            while x < size.width {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = spacing
            while y < size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(lines, with: .color(SceneStyle.paperLine), lineWidth: 0.6)
        }
    }
}

struct SceneCardView: View {
    @ObservedObject var model: SceneCardModel
    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(SceneStyle.marker(27))
                        .foregroundColor(SceneStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    SceneScribbleUnderline(seed: model.title)
                        .stroke(SceneColor.marker.color.opacity(0.85), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                        .frame(height: 7)
                        .frame(maxWidth: min(CGFloat(model.title.count) * 13 + 20, Self.width - 60))
                }
            }
            ForEach(model.items) { item in
                row(item)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            if !model.chips.isEmpty {
                SceneChipRow(chips: model.chips) { model.onChipTapped?($0) }
                    .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 22, bottom: 20, trailing: 22))
        .frame(width: Self.width, alignment: .leading)
        .background(SceneGridPaper())
    }

    @ViewBuilder
    private func row(_ item: SceneCardModel.Item) -> some View {
        let ink = item.color?.color ?? SceneStyle.ink
        switch item.kind {
        case .text:
            Text(item.text)
                .font(SceneStyle.body(18))
                .foregroundColor(ink)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(SceneColor.marker.color).frame(width: 7, height: 7).offset(y: -3)
                Text(item.text)
                    .font(SceneStyle.body(18))
                    .foregroundColor(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .formula:
            Text(item.text)
                .font(SceneStyle.marker(23))
                .foregroundColor(ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.55))
                .overlay(SceneRoughBox(seed: item.id).stroke(SceneStyle.ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round)))
        case .steps(let steps):
            SceneFlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 6) {
                        if index > 0 {
                            Text("→").font(SceneStyle.marker(20)).foregroundColor(SceneColor.marker.color)
                        }
                        Text(step)
                            .font(SceneStyle.body(16))
                            .foregroundColor(SceneStyle.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(SceneColor.palette[index % SceneColor.palette.count].color.opacity(0.16))
                            .overlay(SceneRoughBox(seed: "\(item.id)-\(index)", roughness: 0.6)
                                .stroke(SceneStyle.ink.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)))
                    }
                }
            }
        case .chart(let spec):
            SceneCardChart(spec: spec)
        case .image(let query):
            SceneCardImage(image: item.image, failed: item.imageFailed, query: query, caption: item.text, seed: item.id)
        }
    }
}

/// A quick wavy underline.
struct SceneScribbleUnderline: Shape {
    var seed: String

    func path(in rect: CGRect) -> Path {
        var rng = SceneRNG(id: seed)
        let strokes = SceneRough.line(SceneVec2(rect.minX + 1, rect.midY), SceneVec2(rect.maxX - 1, rect.midY + 1), rng: &rng, roughness: 1.2, passes: 2)
        var combined = Path()
        for path in SceneRoughPath.paths(strokes) { combined.addPath(path) }
        return combined
    }
}

struct SceneChipRow: View {
    var chips: [String]
    var onTap: (String) -> Void

    var body: some View {
        SceneFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(chips, id: \.self) { chip in
                Button { onTap(chip) } label: {
                    Text(chip)
                        .font(SceneStyle.body(15))
                        .foregroundColor(SceneStyle.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.9)))
                        .overlay(Capsule().stroke(SceneStyle.ink.opacity(0.55), lineWidth: 1.2))
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

struct SceneCardChart: View {
    var spec: SceneCardModel.ChartSpec

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let value: Double
    }

    private var points: [Point] {
        spec.values.enumerated().map { index, value in
            Point(id: index, label: index < spec.labels.count ? spec.labels[index] : "\(index + 1)", value: value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(SceneStyle.marker(17)).foregroundColor(SceneStyle.ink)
            }
            Chart(points) { point in
                switch spec.kind {
                case "line", "area":
                    LineMark(x: .value("x", point.label), y: .value("y", point.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(spec.color.color)
                    PointMark(x: .value("x", point.label), y: .value("y", point.value))
                        .symbolSize(46)
                        .foregroundStyle(spec.color.color)
                case "point", "scatter":
                    PointMark(x: .value("x", point.label), y: .value("y", point.value))
                        .symbolSize(70)
                        .foregroundStyle(spec.color.color)
                default:
                    BarMark(x: .value("x", point.label), y: .value("y", point.value), width: .ratio(0.62))
                        .cornerRadius(4)
                        .foregroundStyle(SceneColor.palette[point.id % SceneColor.palette.count].color.opacity(0.85))
                        .annotation(position: .top, spacing: 2) {
                            if points.count <= 10 {
                                Text(Self.format(point.value)).font(SceneStyle.body(11)).foregroundColor(SceneStyle.ink.opacity(0.8))
                            }
                        }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(SceneStyle.body(points.count > 7 ? 10 : 12)).foregroundStyle(SceneStyle.ink)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8, dash: [3, 3])).foregroundStyle(SceneStyle.ink.opacity(0.25))
                    AxisValueLabel().font(SceneStyle.body(11)).foregroundStyle(SceneStyle.ink.opacity(0.8))
                }
            }
            .chartXAxisLabel(spec.xTitle ?? "")
            .chartYAxisLabel(spec.yTitle ?? "")
            .frame(height: 170)
            .padding(10)
            .background(Color.white.opacity(0.5))
            .overlay(SceneRoughBox(seed: spec.title ?? "chart", roughness: 0.6).stroke(SceneStyle.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)))
        }
    }

    static func format(_ value: Double) -> String {
        if abs(value) >= 1000 { return String(format: "%.0f", value) }
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

struct SceneCardImage: View {
    var image: NSImage?
    var failed: Bool
    var query: String
    var caption: String
    var seed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Rectangle().fill(Color.white.opacity(0.5)).frame(height: 110)
                    VStack(spacing: 4) {
                        Image(systemName: failed ? "photo" : "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                            .foregroundColor(SceneStyle.ink.opacity(0.45))
                        Text(failed ? query : "Finding a photo of \(query)…")
                            .font(SceneStyle.body(13))
                            .foregroundColor(SceneStyle.ink.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .overlay(SceneRoughBox(seed: seed, roughness: 0.6).stroke(SceneStyle.ink.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, lineCap: .round)))
            .rotationEffect(.degrees(image == nil ? 0 : -0.8))
            if image != nil, !caption.isEmpty {
                Text(caption).font(SceneStyle.body(13)).foregroundColor(SceneStyle.ink.opacity(0.7))
            }
        }
    }
}

/// Lays children out left to right and wraps to the next line.
struct SceneFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in zip(row.indices, row.offsets) {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var offsets: [CGFloat] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var y: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + lineSpacing)
            }
            let x = current.indices.isEmpty ? 0 : current.width + spacing
            current.indices.append(index)
            current.offsets.append(x)
            current.width = x + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Window

/// A floating, draggable card that never takes focus from the app the person is using.
@MainActor
final class SceneCardWindow {
    let model = SceneCardModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<SceneCardView>?
    private var resizeScheduled = false

    init() {
        model.onContentChanged = { [weak self] in self?.scheduleResize() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    /// Shows the card with its top-left corner at `topLeft` (AppKit screen coordinates).
    func show(topLeft: CGPoint) {
        if panel == nil {
            let panel = SceneFloatingPanel(
                contentRect: CGRect(x: 0, y: 0, width: SceneCardView.width, height: 120),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = NSColor(SceneStyle.paper)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            let hosting = NSHostingView(rootView: SceneCardView(model: model))
            panel.contentView = hosting
            hostingView = hosting
            self.panel = panel
        }
        resize()
        if let panel {
            panel.setFrameTopLeftPoint(topLeft)
            panel.orderFrontRegardless()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resize()
        }
    }

    /// Grows downward from the top edge as lines arrive.
    private func resize() {
        guard let panel, let hostingView else { return }
        let fitting = hostingView.fittingSize
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = min(max(fitting.height, 90), visible - 60)
        let top = panel.frame.maxY
        let frame = CGRect(x: panel.frame.minX, y: top - height, width: SceneCardView.width, height: height)
        if abs(frame.height - panel.frame.height) > 0.5 || abs(frame.width - panel.frame.width) > 0.5 {
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    func snapshot() -> NSImage? {
        let renderer = ImageRenderer(content: SceneCardView(model: model).clipShape(RoundedRectangle(cornerRadius: 12)))
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// A panel that can take clicks (sliders, chips) without activating the app.
final class SceneFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
