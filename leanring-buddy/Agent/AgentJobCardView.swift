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

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.tile, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            if !isCollapsed {
                if model.status.isFinished {
                    finishedBody
                } else {
                    runningBody
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(width: AgentJobCardMetrics.width, alignment: .leading)
        // An orange edge while the job waits on the person, so the card that needs them stands out in a stack.
        .teachyTile(edgeColor: model.status == .waitingForConsent ? DS.Colors.warning : .clear)
        .contentShape(cardShape)
        .onTapGesture { if isCollapsed { actions.expand() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            TeachyStatusMark(kind: statusKind, sideLength: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(DS.Fonts.itemTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if let agentName = model.agentName, !agentName.isEmpty {
                    Text(agentName)
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Spacing.sm)

            if let position, position.count > 1 {
                pager(position)
            }

            if model.status.isFinished {
                Text(model.status.label)
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize()
                iconButton("xmark", help: "Close", action: actions.dismiss)
            } else {
                Button("Stop", action: actions.stop)
                    .teachyButton(.danger, size: .compact)
            }
        }
    }

    private func pager(_ position: (index: Int, count: Int)) -> some View {
        HStack(spacing: 0) {
            iconButton("chevron.left", help: "Previous job (←)", action: actions.previous)
            Text("\(position.index) of \(position.count)")
                .font(DS.Fonts.data)
                .foregroundColor(DS.Colors.textSecondary)
                .contentTransition(.numericText())
                .fixedSize()
            iconButton("chevron.right", help: "Next job (→)", action: actions.next)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .teachyIconButton(sideLength: 20)
        .help(help)
    }

    // MARK: Running

    @ViewBuilder
    private var runningBody: some View {
        if model.plan.steps.isEmpty {
            Text(runningSubtitle)
                .font(DS.Fonts.caption)
                .foregroundColor(model.status == .waitingForConsent ? DS.Colors.warningText : DS.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.plan.steps) { step in
                    planRow(step)
                }
            }

            Text(model.status == .waitingForConsent ? "Waiting for your answer" : model.activity)
                .font(DS.Fonts.data)
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
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.destructiveText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.answer.isEmpty {
            Text(model.answer)
                .font(DS.Fonts.voice)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(9)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        HStack(spacing: DS.Spacing.sm) {
            Text(finishedFootnote)
                .font(DS.Fonts.data)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.sm)
            if !model.answer.isEmpty, model.status == .done {
                Button(action: actions.copyAnswer) {
                    HStack(spacing: 5) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(DS.Fonts.sans(10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(didCopy ? "Copied" : "Copy")
                    }
                }
                .teachyButton(.secondary, size: .compact)
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

    private var statusKind: TeachyStatusKind {
        switch model.status {
        case .planning, .running: return .live
        case .queued: return .waiting
        case .waitingForConsent: return .needsYou
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    /// One line of the plan, as a checklist: a tick when it is done, a filled ring
    /// in the tint on the step in progress, an empty circle on the ones to come.
    private func planRow(_ step: AgentPlanStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            planStepMark(for: step.state)
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] - 2 }

            Text(step.text)
                .font(step.state == .current ? DS.Fonts.sans(12.5, weight: .medium) : DS.Fonts.sans(12.5))
                .foregroundColor(stepTextColor(for: step.state))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func planStepMark(for state: AgentPlanStep.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(DS.Fonts.sans(12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 14, height: 14)
        case .current:
            // A filled ring in the tint: "you are here". (The pointer itself is
            // already in the header, marking the whole job as live.)
            Image(systemName: "circle.inset.filled")
                .font(DS.Fonts.sans(12, weight: .medium))
                .foregroundStyle(DS.Colors.pointer)
                .frame(width: 14, height: 14)
        case .pending:
            Image(systemName: "circle")
                .font(DS.Fonts.sans(12, weight: .medium))
                .foregroundStyle(DS.Colors.textQuaternary)
                .frame(width: 14, height: 14)
        }
    }

    private func stepTextColor(for state: AgentPlanStep.State) -> Color {
        switch state {
        case .current: return DS.Colors.textPrimary
        case .done: return DS.Colors.textTertiary
        case .pending: return DS.Colors.textSecondary
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

            // The cards behind are plain translucent slivers, not more glass:
            // glass stacked on glass turns to mud.
            ForEach(0..<peeks, id: \.self) { layer in
                let inset = CGFloat(layer + 1) * 12
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.78 - Double(layer) * 0.2))
                    .frame(width: AgentJobCardMetrics.width - inset * 2, height: AgentJobCardMetrics.peek + 14)
                    .padding(.top, -14)
                    .zIndex(Double(9 - layer))
            }
        }
        .frame(width: AgentJobCardMetrics.width)
    }
}
