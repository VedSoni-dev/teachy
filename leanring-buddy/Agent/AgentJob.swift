//
//  AgentJob.swift
//  leanring-buddy
//
//  An agent job: one request the agent works through, with a name, a plan the
//  user can read, a step log, a budget and a Stop. `AgentJobCenter` runs up to
//  four of them at once, each with its own conversation, budget and consent
//  scope; `AgentLoop` (AgentLoop.swift) is the model / tool loop each one runs.
//
//  - Starting a job never cancels another. A fifth job waits its turn.
//  - `followUp(jobID:text:)` adds to a job's conversation: a running job reads
//    it before its next step, a finished one wakes up and carries on.
//  - Drive (the real mouse and keyboard) is held by one job at a time.
//  - Every job that had a card, and every routine run, is saved to
//    ~/.teachy/agents/history/.
//
//  Model calls go ONLY through TeachyAIRouter (job `.agent`). Tool calls go
//  ONLY through AgentToolRegistry.invoke, which holds the permission gate.
//

import AppKit
import Combine
import Foundation

/// The job a tool is running inside. Set by the runner around every tool call.
enum AgentJobContext {
    @TaskLocal static var current: AgentJob?
}

enum AgentJobStopReason: Equatable {
    case stopButton
    case userTookOver(String)
    case handedBack(String)
    case superseded

    /// What Teachy says when the job ends this way.
    var spokenLine: String {
        switch self {
        case .stopButton: return "Okay, I've stopped."
        case .userTookOver: return "Okay, it's all yours."
        case .handedBack(let line): return line
        case .superseded: return ""
        }
    }

    var label: String {
        switch self {
        case .stopButton: return "you pressed Stop"
        case .userTookOver(let how): return how
        case .handedBack: return "handed back to you"
        case .superseded: return "replaced by a newer request"
        }
    }
}

@MainActor
final class AgentJob: ObservableObject, Identifiable {
    nonisolated let id: String
    nonisolated let request: String
    /// Coaching turns run as quiet jobs: no card under the notch.
    nonisolated let showsCard: Bool
    nonisolated let drive: DriveSession
    /// The named agent this job runs as, if any.
    nonisolated let agentSlug: String?
    nonisolated let agentName: String?
    /// Set when a routine started it.
    nonisolated let routineID: String?
    /// Nobody is watching (a routine): the gate never asks, it refuses.
    nonisolated let isUnattended: Bool
    /// Where relative file paths, bash and searches start: the code project when the job has
    /// one, else the named agent's `files/` folder. Symlinks resolved.
    nonisolated let workingDirectory: String?
    /// The named agent's `files/` folder (read and written freely), symlinks resolved.
    nonisolated let agentFilesDirectory: String?
    /// The git project the person pointed this job at, symlinks resolved. Read freely, edited with a yes.
    nonisolated let projectDirectory: String?
    let startedAt = Date()

    @Published fileprivate(set) var projectID: String?
    @Published var title: String
    @Published var plan = AgentPlan()
    @Published var status: AgentJobStatus = .planning
    @Published var steps: [AgentStep] = []
    /// One short line about what is happening right now ("Reading the window").
    @Published var activity = "Thinking"
    @Published var isDriving = false
    @Published private(set) var finishedAt: Date?
    /// The final answer, once there is one.
    @Published fileprivate(set) var answer = ""
    /// What the person added after the first request.
    @Published fileprivate(set) var followUps: [String] = []
    /// Calls the gate refused because nobody was there to say yes (unattended runs).
    @Published private(set) var refusals: [String] = []

    var budget: AgentJobBudget
    private(set) var stopReason: AgentJobStopReason?
    fileprivate(set) var task: Task<String, Error>?

    /// This job's own conversation. Kept after it ends so a follow-up can carry on.
    fileprivate var messages: [[String: Any]] = []
    fileprivate var pendingFollowUps: [String] = []
    /// Things the person said that the job must keep to; written to its notes file.
    fileprivate var rules: [String] = []
    fileprivate var launch: AgentJobRequest?
    fileprivate var registry: BackgroundAgentToolRegistry?
    fileprivate let maxIterations: Int
    fileprivate let maxWallTime: TimeInterval

    /// Explicit jobs and routine runs share the four slots; quiet coaching turns do not wait.
    var countsTowardLimit: Bool { showsCard || isUnattended }

