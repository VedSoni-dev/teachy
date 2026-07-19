//
//  TeachyProject.swift
//  leanring-buddy
//
//  A durable build arc — the v2 spine. Guided tasks are ephemeral by design
//  (they die on staleness or course start); a TeachyProject survives across
//  days and app relaunches so "help me make a site for my food truck" is
//  something Teachy and the learner come back to together, step by step,
//  until it ships to a real URL.
//
//  Persisted inside TeachyEngineState (engine-state.json) via the engine's
//  existing save/load machinery — no separate persistence layer.
//

import Foundation

enum ProjectStatus: String, Codable, Equatable {
    /// Actively being worked (or ready to resume any time).
    case active
    /// Deployed/delivered — `deployedURL` should be set, portfolio item captured.
    case shipped
    /// The ephemeral guided task around it went stale — waiting to be picked back up.
    case paused
    /// Explicitly walked away from.
    case abandoned
}

struct TeachyProject: Codable, Identifiable, Equatable {
    let id: String
    /// Short human title, e.g. "Food truck site".
    var title: String
    /// The scoped outcome in plain language — what "done" means for the whole project.
    var goalDescription: String
    /// Reuses the course goal shape (doneWhen etc.) so verification works unchanged.
    var steps: [CourseLearningGoal]
    var currentStepIndex: Int
    var status: ProjectStatus
    /// The whole point — set when the thing goes live.
    var deployedURL: String?
    /// Link to the PortfolioItem captured at ship time.
    var portfolioItemID: String?
    /// Dated "what happened" entries — one per verified step, plus notable moments.
    var stepJournal: [TimestampedFact]
    var createdAt: Date
    var lastWorkedAt: Date

    init(title: String, goalDescription: String) {
        self.id = UUID().uuidString
        self.title = title
        self.goalDescription = goalDescription
        self.steps = []
        self.currentStepIndex = 0
        self.status = .active
        self.stepJournal = []
        self.createdAt = Date()
        self.lastWorkedAt = Date()
    }

    var currentStep: CourseLearningGoal? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    var isComplete: Bool {
        !steps.isEmpty && currentStepIndex >= steps.count
    }

    mutating func appendJournalEntry(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stepJournal.append(TimestampedFact(text: trimmed, capturedAt: Date()))
        // Journals are working notes, not an archive — keep the recent story.
        stepJournal = Array(stepJournal.suffix(30))
        lastWorkedAt = Date()
    }
}
