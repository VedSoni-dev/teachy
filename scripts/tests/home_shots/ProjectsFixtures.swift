import Foundation
import Combine

enum ProjectsFixture {
    nonisolated static let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

extension AgentProjectStore {
    static let shared = AgentProjectStore(file: ProjectsFixture.root.appendingPathComponent("projects.json"))
}

extension AgentRoster {
    static let shared = AgentRoster(root: ProjectsFixture.root, trash: { _ in })
}

extension AgentHistoryStore {
    nonisolated static let shared = AgentHistoryStore(directory: ProjectsFixture.root.appendingPathComponent("history"))
}

final class AgentJob: ObservableObject, Identifiable {
    let id = "fixture"
    let countsTowardLimit = true
    let title = "Check the compressor stages"
    let activity = "Reading design notes"
    let agentName: String? = "Research"
    @Published var projectID: String?
    @Published var status = AgentJobStatus.running

    init(projectID: String) { self.projectID = projectID }
    func stop() { status = .stopped("Stopped") }
}

final class AgentJobCenter: ObservableObject {
    static let shared = AgentJobCenter()
    @Published var activeJobs: [AgentJob] = []
    var historyRevision = 0
    func assignProject(jobID: String, to projectID: String?) throws {
        activeJobs.first { $0.id == jobID }?.projectID = projectID
    }
}