    init(
        request: String,
        title: String? = nil,
        showsCard: Bool,
        maxIterations: Int,
        maxWallTime: TimeInterval,
        agentSlug: String? = nil,
        agentName: String? = nil,
        workingDirectory: String? = nil,
        agentFilesDirectory: String? = nil,
        projectDirectory: String? = nil,
        projectID: String? = nil,
        routineID: String? = nil,
        isUnattended: Bool = false
    ) {
        let identifier = UUID().uuidString
        self.id = identifier
        self.request = request
        self.showsCard = showsCard
        self.drive = DriveSession(jobID: identifier)
        self.agentSlug = agentSlug
        self.agentName = agentName
        self.workingDirectory = workingDirectory
        // Before projects, the working folder WAS the agent's files folder; callers that only
        // pass workingDirectory keep that meaning.
        self.agentFilesDirectory = agentFilesDirectory ?? (projectDirectory == nil ? workingDirectory : nil)
        self.projectDirectory = projectDirectory
        self.projectID = projectID
        self.routineID = routineID
        self.isUnattended = isUnattended
        self.title = title ?? AgentJobTitle.fallback(from: request)
        self.maxIterations = maxIterations
        self.maxWallTime = maxWallTime
        self.budget = AgentJobBudget(maxIterations: maxIterations, maxWallTime: maxWallTime, startedAt: Date())
    }

    /// Stop button, Escape, mouse takeover, or a hand-back. Safe to call more than once.
    func stop(reason: AgentJobStopReason = .stopButton) {
        guard !status.isFinished else { return }
        stopReason = reason
        status = .stopped(reason.label)
        finishedAt = Date()
        task?.cancel()
        // A consent card left open for a job that no longer exists helps nobody.
        ConsentPrompter.shared.dismissCurrent(forJobID: id)
    }

    fileprivate func finish(_ status: AgentJobStatus) {
        guard !self.status.isFinished else { return }
        self.status = status
        finishedAt = Date()
    }

    /// A follow-up arrived after the job ended: it is a live job again, with a fresh budget.
    fileprivate func reopen() {
        stopReason = nil
        finishedAt = nil
        status = .running
        activity = "Thinking"
        budget = AgentJobBudget(maxIterations: maxIterations, maxWallTime: maxWallTime, startedAt: Date())
    }

    /// The gate could not ask (unattended run) and refused. Shown in the routine's result.
    func recordRefusal(_ note: String) {
        if !refusals.contains(note) { refusals.append(note) }
    }

    /// Something the person decided that must outlive context compaction ("not now" to a step).
    func addRule(_ rule: String) {
        if !rules.contains(rule) { rules.append(rule) }
    }

