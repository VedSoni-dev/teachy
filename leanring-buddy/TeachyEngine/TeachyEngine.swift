//
//  TeachyEngine.swift
//  leanring-buddy
//
//  The main engine that coordinates all subsystems: learner model, skill graph,
//  verification, teach-back, spaced repetition, and portfolio. Environment-
//  agnostic — receives events from adapters and outputs coaching decisions.
//  Adapters never know how coaching is generated; the engine never knows
//  where events come from.
//

import Combine
import Foundation

// MARK: - Engine configuration

struct TeachyEngineConfig: Codable {
    var defaultVerificationDepth: VerificationDepth
    var defaultTeachBackDepth: TeachBackDepth
    var maxRetentionChecksPerSession: Int
    var enableSpacedRepetition: Bool
    var enablePortfolio: Bool
    var enableSkillGraph: Bool
    var enableCrossDomainTransfer: Bool
    var retentionCheckFrequency: TimeInterval

    static var `default`: TeachyEngineConfig {
        TeachyEngineConfig(
            defaultVerificationDepth: .visionPlusExplain,
            defaultTeachBackDepth: .fullExplanation,
            maxRetentionChecksPerSession: 3,
            enableSpacedRepetition: true,
            enablePortfolio: true,
            enableSkillGraph: true,
            enableCrossDomainTransfer: true,
            retentionCheckFrequency: 86400
        )
    }
}

// MARK: - Engine state

struct TeachyEngineState: Codable {
    var activeSession: CoachingSession?
    var learnerModel: LearnerModel
    var skillGraph: SkillGraph
    var config: TeachyEngineConfig
    var lastRetentionCheckDate: Date?
    var pendingRetentionChecks: [RetentionCheck]
    var pendingTransfers: [SkillTransfer]
    var sessionHistory: [CoachingSession]
    /// Durable build arcs (v2) — survive across days/relaunches, unlike ephemeral
    /// guided tasks. See `TeachyProject`.
    var projects: [TeachyProject]

    init() {
        self.learnerModel = LearnerModel()
        self.skillGraph = BundledSkillGraph.aiFluencyGraph
        self.config = .default
        self.pendingRetentionChecks = []
        self.pendingTransfers = []
        self.sessionHistory = []
        self.projects = []
    }

    /// Custom decode with `decodeIfPresent ?? default` for EVERY field. Synthesized
    /// Codable would hard-fail on any missing key — meaning adding a new field (like
    /// `projects`) would make every existing engine-state.json undecodable and
    /// silently reset the learner's entire memory. This decoder makes the state file
    /// forward-compatible with future field additions once and for all. Encoding
    /// stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeSession = try container.decodeIfPresent(CoachingSession.self, forKey: .activeSession)
        learnerModel = try container.decodeIfPresent(LearnerModel.self, forKey: .learnerModel) ?? LearnerModel()
        skillGraph = try container.decodeIfPresent(SkillGraph.self, forKey: .skillGraph) ?? BundledSkillGraph.aiFluencyGraph
        config = try container.decodeIfPresent(TeachyEngineConfig.self, forKey: .config) ?? .default
        lastRetentionCheckDate = try container.decodeIfPresent(Date.self, forKey: .lastRetentionCheckDate)
        pendingRetentionChecks = try container.decodeIfPresent([RetentionCheck].self, forKey: .pendingRetentionChecks) ?? []
        pendingTransfers = try container.decodeIfPresent([SkillTransfer].self, forKey: .pendingTransfers) ?? []
        sessionHistory = try container.decodeIfPresent([CoachingSession].self, forKey: .sessionHistory) ?? []
        projects = try container.decodeIfPresent([TeachyProject].self, forKey: .projects) ?? []
    }
}

// MARK: - Teachy engine

@MainActor
final class TeachyEngine: ObservableObject {
    @Published private(set) var state: TeachyEngineState
    @Published private(set) var isProcessing: Bool = false

