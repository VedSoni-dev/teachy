//
//  AgentsSectionContent.swift
//  leanring-buddy
//
//  Home tab cards for agents: the named agents (create, rename, delete), the
//  routines (pause / resume, run now, delete, last result with an unread dot)
//  and the recent jobs (tap one for its answer and step log).
//
//  Mount it with `AgentsSection()`. It only talks to AgentRoster.shared,
//  RoutineScheduler.shared, AgentHistoryStore.shared and AgentJobCenter.shared.
//  The drawing is `AgentsSectionContent`: plain values in, closures out, so it
//  renders to PNG without the app.
//

import SwiftUI

struct AgentsSectionActions {
    var createAgent: (_ name: String, _ role: String) throws -> Void = { _, _ in }
    var renameAgent: (_ slug: String, _ newName: String) throws -> Void = { _, _ in }
    var deleteAgent: (_ slug: String) throws -> Void = { _ in }
    var openAgentFolder: (_ slug: String) -> Void = { _ in }
    var addRoutine: (_ sentence: String) async throws -> Void = { _ in }
    var setRoutineEnabled: (_ id: String, _ enabled: Bool) -> Void = { _, _ in }
    var runRoutineNow: (_ id: String) -> Void = { _ in }
    var deleteRoutine: (_ id: String) -> Void = { _ in }
    var markRoutineRead: (_ id: String) -> Void = { _ in }
    var copy: (_ text: String) -> Void = { _ in }
}

struct AgentsSectionContent: View {
    let agents: [AgentProfile]
    let routines: [Routine]
    var runningRoutineIDs: Set<String> = []
    var routinesProblem: String?
    let jobs: [AgentJobRecord]
    var actions = AgentsSectionActions()
    /// For previews and screenshots: start with this job opened.
    var initiallyExpandedJobID: String?
    var initiallyExpandedRoutineID: String?
    var now = Date()
    var calendar = Calendar.autoupdatingCurrent

    @State private var isCreatingAgent = false
    @State private var newAgentName = ""
    @State private var newAgentRole = ""
    @State private var agentError: String?
    @State private var renamingSlug: String?
    @State private var renameText = ""
    @State private var deletingSlug: String?

    @State private var routineSentence = ""
    @State private var isAddingRoutine = false
    @State private var routineError: String?
    @State private var deletingRoutineID: String?
    @State private var expandedRoutineID: String?

    @State private var expandedJobID: String?
    @State private var showsAllJobs = false
    @State private var copiedJobID: String?
    @State private var didApplyInitialState = false

    private static let collapsedJobCount = 6

    var body: some View {
        VStack(spacing: 8) {
            agentsCard
            routinesCard
            jobsCard
        }
        .onAppear {
            guard !didApplyInitialState else { return }
            didApplyInitialState = true
            expandedJobID = initiallyExpandedJobID
            expandedRoutineID = initiallyExpandedRoutineID
        }
    }

    // MARK: Agents

    private var agentsCard: some View {
        card(title: "Agents", summary: agents.isEmpty
             ? "A named agent keeps its own instructions, notes and files. Ask for it by name."
             : "Say an agent's name to give it the job, like \"ask \(agents[0].name) to…\". Each keeps its own notes and files.") {
            ForEach(agents) { agent in
                agentRow(agent)
            }

            if isCreatingAgent {
                VStack(alignment: .leading, spacing: 8) {
                    field("Name, e.g. Inbox helper", text: $newAgentName) { submitNewAgent() }
                    field("What it does, in one line", text: $newAgentRole) { submitNewAgent() }
                    if let agentError { errorText(agentError) }
                    HStack(spacing: 8) {
                        capsuleButton("Create") { submitNewAgent() }
                        quietButton("Cancel") { resetAgentForm() }
                    }
                }
            } else {
                if let agentError { errorText(agentError) }
                capsuleButton("New agent") {
                    resetAgentForm()
                    isCreatingAgent = true
                }
            }
        }
    }

    private func agentRow(_ agent: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Text(String(agent.name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.Colors.learnAccent.opacity(0.55)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(agent.role.isEmpty ? "No role yet. Open its folder and edit AGENT.md." : agent.role)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            if deletingSlug == agent.slug {
                HStack(spacing: 8) {
                    Text("Delete \(agent.name)? Its folder goes to the Trash.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    capsuleButton("Delete", fill: DS.Colors.destructive, textColor: DS.Colors.textOnAccent) {
                        perform { try actions.deleteAgent(agent.slug) }
                        deletingSlug = nil
                    }
                    quietButton("Cancel") { deletingSlug = nil }
                }
                .padding(.leading, 31)
            } else if renamingSlug == agent.slug {
                HStack(spacing: 8) {
                    field("New name", text: $renameText) { submitRename(agent.slug) }
                    capsuleButton("Save") { submitRename(agent.slug) }
                    quietButton("Cancel") { renamingSlug = nil }
                }
                .padding(.leading, 31)
            } else {
                HStack(spacing: 12) {
                    quietButton("Rename") {
                        agentError = nil
                        renameText = agent.name
                        renamingSlug = agent.slug
                    }
                    quietButton("Open folder") { actions.openAgentFolder(agent.slug) }
                    quietButton("Delete") { deletingSlug = agent.slug }
                }
                .padding(.leading, 31)
            }
        }
        .padding(.vertical, 2)
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            agentError = nil
        } catch {
            agentError = error.localizedDescription
        }
    }

