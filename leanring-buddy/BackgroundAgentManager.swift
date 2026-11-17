import Combine
import Foundation

// MARK: - Agent Models

struct AgentStep: Identifiable {
    let id = UUID()
    let toolName: String
    let arguments: String
    let result: String
    let duration: TimeInterval
}

enum AgentStatus: Equatable {
    case idle
    case reasoning
    case running(toolName: String)
    case completed(result: String)
    case failed(error: String)
}

// MARK: - Agent Manager

@MainActor
final class BackgroundAgentManager: ObservableObject {
    @Published private(set) var status: AgentStatus = .idle
    @Published private(set) var stepLog: [AgentStep] = []

    private let proxyURL: URL
    private let toolRegistry = BackgroundAgentToolRegistry()
    let appConnectorManager: AppConnectorManager
    private var cancellables = Set<AnyCancellable>()

    /// OpenRouter model ID sent on each agent request.
    var selectedModel: String


    private static let baseSystemPrompt = """
    You are Teachy, the user's Mac companion. You get real work done on their Mac by calling tools, as a job the user can watch and stop.

    The user's first message may include live screenshots of their screen(s). You can see them directly; the cursor screen is labeled as primary focus. Each screenshot has a capture_id. Use capture_screen if you need a fresher look mid-task.

    PERMISSION: Teachy runs in auto mode by default: ordinary actions just run. It still asks every time before anything that deletes, sends, pays, posts or touches passwords and keys. You never ask for permission in text: call the tool and Teachy handles the question. If a tool result says the user said not now, or that something is blocked, accept it. Do not retry it and do not reach the same result another way.

    Tools:
    - drive_snapshot / drive_press / drive_set_text / drive_menu / drive_key / drive_scroll / drive_click_point: work inside one Mac app through its accessibility tree
    - computer: real computer use. Screenshot, then click, drag, type, press keys and scroll anywhere on screen with the person's real mouse and keyboard. Use it whenever drive_ or the browser tools cannot do the step.
    - mcp__browser__…: a real web browser you control (open pages, click, fill forms, read). Use it for websites.
    - capture_screen: a fresh screenshot
    - web_search, web_fetch: current information from the public web. Use 1-2 focused searches, then answer.
    - read_file (numbered lines, offset/limit) / edit_file (exact replacement, returns a diff) / write_file (new files or full rewrites): files
    - grep (search contents), glob (find files by pattern), list_directory: explore folders and code
    - bash: shell commands (not interactive; never vim, nano, less). Runs in the job's working folder unless you pass working_directory
    - run_applescript: script Mac apps
    - control_app: open, activate, quit or hide an app. control_browser / open_browser_tab: tabs and pages
    - authenticated_fetch / list_browser_sessions: only work if the user switched on browser sign-in access in settings
    - create_routine / list_routines / pause_routine / delete_routine: work that repeats on a schedule ("every weekday at 9, check my inbox"). Use create_routine when the user asks for something regular.

    How to work:
    - Prefer a connected app's own tools when one fits. For websites use the browser tools. For Mac apps prefer control_app and the drive_ tools, then computer when they cannot reach something, then AppleScript, then bash.
    - Do the whole job. Keep going until the task is completely resolved; do not stop to ask whether to continue or hand the person steps you could do yourself. Only stop early when you truly need something only they can give (a sign-in, a choice that changes the outcome).
    - Check your work before you finish: look at the screen, the page or the file and confirm the result is what they asked for.
    - Go one step beyond when it is clearly welcome: leave the page open on the answer, put the result where they will look for it, mention the one thing they should know.
    - Take small steps and check each one worked before the next.
    - If a tool fails, read the error and change approach. Never repeat the exact same failing call.
    - Use absolute paths or ~/ for files. Put new projects in ~/teachy-builds/<project-name>/ unless told otherwise.
    - Never print cookie values, keys or passwords.

    YOUR FINAL ANSWER IS SPOKEN ALOUD. Write it the way you would say it to a friend:
    - One to three plain, complete sentences with normal capitals and punctuation. Longer only if they asked for detail.
    - No lists, markdown, headers or citations. No URLs unless they asked for one.
    - Say what you did and what, if anything, is left for them. Never dump raw tool output.

    \(ScreenGridAnnotationUtility.modelInstructions)
    """

    init(proxyURL: String, selectedModel: String = OpenRouterModelOption.defaultModelID) {
        self.proxyURL = URL(string: proxyURL)!
        self.selectedModel = selectedModel
        self.appConnectorManager = AppConnectorManager(toolRegistry: toolRegistry)

        appConnectorManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        Task {
            await appConnectorManager.refreshConnectors()
        }
    }

    private func buildSystemPrompt() -> String {
        let connectorSection = appConnectorManager.connectorPromptSection()
        guard !connectorSection.isEmpty else { return Self.baseSystemPrompt }
        return Self.baseSystemPrompt + "\n\n" + connectorSection
    }

