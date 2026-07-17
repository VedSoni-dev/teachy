//
//  CoachingSession.swift
//  leanring-buddy
//
//  Session management for coaching interactions. Tracks the current state
//  of a learning session, manages transitions between phases, and coordinates
//  the core loop (trigger → teach → verify → teach-back → accumulate).
//

import Foundation

// MARK: - Coaching phase

enum CoachingPhase: String, Codable, Equatable {
    case idle
    case settingUp
    case coaching
    case yourTurn
    case checking
    case verifying
    case understanding
    case teachBack
    case celebrating
    case retentionReview
    case placementCheck

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .settingUp: return "Setting Up"
        case .coaching: return "Coaching"
        case .yourTurn: return "Your Turn"
        case .checking: return "Checking"
        case .verifying: return "Verifying"
        case .understanding: return "Understanding"
        case .teachBack: return "Teach Back"
        case .celebrating: return "Celebrating"
        case .retentionReview: return "Retention Review"
        case .placementCheck: return "Placement Check"
        }
    }
}

// MARK: - Session event

enum SessionEvent: Codable {
    case sessionStarted(courseID: String)
    case goalStarted(goalID: String)
    case coachDelivered(text: String)
    case learnerResponded(text: String)
    case verificationStarted(depth: String)
    case verificationCompleted(result: String)
    case teachBackStarted(depth: String)
    case teachBackCompleted(result: String)
    case goalCompleted(goalID: String, summary: String)
    case courseCompleted(courseID: String)
    case retentionCheckScheduled(skillID: String)
    case retentionCheckCompleted(skillID: String, correct: Bool)
    case skillUpdated(skillID: String, oldLevel: String, newLevel: String)
    case portfolioItemCreated(itemID: String)
    case sessionPaused
    case sessionResumed
}

// MARK: - Coaching session

struct CoachingSession: Codable, Identifiable {
    let id: String
    let adapterID: String
    var courseID: String?
    var currentPhase: CoachingPhase
    var currentGoalID: String?
    var startedAt: Date
    var lastActivityAt: Date
    var eventLog: [SessionEvent]
    var goalHistory: [GoalSessionRecord]
    var retainedSkills: [String]
    var portfolioItemsCreated: [String]
    var totalVerificationChecks: Int
    var totalTeachBackTurns: Int
    var averageVerificationScore: Double
    var isActive: Bool

    init(adapterID: String, courseID: String? = nil) {
        self.id = UUID().uuidString
        self.adapterID = adapterID
        self.courseID = courseID
        self.currentPhase = .idle
        self.startedAt = Date()
        self.lastActivityAt = Date()
        self.eventLog = []
        self.goalHistory = []
        self.retainedSkills = []
        self.portfolioItemsCreated = []
        self.totalVerificationChecks = 0
        self.totalTeachBackTurns = 0
        self.averageVerificationScore = 0.0
        self.isActive = true
    }

    mutating func recordEvent(_ event: SessionEvent) {
        eventLog.append(event)
        lastActivityAt = Date()
        if eventLog.count > 100 {
            eventLog = Array(eventLog.suffix(100))
        }
    }

    mutating func advancePhase(to newPhase: CoachingPhase) {
        currentPhase = newPhase
        lastActivityAt = Date()
    }

    mutating func completeGoal(goalID: String, summary: String) {
        let record = GoalSessionRecord(
            goalID: goalID,
            completedAt: Date(),
            summary: summary
        )
        goalHistory.append(record)
        currentGoalID = nil
        lastActivityAt = Date()
    }

    mutating func recordVerification(score: Double) {
        totalVerificationChecks += 1
        let total = Double(totalVerificationChecks)
        averageVerificationScore = ((averageVerificationScore * (total - 1)) + score) / total
    }

    mutating func recordTeachBack() {
        totalTeachBackTurns += 1
    }

    var sessionDurationMinutes: Int {
        Calendar.current.dateComponents([.minute], from: startedAt, to: Date()).minute ?? 0
    }

    var goalsCompleted: Int {
        goalHistory.count
    }
}

// MARK: - Goal session record

struct GoalSessionRecord: Codable {
    let goalID: String
    let completedAt: Date
    let summary: String
}

// MARK: - Session factory

enum CoachingSessionFactory {
    /// Create a session for a course on the macOS adapter.
    static func macOSCourseSession(courseID: String) -> CoachingSession {
        CoachingSession(adapterID: "macos", courseID: courseID)
    }

    /// Create a session for the browser adapter.
    static func browserSession() -> CoachingSession {
        CoachingSession(adapterID: "browser")
    }

    /// Create a session for the CLI adapter.
    static func cliSession() -> CoachingSession {
        CoachingSession(adapterID: "cli")
    }

    /// Create a session for a Makr client adapter.
    static func makrSession(clientID: String) -> CoachingSession {
        CoachingSession(adapterID: "makr-\(clientID)")
    }
}