    var elapsedDescription: String {
        let seconds = Int((finishedAt ?? Date()).timeIntervalSince(startedAt))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// The answer plus anything a routine run was not allowed to do.
    var resultSummary: String {
        guard !refusals.isEmpty else { return answer }
        return ([answer] + refusals).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// What a caller asks the runner to do.
struct AgentJobRequest {
    var transcript: String
    var screenCaptures: [CompanionScreenCapture] = []
    var mouseOutlineContext: CompanionMouseOutlineContext?
    var systemPrompt: String
    var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []
    /// nil = every registered tool.
    var allowedToolNames: Set<String>?
    /// Explicit jobs keep a visible plan; quick coaching turns skip it.
    var usesPlan = false
    var showsCard = false
    var maxIterations = AgentJobBudget.defaultMaxIterations
    var maxWallTime = AgentJobBudget.defaultMaxWallTime
    /// Run as this named agent: its AGENT.md and MEMORY.md go in the prompt, its `files/` is the working folder
    /// (unless the job also has a project, which then is).
    var agent: AgentProfile?
    /// A code project folder (absolute or ~/) to work in: it becomes the working folder, its
    /// AGENTS.md / CLAUDE.md go in the prompt, and reading it needs no yes. Ignored if it is not a folder.
    var projectDirectory: String?
    var projectID: String?
    var routineID: String?
    /// A routine run: nobody can be asked, so anything needing a yes is refused.
    var isUnattended = false
    /// The plan rides along as a line of text with each tool call (no extra round trip). Off = the old loop.
    var inlinePlan = true
    /// Stream the model's replies, so the answer can be spoken as it arrives.
    var streams = true
    var onToolStep: ((AgentStep) -> Void)?
    var onStatus: ((AgentJobStatus, String) -> Void)?
    /// Each sentence of the final answer as soon as it is complete, already cleaned for speech.
    var onAnswerSentence: ((String) -> Void)?
    /// The sentences just delivered were not the answer after all (rare): stop speaking them.
    var onAnswerRetracted: (() -> Void)?
    /// The job ended (again, after each follow-up): its answer, or why it failed. Not called when superseded.
    var onFinished: ((AgentJob, Result<String, Error>) -> Void)?
}

struct AgentJobError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The published list of jobs, and the thing that runs them. UI observes `AgentJobCenter.shared.jobs`.
@MainActor
final class AgentJobCenter: ObservableObject {
    static let shared = AgentJobCenter()
    /// How many jobs are kept in memory (finished ones are dropped first; all are in the history files).
    static let historyLimit = 20

    @Published private(set) var jobs: [AgentJob] = []
    /// The card in front under the notch (set by the card stack). A follow-up with no name goes here.
    @Published var frontJobID: String?
    /// Bumped whenever a job is saved to the history files, so lists can refresh.
    @Published private(set) var historyRevision = 0

    var historyStore: AgentHistoryStore? = .shared
    var notesDirectory: URL = AgentHome.notesDirectory
    var roster: AgentRoster = .shared

    private var statusWatchers: [String: AnyCancellable] = [:]
    private var slots = AgentSlotBook()
    private var driveLease = DriveLease()
    private var slotWaiters: [String: CheckedContinuation<Void, Error>] = [:]

    var activeJobs: [AgentJob] { jobs.filter { !$0.status.isFinished } }

    func job(withID id: String) -> AgentJob? {
        jobs.first { $0.id == id }
    }

    func stopAll(reason: AgentJobStopReason = .stopButton) {
        activeJobs.forEach { $0.stop(reason: reason) }
    }

    func assignProject(jobID: String, to projectID: String?) throws {
        if let projectID, !AgentProjectStore.shared.projects.contains(where: { $0.id == projectID }) {
            throw AgentJobError(message: "This project no longer exists.")
        }
        let liveJob = job(withID: jobID)
        // A reopened job can still have a completed snapshot on disk.
        if let historyStore, var record = historyStore.record(id: jobID) {
            record.projectID = projectID
            try historyStore.save(record)
        } else if liveJob == nil {
            throw AgentJobError(message: "This job is no longer available.")
        }
        liveJob?.projectID = projectID
        historyRevision += 1
    }

    // MARK: Starting

    /// Starts a job and returns at once. It runs alongside whatever else is running; if four
    /// are already going it waits its turn (status `.queued`). Results come through
    /// `request.onFinished` and the published job.
    @discardableResult
    func start(_ request: AgentJobRequest, registry: BackgroundAgentToolRegistry) -> AgentJob {
        var agentFilesDirectory: String?
        if let agent = request.agent {
            let files = roster.filesDirectory(for: agent.slug)
            try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            agentFilesDirectory = files.resolvingSymlinksInPath().path
        }
        let projectDirectory = Self.existingDirectory(request.projectDirectory)
        let job = AgentJob(
            request: request.transcript,
            showsCard: request.showsCard,
            maxIterations: request.maxIterations,
            maxWallTime: request.maxWallTime,
            agentSlug: request.agent?.slug,
            agentName: request.agent?.name,
            workingDirectory: projectDirectory ?? agentFilesDirectory,
            agentFilesDirectory: agentFilesDirectory,
            projectDirectory: projectDirectory,
            projectID: request.projectID,
            routineID: request.routineID,
            isUnattended: request.isUnattended
        )
        job.launch = request
        job.registry = registry
        add(job)
        launch(job, isResume: false)
        return job
    }

    /// `path` expanded, standardized and with symlinks resolved, if it names an existing folder.
    static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.path
    }

    /// The prompt section for a job working in a code project: its AGENTS.md / CLAUDE.md
    /// (capped) and how to work on code. Read when the job starts, so edits to those files count.
    static func projectPromptSection(projectDirectory: String) -> String {
        let instructionFiles = CodingProjectDetection.instructionFileNames.compactMap { fileName -> (name: String, contents: String)? in
            let url = URL(fileURLWithPath: projectDirectory).appendingPathComponent(fileName)
            // Only small text files: a huge or binary "CLAUDE.md" is not instructions.
            guard let data = try? Data(contentsOf: url), data.count < 512 * 1024, !CodingFileReading.looksBinary(data),
                  let contents = String(data: data, encoding: .utf8) else { return nil }
            return (fileName, contents)
        }
        return CodingProjectDetection.promptSection(projectDirectory: projectDirectory, instructionFiles: instructionFiles)
    }

    /// Starts a job and waits for its answer (guided steps and other callers that need the result inline).
    /// Cancelling the caller stops the job.
    func run(_ request: AgentJobRequest, registry: BackgroundAgentToolRegistry) async throws -> String {
        let job = start(request, registry: registry)
        guard let task = job.task else { throw AgentJobError(message: "The job could not start.") }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in job.stop(reason: .superseded) }
        }
    }

