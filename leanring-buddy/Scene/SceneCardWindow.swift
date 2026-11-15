//
//  SceneCardWindow.swift
//  leanring-buddy / Scene
//
//  Explainer cards: a small floating tile with text, a formula, step chains,
//  charts, photos and follow-up questions. Lines appear one at a time as the
//  script streams in.
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
        /// Where the photo is from, for the small caption under it.
        var sourceURL: URL?
        var sourceName: String?
    }

    @Published var title = ""
    @Published private(set) var items: [Item] = []
    @Published private(set) var chips: [String] = []

    var onChipTapped: ((String) -> Void)?
    var imageFetcher: ((String) async -> NSImage?)?
    var photoFetcher: ((String) async -> ScenePhoto?)?
    /// Called after content changes so the window can grow to fit.
    var onContentChanged: (() -> Void)?
    /// Goes up whenever what the card shows changes (the video exporter redraws a card only then).
    private(set) var revision = 0
    /// Photos still being fetched.
    private(set) var pendingPhotos = 0

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
        revision += 1
        onContentChanged?()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        revision += 1
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
        // The photo is fetched on its own task: the card keeps filling in while it loads.
        if let photoFetcher {
            pendingPhotos += 1
            Task { [weak self] in
                let photo = await photoFetcher(query)
                self?.pendingPhotos -= 1
                self?.markImage(id: id, image: photo?.image, sourceURL: photo?.sourceURL, sourceName: photo?.sourceName)
            }
            return
        }
        guard let imageFetcher else {
            markImage(id: id, image: nil)
            return
        }
        Task { [weak self] in
            let image = await imageFetcher(query)
            self?.markImage(id: id, image: image)
        }
    }

    private func markImage(id: String, image: NSImage?, sourceURL: URL? = nil, sourceName: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].image = image
        items[index].imageFailed = image == nil
        items[index].sourceURL = sourceURL
        items[index].sourceName = sourceName
        revision += 1
        onContentChanged?()
    }
}

// MARK: - View

/// What the card is written with. The script's colours were picked for pale
/// paper, so one too dark to read on the dark tile (navy, black, "ink") is
/// written in the primary text colour instead.
private enum SceneCardWriting {
    private static let darkestReadableLuminance = 0.32

    static func color(for contentColor: SceneColor?) -> Color {
        guard let contentColor else { return DS.Colors.textPrimary }
        let relativeLuminance = 0.2126 * contentColor.r + 0.7152 * contentColor.g + 0.0722 * contentColor.b
        return relativeLuminance < darkestReadableLuminance ? DS.Colors.textPrimary : contentColor.color
    }
}

struct SceneCardView: View {
    @ObservedObject var model: SceneCardModel
    static let width: CGFloat = 400
    /// The window is never shorter than this, so the tile is not either: the
    /// window draws nothing of its own to fill a gap.
    static let minimumHeight: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.title.isEmpty {
                Text(model.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.items) { item in
                row(item)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            if !model.chips.isEmpty {
                TeachyRule()
                    .padding(.top, 2)
                SceneChipRow(chips: model.chips) { model.onChipTapped?($0) }
            }
        }
        .padding(EdgeInsets(top: 34, leading: 22, bottom: 20, trailing: 22))
        .frame(width: Self.width, alignment: .leading)
        .frame(minHeight: Self.minimumHeight, alignment: .top)
        .teachyTile()
    }

    @ViewBuilder
    private func row(_ item: SceneCardModel.Item) -> some View {
        let writingColor = SceneCardWriting.color(for: item.color)
        switch item.kind {
        case .text:
            Text(item.text)
                .font(DS.Fonts.voice)
                .lineSpacing(3)
                .foregroundColor(writingColor)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(DS.Colors.textTertiary).frame(width: 4, height: 4).offset(y: -2.5)
                Text(item.text)
                    .font(DS.Fonts.voice)
                    .lineSpacing(3)
                    .foregroundColor(writingColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .formula:
            Text(item.text)
                .font(DS.Fonts.title)
                .foregroundColor(writingColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .teachyWell(cornerRadius: DS.CornerRadius.control)
        case .steps(let steps):
            SceneFlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if index > 0 {
                            Image(systemName: "arrow.right").font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
                        }
                        Text("\(index + 1)").font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
                        Text(step).font(DS.Fonts.itemTitle).foregroundColor(DS.Colors.textPrimary)
                    }
                }
            }
        case .chart(let spec):
            SceneCardChart(spec: spec, namedColor: item.color)
        case .image(let query):
            SceneCardImage(image: item.image, failed: item.imageFailed, query: query, caption: item.text, seed: item.id,
                           sourceURL: item.sourceURL, sourceName: item.sourceName)
        }
    }
}

/// The follow-up questions under a card or a model. Picking one asks it.
struct SceneChipRow: View {
    var chips: [String]
    var onTap: (String) -> Void