    // MARK: - Explicit agent jobs (full toolset, plan, card under the notch)

    /// What to say when a job started by `runTask` ends (its answer, or why it failed).
    /// NOT called for a job that was given `onAnswerSentence`: that job's words all arrive
    /// through the sentence callback instead, so nothing is spoken twice.
    var onTaskFinished: ((String) -> Void)?
    /// Called for every explicit job when it ends, spoken or not (for captions, history, badges).
    var onJobFinished: ((AgentJob, String) -> Void)?

    /// Everything about one job start. Only `transcript` is needed.
    struct JobLaunch {
        var transcript: String
        var screenCaptures: [CompanionScreenCapture] = []
        var mouseOutlineContext: CompanionMouseOutlineContext?
        /// Run as this named agent (`~/.teachy/agents/<slug>`). nil = see `picksAgentByName`.
        var agentSlug: String?
        /// With no `agentSlug`: run as the agent the request names ("ask Research buddy to…"), else as a plain job.
        var picksAgentByName = true
        var routineID: String?
        var projectID: String?
        /// A code project to work in (absolute or ~/). nil = use a git project the request names, if any.
        var projectDirectory: String?
        /// A routine run: no card, nothing spoken, nobody to ask (anything needing a yes is refused).
        var isUnattended = false
        /// Sentences of the answer as they are ready, cleaned for speech. Give this to start speaking early.
        var onAnswerSentence: ((String) -> Void)?
        /// The sentences just delivered were not the answer after all (rare): stop speaking them.
        var onAnswerRetracted: (() -> Void)?
    }

    /// Starts an explicit agent job: the full toolset behind the permission gate, a visible plan,
    /// a budget (25 steps / 10 minutes) and a Stop button. It runs alongside any other jobs
    /// (up to four at once; more wait their turn). Starting one never cancels another.
    /// Progress is published on `status` / `stepLog` here and as a job in `AgentJobCenter.shared.jobs`.
    func runTask(
        transcript: String,
        screenCaptures: [CompanionScreenCapture] = [],
        mouseOutlineContext: CompanionMouseOutlineContext? = nil,
        agentSlug: String? = nil,
        projectDirectory: String? = nil,
        onAnswerSentence: ((String) -> Void)? = nil,
        onAnswerRetracted: (() -> Void)? = nil
    ) {
        var launch = JobLaunch(transcript: transcript)
        launch.projectID = AgentProjectStore.shared.activeProjectID
        launch.projectDirectory = projectDirectory
        launch.screenCaptures = screenCaptures
        launch.mouseOutlineContext = mouseOutlineContext
        launch.agentSlug = agentSlug
        launch.onAnswerSentence = onAnswerSentence
        launch.onAnswerRetracted = onAnswerRetracted
        stepLog = []
        status = .reasoning
        Task { [weak self] in
            _ = await self?.startJob(launch)
        }
    }

    /// Starts a job and returns it once it is under way (after the connectors have been refreshed).
    @discardableResult
    func startJob(_ launch: JobLaunch) async -> AgentJob {
        await appConnectorManager.refreshConnectors()

        var request = AgentJobRequest(transcript: launch.transcript, systemPrompt: buildSystemPrompt())
        request.screenCaptures = launch.screenCaptures
        request.mouseOutlineContext = launch.mouseOutlineContext
        request.allowedToolNames = nil
        request.usesPlan = true
        request.showsCard = !launch.isUnattended
        request.projectID = launch.projectID
        request.routineID = launch.routineID
        request.isUnattended = launch.isUnattended
        // "Fix the failing test in ~/code/app" works in that project without being told twice.
        request.projectDirectory = launch.projectDirectory ?? CodingProjectDetection.projectDirectory(
            inRequestText: launch.transcript,
            home: NSHomeDirectory(),
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            hasGitEntry: { path in FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) }
        )
        if let slug = launch.agentSlug {
            request.agent = AgentRoster.shared.agent(slug: slug)
        } else if launch.picksAgentByName, !launch.isUnattended {
            request.agent = AgentRoster.shared.bestAgent(for: launch.transcript)
        }

