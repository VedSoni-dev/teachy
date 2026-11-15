//
//  AgentsSectionContent.swift
//  leanring-buddy
//
//  Home tab lists for agents: the named agents (create, rename, delete), the
//  routines (pause / resume, run now, delete, last result with a "New" mark)
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

    /// Space between the three sections, the same as between the sections of the Home tab.
    private static let sectionSpacing: CGFloat = 24
    /// Space between a section's title, its group of rows and what sits under the group.
    private static let sectionPartSpacing: CGFloat = 9
    /// Space above and below the content of one row of a group.
    private static let groupRowVerticalPadding: CGFloat = 11
    private static let statusMarkSideLength: CGFloat = 14
    /// The gap between a status mark and the text beside it.
    private static let statusMarkSpacing: CGFloat = 10
    /// How far the lines under a marked title sit in, so they line up with the
    /// title. The dividers between marked rows start here too.
    private static let statusMarkIndent: CGFloat = statusMarkSideLength + statusMarkSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            agentsSection
            routinesSection
            jobsSection
        }
        .onAppear {
            guard !didApplyInitialState else { return }
            didApplyInitialState = true
            expandedJobID = initiallyExpandedJobID
            expandedRoutineID = initiallyExpandedRoutineID
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: Self.sectionPartSpacing) {
            sectionHeader(
                title: "Agents",
                detail: agents.isEmpty ? nil : "\(agents.count)",
                caption: agents.isEmpty
                    ? nil
                    : "Say an agent's name to give it the job, like \"ask \(agents[0].name) to…\". Each keeps its own notes and files."
            )

            rowGroup {
                if agents.isEmpty {
                    emptyState(
                        line: "No agents yet.",
                        caption: "A named agent keeps its own instructions, notes and files. Ask for it by name."
                    )
                }

                ForEach(Array(agents.enumerated()), id: \.element.id) { agentIndex, agent in
                    if agentIndex > 0 {
                        TeachyRule()
                    }
                    agentRow(agent)
                }
            }

            if isCreatingAgent {
                VStack(alignment: .leading, spacing: 8) {
                    wellField("Name, e.g. Inbox helper", text: $newAgentName) { submitNewAgent() }
                    wellField("What it does, in one line", text: $newAgentRole) { submitNewAgent() }
                    if let agentError { errorText(agentError) }
                    HStack(spacing: 6) {
                        compactButton("Create", kind: .primary) { submitNewAgent() }
                        compactButton("Cancel", kind: .quiet) { resetAgentForm() }
                    }
                }
            } else {
                if let agentError { errorText(agentError) }
                compactButton("New agent", kind: .secondary) {
                    resetAgentForm()
                    isCreatingAgent = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agentRow(_ agent: AgentProfile) -> some View {
        let isConfirmingDelete = deletingSlug == agent.slug
        let isRenaming = renamingSlug == agent.slug
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(DS.Fonts.itemTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(agent.role.isEmpty ? "No role yet. Open its folder and edit AGENT.md." : agent.role)
                        .font(DS.Fonts.caption)
                        .foregroundColor(agent.role.isEmpty ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if !isConfirmingDelete && !isRenaming {
                    HStack(spacing: 14) {
                        linkButton("Rename") {
                            agentError = nil
                            renameText = agent.name
                            renamingSlug = agent.slug
                        }
                        linkButton("Open folder") { actions.openAgentFolder(agent.slug) }
                        linkButton("Delete", color: DS.Colors.destructiveText) { deletingSlug = agent.slug }
                    }
                }
            }

            if isConfirmingDelete {
                HStack(spacing: 6) {
                    confirmationQuestion("Delete \(agent.name)? Its folder goes to the Trash.")
                    Spacer(minLength: 8)
                    compactButton("Delete", kind: .danger) {
                        perform { try actions.deleteAgent(agent.slug) }
                        deletingSlug = nil
                    }
                    compactButton("Cancel", kind: .quiet) { deletingSlug = nil }
                }
            } else if isRenaming {
                HStack(spacing: 6) {
                    wellField("New name", text: $renameText) { submitRename(agent.slug) }
                    compactButton("Save") { submitRename(agent.slug) }
                    compactButton("Cancel", kind: .quiet) { renamingSlug = nil }
                }
            }
        }
        .padding(.vertical, Self.groupRowVerticalPadding)
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

    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: Self.sectionPartSpacing) {
            sectionHeader(
                title: "Routines",
                detail: routinesSectionDetail,
                caption: routines.isEmpty
                    ? nil
                    : "Routines run while Teachy is open. They can look and report, but never do anything that needs your yes."
            )

            if let routinesProblem {
                Text(routinesProblem)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            rowGroup {
                if routines.isEmpty {
                    emptyState(
                        line: "No routines yet.",
                        caption: "Things Teachy does on a schedule while it is open. Say when and what."
                    )
                }

                ForEach(Array(routines.enumerated()), id: \.element.id) { routineIndex, routine in
                    if routineIndex > 0 {
                        TeachyRule()
                            .padding(.leading, Self.statusMarkIndent)
                    }
                    routineRow(routine)
                }
            }

            addRoutineWell
            if let routineError { errorText(routineError) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The count beside the title, and how many are running right now.
    private var routinesSectionDetail: String? {
        guard !routines.isEmpty else { return nil }
        let runningRoutineCount = routines.filter { runningRoutineIDs.contains($0.id) }.count
        return runningRoutineCount > 0 ? "\(routines.count) · \(runningRoutineCount) running" : "\(routines.count)"
    }

    /// One well that holds the sentence and its "Add" button.
    private var addRoutineWell: some View {
        HStack(spacing: 8) {
            plainTextField("every weekday at 9, check my GitHub notifications", text: $routineSentence) { submitRoutine() }
                .disabled(isAddingRoutine)
            if isAddingRoutine {
                TeachyStatusMark(kind: .live, sideLength: Self.statusMarkSideLength)
                    .frame(width: 24, height: 24)
            } else {
                compactButton("Add", kind: .primary) { submitRoutine() }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 32)
        .teachyWell()
    }

    private func routineRow(_ routine: Routine) -> some View {
        let isRunning = runningRoutineIDs.contains(routine.id)
        let isExpanded = expandedRoutineID == routine.id
        return HStack(alignment: .top, spacing: Self.statusMarkSpacing) {
            TeachyStatusMark(kind: routineStatusKind(routine, isRunning: isRunning), sideLength: Self.statusMarkSideLength)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(routine.task)
                            .font(DS.Fonts.bodyEmphasized)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        if routine.hasUnreadResult {
                            Text("New")
                                .font(DS.Fonts.dataEmphasized)
                                .foregroundColor(DS.Colors.pointer)
                        }
                    }
                    Text(routineFactsLine(routine, isRunning: isRunning))
                        .font(DS.Fonts.data)
                        .foregroundColor(routineFactsColor(routine))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let result = routine.lastResult, !result.isEmpty {
                    Button {
                        expandedRoutineID = isExpanded ? nil : routine.id
                        if routine.hasUnreadResult { actions.markRoutineRead(routine.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lastRunLine(routine))
                                .font(DS.Fonts.data)
                                .foregroundColor(lastStatusColor(routine))
                            Text(result)
                                .font(DS.Fonts.voice)
                                .lineSpacing(3)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(isExpanded ? 14 : 2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                if deletingRoutineID == routine.id {
                    HStack(spacing: 6) {
                        confirmationQuestion("Delete this routine?")
                        Spacer(minLength: 8)
                        compactButton("Delete", kind: .danger) {
                            actions.deleteRoutine(routine.id)
                            deletingRoutineID = nil
                        }
                        compactButton("Cancel", kind: .quiet) { deletingRoutineID = nil }
                    }
                } else {
                    HStack(spacing: 14) {
                        linkButton(routine.enabled ? "Pause" : "Resume") {
                            actions.setRoutineEnabled(routine.id, !routine.enabled)
                        }
                        if !isRunning {
                            linkButton("Run now") { actions.runRoutineNow(routine.id) }
                        }
                        linkButton("Delete", color: DS.Colors.destructiveText) { deletingRoutineID = routine.id }
                    }
                }
            }
        }
        .padding(.vertical, Self.groupRowVerticalPadding)
    }

    /// The mark says the state: live while it runs, failed when it was paused
    /// after failures or its last run failed, stopped when the person paused
    /// it, needs-you when the last run needs them, waiting until its next time.
    private func routineStatusKind(_ routine: Routine, isRunning: Bool) -> TeachyStatusKind {
        if isRunning { return .live }
        if !routine.enabled { return routine.pausedReason != nil ? .failed : .stopped }
        switch routine.lastStatus {
        case "failed": return .failed
        case "needs you": return .needsYou
        default: return .waiting
        }
    }

    /// The facts in one line: "Weekdays at 9 am · Next Mon at 9:00 am".
    private func routineFactsLine(_ routine: Routine, isRunning: Bool) -> String {
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

    /// Red only when Teachy paused the routine after failed runs.
    private func routineFactsColor(_ routine: Routine) -> Color {
        if !routine.enabled && routine.pausedReason != nil { return DS.Colors.destructiveText }
        return DS.Colors.textSecondary
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

    private var jobsSection: some View {
        let shownJobs = showsAllJobs ? jobs : Array(jobs.prefix(Self.collapsedJobCount))
        return VStack(alignment: .leading, spacing: Self.sectionPartSpacing) {
            sectionHeader(
                title: "Recent jobs",
                detail: jobs.isEmpty ? nil : "\(jobs.count)",
                caption: jobs.isEmpty ? nil : "Tap a job for its answer and the steps it took."
            )

            rowGroup {
                if jobs.isEmpty {
                    emptyState(
                        line: "No jobs yet.",
                        caption: "Jobs Teachy has done for you show up here, with what it found and each step it took."
                    )
                }

                ForEach(Array(shownJobs.enumerated()), id: \.element.id) { jobIndex, job in
                    if jobIndex > 0 {
                        TeachyRule()
                            .padding(.leading, Self.statusMarkIndent)
                    }
                    jobRow(job)
                }

                // The last row of the group, lined up with the job names.
                if jobs.count > Self.collapsedJobCount {
                    TeachyRule()
                        .padding(.leading, Self.statusMarkIndent)
                    linkButton(showsAllJobs ? "Show fewer" : "Show all \(jobs.count)") { showsAllJobs.toggle() }
                        .padding(.leading, Self.statusMarkIndent)
                        .padding(.vertical, Self.groupRowVerticalPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func jobRow(_ job: AgentJobRecord) -> some View {
        let isExpanded = expandedJobID == job.id
        return VStack(alignment: .leading, spacing: 0) {
            HoverToneButton {
                expandedJobID = isExpanded ? nil : job.id
            } label: { isHovered in
                HStack(alignment: .center, spacing: Self.statusMarkSpacing) {
                    TeachyStatusMark(kind: jobStatusKind(job), sideLength: Self.statusMarkSideLength)
                    Text(job.title)
                        .font(DS.Fonts.itemTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(jobFactsLine(job))
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(DS.Fonts.sans(10, weight: .semibold))
                        .foregroundColor(isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, Self.groupRowVerticalPadding)
            }

            if isExpanded {
                jobDetail(job)
                    .padding(.leading, Self.statusMarkIndent)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
            }
        }
    }

    private func jobDetail(_ job: AgentJobRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(job.request)”")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(job.followUps.enumerated()), id: \.offset) { _, followUp in
                    Text("Then: “\(followUp)”")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !job.answer.isEmpty {
                Text(job.answer)
                    .font(DS.Fonts.voice)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(3)
                    .lineLimit(16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !job.statusDetail.isEmpty, job.status != "done" {
                Text(job.status == "failed" ? job.statusDetail : "Stopped: \(job.statusDetail)")
                    .font(DS.Fonts.caption)
                    .foregroundColor(job.status == "failed" ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(job.refusals, id: \.self) { refusal in
                Text(refusal)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !job.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(job.steps.count) step\(job.steps.count == 1 ? "" : "s")")
                        .font(DS.Fonts.dataEmphasized)
                        .foregroundColor(DS.Colors.textSecondary)
                    ForEach(Array(job.steps.prefix(30).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .font(DS.Fonts.data)
                                .foregroundColor(DS.Colors.textTertiary)
                                .frame(width: 20, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                // A tool's name is a real identifier, so it is the one thing here in mono.
                                Text(step.tool)
                                    .font(DS.Fonts.mono(11))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                                Text(step.result)
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if job.steps.count > 30 {
                        Text("and \(job.steps.count - 30) more")
                            .font(DS.Fonts.data)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            if !job.answer.isEmpty {
                compactButton(copiedJobID == job.id ? "Copied" : "Copy answer") {
                    actions.copy(job.answer)
                    copiedJobID = job.id
                }
            }
        }
    }

    /// A finished job that was refused something still needs the person, so
    /// it gets the needs-you mark and not the done mark.
    private func jobStatusKind(_ job: AgentJobRecord) -> TeachyStatusKind {
        switch job.status {
        case "done": return job.refusals.isEmpty ? .done : .needsYou
        case "failed": return .failed
        case "running": return .live
        default: return .stopped
        }
    }

    /// The facts in one line: "Done · Research buddy · 48 min ago".
    private func jobFactsLine(_ job: AgentJobRecord) -> String {
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

    // MARK: Pieces (same look as the Connectors section)

    /// What sits above a group: the section's title with a fact beside it, and
    /// one caption line at most.
    private func sectionHeader(title: String, detail: String?, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TeachySectionTitle(title: title, detail: detail)
            if let caption {
                Text(caption)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The rows of one section and nothing else, with only dividers between
    /// them, in the section's one rounded container.
    private func rowGroup<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rows()
        }
        .teachyGroup()
    }

    /// Nothing here yet: one line and one caption line. It is the only row of
    /// its group.
    private func emptyState(line: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line)
                .font(DS.Fonts.itemTitle)
                .foregroundColor(DS.Colors.textPrimary)
            Text(caption)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Self.groupRowVerticalPadding)
    }

    /// Teachy asking before it removes something.
    private func confirmationQuestion(_ question: String) -> some View {
        Text(question)
            .font(DS.Fonts.body)
            .foregroundColor(DS.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A text field with no surface of its own, for a well that also holds a button.
    private func plainTextField(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text, prompt: Text(placeholder).foregroundColor(DS.Colors.textQuaternary))
            .textFieldStyle(.plain)
            .font(DS.Fonts.body)
            .foregroundColor(DS.Colors.textPrimary)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
    }

    private func wellField(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        plainTextField(placeholder, text: text, onSubmit: onSubmit)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .teachyWell()
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.destructiveText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func compactButton(
        _ title: String,
        kind: TeachyButtonKind = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .teachyButton(kind, size: .compact)
    }

    /// A word in a row that does something. With no colour it takes the tint.
    private func linkButton(_ title: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .teachyLinkButton(color: color)
    }
}

/// A whole row that opens in place when clicked. It has no surface of its
/// own, so hover only changes tone: the label is told whether the pointer is
/// over it and brightens what it wants.
private struct HoverToneButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (_ isHovered: Bool) -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label(isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovered = hovering }
        }
    }
}
