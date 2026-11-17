// Compact job controls on the trailing edge of the desktop. Only the square buttons
// receive pointer events. The larger hover preview is a separate click-through panel.
import AppKit
import SwiftUI

enum AgentRailAccent: Int, CaseIterable {
    case lilac, mint, apricot, sky, rose, lemon

    var color: Color {
        switch self {
        case .lilac: Color(red: 0.76, green: 0.69, blue: 1)
        case .mint: Color(red: 0.57, green: 0.90, blue: 0.75)
        case .apricot: Color(red: 1, green: 0.73, blue: 0.53)
        case .sky: Color(red: 0.56, green: 0.81, blue: 1)
        case .rose: Color(red: 1, green: 0.65, blue: 0.76)
        case .lemon: Color(red: 0.95, green: 0.87, blue: 0.52)
        }
    }
}

struct AgentRailSquare: View {
    let job: AgentJobCardModel
    let accent: AgentRailAccent
    let selected: Bool
    let click: () -> Void
    let hover: (Bool) -> Void

    private var symbol: String {
        switch job.status {
        case .queued: "clock"
        case .planning: "ellipsis"
        case .running: job.isDriving ? "cursorarrow" : "waveform"
        case .waitingForConsent: "hand.raised.fill"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .stopped: "stop.fill"
        }
    }

    var body: some View {
        Button(action: click) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.color.gradient)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.76))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.98 : 0.4), lineWidth: selected ? 2 : 1)
            }
            .frame(width: 26, height: 26)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(job.title), \(job.status.label)")
        .accessibilityValue(job.plan.currentStep?.text ?? job.activity)
        .accessibilityHint("Show or hide job details")
    }
}

/// The rail also works while another app owns keyboard focus.
final class AgentRailButtonHost: NSHostingView<AgentRailSquare> {
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        super.updateTrackingAreas()
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === pointerTracking { rootView.hover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === pointerTracking { rootView.hover(false) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct AgentRailPreview: View {
    let job: AgentJobCardModel
    let accent: AgentRailAccent

    private var detail: String {
        if case .failed(let reason) = job.status { return reason }
        if case .stopped(let reason) = job.status { return reason }
        if job.status == .done { return job.answer }
        return job.plan.currentStep?.text ?? job.activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(accent.color).frame(width: 8, height: 8)
                Text(job.agentName ?? "Teachy").lineLimit(1)
                Spacer(minLength: 8)
                Text(job.status.label)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.78))
            Text(job.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
            }
            if !job.plan.steps.isEmpty {
                HStack(spacing: 3) {
                    ForEach(job.plan.steps) { step in
                        Capsule().fill(step.state == .done ? accent.color : step.state == .current ? accent.color.opacity(0.68) : .white.opacity(0.16))
                            .frame(height: 3)
                    }
                }
                .padding(.top, 2)
                .accessibilityLabel("\(job.plan.steps.filter { $0.state == .done }.count) of \(job.plan.steps.count) steps complete")
            }
        }
        .padding(13)
        .frame(width: 232, alignment: .leading)
        .foregroundStyle(.white)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.12)))
    }
}

@MainActor
final class AgentSideRail {
    private var panels: [String: NSPanel] = [:]
    private var colors: [String: AgentRailAccent] = [:]
    private var models: [String: AgentJobCardModel] = [:]
    private var selectedID: String?
    private(set) var hoveredID: String?
    private var preview: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var ids: [String] = []
    var onSelect: ((String) -> Void)?

    func update(_ jobs: [AgentJobCardModel], selected: String?) {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
        }
        let nextIDs = jobs.map(\.id)
        let membershipChanged = ids != nextIDs
        ids = nextIDs
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.orderOut(nil)
            colors[id] = nil
            models[id] = nil
            if hoveredID == id { hidePreview() }
        }
        let oldSelection = selectedID
        selectedID = selected
        for job in jobs {
            if colors[job.id] == nil {
                // Allocate different tints before reusing one; existing jobs keep theirs.
                let counts = Dictionary(grouping: colors.values, by: { $0 }).mapValues(\.count)
                colors[job.id] = AgentRailAccent.allCases.min { counts[$0, default: 0] < counts[$1, default: 0] }
            }
            let panel = panels[job.id] ?? AgentNotchLayout.makePanel(size: NSSize(width: 32, height: 32), acceptsClicks: true)
            let selectionChanged = oldSelection != selected && (job.id == oldSelection || job.id == selected)
            if models[job.id] != job || selectionChanged {
                models[job.id] = job
                let square = AgentRailSquare(job: job, accent: colors[job.id] ?? .lilac, selected: selected == job.id, click: { [weak self] in
                    self?.hidePreview()
                    self?.onSelect?(job.id)
                }, hover: { [weak self] inside in
                    if inside { self?.showPreview(for: job.id) }
                    else if self?.hoveredID == job.id { self?.hidePreview() }
                })
                if let hosting = panel.contentView as? AgentRailButtonHost { hosting.rootView = square }
                else { panel.contentView = AgentRailButtonHost(rootView: square) }
                if hoveredID == job.id { showPreview(for: job.id) }
            }
            panels[job.id] = panel
        }
        if membershipChanged { layout() }
    }

    private func layout() {
        guard !ids.isEmpty,
              let screen = ids.compactMap({ panels[$0] }).first(where: { $0.isVisible })?.screen ?? AgentNotchLayout.screenUnderPointer() else { return }
        let bounds = screen.visibleFrame
        let capacity = max(1, Int((bounds.height - 24) / 34))
        for (index, id) in ids.enumerated() {
            guard let panel = panels[id] else { continue }
            let column = index / capacity
            let count = min(capacity, ids.count - column * capacity)
            let top = bounds.midY + CGFloat(count) * 17
            let origin = CGPoint(x: bounds.maxX - 40 - CGFloat(column) * 34, y: top - CGFloat(index % capacity) * 34 - 32)
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
        }
        if let hoveredID { showPreview(for: hoveredID) }
    }

    private func showPreview(for id: String) {
        guard let job = models[id], let square = panels[id], let screen = square.screen else { return }
        hoveredID = id
        let panel = preview ?? AgentNotchLayout.makePanel(size: NSSize(width: 232, height: 100), acceptsClicks: false)
        preview = panel
        let view = AgentRailPreview(job: job, accent: colors[id] ?? .lilac)
        let hosting: NSHostingView<AgentRailPreview>
        if let existing = panel.contentView as? NSHostingView<AgentRailPreview> {
            existing.rootView = view
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
        }
        let size = hosting.fittingSize
        let bounds = screen.visibleFrame
        let origin = CGPoint(x: max(bounds.minX, square.frame.minX - size.width - 6),
                             y: max(bounds.minY, min(square.frame.midY - size.height / 2, bounds.maxY - size.height)))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func hidePreview() { hoveredID = nil; preview?.orderOut(nil) }
}
