//
//  AgentJobPanelPresenter.swift
//  leanring-buddy
//
//  Presents the rail and the selected detail card, synchronized with the live
//  jobs in `AgentJobCenter`.
//
//  - One square per visible job. Clicking it selects its card under the notch.
//  - ← / → flip between cards while the pointer is over the stack (and the
//    little arrows on the card do the same with a click).
//  - A finished card shows its answer with Copy. After a while it folds to one
//    line, and later it leaves. Click a folded card to open it again.
//  - Hidden while a consent card is up (the question comes first).
//

import AppKit
import Combine
import SwiftUI

extension AgentJobCardModel {
    @MainActor
    init(job: AgentJob) {
        self.init(
            id: job.id,
            title: job.title,
            agentName: job.agentName,
            status: job.status,
            plan: job.plan,
            activity: job.activity,
            answer: job.answer,
            elapsed: job.elapsedDescription,
            isDriving: job.isDriving
        )
    }
}

/// One live job as a card (no stack). Kept for anyone who wants to show a single job.
struct AgentJobCardView: View {
    @ObservedObject var job: AgentJob

    var body: some View {
        AgentJobCard(model: AgentJobCardModel(job: job), actions: AgentJobCardActions(
            stop: { job.stop(reason: .stopButton) },
            copyAnswer: { AgentJobPanelPresenter.copy(job.answer) }
        ))
    }
}

@MainActor
private final class AgentCardStackModel: ObservableObject {
    @Published var deck = AgentCardDeck()
    @Published var copiedJobID: String?
    /// Bumped whenever a visible job changes, so the stack redraws.
    @Published var revision = 0
}

private struct AgentCardStackHost: View {
    @ObservedObject var model: AgentCardStackModel
    let presenter: AgentJobPanelPresenter

    var body: some View {
        Group {
            if let frontID = model.deck.frontID, let job = AgentJobCenter.shared.job(withID: frontID) {
                AgentJobCardStack(
                    front: AgentJobCardModel(job: job),
                    index: model.deck.frontIndex,
                    count: model.deck.count,
                    isCollapsed: model.deck.isCollapsed(frontID),
                    didCopy: model.copiedJobID == frontID,
                    actions: AgentJobCardActions(
                        stop: { job.stop(reason: .stopButton) },
                        copyAnswer: { presenter.copyAnswer(of: job) },
                        dismiss: { presenter.dismiss(jobID: frontID) },
                        expand: { presenter.expand(jobID: frontID) },
                        previous: { presenter.flip(by: -1) },
                        next: { presenter.flip(by: 1) }
                    )
                )
            }
        }
        .onHover { presenter.setHovering($0) }
    }
}

@MainActor
final class AgentJobPanelPresenter {
    static let shared = AgentJobPanelPresenter()
    static let cardWidth: CGFloat = AgentJobCardMetrics.width
    /// A finished card stays open this long, then folds to one line…
    static let collapseAfterSeconds: TimeInterval = 30
    /// …and leaves this long after that.
    static let dismissAfterSeconds: TimeInterval = 90

    private let model = AgentCardStackModel()
    private var selectedJobID: String?
    private lazy var rail: AgentSideRail = {
        let rail = AgentSideRail()
        rail.onSelect = { [weak self] id in self?.selectFromRail(id) }
        return rail
    }()

    private func selectFromRail(_ id: String) {
        selectedJobID = selectedJobID == id ? nil : id
        if selectedJobID != nil { model.deck.setCollapsed(false, id: id) }
        refresh()
    }

    private func updateRail() {
        let cards = model.deck.ids.compactMap { AgentJobCenter.shared.job(withID: $0) }.map { AgentJobCardModel(job: $0) }
        rail.update(cards, selected: selectedJobID)
    }
    private var panel: NSPanel?
    private var jobWatchers: [String: AnyCancellable] = [:]
    private var dismissed: Set<String> = []
    private var finishTimers: [String: Task<Void, Never>] = [:]
    private var isHovering = false
    private var keyMonitors: [Any] = []

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Keeping up with the jobs

    func refresh() {
        let center = AgentJobCenter.shared
        let visibleJobs = center.jobs.filter { $0.showsCard && !dismissed.contains($0.id) }
        dismissed.formIntersection(Set(center.jobs.map(\.id)))

        var deck = model.deck
        deck.sync(visible: visibleJobs.map(\.id), active: Set(visibleJobs.filter { !$0.status.isFinished }.map(\.id)))
        if let selectedJobID, let chosen = deck.ids.firstIndex(of: selectedJobID) {
            deck.flip(by: chosen - (deck.frontIndex - 1))
        } else {
            selectedJobID = nil
        }
        if deck != model.deck { model.deck = deck }
        updateRail()
        center.frontJobID = deck.frontID

        // Redraw and resize whenever a visible job changes.
        let visibleIDs = Set(visibleJobs.map(\.id))
        jobWatchers = jobWatchers.filter { visibleIDs.contains($0.key) }
        for job in visibleJobs where jobWatchers[job.id] == nil {
            jobWatchers[job.id] = job.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.model.revision += 1
                    self?.updateRail()
                    self?.resize()
                }
        }