    private func launch(_ job: AgentJob, isResume: Bool) {
        job.task = Task<String, Error> { @MainActor in
            try await self.execute(job, isResume: isResume)
        }
    }

    // MARK: Follow-ups

    /// Adds to a job's conversation. A running job reads it before its next step; a finished
    /// one wakes up and carries on with what it already knows. False when the job is no longer
    /// in memory (start a new one instead).
    @discardableResult
    func followUp(jobID: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let job = job(withID: jobID), job.launch != nil, job.registry != nil else { return false }
        job.followUps.append(trimmed)
        job.addRule(trimmed)
        if job.status.isFinished {
            let hasConversation = !job.messages.isEmpty
            job.reopen()
            if hasConversation {
                job.messages.append(["role": "user", "content": trimmed])
            } else {
                // It never got as far as its first model call (stopped while waiting its turn).
                job.pendingFollowUps.append(trimmed)
            }
            launch(job, isResume: hasConversation)
            AgentJobPanelPresenter.shared.refresh()
        } else {
            job.pendingFollowUps.append(trimmed)
        }
        return true
    }

    /// Which job a spoken follow-up is for: one named in it (by job title or agent name), else
    /// the only running job, else the card in front if it is running or just finished. nil = none.
    func followUpTarget(for text: String) -> AgentJob? {
        let candidates = jobs.filter(\.showsCard).map {
            AgentFollowUpRouter.Candidate(id: $0.id, title: $0.title, agentName: $0.agentName, isActive: !$0.status.isFinished, finishedAt: $0.finishedAt)
        }
        guard let id = AgentFollowUpRouter.target(for: text, candidates: candidates, frontJobID: frontJobID, now: Date()) else { return nil }
        return job(withID: id)
    }

    // MARK: Drive is exclusive

