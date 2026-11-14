//
//  AgentJobCardView.swift
//  leanring-buddy
//
//  The compact card that hangs under the notch while a job runs: the job's
//  name, its plan with the current step highlighted, and a Stop button.
//  `AgentJobCardView` is a self-contained SwiftUI view (pass it any AgentJob);
//  `AgentJobPanelPresenter` is the small non-activating panel that shows it.
//

import AppKit
import Combine
import SwiftUI

struct AgentJobCardView: View {
    @ObservedObject var job: AgentJob

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                statusDot
                Text(job.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.sm)
                if job.status.isFinished {
                    Text(job.status.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    Button {
                        job.stop(reason: .stopButton)
                    } label: {
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.destructiveText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.destructive.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if job.plan.steps.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(job.plan.steps) { step in
                        planRow(step)
                    }
                }
                if !job.status.isFinished {
                    Text(job.activity)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            if case .failed(let why) = job.status {
                Text(why)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(3)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: AgentJobPanelPresenter.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private var subtitle: String {
        switch job.status {
        case .planning: return "Working out a plan…"
        case .waitingForConsent: return "Waiting for your answer"
        case .running: return job.activity
        case .done: return "Finished in \(job.elapsedDescription)"
        case .failed: return "Couldn't finish"
        case .stopped(let why): return "Stopped: \(why)"
        }
    }

    private var statusDot: some View {
        let color: Color
        switch job.status {
        case .planning, .running: color = DS.Colors.learnAccent
        case .waitingForConsent: color = DS.Colors.warning
        case .done: color = DS.Colors.success
        case .failed: color = DS.Colors.destructive
        case .stopped: color = DS.Colors.textTertiary
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func planRow(_ step: AgentPlanStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon(for: step.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(step.state == .pending ? DS.Colors.textTertiary : DS.Colors.learnAccent)
                .frame(width: 12)
            Text(step.text)
                .font(.system(size: 12, weight: step.state == .current ? .semibold : .regular))
                .foregroundColor(step.state == .current ? DS.Colors.textPrimary : (step.state == .done ? DS.Colors.textTertiary : DS.Colors.textSecondary))
                .strikethrough(step.state == .done, color: DS.Colors.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, step.state == .current ? 3 : 0)
        .padding(.horizontal, step.state == .current ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                .fill(step.state == .current ? DS.Colors.learnAccentSoft : Color.clear)
        )
    }

    private func icon(for state: AgentPlanStep.State) -> String {
        switch state {
        case .done: return "checkmark"
        case .current: return "arrow.right"
        case .pending: return "circle"
        }
    }
}

/// Hangs the card under the notch for the newest job that wants one, and takes it down a few
/// seconds after that job ends. Hidden while a consent card is up (the question comes first).
@MainActor
final class AgentJobPanelPresenter {
    static let shared = AgentJobPanelPresenter()
    static let cardWidth: CGFloat = 320
    private static let lingerSeconds: TimeInterval = 4

    private var panel: NSPanel?
    private var shownJobID: String?
    private var jobWatcher: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    func refresh() {
        let center = AgentJobCenter.shared
        let candidate = center.jobs.last { $0.showsCard && !$0.status.isFinished }
            ?? center.jobs.last { $0.showsCard && $0.id == shownJobID }

        guard let job = candidate else {
            hide()
            return
        }
        if job.status == .waitingForConsent {
            panel?.orderOut(nil)
            return
        }
        show(job)
        if job.status.isFinished {
            scheduleHide(jobID: job.id)
        } else {
            hideTask?.cancel()
        }
    }

    private func show(_ job: AgentJob) {
        let panel = self.panel ?? AgentNotchLayout.makePanel(size: NSSize(width: Self.cardWidth, height: 80), acceptsClicks: true)
        self.panel = panel
        if shownJobID != job.id || panel.contentView == nil {
            shownJobID = job.id
            panel.contentView = NSHostingView(rootView: AgentJobCardView(job: job))
            // The card grows and shrinks with the plan.
            jobWatcher = job.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.resize() }
        }
        resize()
        panel.orderFrontRegardless()
    }

    private func resize() {
        guard let panel, let hosting = panel.contentView else { return }
        let size = hosting.fittingSize
        let offset = DriveTakeoverMonitor.shared.isDriving ? AgentNotchLayout.pillSlotHeight : 0
        // Stay on the screen the card is already on, so it does not jump when the pointer changes screens.
        if let frame = AgentNotchLayout.frame(for: size, offset: offset, on: panel.isVisible ? panel.screen : nil) {
            panel.setFrame(frame, display: true)
        }
    }

    private func scheduleHide(jobID: String) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lingerSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.shownJobID == jobID else { return }
            self.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        jobWatcher = nil
        shownJobID = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}
