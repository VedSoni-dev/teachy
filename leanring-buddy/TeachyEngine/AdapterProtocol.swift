//
//  AdapterProtocol.swift
//  leanring-buddy
//
//  Environment-agnostic contract between the Teachy engine and any surface
//  (macOS app, browser extension, CLI, Makr client stack). The engine never
//  knows where events come from; adapters never know how coaching is generated.
//

import Foundation

// MARK: - Input events that adapters emit

enum LearnerEvent: Codable, Equatable {
    case screenCaptured(imageDataBase64: String, context: String)
    case actionPerformed(toolName: String, arguments: String, resultSummary: String)
    case questionAsked(questionText: String)
    case goalAttempted(goalID: String, attemptDescription: String)
    case teachBackResponse(responseText: String)
    case skillUsed(skillID: String, usageContext: String)
    case courseStarted(courseID: String)
    case courseCompleted(courseID: String)
    case goalCompleted(goalID: String, verificationSummary: String)
    case retentionCheckAnswered(skillID: String, correct: Bool, responseTimeMs: Int)
    case userMoodDetected(mood: String)
    case sessionResumed
    case sessionPaused
    case personalFactShared(factText: String)
}

// MARK: - Output from the engine

enum CoachingOutput: Equatable {
    case coachMessage(text: String, pointingTargetID: String?)
    case verificationCheck(criteriaText: String, depth: String)
    case teachBackPrompt(questionText: String)
    case retentionCheck(skillID: String, questionText: String)
    case portfolioUpdate(itemSummary: String)
    case skillLevelChanged(skillID: String, oldLevel: String, newLevel: String)
    case nudge(text: String, reason: String)
    case coursePlacementSuggestion(startGoalIndex: Int, reason: String)
    case celebration(messageText: String)
}

// MARK: - Adapter session

struct AdapterSession: Codable, Identifiable {
    let id: String
    let adapterID: String
    let adapterName: String
    let startedAt: Date
    var lastEventAt: Date
    var eventCount: Int

    init(adapterID: String, adapterName: String) {
        self.id = UUID().uuidString
        self.adapterID = adapterID
        self.adapterName = adapterName
        self.startedAt = Date()
        self.lastEventAt = Date()
        self.eventCount = 0
    }

    mutating func recordEvent() {
        lastEventAt = Date()
        eventCount += 1
    }
}

// MARK: - Adapter protocol

/// Every surface (macOS, browser, CLI, Makr client) implements this to
/// connect to the Teachy engine. The engine is the brain; adapters are
/// the senses and voice.
protocol TeachyAdapter {
    /// Unique identifier for this adapter type (e.g. "macos", "browser-chrome", "cli").
    var adapterID: String { get }

    /// Human-readable name (e.g. "macOS Menu Bar", "Chrome Extension").
    var adapterName: String { get }

    /// Called when the engine wants to deliver coaching to the learner.
    /// The adapter renders this in its native UI (overlay, terminal, browser popup, etc.).
    func deliverCoaching(_ outputs: [CoachingOutput], session: AdapterSession) async

    /// Called when the engine needs a screenshot for verification.
    /// Returns nil if the adapter can't capture right now.
    func captureScreen() async -> Data?

    /// Called when the engine needs the learner to answer a teach-back question.
    /// The adapter presents the question and waits for a response.
    func promptTeachBack(question: String, session: AdapterSession) async -> String?

    /// Called when the engine wants to open a URL in the learner's browser.
    func openURL(_ urlString: String) async
}
