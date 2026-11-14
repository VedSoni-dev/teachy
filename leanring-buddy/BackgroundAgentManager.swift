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
    private var currentJobTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// OpenRouter model ID sent on each agent request.
    var selectedModel: String


    private static let baseSystemPrompt = """
    You are Teachy, the user's Mac companion. You get real work done on their Mac by calling tools, as a job the user can watch and stop.

    The user's first message may include live screenshots of their screen(s). You can see them directly; the cursor screen is labeled as primary focus. Each screenshot has a capture_id. Use capture_screen if you need a fresher look mid-task.

    PERMISSION: Teachy itself asks the user before anything that changes their Mac, and asks every time before anything that deletes, sends, pays, posts or touches passwords and keys. You never ask for permission in text: call the tool and Teachy handles the question. If a tool result says the user said not now, or that something is blocked, accept it. Do not retry it and do not reach the same result another way.

    Tools:
    - drive_snapshot / drive_press / drive_set_text / drive_menu / drive_key / drive_scroll / drive_click_point: work inside one Mac app through its accessibility tree
    - capture_screen: a fresh screenshot
    - web_search, web_fetch: current information from the public web. Use 1-2 focused searches, then answer.
    - read_file / write_file: files
    - bash: shell commands (not interactive; never vim, nano, less)
    - run_applescript: script Mac apps
    - control_app: open, activate, quit or hide an app. control_browser / open_browser_tab: tabs and pages
    - authenticated_fetch / list_browser_sessions: only work if the user switched on browser sign-in access in settings

    How to work:
    - Prefer a connected app's own tools when one fits. Otherwise prefer control_app, control_browser and the drive_ tools over AppleScript, and AppleScript over bash for app control.
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

    /// Starts an explicit agent job: the full toolset behind the permission gate, a visible plan,
    /// a budget (25 steps / 10 minutes by default) and a Stop button. Progress is published on
    /// `status` / `stepLog` here and as a job in `AgentJobCenter.shared.jobs`.
    /// Called with what to say when a job started by `runTask` ends (its answer, or why it failed).
    var onTaskFinished: ((String) -> Void)?

    func runTask(
        transcript: String,
        screenCaptures: [CompanionScreenCapture] = [],
        mouseOutlineContext: CompanionMouseOutlineContext? = nil
    ) {
        currentJobTask?.cancel()
        currentJobTask = nil
        stepLog = []
        status = .reasoning

        currentJobTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.appConnectorManager.refreshConnectors()
                var request = AgentJobRequest(transcript: transcript, systemPrompt: self.buildSystemPrompt())
                request.screenCaptures = screenCaptures
                request.mouseOutlineContext = mouseOutlineContext
                request.allowedToolNames = nil
                request.usesPlan = true
                request.showsCard = true
                request.onToolStep = { [weak self] step in
                    self?.stepLog.append(step)
                }
                request.onStatus = { [weak self] jobStatus, activity in
                    guard let self, !jobStatus.isFinished else { return }
                    self.status = jobStatus == .planning ? .reasoning : .running(toolName: activity)
                }
                let result = try await AgentJobRunner.run(request, registry: self.toolRegistry)
                if !Task.isCancelled {
                    self.status = .completed(result: result)
                    self.onTaskFinished?(result)
                }
            } catch is CancellationError {
                self.status = .idle
            } catch {
                self.status = .failed(error: error.localizedDescription)
                self.onTaskFinished?("I couldn't finish that. \(error.localizedDescription)")
            }
        }
    }

    func cancelTask() {
        currentJobTask?.cancel()
        currentJobTask = nil
        AgentJobCenter.shared.stopAll(reason: .superseded)
        status = .idle
    }

    // MARK: - Course and one-shot turns (quiet jobs, restricted toolset)

    /// Which tools a turn may see. Every call still passes the permission gate, whatever the set.
    enum Toolset {
        /// Ordinary coaching turns: read-only tools plus Drive (which asks first). No shell,
        /// no AppleScript, no cookies.
        case course
        /// A direct "open Spotify" / "close this tab": the course set plus app and tab control.
        case nativeControl
        /// Everything registered. For explicit agent jobs.
        case full

        var toolNames: Set<String>? {
            switch self {
            case .course: return ToolPolicy.courseToolNames
            case .nativeControl: return ToolPolicy.nativeControlToolNames
            case .full: return nil
            }
        }
    }

    /// Runs one course-mode turn that may use tools. The default toolset is `.course`:
    /// safe tools plus Drive. Returns the model's final answer.
    func runCourseInteraction(
        userPrompt: String,
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        screenCaptures: [CompanionScreenCapture],
        mouseOutlineContext: CompanionMouseOutlineContext?,
        toolset: Toolset = .course,
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

    /// Navigation-only phase for courses: open the right page or app, no vision in the first message.
    func runCourseNavigationPhase(
        userPrompt: String,
        systemPrompt: String,
        onToolStep: ((AgentStep) -> Void)? = nil
    ) async throws -> String {
        var request = AgentJobRequest(transcript: userPrompt, systemPrompt: systemPrompt)
        request.allowedToolNames = ["open_browser_tab", "control_app", "control_browser"]
        request.maxIterations = 5
        request.maxWallTime = 2 * 60
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