    /// Asks for the mouse and keyboard on behalf of a job. If another job has them, waits a
    /// little for it to finish, then reports who holds them.
    func claimDrive(for job: AgentJob, waitingUpTo seconds: TimeInterval = 20) async -> DriveLease.Claim {
        let deadline = Date().addingTimeInterval(seconds)
        var isWaiting = false
        defer { if isWaiting { job.budget.resume(now: Date()) } }
        while true {
            let claim = driveLease.claim(job.id)
            if claim == .granted { return claim }
            if Date() >= deadline || Task.isCancelled || job.status.isFinished { return claim }
            if !isWaiting {
                isWaiting = true
                job.budget.pause(now: Date())
                job.activity = "Waiting for Drive"
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func releaseDrive(jobID: String) {
        driveLease.release(jobID)
    }

    var driveHolder: AgentJob? { driveLease.holder.flatMap(job(withID:)) }

    // MARK: Running one job

    private func execute(_ job: AgentJob, isResume: Bool) async throws -> String {
        guard let request = job.launch, let registry = job.registry else {
            throw AgentJobError(message: "The job could not start.")
        }
        let outcome: Result<String, Error>
        do {
            if job.countsTowardLimit { try await waitForSlot(job) }
            outcome = .success(try await runLoop(job: job, request: request, registry: registry, isResume: isResume))
        } catch {
            outcome = .failure(error)
        }

        await job.drive.end()
        BrowserBridge.shared.jobEnded(jobID: job.id)
        releaseDrive(jobID: job.id)
        AgentToolGate.shared.ledger.endJob(job.id)
        if job.countsTowardLimit { promote(slots.release(job.id)) }

        let result: Result<String, Error>
        switch outcome {
        case .success(let answer):
            job.answer = answer
            job.finish(.done)
            result = .success(answer)
        case .failure(let error):
            if let handBack = error as? AgentLoopHandBack {
                job.stop(reason: .handedBack(handBack.spokenLine))
                job.answer = handBack.spokenLine
                result = .success(handBack.spokenLine)
            } else if let handBack = error as? DriveHandBack {
                job.stop(reason: .handedBack(handBack.spokenLine))
                job.answer = handBack.spokenLine
                result = .success(handBack.spokenLine)
            } else if let reason = job.stopReason, reason != .superseded {
                // The user stopped the job (Stop, Escape, mouse). That is an answer, not an error.
                job.answer = reason.spokenLine
                result = .success(reason.spokenLine)
            } else if error is CancellationError || job.stopReason == .superseded {
                job.stop(reason: .superseded)
                saveHistory(job)
                request.onStatus?(job.status, job.activity)
                throw CancellationError()
            } else {
                job.finish(.failed(error.localizedDescription))
                result = .failure(error)
            }
        }

        saveHistory(job)
        request.onStatus?(job.status, job.activity)
        request.onFinished?(job, result)

        // Something the person said in the last moment, after the model had already written
        // its answer: do not lose it, carry on with it now.
        if !job.pendingFollowUps.isEmpty, job.stopReason == nil, job.status.isFinished, !job.messages.isEmpty {
            let late = job.pendingFollowUps
            job.pendingFollowUps = []
            job.reopen()
            job.messages.append(["role": "user", "content": late.joined(separator: "\n")])
            launch(job, isResume: true)
        }
        return try result.get()
    }

    private func waitForSlot(_ job: AgentJob) async throws {
        guard case .queued = slots.request(job.id) else { return }
        job.status = .queued
        job.activity = "Waiting for another job to finish"
        let jobID = job.id
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                slotWaiters[jobID] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.slotWaiters.removeValue(forKey: jobID)?.resume(throwing: CancellationError())
            }
        }
        if !job.status.isFinished { job.status = .planning }
    }

    private func promote(_ jobIDs: [String]) {
        for jobID in jobIDs {
            slotWaiters.removeValue(forKey: jobID)?.resume()
        }
    }

    /// Tools that only make sense in some jobs are left out of the others' tool lists.
    static func toolNames(for request: AgentJobRequest, registered: [String]) -> Set<String> {
        AgentToolAvailability.names(registered: registered, hasAgent: request.agent != nil, isUnattended: request.isUnattended)
    }

    private func runLoop(job: AgentJob, request: AgentJobRequest, registry: BackgroundAgentToolRegistry, isResume: Bool) async throws -> String {
        var allowed = Self.toolNames(for: request, registered: registry.toolNames(allowed: request.allowedToolNames))
        // Teachy's own browser tools only work with its extension connected. Without it, leave
        // them out so the model reaches for the built-in Playwright browser (mcp__browser__…)
        // or the computer tool instead of failing on every browser_ call.
        if !BrowserBridge.shared.isExtensionConnected {
            allowed = allowed.filter { !$0.hasPrefix("browser_") }
        }
        // Their setting for websites and for their mouse decides which tools the job even has.
        let webPreference = TeachySettingsStorage.webControlPreference()
        let pointerPreference = TeachySettingsStorage.pointerControlPreference()
        allowed = TeachyActionPreferences.filteredToolNames(allowed, web: webPreference, pointer: pointerPreference)

        var config = AgentLoopConfig()
        config.tools = registry.toolDefinitions(allowed: allowed)
        config.usesPlan = request.usesPlan
        config.inlinePlan = request.inlinePlan
        config.streams = request.streams
        config.knownPlanSteps = job.plan.steps.map(\.text)

        if !isResume {
            var systemPrompt = request.systemPrompt
            if allowed.contains(where: { $0.hasPrefix("drive_") }) {
                systemPrompt += "\n\n" + DriveToolGuide.text
            }
            if allowed.contains("computer") {
                systemPrompt += "\n\n" + ComputerUseGuide.text
            }
            if allowed.contains(where: { $0.hasPrefix("browser_") }) {
                systemPrompt += "\n\n" + BrowserToolGuide.text
            }
            systemPrompt += "\n\n" + TeachyActionPreferences.promptSection(web: webPreference, pointer: pointerPreference, availableTools: allowed)
            // What Teachy knows about them, and what it remembers that bears on this task.
            let rememberedContext = BrainStore.shared.promptContext()
            if !rememberedContext.isEmpty {
                systemPrompt += "\n\nWHAT YOU REMEMBER ABOUT THEM:\n" + rememberedContext
            }
            let task = request.transcript
            let recalled = await Task.detached(priority: .userInitiated) {
                BrainStore.shared.recallPromptSection(forQuestion: task)
            }.value
            if !recalled.isEmpty {
                systemPrompt += "\n\n" + recalled
            }
            if let agent = request.agent {
                systemPrompt += "\n\n" + roster.promptSection(for: agent)
            }
            if let projectDirectory = job.projectDirectory {
                systemPrompt += "\n\n" + Self.projectPromptSection(projectDirectory: projectDirectory)
            }
            // What happened on recent days, so "carry on from yesterday" works; search_past_chats has the details.
            let journal = BrainStore.shared.sessions.recentJournal(budgetCharacters: 1_200)
            if !journal.isEmpty {
                systemPrompt += "\n\nRECENT DAYS WITH THIS PERSON (Teachy's journal; use search_past_chats for details):\n" + journal
            }
            if request.isUnattended {
                systemPrompt += "\n\n" + Self.unattendedGuide
            }
            if request.usesPlan {
                systemPrompt += "\n\n" + AgentLoop.planGuide(for: config)
            }
            var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
            for entry in request.conversationHistory {
                messages.append(["role": "user", "content": entry.userTranscript])
                messages.append(["role": "assistant", "content": entry.assistantResponse])
            }
            messages.append([
                "role": "user",
                "content": await Self.buildUserMessageContent(request: request, drive: job.drive)
            ])
            job.messages = messages
        }

        var hooks = AgentLoopHooks(
            model: { try await AgentModelClient.send($0) },
            checkBudget: { job.budget.check(now: Date()) },
            recordIteration: { job.budget.recordIteration() },
            runTool: { [weak self] call, arguments in
                guard let self else { return .failed("Teachy is shutting down.") }
                return await self.runTool(call, arguments: arguments, job: job, allowed: allowed, registry: registry)
            }
        )
        hooks.publish = { status, activity in
            if let status, !job.status.isFinished { job.status = status }
            if let activity { job.activity = activity }
            request.onStatus?(job.status, job.activity)
        }
        hooks.planChanged = { title, plan in
            job.plan = plan
            if let title { job.title = title }
        }
        hooks.stepFinished = { call, resultText, duration in
            let step = AgentStep(toolName: call.name, arguments: call.arguments, result: String(resultText.prefix(2000)), duration: duration)
            job.steps.append(step)
            request.onToolStep?(step)
        }
        hooks.takeFollowUps = {
            let taken = job.pendingFollowUps
            job.pendingFollowUps = []
            return taken
        }
        hooks.compacted = { [weak self] summaries in
            self?.writeNotes(for: job, addingDone: summaries)
        }
        hooks.answerSentence = request.onAnswerSentence
        hooks.answerRetracted = request.onAnswerRetracted
        hooks.describeActivity = { AgentToolActivity.describe(toolName: $0, arguments: $1) }

        // The loop works on a copy; whatever happens, the job keeps the conversation so far.
        var messages = job.messages
        defer { job.messages = messages }
        return try await AgentLoop.run(messages: &messages, config: config, hooks: hooks)
    }

    static let unattendedGuide = """
    NOBODY IS WATCHING THIS RUN: it is a routine that started on its own schedule. Nobody can be asked for permission, \
    so anything that would need a yes is refused. Do the work you can do without it. \
    In your answer say plainly what you found and, if something was refused, what is left for the person to do. \
    Your answer is shown as text, not spoken: a few short plain sentences.
    """

    private func runTool(_ call: AgentToolCall, arguments: [String: Any], job: AgentJob, allowed: Set<String>, registry: BackgroundAgentToolRegistry) async -> AgentLoopToolOutcome {
        let takesThePointer = call.name == "computer" && !ToolPolicy.computerLookOnlyActions.contains(ToolPolicy.string(arguments["action"]).lowercased())
        if ToolPolicy.driveActionToolNames.contains(call.name) || takesThePointer {
            if case .busy(let holderID) = await claimDrive(for: job) {
                let holderTitle = self.job(withID: holderID)?.title ?? "another job"
                return .refused(DriveLease.busyMessage(holderTitle: holderTitle))
            }
        }
        switch await registry.invoke(toolName: call.name, arguments: arguments, allowedToolNames: allowed, job: job) {
        case .result(let result):
            return .result(text: result.text, content: Self.toolResultContent(from: result))
        case .refused(let message):
            return .refused(message)
        case .handBack(let line):
            return .handBack(line)
        case .failed(let message):
            return .failed(message)
        }
    }

    // MARK: Notes (long jobs)

    func notesURL(for job: AgentJob) -> URL {
        notesDirectory.appendingPathComponent("\(job.id).md")
    }

    /// Writes the job's goal, the person's rules and the summaries of dropped tool results to
    /// its notes file, and returns the whole file so it can be read back into context.
    private func writeNotes(for job: AgentJob, addingDone summaries: [String]) -> String? {
        let url = notesURL(for: job)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? AgentJobNotes.initial(request: job.request, title: job.title)
        for rule in job.rules { text = AgentJobNotes.addingRule(rule, to: text) }
        text = AgentJobNotes.addingDone(summaries, to: text)
        do {
            try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Agent: could not save job notes: \(error.localizedDescription)")
        }
        return text
    }

    // MARK: History

    static func record(for job: AgentJob) -> AgentJobRecord {
        var detail = ""
        switch job.status {
        case .failed(let why), .stopped(let why): detail = why
        default: break
        }
        return AgentJobRecord(
            id: job.id,
            title: job.title,
            request: job.request,
            agentSlug: job.agentSlug,
            agentName: job.agentName,
            routineID: job.routineID,
            projectID: job.projectID,
            plan: job.plan.steps.map { AgentJobRecord.PlanStep(text: $0.text, state: $0.state.rawValue) },
            steps: job.steps.map { AgentJobRecord.Step(tool: $0.toolName, result: AgentJobRecord.shortResult($0.result), seconds: ($0.duration * 10).rounded() / 10) },
            answer: job.answer,
            status: job.status.historyWord,
            statusDetail: detail,
            refusals: job.refusals,
            followUps: job.followUps,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt
        )
    }

    private func saveHistory(_ job: AgentJob) {
        guard job.countsTowardLimit, let historyStore else { return }
        do {
            try historyStore.save(Self.record(for: job))
            historyRevision += 1
        } catch {
            print("⚠️ Agent: could not save job history: \(error.localizedDescription)")
        }
    }

    // MARK: The list

    private func add(_ job: AgentJob) {
        jobs.append(job)
        if jobs.count > Self.historyLimit {
            let finished = jobs.filter { $0.status.isFinished }
            let overflow = jobs.count - Self.historyLimit
            let dropping = Set(finished.prefix(overflow).map(\.id))
            jobs.removeAll { dropping.contains($0.id) }
            dropping.forEach { statusWatchers.removeValue(forKey: $0) }
        }
        statusWatchers[job.id] = job.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                AgentJobPanelPresenter.shared.refresh()
            }
        AgentJobPanelPresenter.shared.refresh()
    }