    private func submitNewAgent() {
        let name = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            agentError = "Give the agent a name."
            return
        }
        do {
            try actions.createAgent(name, newAgentRole)
            resetAgentForm()
        } catch {
            agentError = error.localizedDescription
        }
    }

    private func submitRename(_ slug: String) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform { try actions.renameAgent(slug, name) }
        if agentError == nil { renamingSlug = nil }
    }

    private func resetAgentForm() {
        isCreatingAgent = false
        newAgentName = ""
        newAgentRole = ""
        agentError = nil
    }

    // MARK: Routines

    private var routinesCard: some View {
        card(title: "Routines", summary: routines.isEmpty
             ? "Things Teachy does on a schedule while it is open. Say when and what."
             : "Routines run while Teachy is open. They can look and report, but never do anything that needs your yes.") {
            if let routinesProblem {
                Text(routinesProblem)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(routines) { routine in
                routineRow(routine)
            }

            HStack(spacing: 8) {
                field("every weekday at 9, check my GitHub notifications", text: $routineSentence) { submitRoutine() }
                    .disabled(isAddingRoutine)
                if isAddingRoutine {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    capsuleButton("Add") { submitRoutine() }
                }
            }
            if let routineError { errorText(routineError) }
        }
    }

    private func routineRow(_ routine: Routine) -> some View {
        let isRunning = runningRoutineIDs.contains(routine.id)
        let isExpanded = expandedRoutineID == routine.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(routineDotColor(routine, isRunning: isRunning))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.task)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(routineSubtitle(routine, isRunning: isRunning))
                        .font(.system(size: 10))
                        .foregroundColor(routine.pausedReason != nil ? DS.Colors.warningText : DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else if routine.hasUnreadResult {
                    Text("New")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.accent))
                }
            }

            if let result = routine.lastResult, !result.isEmpty {
                Button {
                    expandedRoutineID = isExpanded ? nil : routine.id
                    if routine.hasUnreadResult { actions.markRoutineRead(routine.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lastRunLine(routine))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(lastStatusColor(routine))
                        Text(result)
                            .font(.system(size: 11))
                            .foregroundColor(routine.hasUnreadResult ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .lineLimit(isExpanded ? 14 : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.leading, 15)
            }

            if deletingRoutineID == routine.id {
                HStack(spacing: 8) {
                    Text("Delete this routine?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    capsuleButton("Delete", fill: DS.Colors.destructive, textColor: DS.Colors.textOnAccent) {
                        actions.deleteRoutine(routine.id)
                        deletingRoutineID = nil
                    }
                    quietButton("Cancel") { deletingRoutineID = nil }
                }
                .padding(.leading, 15)
            } else {
                HStack(spacing: 12) {
                    quietButton(routine.enabled ? "Pause" : "Resume", color: routine.enabled ? DS.Colors.textTertiary : DS.Colors.accentText) {
                        actions.setRoutineEnabled(routine.id, !routine.enabled)
                    }
                    if !isRunning {
                        quietButton("Run now") { actions.runRoutineNow(routine.id) }
                    }
                    quietButton("Delete") { deletingRoutineID = routine.id }
                }
                .padding(.leading, 15)
            }
        }
        .padding(.vertical, 2)
    }

    private func routineDotColor(_ routine: Routine, isRunning: Bool) -> Color {
        if isRunning { return DS.Colors.learnAccent }
        if !routine.enabled { return routine.pausedReason != nil ? DS.Colors.warning : DS.Colors.textTertiary }
        return DS.Colors.success
    }

    private func routineSubtitle(_ routine: Routine, isRunning: Bool) -> String {
        var parts = [routine.schedule.summary]
        if let slug = routine.agentSlug {
            parts.append(agents.first { $0.slug == slug }?.name ?? slug)
        }
        if isRunning {
            parts.append("Running now")
        } else if !routine.enabled {
            parts.append(routine.pausedReason ?? "Paused")
        } else if let next = routine.nextRun(calendar: calendar) {
            parts.append("Next \(Self.whenText(next, now: now, calendar: calendar))")
        }
        return parts.joined(separator: " · ")
    }

    private func lastRunLine(_ routine: Routine) -> String {
        var line: String
        switch routine.lastStatus {
        case "failed": line = "Last run failed"
        case "needs you": line = "Last run needs you"
        default: line = "Last run"
        }
        if let lastRun = routine.lastRun { line += " · \(Self.agoText(lastRun, now: now))" }
        return line
    }

    private func lastStatusColor(_ routine: Routine) -> Color {
        switch routine.lastStatus {
        case "failed": return DS.Colors.destructiveText
        case "needs you": return DS.Colors.warningText
        default: return DS.Colors.textTertiary
        }
    }

    private func submitRoutine() {
        let sentence = routineSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, !isAddingRoutine else { return }
        isAddingRoutine = true
        routineError = nil
        Task {
            do {
                try await actions.addRoutine(sentence)
                routineSentence = ""
            } catch {
                routineError = error.localizedDescription
            }
            isAddingRoutine = false
        }
    }

    // MARK: Recent jobs

    private var jobsCard: some View {
        let shown = showsAllJobs ? jobs : Array(jobs.prefix(Self.collapsedJobCount))
        return card(title: "Recent jobs", summary: jobs.isEmpty
                    ? "Jobs Teachy has done for you show up here, with what it found and each step it took."
                    : "Tap a job for its answer and the steps it took.") {
            ForEach(shown) { job in
                jobRow(job)
            }
            if jobs.count > Self.collapsedJobCount {
                quietButton(showsAllJobs ? "Show fewer" : "Show all \(jobs.count)") { showsAllJobs.toggle() }
            }
        }
    }

    private func jobRow(_ job: AgentJobRecord) -> some View {
        let isExpanded = expandedJobID == job.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedJobID = isExpanded ? nil : job.id
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(jobDotColor(job))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(jobSubtitle(job))
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                jobDetail(job)
                    .padding(.leading, 15)
            }
        }
        .padding(.vertical, 2)
    }

    private func jobDetail(_ job: AgentJobRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(job.request)”")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(job.followUps.enumerated()), id: \.offset) { _, followUp in
                Text("Then: “\(followUp)”")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !job.answer.isEmpty {
                Text(job.answer)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !job.statusDetail.isEmpty, job.status != "done" {
                Text(job.status == "failed" ? job.statusDetail : "Stopped: \(job.statusDetail)")
                    .font(.system(size: 11))
                    .foregroundColor(job.status == "failed" ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(job.refusals, id: \.self) { refusal in
                Text(refusal)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !job.steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(job.steps.count) step\(job.steps.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    ForEach(Array(job.steps.prefix(30).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(DS.Colors.textTertiary)
                                .frame(width: 14, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.tool)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(DS.Colors.codeText)
                                    .lineLimit(1)
                                Text(step.result)
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if job.steps.count > 30 {
                        Text("and \(job.steps.count - 30) more")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            }

            if !job.answer.isEmpty {
                capsuleButton(copiedJobID == job.id ? "Copied" : "Copy answer") {
                    actions.copy(job.answer)
                    copiedJobID = job.id
                }
            }
        }
    }

    private func jobDotColor(_ job: AgentJobRecord) -> Color {
        switch job.status {
        case "done": return job.refusals.isEmpty ? DS.Colors.success : DS.Colors.warning
        case "failed": return DS.Colors.destructive
        case "running": return DS.Colors.learnAccent
        default: return DS.Colors.textTertiary
        }
    }

    private func jobSubtitle(_ job: AgentJobRecord) -> String {
        var parts: [String] = []
        switch job.status {
        case "done": parts.append(job.refusals.isEmpty ? "Done" : "Done, needs you")
        case "failed": parts.append("Couldn't finish")
        case "stopped": parts.append("Stopped")
        default: parts.append("Working")
        }
        if let agentName = job.agentName { parts.append(agentName) }
        if job.routineID != nil { parts.append("Routine") }
        parts.append(Self.agoText(job.finishedAt ?? job.startedAt, now: now))
        return parts.joined(separator: " · ")
    }

    // MARK: Words for times

    static func agoText(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    static func whenText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "h:mm a"
        let clock = time.string(from: date).lowercased()
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(clock)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(clock)"
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "EEE"
        return "\(day.string(from: date)) at \(clock)"
    }

    // MARK: Pieces (same look as the Connectors card)

    private func card<Content: View>(title: String, summary: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(summary)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func field(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textPrimary)
            .autocorrectionDisabled()
            .padding(8)
            .glassCard(cornerRadius: 8)
            .onSubmit(onSubmit)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.destructiveText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func capsuleButton(
        _ title: String,
        fill: Color = Color.white.opacity(0.1),
        textColor: Color = DS.Colors.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func quietButton(_ title: String, color: Color = DS.Colors.textTertiary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
