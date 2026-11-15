// Stand-ins for the few agent types the browser bridge and tools refer to, so this test can
// compile the real Browser/ files without the whole app. Same names and shapes as Agent/AgentJob.swift.

import Foundation

enum AgentJobStopReason: Equatable {
    case stopButton
    case userTookOver(String)
}

@MainActor
final class AgentJob {
    nonisolated let id: String
    var title: String
    private(set) var stopReason: AgentJobStopReason?

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    func stop(reason: AgentJobStopReason = .stopButton) {
        if stopReason == nil { stopReason = reason }
    }
}

enum AgentJobContext {
    @TaskLocal static var current: AgentJob?
}

@MainActor
final class AgentJobCenter {
    static let shared = AgentJobCenter()
    private var jobs: [String: AgentJob] = [:]

    func add(_ job: AgentJob) { jobs[job.id] = job }
    func job(withID id: String) -> AgentJob? { jobs[id] }
}