    let portfolioManager: PortfolioManager
    private let dataDirectoryURL: URL

    /// Number of calendar days between the previous session's date and today.
    /// Captured at `startSession` BEFORE `recordActivity()` overwrites `lastActiveDate`,
    /// so prompt builders can say "last session was N days ago" accurately.
    /// Transient — in-memory only, recomputed each launch on the first session call.
    private(set) var daysSinceLastSession: Int?

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.dataDirectoryURL = homeDir.appendingPathComponent(".teachy", isDirectory: true)
        self.portfolioManager = PortfolioManager()

        if let savedState = Self.loadState(from: dataDirectoryURL) {
            self.state = savedState
        } else {
            self.state = TeachyEngineState()
        }
    }

    // MARK: - Session lifecycle

    /// Start a new coaching session.
    func startSession(adapterID: String, courseID: String? = nil) -> CoachingSession {
        var session = CoachingSession(adapterID: adapterID, courseID: courseID)
        session.advancePhase(to: .settingUp)
        state.activeSession = session

        // Snapshot the days-since-last-session BEFORE recordActivity() overwrites
        // lastActiveDate — the prompt builder reads this value to say "last session
        // was N days ago" and needs the pre-update date to be accurate.
        if let previousLastActiveDate = state.learnerModel.lastActiveDate {
            let today = Calendar.current.startOfDay(for: Date())
            let previousDay = Calendar.current.startOfDay(for: previousLastActiveDate)
            daysSinceLastSession = Calendar.current.dateComponents([.day], from: previousDay, to: today).day
        } else {
            // First-ever session — no previous date to compare against.
            daysSinceLastSession = nil
        }

        state.learnerModel.recordActivity()

        // Check for retention checks on session start
        if state.config.enableSpacedRepetition {
            state.pendingRetentionChecks = SpacedRepetitionEngine.generateBatchRetentionChecks(
                from: state.learnerModel,
                skillGraph: state.skillGraph,
                maxChecks: state.config.maxRetentionChecksPerSession
            )
        }

        saveState()
        return session
    }

    /// End the current session and persist state.
    func endSession() {
        guard var session = state.activeSession else { return }
        session.isActive = false
        session.recordEvent(.sessionPaused)
        state.sessionHistory.append(session)
        state.activeSession = nil
        saveState()
    }

    // MARK: - Event processing

    /// Process a learner event and return coaching outputs.
    func processEvent(_ event: LearnerEvent) async -> [CoachingOutput] {
        guard var session = state.activeSession else { return [] }

        isProcessing = true
        defer { isProcessing = false }

        var outputs: [CoachingOutput] = []

        switch event {
        case .courseStarted(let courseID):
            session.courseID = courseID
            session.recordEvent(.sessionStarted(courseID: courseID))
            state.activeSession = session
            outputs.append(.celebration(messageText: "Course started — let's learn something new."))

        case .goalAttempted(let goalID, let description):
            session.currentGoalID = goalID
            session.advancePhase(to: .coaching)
            session.recordEvent(.goalStarted(goalID: goalID))
            state.activeSession = session

            // Check for cross-domain transfers
            if state.config.enableCrossDomainTransfer {
                let transfers = findTransfersForGoal(goalID)
                state.pendingTransfers = transfers
                for transfer in transfers {
                    outputs.append(.nudge(text: transfer.transferDescription, reason: "cross-domain-transfer"))
                }
            }

        case .goalCompleted(let goalID, let verificationSummary):
            session.completeGoal(goalID: goalID, summary: verificationSummary)
            session.recordEvent(.goalCompleted(goalID: goalID, summary: verificationSummary))
            state.activeSession = session
            state.learnerModel.totalGoalsCompleted += 1

            // Create portfolio item if enabled
            if state.config.enablePortfolio {
                let item = createPortfolioItem(for: goalID, verificationSummary: verificationSummary)
                outputs.append(.portfolioUpdate(itemSummary: "Portfolio item created: \(item.title)"))
                session.portfolioItemsCreated.append(item.id)
            }

            // Update skill levels. Capture the overall autonomy level BEFORE applying the
            // updates so we can fire the "training wheels came off" moment only on a real
            // transition (never every completed goal — that would spam).
            let autonomyLevelBeforeUpdates = CoachAutonomy.level(for: state.learnerModel)
            let skillUpdates = inferSkillUpdatesForGoal(goalID)
            var mostRecentlyLeveledSkillName: String?
            for update in skillUpdates {
                state.learnerModel.noteSkillVerified(update.skillID, level: update.newLevel, reason: update.reason)
                outputs.append(.skillLevelChanged(skillID: update.skillID, oldLevel: "", newLevel: update.newLevel.displayName))
                // Track the skill whose new level itself reaches proficient+ — that's the
                // one most plausibly responsible for a handoff, so we name it out loud.
                if update.newLevel >= .proficient {
                    mostRecentlyLeveledSkillName = state.learnerModel.skillNode(byID: update.skillID)?.skillName ?? update.skillID
                }
            }

            // Anti-dependency "say it out loud" moment: fire ONLY when the OVERALL autonomy
            // level actually stepped up (before < after) AND landed at watchThem or handsOff
            // (proficient / expert). Guarding on the transition means it fires once per
            // graduation, not on every goal that nudges a skill.
            let autonomyLevelAfterUpdates = CoachAutonomy.level(for: state.learnerModel)
            if autonomyLevelAfterUpdates > autonomyLevelBeforeUpdates,
               autonomyLevelAfterUpdates >= .watchThem {
                let leveledSkillPhrase = mostRecentlyLeveledSkillName.map { " your \($0)" } ?? " this"
                outputs.append(.nudge(
                    text: "You've leveled past me doing\(leveledSkillPhrase) — you're driving that yourself now.",
                    reason: "autonomy-transfer"
                ))
            }

            state.activeSession = session

        case .teachBackResponse(let responseText):
            session.recordEvent(.learnerResponded(text: responseText))
            session.recordTeachBack()
            state.activeSession = session
            state.learnerModel.appendRollingNote("teach-back: \(responseText.prefix(100))")

        case .retentionCheckAnswered(let skillID, let correct, let responseTimeMs):
            session.recordEvent(.retentionCheckCompleted(skillID: skillID, correct: correct))
            state.activeSession = session

            if let idx = state.learnerModel.skillNodes.firstIndex(where: { $0.id == skillID }) {
                let performance: ReviewPerformance = correct ? (responseTimeMs < 5000 ? .easy : .struggled) : .forgot
                let schedule = SpacedRepetitionEngine.scheduleReview(for: state.learnerModel.skillNodes[idx], performance: performance)
                state.learnerModel.skillNodes[idx].nextReviewAt = schedule.nextReviewDate
                state.learnerModel.skillNodes[idx].reviewCount = schedule.reviewCount
                state.learnerModel.skillNodes[idx].recordAttempt(performance: performance, context: "retention-check")
            }

        case .skillUsed(let skillID, let usageContext):
            state.learnerModel.noteSkillUsed(skillID, skillName: skillID, domain: "general", context: usageContext)

            // Check for contextual nudge
            if let skillNode = state.learnerModel.skillNode(byID: skillID),
               let nudge = SpacedRepetitionEngine.generateContextualNudge(for: skillNode, currentContext: usageContext) {
                outputs.append(.nudge(text: nudge, reason: "spaced-repetition"))
            }

        case .userMoodDetected(let mood):
            state.learnerModel.detectedMood = mood

        case .personalFactShared(let factText):
            state.learnerModel.appendPersonalFact(factText)

        case .courseCompleted(let courseID):
            state.learnerModel.totalCoursesCompleted += 1
            session.recordEvent(.courseCompleted(courseID: courseID))
            outputs.append(.celebration(messageText: "Course completed! Great work."))

        case .screenCaptured, .actionPerformed, .questionAsked, .sessionResumed, .sessionPaused:
            break
        }

        saveState()
        return outputs
    }

    // MARK: - Verification

    /// Run verification for the current goal at the specified depth.
    func verifyCurrentGoal(
        goal: CourseLearningGoal,
        depth: VerificationDepth? = nil,
        claudeAPI: ClaudeAPI
    ) async -> ExtendedVerificationResult {
        let effectiveDepth = depth ?? state.config.defaultVerificationDepth

        let result = await VerificationEngine.verify(
            goal: goal,
            depth: effectiveDepth,
            claudeAPI: claudeAPI,
            learnerModel: state.learnerModel
        )

        if var session = state.activeSession {
            session.recordVerification(score: result.baseResult.status == .pass ? 1.0 : result.baseResult.status == .partial ? 0.5 : 0.0)
            state.activeSession = session
        }

        // Update skill levels from verification
        for update in result.suggestedSkillUpdates {
            state.learnerModel.noteSkillVerified(update.skillID, level: update.newLevel, reason: update.reason)
        }

        saveState()
        return result
    }

    // MARK: - Teach-back

    /// Run teach-back at the specified or recommended depth.
    func runTeachBack(
        goal: CourseLearningGoal,
        learnerAnswer: String,
        previousAnswers: [String] = [],
        verifyResult: CourseVerificationResult? = nil,
        depth: TeachBackDepth? = nil,
        claudeAPI: ClaudeAPI
    ) async -> TeachBackResult {
        let effectiveDepth = depth ?? TeachBackEngine.recommendedDepth(
            goal: goal,
            learnerModel: state.learnerModel,
            verifyResult: verifyResult
        )

        let result = await TeachBackEngine.runTeachBack(
            goal: goal,
            depth: effectiveDepth,
            learnerAnswer: learnerAnswer,
            previousAnswers: previousAnswers,
            verifyResult: verifyResult,
            claudeAPI: claudeAPI
        )

        // Apply skill updates from teach-back
        for update in result.skillUpdates {
            state.learnerModel.noteSkillVerified(update.skillID, level: update.newLevel, reason: update.reason)
        }

        // Store teaching demo if present
        if let demo = result.teachingDemo {
            state.learnerModel.addTeachingDemo(demo)
        }

        if var session = state.activeSession {
            session.recordEvent(.teachBackCompleted(result: result.understood ? "understood" : "needs-work"))
            state.activeSession = session
        }

        saveState()
        return result
    }

    // MARK: - Placement

    /// Run placement check using the skill graph.
    func runPlacementCheck(
        course: ClickyCourse,
        learnerAnswer: String
    ) -> PlacementRecommendation {
        let answers = learnerAnswer.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return state.skillGraph.placementRecommendation(for: answers, learnerModel: state.learnerModel)
    }

    // MARK: - Retention checks

    /// Get all due retention checks.
    func getDueRetentionChecks() -> [RetentionCheck] {
        state.pendingRetentionChecks.isEmpty
            ? SpacedRepetitionEngine.generateBatchRetentionChecks(from: state.learnerModel, skillGraph: state.skillGraph)
            : state.pendingRetentionChecks
    }

    /// Get skills at risk of being forgotten.
    func getAtRiskSkills() -> [LearnerSkillNode] {
        SpacedRepetitionEngine.getAtRiskSkills(from: state.learnerModel)
    }

    // MARK: - Portfolio

    /// Get the full portfolio summary.
    func portfolioSummary() -> PortfolioSummary? {
        portfolioManager.summary
    }

    /// Export the portfolio for sharing.
    func exportPortfolio(learnerName: String) -> PortfolioExport {
        portfolioManager.exportPortfolio(learnerName: learnerName)
    }

    // MARK: - Learner model

    /// Get the current learner model.
    func getLearnerModel() -> LearnerModel {
        state.learnerModel
    }

    /// Replace the learner model (used for legacy profile migration).
    func setLearnerModel(_ model: LearnerModel) {
        state.learnerModel = model
        saveState()
    }

    /// Detect mood from user response and update the learner model.
    func detectMood(from response: String) {
        state.learnerModel.detectMood(from: response)
        saveState()
    }

    /// Detect humor receptivity from user response and update the learner model.
    func updateHumorReceptivity(from response: String) {
        let receptivity = HumorReceptivityHeuristic.detect(from: response)
        state.learnerModel.updateHumorReceptivity(receptivity)
        saveState()
    }

    /// Record a reaction to the outside-lesson relationship check-in card (Home tab).
    /// Updates the timestamp (gates re-showing the card for 24h) and nudges
    /// `humorReceptivity` — direct user feedback carries at least as much weight
    /// as the passive heuristic already updating that same field.
    func recordRelationshipCheckInReaction(wasPositive: Bool) {
        state.learnerModel.lastRelationshipCheckInAt = Date()
        state.learnerModel.updateHumorReceptivity(wasPositive ? .warm : .efficient)
        saveState()
    }

    /// Record a personal fact directly, independent of an active `CoachingSession`.
    /// `processEvent(.personalFactShared)` is the right call inside a course turn
    /// (a session is already guaranteed active there), but quick companion Q&A
    /// happens *outside* a course — `processEvent` no-ops without an active session
    /// (see the guard at the top of `processEvent`), so that path calls this instead.
    func recordPersonalFact(_ fact: String) {
        state.learnerModel.appendPersonalFact(fact)
        saveState()
    }

    /// Record one practice occurrence of the "reading errors" skill — the single most
    /// transferable builder skill, made visible in the Skills tab alongside the others.
    /// Called each time the debugging-coach protocol fires (an error was visible on
    /// screen during a verification turn) to track exposure over time. Uses
    /// `noteSkillUsed` (practice mark) rather than `noteSkillVerified` (proficiency
    /// jump) because seeing one error does not prove mastery — repeated exposure across
    /// sessions builds the skill naturally through the SM-2 review path.
    func recordErrorReadingPractice() {
        state.learnerModel.noteSkillUsed(
            "reading-errors",
            skillName: "Reading errors",
            domain: "programming",
            context: "error-visible-during-verification"
        )
        saveState()
    }

    /// Stamps onboarding-complete timestamp the first time it's called.
    /// Idempotent — subsequent calls are no-ops so re-entrant callers are safe.
    func recordOnboardingCompleted() {
        guard state.learnerModel.onboardingCompletedAt == nil else { return }
        state.learnerModel.onboardingCompletedAt = Date()
        saveState()
    }

    /// Session-independent recorder for app-context sightings (mirrors `recordPersonalFact`).
    /// Returns the app name when THIS sighting pushed the app over the recommendation
    /// threshold (≥5 sightings across ≥2 distinct days, not previously suggested) — the
    /// caller queues a proactive AI-workflow moment for it. Marks the app as suggested
    /// in the same mutation so it can only ever fire once per app.
    func recordWorkflowSignal(_ signalText: String) -> String? {
        state.learnerModel.appendWorkflowSignal(signalText)

        let appName = LearnerModel.workflowSignalAppName(from: signalText)
        var newlyCrossedThresholdAppName: String?
        if !state.learnerModel.workflowAppsAlreadySuggested.contains(appName) {
            let appSignals = state.learnerModel.workflowSignals.filter {
                LearnerModel.workflowSignalAppName(from: $0.text) == appName
            }
            let distinctDays = Set(appSignals.map { Calendar.current.startOfDay(for: $0.capturedAt) })
            if appSignals.count >= 5, distinctDays.count >= 2 {
                state.learnerModel.workflowAppsAlreadySuggested.append(appName)
                newlyCrossedThresholdAppName = appName
            }
        }
        saveState()
        return newlyCrossedThresholdAppName
    }

    // MARK: - Projects (durable build arcs)

    var activeProjects: [TeachyProject] {
        state.projects.filter { $0.status == .active || $0.status == .paused }
    }

    func project(withID projectID: String) -> TeachyProject? {
        state.projects.first { $0.id == projectID }
    }

    /// Insert or replace by id, then persist.
    func upsertProject(_ project: TeachyProject) {
        if let existingIndex = state.projects.firstIndex(where: { $0.id == project.id }) {
            state.projects[existingIndex] = project
        } else {
            state.projects.append(project)
        }
        saveState()
    }

    /// Reattach to an existing non-abandoned project with a matching title, or
    /// create a fresh one. Matching by title (case-insensitive) is what lets the
    /// model say "[PROJECT: Food truck site]" across sessions and land on the same
    /// arc instead of duplicating it.
    func createOrResumeProject(title: String, goalDescription: String) -> TeachyProject {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingIndex = state.projects.firstIndex(where: {
            $0.status != .abandoned && $0.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame
        }) {
            state.projects[existingIndex].status = .active
            state.projects[existingIndex].lastWorkedAt = Date()
            saveState()
            return state.projects[existingIndex]
        }
        let newProject = TeachyProject(title: normalizedTitle, goalDescription: goalDescription)
        state.projects.append(newProject)
        saveState()
        return newProject
    }

    /// A guided task around this project went stale — the work waits, it doesn't die.
    func pauseProject(withID projectID: String) {
        guard let index = state.projects.firstIndex(where: { $0.id == projectID }),
              state.projects[index].status == .active else { return }
        state.projects[index].status = .paused
        saveState()
    }

    /// Ships the project: status, URL, portfolio capture (first real use of
    /// `PortfolioItem.artifactURL`). Returns the updated project for celebration copy.
    @discardableResult
    func shipProject(withID projectID: String, deployedURL: String?) -> TeachyProject? {
        guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        state.projects[index].status = .shipped
        if let deployedURL, !deployedURL.isEmpty {
            state.projects[index].deployedURL = deployedURL
        }
        state.projects[index].appendJournalEntry("Shipped\(deployedURL.map { " — \($0)" } ?? "")")

        let project = state.projects[index]
        let portfolioItem = portfolioManager.createItem(
            courseID: "project",
            goalID: project.id,
            kind: .project,
            title: project.title,
            description: project.goalDescription,
            artifactURL: project.deployedURL,
            skillsUsed: project.steps.map(\.title)
        )
        state.projects[index].portfolioItemID = portfolioItem.id

        // North-star metric: record the first-ever ship timestamp and fire the
        // time-to-first-ship event when we also have an onboarding timestamp.
        if state.learnerModel.firstShippedAt == nil {
            let firstShipDate = Date()
            state.learnerModel.firstShippedAt = firstShipDate
            if let onboardingDate = state.learnerModel.onboardingCompletedAt {
                let secondsSinceOnboarding = Int(firstShipDate.timeIntervalSince(onboardingDate))
                ClickyAnalytics.trackFirstShip(secondsSinceOnboarding: secondsSinceOnboarding)
                print("Teachy north-star: \(secondsSinceOnboarding)s from onboarding to first ship")
            }
        }

        saveState()
        return state.projects[index]
    }

    /// Get skills in a specific domain.
    func skills(inDomain domain: String) -> [LearnerSkillNode] {
        state.learnerModel.skills(inDomain: domain)
    }

    /// Get suggested next skills to learn.
    func suggestedNextSkills() -> [SkillNode] {
        state.skillGraph.suggestedNextSkills(for: state.learnerModel)
    }

    /// Get cross-domain transfers available.
    func availableTransfers() -> [SkillTransfer] {
        var allTransfers: [SkillTransfer] = []
        for node in state.learnerModel.skillNodes where node.proficiencyLevel >= .competent {
            let transfers = state.skillGraph.findTransfers(for: node.id, in: state.learnerModel)
            allTransfers.append(contentsOf: transfers)
        }
        return allTransfers
    }

    // MARK: - Config

    /// Update engine configuration.
    func updateConfig(_ updater: (inout TeachyEngineConfig) -> Void) {
        updater(&state.config)
        saveState()
    }

    // MARK: - Private helpers

    private func findTransfersForGoal(_ goalID: String) -> [SkillTransfer] {
        let skills = inferSkillIDsForGoal(goalID)
        var transfers: [SkillTransfer] = []
        for skillID in skills {
            let skillTransfers = state.skillGraph.findTransfers(for: skillID, in: state.learnerModel)
            transfers.append(contentsOf: skillTransfers)
        }
        return transfers
    }

    private func inferSkillUpdatesForGoal(_ goalID: String) -> [ExtendedVerificationResult.SkillUpdate] {
        let skills = inferSkillIDsForGoal(goalID)
        return skills.map { skillID in
            ExtendedVerificationResult.SkillUpdate(
                skillID: skillID,
                newLevel: progressedProficiencyLevel(forSkillID: skillID),
                reason: "Goal completed"
            )
        }
    }

    /// Evidence-based leveling — the fix for the "always beginner" cap that
    /// kept the autonomy-transfer mechanic from ever firing. Each verified
    /// goal completion is one rep on the skill; cumulative reps map to a
    /// level: 1 → beginner, 3 → competent, 6 → proficient. Rep-based
    /// progression deliberately caps at proficient — expert stays reserved
    /// for the richer assessments (transfer tests, code-quality) that prove
    /// depth rather than repetition. `reviewCount` is read BEFORE
    /// `noteSkillVerified` increments it, so the Nth completion lands the level.
    private func progressedProficiencyLevel(forSkillID skillID: String) -> ProficiencyLevel {
        let completedVerificationsIncludingThisOne =
            (state.learnerModel.skillNode(byID: skillID)?.reviewCount ?? 0) + 1
        switch completedVerificationsIncludingThisOne {
        case ..<3: return .beginner
        case 3..<6: return .competent
        default: return .proficient
        }
    }

    private func inferSkillIDsForGoal(_ goalID: String) -> [String] {
        var skills: [String] = []
        let goalLower = goalID.lowercased()

        let patterns: [(String, [String])] = [
            ("prompt-engineering-basics", ["prompt"]),
            ("output-verification", ["verify", "check"]),
            ("ai-assisted-coding", ["code", "program"]),
            ("ai-writing-assistance", ["write", "draft"]),
            ("ai-research", ["research"]),
            ("ai-data-analysis", ["data", "analyze"]),
            ("cursor-ide-usage", ["cursor"]),
            ("claude-code-usage", ["claude-code"]),
            ("chatgpt-usage", ["chatgpt"]),
            ("claude-usage", ["claude"]),
            ("ai-automation", ["automate"]),
            ("ai-agent-usage", ["agent"])
        ]

        for (skillID, keywords) in patterns {
            if keywords.contains(where: { goalLower.contains($0) }) {
                skills.append(skillID)
            }
        }

        return skills
    }

    private func createPortfolioItem(for goalID: String, verificationSummary: String) -> PortfolioItem {
        portfolioManager.createItem(
            courseID: state.activeSession?.courseID ?? "unknown",
            goalID: goalID,
            kind: .project,
            title: "Goal: \(goalID)",
            description: verificationSummary,
            skillsUsed: inferSkillIDsForGoal(goalID)
        )
    }

    // MARK: - Persistence

    private static let stateFileName = "engine-state.json"

    private func saveState() {
        let directoryURL = dataDirectoryURL
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let fileURL = directoryURL.appendingPathComponent(Self.stateFileName)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadState(from directoryURL: URL) -> TeachyEngineState? {
        let fileURL = directoryURL.appendingPathComponent(stateFileName)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(TeachyEngineState.self, from: data) else {
            return nil
        }
        return decoded
    }
}