    // MARK: Messages

    private static func buildUserMessageContent(request: AgentJobRequest, drive: DriveSession) async -> Any {
        guard !request.screenCaptures.isEmpty else { return request.transcript }

        let cursorCaptures = request.screenCaptures.filter(\.isCursorScreen)
        let capturesToAttach = cursorCaptures.isEmpty ? request.screenCaptures : cursorCaptures
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        var blocks: [[String: Any]] = []

        for capture in capturesToAttach {
            let outlinePoints = capture.isCursorScreen ? (request.mouseOutlineContext?.outlinePointsInScreenshotSpace ?? []) : []
            let highlightedCells = capture.isCursorScreen ? (request.mouseOutlineContext?.touchedGridCellLabels ?? []) : []
            let captureID = await drive.registerCapture(
                screenshotWidth: capture.screenshotWidthInPixels,
                screenshotHeight: capture.screenshotHeightInPixels,
                displayFrameInAppKitPoints: capture.displayFrame,
                primaryDisplayHeight: primaryDisplayHeight
            )

            var label = capture.label + " (capture_id: \(captureID); image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels, grid overlay: columns A-X, rows 1-16)"
            if let spatial = request.mouseOutlineContext?.spatialContextLabel, capture.isCursorScreen {
                label += "; \(spatial)"
            }
            let annotated = ScreenGridAnnotationUtility.annotateScreenshotForModel(
                originalJPEGData: capture.imageData,
                screenshotWidthInPixels: capture.screenshotWidthInPixels,
                screenshotHeightInPixels: capture.screenshotHeightInPixels,
                mouseOutlinePointsInScreenshotSpace: outlinePoints,
                highlightedGridCellLabels: highlightedCells
            ) ?? capture.imageData

            blocks.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(annotated.base64EncodedString())"]])
            blocks.append(["type": "text", "text": label])
        }

        var transcript = request.transcript
        if let spatial = request.mouseOutlineContext?.spatialContextLabel {
            transcript += "\n\n[\(spatial) — the user circled this region on screen while asking.]"
        }
        blocks.append(["type": "text", "text": transcript])
        return blocks
    }

