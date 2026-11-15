//
//  AgentJobCardView.swift
//  leanring-buddy
//
//  The cards that hang under the notch while jobs run. Several jobs stack; the
//  one in front shows its name, its plan with the current step highlighted and
//  a Stop button. A finished card shows the answer with Copy, then folds down
//  to one line, then leaves.
//
//  Everything in this file is plain SwiftUI drawn from a value (`AgentJobCardModel`),
//  so it renders to PNG without the app (scripts/tests/render_agents2_shots.sh).
//  The panel that hosts it and follows live jobs is AgentJobPanelPresenter.swift.
//

import SwiftUI

/// What one card shows. A snapshot of an `AgentJob`.
struct AgentJobCardModel: Identifiable, Equatable {
    var id: String
    var title: String
    var agentName: String?
    var status: AgentJobStatus
    var plan: AgentPlan
    var activity: String
    var answer: String
    var elapsed: String
    var isDriving = false

    init(id: String, title: String, agentName: String? = nil, status: AgentJobStatus, plan: AgentPlan = AgentPlan(), activity: String = "", answer: String = "", elapsed: String = "", isDriving: Bool = false) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.status = status
        self.plan = plan
        self.activity = activity
        self.answer = answer
        self.elapsed = elapsed
        self.isDriving = isDriving
    }
}

struct AgentJobCardActions {
    var stop: () -> Void = {}
    var copyAnswer: () -> Void = {}
    var dismiss: () -> Void = {}
    var expand: () -> Void = {}
    var previous: () -> Void = {}
    var next: () -> Void = {}
}

enum AgentJobCardMetrics {
    static let width: CGFloat = 340
    /// How much of each card behind the front one shows.
    static let peek: CGFloat = 7
    static let maxPeeks = 3
}

struct AgentJobCard: View {
    let model: AgentJobCardModel
    /// 1-based place in the stack and how many there are; nil when it is the only card.
    var position: (index: Int, count: Int)?
    /// A finished card folded down to its header.
    var isCollapsed = false
    var didCopy = false
    var actions = AgentJobCardActions()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header

            if !isCollapsed {
                if model.status.isFinished {
                    finishedBody
                } else {
                    runningBody
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: AgentJobCardMetrics.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { if isCollapsed { actions.expand() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Circle().fill(statusColor).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if let agentName = model.agentName, !agentName.isEmpty {
                    Text(agentName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Spacing.sm)

            if let position, position.count > 1 {
                pager(position)
            }

            if model.status.isFinished {
                Text(model.status.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize()
                iconButton("xmark", help: "Close", action: actions.dismiss)
            } else {
                Button(action: actions.stop) {
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
    }

    private func pager(_ position: (index: Int, count: Int)) -> some View {
        HStack(spacing: 2) {
            iconButton("chevron.left", help: "Previous job (←)", action: actions.previous)
            Text("\(position.index) of \(position.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize()
            iconButton("chevron.right", help: "Next job (→)", action: actions.next)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    // MARK: Running

    @ViewBuilder
    private var runningBody: some View {
        if model.plan.steps.isEmpty {
            Text(runningSubtitle)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.plan.steps) { step in
                    planRow(step)
                }
            }
            Text(model.status == .waitingForConsent ? "Waiting for your answer" : model.activity)
                .font(.system(size: 10))
                .foregroundColor(model.status == .waitingForConsent ? DS.Colors.warningText : DS.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var runningSubtitle: String {
        switch model.status {
        case .queued: return "Four jobs are already running. This one starts when one of them ends."
        case .planning: return "Working out a plan…"
        case .waitingForConsent: return "Waiting for your answer"
        default: return model.activity
        }
    }

    // MARK: Finished

    @ViewBuilder
    private var finishedBody: some View {
        if case .failed(let why) = model.status {
            Text(why)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.destructiveText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.answer.isEmpty {
            Text(model.answer)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(9)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        HStack(spacing: DS.Spacing.sm) {
            Text(finishedFootnote)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.sm)
            if !model.answer.isEmpty, model.status == .done {
                Button(action: actions.copyAnswer) {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text(didCopy ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var finishedFootnote: String {
        switch model.status {
        case .done:
            let stepCount = model.plan.steps.count
            let steps = stepCount == 0 ? "" : " · \(stepCount) step\(stepCount == 1 ? "" : "s")"
            return "Finished in \(model.elapsed)\(steps)"
        case .stopped(let why): return "Stopped: \(why)"
        case .failed: return "Couldn't finish"
        default: return ""
        }
    }

    // MARK: Pieces

    private var statusColor: Color {
        switch model.status {
        case .planning, .running: return DS.Colors.learnAccent
        case .queued: return DS.Colors.textTertiary
        case .waitingForConsent: return DS.Colors.warning
        case .done: return DS.Colors.success
        case .failed: return DS.Colors.destructive
        case .stopped: return DS.Colors.textTertiary
        }
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

/// The front card with the edges of the cards behind it showing below, like a small deck.
struct AgentJobCardStack: View {
    let front: AgentJobCardModel
    /// 1-based place of the front card and the number of cards.
    let index: Int
    let count: Int
    var isCollapsed = false
    var didCopy = false
    var actions = AgentJobCardActions()

    private var peeks: Int { min(max(0, count - 1), AgentJobCardMetrics.maxPeeks) }

    var body: some View {
        VStack(spacing: 0) {
            AgentJobCard(
                model: front,
                position: count > 1 ? (index, count) : nil,
                isCollapsed: isCollapsed,
                didCopy: didCopy,
                actions: actions
            )
            .zIndex(10)

            ForEach(0..<peeks, id: \.self) { layer in
                let inset = CGFloat(layer + 1) * 10
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(1 - Double(layer) * 0.22))
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                            .strokeBorder(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
                    )
                    .frame(width: AgentJobCardMetrics.width - inset * 2, height: AgentJobCardMetrics.peek + 12)
                    .padding(.top, -12)
                    .zIndex(Double(9 - layer))
            }
        }
        .frame(width: AgentJobCardMetrics.width)
    }
}