        let speaksBySentence = launch.onAnswerSentence != nil
        let isSpoken = !launch.isUnattended
        if isSpoken {
            request.onAnswerSentence = launch.onAnswerSentence
            request.onAnswerRetracted = launch.onAnswerRetracted
            request.onToolStep = { [weak self] step in
                self?.stepLog.append(step)
            }
            request.onStatus = { [weak self] jobStatus, activity in
                guard let self, !jobStatus.isFinished else { return }
                self.status = jobStatus == .planning || jobStatus == .queued ? .reasoning : .running(toolName: activity)
            }
        }
        request.onFinished = { [weak self] job, result in
            guard let self else { return }
            let spoken: String
            var wasStreamed = false
            switch result {
            case .success(let answer):
                spoken = answer
                // A normal answer already went out sentence by sentence; a Stop or hand-back line did not.
                wasStreamed = job.status == .done
            case .failure(let error):
                spoken = "I couldn't finish that. \(error.localizedDescription)"
            }
            self.onJobFinished?(job, spoken)
            guard isSpoken else { return }
            self.settleStatus(afterJobEndedWith: result, spoken: spoken)
            if speaksBySentence {
                if !wasStreamed, !spoken.isEmpty { launch.onAnswerSentence?(spoken) }
            } else {
                self.onTaskFinished?(spoken)
            }
        }
        return AgentJobCenter.shared.start(request, registry: toolRegistry)
    }

    /// `status` describes the explicit jobs as a whole: still "running" while any of them is.
    private func settleStatus(afterJobEndedWith result: Result<String, Error>, spoken: String) {
        if let stillRunning = AgentJobCenter.shared.activeJobs.last(where: { $0.showsCard }) {
            status = .running(toolName: stillRunning.activity)
            return
        }
        switch result {
        case .success: status = .completed(result: spoken)
        case .failure(let error): status = .failed(error: error.localizedDescription)
        }
    }

    /// Sends what the person just said to the job it belongs to: one they named (by its title
    /// or its agent's name), else the only running job, else the card in front. Returns that
    /// job, or nil when there is none to follow up (start a new job instead).
    @discardableResult
    func followUp(_ text: String) -> AgentJob? {
        guard let job = AgentJobCenter.shared.followUpTarget(for: text),
              AgentJobCenter.shared.followUp(jobID: job.id, text: text) else { return nil }
        status = .running(toolName: job.activity)
        return job
    }

    /// One unattended run of a routine. Used by `RoutineScheduler`.
    func runRoutine(_ routine: Routine) async -> RoutineRunOutcome {
        var launch = JobLaunch(transcript: routine.task)
        launch.agentSlug = routine.agentSlug.flatMap { AgentRoster.shared.agent(slug: $0)?.slug }
        launch.picksAgentByName = false
        launch.routineID = routine.id
        launch.isUnattended = true
        let job = await startJob(launch)
        do {
            let answer = try await job.task?.value ?? ""
            if case .stopped(let why) = job.status {
                return .succeeded(result: "Stopped before it finished (\(why)).")
            }
            return job.refusals.isEmpty ? .succeeded(result: answer) : .needsPerson(result: job.resultSummary)
        } catch is CancellationError {
            return .failed(reason: "The run was cut short.")
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Stops every running job (used when the companion shuts down).
    func cancelTask() {
        AgentJobCenter.shared.stopAll(reason: .superseded)
        status = .idle
    }

    // MARK: - Guided-step and one-shot turns (quiet jobs, restricted toolset)

    /// Which tools a turn may see. Every call still passes the permission gate, whatever the set.
    enum Toolset {
        /// A guided-walkthrough step Teachy does for the person: read-only tools plus Drive
        /// (which asks first). No shell, no AppleScript, no cookies.
        case guidedStep
        /// A direct "open Spotify" / "close this tab": the guided-step set plus app and tab control.
        case nativeControl
        /// Everything registered. For explicit agent jobs.
        case full

        var toolNames: Set<String>? {
            switch self {
            case .guidedStep: return ToolPolicy.guidedStepToolNames
            case .nativeControl: return ToolPolicy.nativeControlToolNames
            case .full: return nil
            }
        }
    }

    /// Runs one short, quiet tool-using turn (a guided step Teachy does itself, or a direct
    /// native command). The default toolset is `.guidedStep`: safe tools plus Drive.
    /// Returns the model's final answer.
    func runScopedToolTurn(
        userPrompt: String,
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        screenCaptures: [CompanionScreenCapture],
        mouseOutlineContext: CompanionMouseOutlineContext?,
        toolset: Toolset = .guidedStep,
        onToolStep: ((AgentStep) -> Void)? = nil
    ) async throws -> String {
        var request = AgentJobRequest(transcript: userPrompt, systemPrompt: systemPrompt)
        request.conversationHistory = conversationHistory
        request.screenCaptures = screenCaptures
        request.mouseOutlineContext = mouseOutlineContext
        request.allowedToolNames = toolset.toolNames
        request.maxIterations = 10
        request.maxWallTime = 4 * 60
        request.onToolStep = onToolStep
        return try await AgentJobRunner.run(request, registry: toolRegistry)
    }

    /// Turns a written answer into natural spoken sentences: pointing and drawing tags,
    /// markdown and URLs go; capitals and identifiers like file_name stay as they are.
    static func formatFinalResponseForSpeech(_ text: String) -> String {
        let textWithoutDrawTags = ScreenGridDrawParser.responseTextByRemovingDrawTags(from: text)
        let pointingParseResult = CompanionManager.parsePointingCoordinates(from: textWithoutDrawTags)
        return AgentSpeechFormatter.naturalSentences(pointingParseResult.spokenText)
    }
}
