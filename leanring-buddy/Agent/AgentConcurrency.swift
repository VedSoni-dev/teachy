//
//  AgentConcurrency.swift
//  leanring-buddy
//
//  Bookkeeping for several jobs at once. Pure: no AppKit, no clock, no tasks.
//
//  - AgentSlotBook: at most four jobs run at a time; later ones wait their turn
//    in the order they arrived.
//  - DriveLease: only one job may hold Drive (the real mouse and keyboard).
//  - AgentFollowUpRouter: which job a spoken follow-up belongs to.
//
//  Tested by scripts/tests/run_agents2_tests.sh.
//

import Foundation

nonisolated struct AgentSlotBook: Equatable, Sendable {
    static let defaultLimit = 4

    enum Admission: Equatable, Sendable {
        case runNow
        /// 1 = next in line.
        case queued(position: Int)
    }

    let limit: Int
    private(set) var running: [String] = []
    private(set) var waiting: [String] = []

    init(limit: Int = AgentSlotBook.defaultLimit) {
        self.limit = max(1, limit)
    }

    func isRunning(_ id: String) -> Bool { running.contains(id) }

    /// Asks for a slot. Asking twice for the same job changes nothing.
    mutating func request(_ id: String) -> Admission {
        if running.contains(id) { return .runNow }
        if let position = waiting.firstIndex(of: id) { return .queued(position: position + 1) }
        if running.count < limit {
            running.append(id)
            return .runNow
        }
        waiting.append(id)
        return .queued(position: waiting.count)
    }

    /// The job ended (or gave up waiting). Returns the jobs that may start now, in order.
    @discardableResult
    mutating func release(_ id: String) -> [String] {
        waiting.removeAll { $0 == id }
        running.removeAll { $0 == id }
        var promoted: [String] = []
        while running.count < limit, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running.append(next)
            promoted.append(next)
        }
        return promoted
    }
}

/// Drive moves the one real pointer, so one job holds it at a time. The holder keeps it
/// until it ends; the others wait or are told who has it.
nonisolated struct DriveLease: Equatable, Sendable {
    enum Claim: Equatable, Sendable {
        case granted
        case busy(holder: String)
    }

    private(set) var holder: String?

    mutating func claim(_ jobID: String) -> Claim {
        if let holder, holder != jobID { return .busy(holder: holder) }
        holder = jobID
        return .granted
    }

    /// Only the holder can give it up; anyone else's release is ignored.
    mutating func release(_ jobID: String) {
        if holder == jobID { holder = nil }
    }

    /// What a job that could not get Drive is told.
    static func busyMessage(holderTitle: String) -> String {
        "Drive is busy: the job \"\(holderTitle)\" is using the mouse and keyboard right now, and only one job can. Do the parts of your work that do not need Drive. If nothing is left without it, stop and say that you are waiting for \"\(holderTitle)\" to finish."
    }
}

/// Picks the job a follow-up is meant for.
nonisolated enum AgentFollowUpRouter {
    struct Candidate: Equatable, Sendable {
        var id: String
        var title: String
        var agentName: String?
        var isActive: Bool
        /// When it finished; nil while running.
        var finishedAt: Date?

        init(id: String, title: String, agentName: String? = nil, isActive: Bool, finishedAt: Date? = nil) {
            self.id = id
            self.title = title
            self.agentName = agentName
            self.isActive = isActive
            self.finishedAt = finishedAt
        }
    }

    /// A finished job still takes a follow-up for this long.
    static let recentWindow: TimeInterval = 10 * 60

    private static func words(_ text: String) -> String {
        " " + text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
    }

    /// Rules, in order: a job named in the text (by its title or its agent's name); then the
    /// only running job; then the card in front if it is running or just finished. nil = start
    /// a new job instead. `candidates` are oldest first.
    static func target(for text: String, candidates: [Candidate], frontJobID: String?, now: Date) -> String? {
        let spoken = words(text)
        let eligible = candidates.filter { candidate in
            candidate.isActive || candidate.finishedAt.map { now.timeIntervalSince($0) <= recentWindow } == true
        }
        // Newest first: "tell Research Buddy…" means the latest job that agent ran.
        for candidate in eligible.reversed() {
            let title = words(candidate.title)
            if title.count > 2, spoken.contains(title) { return candidate.id }
        }
        for candidate in eligible.reversed() {
            if let name = candidate.agentName, words(name).count > 2, spoken.contains(words(name)) { return candidate.id }
        }
        let active = eligible.filter(\.isActive)
        if active.count == 1 { return active[0].id }
        if let frontJobID, eligible.contains(where: { $0.id == frontJobID }) { return frontJobID }
        return nil
    }
}

/// Which cards are up, which is in front, which are folded. Pure, so the rules are tested.
nonisolated struct AgentCardDeck: Equatable, Sendable {
    /// Oldest first.
    private(set) var ids: [String] = []
    private(set) var frontID: String?
    private(set) var collapsed: Set<String> = []

    var count: Int { ids.count }
    /// 1-based.
    var frontIndex: Int { (frontID.flatMap { ids.firstIndex(of: $0) } ?? 0) + 1 }

    /// Brings the deck in line with the jobs that want a card now. A newly arrived job comes
    /// to the front; if the front card left, the newest running one takes its place.
    mutating func sync(visible: [String], active: Set<String>) {
        let arrived = visible.filter { !ids.contains($0) }
        ids = visible
        collapsed.formIntersection(Set(visible))
        if let newest = arrived.last {
            frontID = newest
        } else if frontID == nil || !visible.contains(frontID!) {
            frontID = visible.last { active.contains($0) } ?? visible.last
        }
    }

    mutating func flip(by step: Int) {
        guard ids.count > 1, let frontID, let index = ids.firstIndex(of: frontID) else { return }
        let next = ((index + step) % ids.count + ids.count) % ids.count
        self.frontID = ids[next]
    }

    mutating func setCollapsed(_ isCollapsed: Bool, id: String) {
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
    }

    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }
}

/// Which of the registered tools a job is offered.
nonisolated enum AgentToolAvailability {
    /// A routine run must not be able to set up, wake or delete routines.
    static let hiddenFromUnattendedRuns: Set<String> = ["create_routine", "delete_routine", "pause_routine"]

    static func names(registered: [String], hasAgent: Bool, isUnattended: Bool) -> Set<String> {
        var names = Set(registered)
        // Only a named agent has a memory file to add to.
        if !hasAgent { names.remove("remember") }
        if isUnattended { names.subtract(hiddenFromUnattendedRuns) }
        return names
    }
}
