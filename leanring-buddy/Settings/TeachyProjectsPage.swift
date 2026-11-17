import AppKit
import SwiftUI

struct TeachyProjectsPage: View {
    let companionManager: CompanionManager
    @ObservedObject private var projects = AgentProjectStore.shared
    @ObservedObject private var roster = AgentRoster.shared
    @ObservedObject private var jobs = AgentJobCenter.shared
    @ObservedObject private var drawings = SceneHistory.shared
    @State private var records: [AgentJobRecord] = []
    @State private var projectForm: ProjectForm?
    @State private var projectName = ""
    @State private var taskText = ""
    @State private var agentSlug: String?
    @State private var errorText: String?
    @FocusState private var namingProject: Bool

    private enum ProjectForm: Equatable {
        case create
        case rename(String)
    }

    private var selectedProject: AgentProject? {
        projects.projects.first { $0.id == projects.activeProjectID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            projectSelector
            if let message = errorText ?? projects.loadProblem {
                Text(message).font(DS.Fonts.caption).foregroundStyle(DS.Colors.destructiveText)
                    .textSelection(.enabled)
            }
            launcher
            let running = jobs.activeJobs.filter { $0.countsTowardLimit && includes($0.projectID) }
            if !running.isEmpty {
                SettingsPageGroup(title: "Active jobs") {
                    ForEach(running) { job in
                        ActiveProjectJobRow(job: job, projects: projects.projects, assign: assign)
                    }
                }
            }
            if let project = selectedProject {
                let saved = drawings.entries.filter { $0.projectID == project.id }
                if !saved.isEmpty {
                    SettingsPageGroup(title: "Drawings") {
                        ForEach(saved) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.kind == "3D model" ? "cube" : "scribble.variable")
                                    .foregroundStyle(DS.Colors.textSecondary)
                                Text(entry.title).font(DS.Fonts.bodyEmphasized).lineLimit(2)
                                Spacer(minLength: 6)
                                Button { drawings.replay(entry.id) } label: {
                                    Image(systemName: "play.fill")
                                }
                                .teachyIconButton(sideLength: 28)
                                .help("Replay " + entry.title)
                                .accessibilityLabel("Replay " + entry.title)
                            }
                        }
                    }
                }
            }
            let runningIDs = Set(running.map(\.id))
            let history = records.filter { includes($0.projectID) && !runningIDs.contains($0.id) }
            if !history.isEmpty {
                jobHistory(history)
            } else if running.isEmpty {
                Text("Finished jobs and their answers will appear here.")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .onAppear { roster.reload() }
        .task(id: jobs.historyRevision) {
            let loaded = await Task.detached(priority: .utility) { AgentHistoryStore.shared.list() }.value
            if !Task.isCancelled { records = loaded }
        }
    }

    private func jobHistory(_ history: [AgentJobRecord]) -> some View {
        AgentsSectionContent(
            agents: [], routines: [], jobs: history,
            projectOptions: projects.projects.map { ($0.id, $0.name) },
            showsRoutines: false, showsAgents: false,
            actions: AgentsSectionActions(assignProject: assign, copy: { answer in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            })
        )
        .id(projects.activeProjectID)
    }

    private var projectSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Current project", selection: Binding<String?>(
                    get: { projects.activeProjectID },
                    set: { id in
                        do {
                            try projects.select(id)
                            projectForm = nil
                            errorText = nil
                        } catch { errorText = error.localizedDescription }
                    })
                ) {
                    Text("All projects").tag(String?.none)
                    ForEach(projects.projects) { project in Text(project.name).tag(Optional(project.id)) }
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityLabel("Current project")
                if let project = selectedProject {
                    Button {
                        editProject(.rename(project.id), name: project.name)
                    } label: { Image(systemName: "pencil") }
                    .teachyIconButton(sideLength: 28)
                    .help("Rename project").accessibilityLabel("Rename project")
                }
                Spacer(minLength: 4)
                Button { editProject(.create, name: "") } label: {
                    Label("New project", systemImage: "plus")
                }
                .teachyButton(.secondary, size: .compact)
            }
            if let form = projectForm {
                HStack(spacing: 8) {
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.plain).focused($namingProject)
                        .padding(9).teachyWell(isEdged: true)
                        .onSubmit { saveProject(form) }
                    Button(form == .create ? "Create" : "Save") { saveProject(form) }
                        .teachyButton(.primary, size: .compact)
                        .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { projectForm = nil; errorText = nil }
                        .teachyButton(.quiet, size: .compact)
                }
                .onAppear { namingProject = true }
            }
        }
    }

    private var launcher: some View {
        SettingsPageGroup(title: "New job") {
            TextField("What should this agent do?", text: $taskText, axis: .vertical)
                .textFieldStyle(.plain).font(DS.Fonts.body)
                .lineLimit(2...5)
            HStack {
                Picker("Agent", selection: $agentSlug) {
                    Text("Teachy").tag(String?.none)
                    ForEach(roster.agents) { profile in Text(profile.name).tag(Optional(profile.slug)) }
                }
                .pickerStyle(.menu).labelsHidden().accessibilityLabel("Agent")
                Spacer()
                Button { startJob() } label: { Label("Start job", systemImage: "arrow.up") }
                    .teachyButton(.primary, size: .compact)
                    .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func includes(_ projectID: String?) -> Bool {
        projects.activeProjectID == nil || projects.activeProjectID == projectID
    }

    private func startJob() {
        let request = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        companionManager.backgroundAgentManager.runTask(transcript: request, agentSlug: agentSlug)
        taskText = ""
    }

    private func editProject(_ form: ProjectForm, name: String) {
        projectName = name
        projectForm = form
        errorText = nil
        namingProject = true
    }

    private func saveProject(_ form: ProjectForm) {
        do {
            switch form {
            case .create: try projects.create(name: projectName)
            case .rename(let id): try projects.rename(id: id, name: projectName)
            }
            projectForm = nil
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func assign(_ jobID: String, _ projectID: String?) {
        do {
            try jobs.assignProject(jobID: jobID, to: projectID)
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }
}

private struct ActiveProjectJobRow: View {
    @ObservedObject var job: AgentJob
    let projects: [AgentProject]
    let assign: (String, String?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(DS.Fonts.itemTitle).lineLimit(2)
                Text("\(job.agentName ?? "Teachy") · \(job.status == .running ? job.activity : job.status.label)")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 4)
            if !projects.isEmpty {
                Menu {
                    Picker("Project", selection: Binding<String?>(
                        get: { job.projectID }, set: { assign(job.id, $0) }
                    )) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(projects) { project in Text(project.name).tag(Optional(project.id)) }
                    }
                } label: { Image(systemName: "folder") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Move job to project").accessibilityLabel("Move " + job.title + " to project")
            }
            Button("Stop") { job.stop() }
                .teachyButton(.quiet, size: .compact)
                .accessibilityLabel("Stop " + job.title)
        }
    }
}