    /// The follow-up the person picked. It stays marked as chosen while Teachy answers.
    @State private var pickedChip: String?
    @Environment(\.teachyIsDrawnIntoPicture) private var isDrawnIntoPicture

    var body: some View {
        SceneFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(chips, id: \.self) { chip in
                Button {
                    pickedChip = chip
                    onTap(chip)
                } label: {
                    Text(chip)
                        .font(DS.Fonts.bodyEmphasized)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .teachyOption(isSelected: pickedChip == chip)
                // The cursor is an AppKit view, which a picture cannot draw.
                .pointerCursor(isEnabled: !isDrawnIntoPicture)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

struct SceneCardChart: View {
    var spec: SceneCardModel.ChartSpec
    /// The colour the script asked for, or nil when it left the choice to the card.
    var namedColor: SceneColor?

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

    /// Marks are drawn in the pointer colour (Teachy's one tint) unless the script named a colour.
    private var markColor: Color {
        guard let namedColor else { return DS.Colors.pointer }
        return SceneCardWriting.color(for: namedColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(DS.Fonts.itemTitle)
                    .foregroundColor(DS.Colors.textPrimary)
            }
            Chart(points) { point in
                switch spec.kind {
                case "line", "area":
                    LineMark(x: .value("x", point.label), y: .value("y", point.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(markColor)
                    PointMark(x: .value("x", point.label), y: .value("y", point.value))
                        .symbolSize(46)
                        .foregroundStyle(markColor)
                case "point", "scatter":
                    PointMark(x: .value("x", point.label), y: .value("y", point.value))
                        .symbolSize(70)
                        .foregroundStyle(markColor)
                default:
                    BarMark(x: .value("x", point.label), y: .value("y", point.value), width: .ratio(0.62))
                        .cornerRadius(4)
                        .foregroundStyle(markColor)
                        .annotation(position: .top, spacing: 2) {
                            if points.count <= 10 {
                                Text(Self.format(point.value)).font(DS.Fonts.data).foregroundColor(DS.Colors.textSecondary)
                            }
                        }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(DS.Fonts.data).foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(DS.Colors.hairlineStrong)
                    AxisValueLabel().font(DS.Fonts.data).foregroundStyle(DS.Colors.textTertiary)
                }
            }
            .chartXAxisLabel {
                Text(spec.xTitle ?? "").font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
            }
            .chartYAxisLabel {
                Text(spec.yTitle ?? "").font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
            }
            .frame(height: 170)
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
    var sourceURL: URL?
    var sourceName: String?

    @Environment(\.teachyIsDrawnIntoPicture) private var isDrawnIntoPicture

    private var photoShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Rectangle().fill(DS.Colors.fillTertiary).frame(height: 110)
                    VStack(spacing: 6) {
                        Image(systemName: failed ? "photo" : "photo.on.rectangle.angled")
                            .font(DS.Fonts.sans(20))
                            .foregroundColor(DS.Colors.textQuaternary)
                        Text(failed ? query : "Finding a photo of \(query)…")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .clipShape(photoShape)
            .overlay(photoShape.strokeBorder(DS.Colors.hairline, lineWidth: 1))
            if image != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !caption.isEmpty {
                        Text(caption).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 4)
                    if let sourceURL {
                        let sourceLabel = Text("Source: \(sourceName ?? sourceURL.host ?? "web")").lineLimit(1)
                        if isDrawnIntoPicture {
                            // Nothing in a picture can be clicked, and the link style
                            // carries an AppKit cursor view that a picture cannot draw.
                            sourceLabel
                                .font(DS.Fonts.data)
                                .foregroundColor(DS.Colors.pointer)
                        } else {
                            Button { NSWorkspace.shared.open(sourceURL) } label: { sourceLabel }
                                .teachyLinkButton(font: DS.Fonts.data)
                                .help(sourceURL.absoluteString)
                        }
                    }
                }
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
    /// Headless: the card is only a model that `snapshot()` draws; no window is opened.
    var isHeadless = false

    init() {
        model.onContentChanged = { [weak self] in self?.scheduleResize() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    /// Shows the card with its top-left corner at `topLeft` (AppKit screen coordinates).
    func show(topLeft: CGPoint) {
        guard !isHeadless else { return }
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
            // The window itself draws nothing: the card's tile is the only surface,
            // so whatever the tile is made of shows what is behind the window.
            panel.isOpaque = false
            panel.backgroundColor = .clear
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
        let height = min(max(fitting.height, SceneCardView.minimumHeight), visible - 60)
        let top = panel.frame.maxY
        let frame = CGRect(x: panel.frame.minX, y: top - height, width: SceneCardView.width, height: height)
        if abs(frame.height - panel.frame.height) > 0.5 || abs(frame.width - panel.frame.width) > 0.5 {
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    func snapshot() -> NSImage? {
        let renderer = ImageRenderer(content: SceneCardView(model: model).environment(\.teachyIsDrawnIntoPicture, true))
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// A panel that can take clicks (sliders, chips) without activating the app.
final class SceneFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