        for job in visibleJobs {
            if job.status.isFinished {
                if finishTimers[job.id] == nil { startFinishTimer(jobID: job.id) }
            } else if let timer = finishTimers.removeValue(forKey: job.id) {
                // A follow-up woke it up again.
                timer.cancel()
                model.deck.setCollapsed(false, id: job.id)
            }
        }

        guard !visibleJobs.isEmpty else {
            hide()
            return
        }
        // The question card sits in the same place: let it have the spot.
        if selectedJobID == nil || visibleJobs.contains(where: { $0.status == .waitingForConsent }) {
            setHovering(false)
            panel?.orderOut(nil)
            return
        }
        show()
    }

    private func startFinishTimer(jobID: String) {
        finishTimers[jobID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.collapseAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.waitWhileHovering(jobID: jobID)
            guard !Task.isCancelled else { return }
            self.model.deck.setCollapsed(true, id: jobID)
            self.resize()
            try? await Task.sleep(nanoseconds: UInt64(Self.dismissAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.waitWhileHovering(jobID: jobID)
            guard !Task.isCancelled else { return }
            self.dismiss(jobID: jobID)
        }
    }

    /// Nothing folds or leaves under the pointer.
    private func waitWhileHovering(jobID: String) async {
        while (isHovering && selectedJobID == jobID) || rail.hoveredID == jobID {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: What the card's buttons do

    func flip(by step: Int) {
        model.deck.flip(by: step)
        selectedJobID = model.deck.frontID
        updateRail()
        AgentJobCenter.shared.frontJobID = model.deck.frontID
        resize()
    }

    func dismiss(jobID: String) {
        finishTimers.removeValue(forKey: jobID)?.cancel()
        dismissed.insert(jobID)
        refresh()
    }

    func expand(jobID: String) {
        model.deck.setCollapsed(false, id: jobID)
        finishTimers.removeValue(forKey: jobID)?.cancel()
        startFinishTimer(jobID: jobID)
        resize()
    }

    func copyAnswer(of job: AgentJob) {
        Self.copy(job.answer)
        model.copiedJobID = job.id
        let jobID = job.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self?.model.copiedJobID == jobID { self?.model.copiedJobID = nil }
        }
    }

    // MARK: ← / →

    /// The arrow keys flip cards only while the pointer is over the stack, so they are never
    /// taken from whatever the person is typing in.
    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering, model.deck.count > 1 {
            installKeyMonitors()
        } else {
            removeKeyMonitors()
        }
    }

    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        let handle: (NSEvent) -> Bool = { [weak self] event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            switch event.keyCode {
            case 123: Task { @MainActor in self?.flip(by: -1) }; return true
            case 124: Task { @MainActor in self?.flip(by: 1) }; return true
            default: return false
            }
        }
        // Global: the person's own app is in front (the usual case). It needs Accessibility,
        // which Drive already asks for; without it the arrows on the card still work.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handle($0) }) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0) ? nil : $0 }) {
            keyMonitors.append(local)
        }
    }

    private func removeKeyMonitors() {
        keyMonitors.forEach { NSEvent.removeMonitor($0) }
        keyMonitors = []
    }

    // MARK: The panel

    private func show() {
        let panel = self.panel ?? AgentNotchLayout.makePanel(size: NSSize(width: Self.cardWidth, height: 80), acceptsClicks: true)
        if self.panel == nil {
            panel.contentView = NSHostingView(rootView: AgentCardStackHost(model: model, presenter: self))
        }
        self.panel = panel
        resize()
        panel.orderFrontRegardless()
    }

    private func resize() {
        guard let panel, let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let offset = DriveTakeoverMonitor.shared.isDriving ? AgentNotchLayout.pillSlotHeight : 0
        // Stay on the screen the card is already on, so it does not jump when the pointer changes screens.
        if let frame = AgentNotchLayout.frame(for: size, offset: offset, on: panel.isVisible ? panel.screen : nil) {
            panel.setFrame(frame, display: true)
        }
    }

    private func hide() {
        removeKeyMonitors()
        isHovering = false
        jobWatchers.removeAll()
        panel?.orderOut(nil)
    }
}