    private static func toolResultContent(from result: AgentToolResult) -> Any {
        let text = AgentLoop.truncate(result.text)
        guard let imageData = result.visionImageJPEGData else { return text }
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        if let label = result.visionImageLabel { blocks.append(["type": "text", "text": label]) }
        blocks.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"]])
        return blocks
    }
}

/// The old entry point, kept for callers that wait for the answer.
@MainActor
enum AgentJobRunner {
    static let planToolName = AgentLoop.planToolName

    /// Runs one job to its end and returns the final answer as written by the model
    /// (or the line to say if the job was stopped or handed back).
    static func run(_ request: AgentJobRequest, registry: BackgroundAgentToolRegistry) async throws -> String {
        try await AgentJobCenter.shared.run(request, registry: registry)
    }
}

/// A few plain words for the job card while a tool runs.
enum AgentToolActivity {
    static func describe(toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "drive_snapshot": return "Reading the window"
        case "drive_press": return "Pressing a control"
        case "drive_set_text": return "Typing"
        case "drive_menu": return "Using the menu bar"
        case "drive_key": return "Pressing keys"
        case "drive_scroll": return "Scrolling"
        case "drive_click_point": return "Clicking"
        case "computer":
            switch ToolPolicy.string(arguments["action"]).lowercased() {
            case "screenshot", "cursor_position", "wait": return "Looking at the screen"
            case "type": return "Typing"
            case "key": return "Pressing keys"
            case "scroll": return "Scrolling"
            case "drag": return "Dragging"
            default: return "Clicking"
            }
        case "capture_screen": return "Looking at the screen"
        case "web_search": return "Searching the web"
        case "web_fetch": return "Reading a page"
        case "read_file": return fileActivity("Reading", arguments: arguments, fallback: "Reading a file")
        case "write_file": return fileActivity("Writing", arguments: arguments, fallback: "Writing a file")
        case "edit_file": return fileActivity("Editing", arguments: arguments, fallback: "Editing a file")
        case "list_directory": return fileActivity("Looking in", arguments: arguments, fallback: "Looking in the folder")
        case "grep":
            let pattern = ToolPolicy.string(arguments["pattern"])
            return pattern.isEmpty ? "Searching the code" : "Searching for \u{201C}\(pattern.count > 40 ? String(pattern.prefix(40)) + "…" : pattern)\u{201D}"
        case "glob":
            let pattern = ToolPolicy.string(arguments["pattern"])
            return pattern.isEmpty ? "Finding files" : "Finding \(pattern.count > 40 ? String(pattern.prefix(40)) + "…" : pattern)"
        case "bash": return "Running a command"
        case "run_applescript": return "Running a script"
        case "open_browser_tab", "control_browser": return "Working in the browser"
        case "control_app": return "Opening an app"
        case "authenticated_fetch": return "Reading a signed-in page"
        case "remember": return "Saving a note"
        case "search_past_chats": return "Looking through earlier chats"
        case "create_routine": return "Setting up a routine"
        case "list_routines": return "Checking your routines"
        case "pause_routine", "delete_routine": return "Changing a routine"
        default: return "Using \(toolName.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// "Editing Foo.swift": the verb and the file or folder name from the `path` argument.
    private static func fileActivity(_ verb: String, arguments: [String: Any], fallback: String) -> String {
        let path = ToolPolicy.string(arguments["path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (path as NSString).lastPathComponent
        guard !path.isEmpty, !name.isEmpty, name != "/" else { return fallback }
        return "\(verb) \(name)"
    }
}
