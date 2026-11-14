//
//  AgentJob.swift
//  leanring-buddy
//
//  An agent job: one request the agent works through, with a name, a plan the
//  user can read, a step log, a budget and a Stop. AgentJobCenter publishes the
//  jobs so UI can show them; AgentJobRunner runs the model/tool loop.
//
//  Model calls go ONLY through TeachyAIRouter.sendJSON(job: .agent, …).
//  Tool calls go ONLY through AgentToolRegistry.invoke, which holds the
//  permission gate.
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
    let startedAt = Date()

    @Published var title: String
    @Published var plan = AgentPlan()
    @Published var status: AgentJobStatus = .planning
    @Published var steps: [AgentStep] = []
    /// One short line about what is happening right now ("Reading the window").
    @Published var activity = "Thinking"
    @Published var isDriving = false
    @Published private(set) var finishedAt: Date?

    var budget: AgentJobBudget
    private(set) var stopReason: AgentJobStopReason?
    fileprivate(set) var task: Task<String, Error>?

    init(request: String, title: String? = nil, showsCard: Bool, maxIterations: Int, maxWallTime: TimeInterval) {
        let identifier = UUID().uuidString
        self.id = identifier
        self.request = request
        self.showsCard = showsCard
        self.drive = DriveSession(jobID: identifier)
        self.title = title ?? AgentJobTitle.fallback(from: request)
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

    var elapsedDescription: String {
        let seconds = Int((finishedAt ?? Date()).timeIntervalSince(startedAt))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// The published list of jobs. UI observes `AgentJobCenter.shared.jobs`.
@MainActor
final class AgentJobCenter: ObservableObject {
    static let shared = AgentJobCenter()
    static let historyLimit = 20

    @Published private(set) var jobs: [AgentJob] = []
    private var statusWatchers: [String: AnyCancellable] = [:]

    var activeJobs: [AgentJob] { jobs.filter { !$0.status.isFinished } }

    func job(withID id: String) -> AgentJob? {
        jobs.first { $0.id == id }
    }

    func stopAll(reason: AgentJobStopReason = .stopButton) {
        activeJobs.forEach { $0.stop(reason: reason) }
    }

    fileprivate func add(_ job: AgentJob) {
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
    /// Explicit jobs state a plan first; quick coaching turns skip it.
    var usesPlan = false
    var showsCard = false
    var maxIterations = AgentJobBudget.defaultMaxIterations
    var maxWallTime = AgentJobBudget.defaultMaxWallTime
    var onToolStep: ((AgentStep) -> Void)?
    var onStatus: ((AgentJobStatus, String) -> Void)?
}

struct AgentJobError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum AgentJobRunner {
    static let planToolName = "update_plan"

    static let planToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": planToolName,
            "description": "State or update your plan. Call this FIRST, before any other tool, with a 2-3 word title for the job and 2-6 short steps. Call it again whenever you move to the next step or the plan changes. The user sees this plan while you work.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "A 2-3 word name for the job, like \"Inbox Hunter\" or \"Crop Photo\"."],
                    "steps": ["type": "array", "items": ["type": "string"], "description": "The steps, each a few plain words."],
                    "current_step": ["type": "integer", "description": "Which step you are on now, counting from 1. One past the last step means all done."]
                ],
                "required": ["steps", "current_step"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let planGuide = """
    PLAN FIRST: your very first tool call must be update_plan, with a 2-3 word title and 2-6 short steps. \
    Call update_plan again each time you move to the next step. Keep steps short and plain; the user reads them.
    """

    /// Runs one job to its end and returns the final answer as written by the model
    /// (or the line to say if the job was stopped or handed back).
    static func run(_ request: AgentJobRequest, registry: BackgroundAgentToolRegistry) async throws -> String {
        let job = AgentJob(
            request: request.transcript,
            showsCard: request.showsCard,
            maxIterations: request.maxIterations,
            maxWallTime: request.maxWallTime
        )
        AgentJobCenter.shared.add(job)

        let work = Task<String, Error> { @MainActor in
            try await loop(job: job, request: request, registry: registry)
        }
        job.task = work

        let outcome: Result<String, Error>
        do {
            let answer = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            outcome = .success(answer)
        } catch {
            outcome = .failure(error)
        }

        await job.drive.end()
        AgentToolGate.shared.ledger.endJob(job.id)

        switch outcome {
        case .success(let answer):
            job.finish(.done)
            request.onStatus?(job.status, job.activity)
            return answer
        case .failure(let error):
            if let handBack = error as? DriveHandBack {
                job.stop(reason: .handedBack(handBack.spokenLine))
                request.onStatus?(job.status, job.activity)
                return handBack.spokenLine
            }
            if let reason = job.stopReason, !Task.isCancelled {
                // The user stopped the job (Stop, Escape, mouse). That is an answer, not an error.
                request.onStatus?(job.status, job.activity)
                return reason.spokenLine
            }
            if error is CancellationError || Task.isCancelled {
                job.stop(reason: .superseded)
                throw CancellationError()
            }
            job.finish(.failed(error.localizedDescription))
            request.onStatus?(job.status, job.activity)
            throw error
        }
    }

    // MARK: The loop

    private static func loop(job: AgentJob, request: AgentJobRequest, registry: BackgroundAgentToolRegistry) async throws -> String {
        var systemPrompt = request.systemPrompt
        let toolNames = registry.toolNames(allowed: request.allowedToolNames)
        if toolNames.contains(where: { $0.hasPrefix("drive_") }) {
            systemPrompt += "\n\n" + DriveToolGuide.text
        }
        if request.usesPlan {
            systemPrompt += "\n\n" + planGuide
        }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for entry in request.conversationHistory {
            messages.append(["role": "user", "content": entry.userTranscript])
            messages.append(["role": "assistant", "content": entry.assistantResponse])
        }
        messages.append([
            "role": "user",
            "content": await buildUserMessageContent(request: request, drive: job.drive)
        ])

        var tools = registry.toolDefinitions(allowed: request.allowedToolNames)
        if request.usesPlan { tools.insert(planToolDefinition, at: 0) }

        var failures = ToolFailureTracker()
        var isFinalTurn = false

        func publish(_ status: AgentJobStatus? = nil, activity: String? = nil) {
            if let status, !job.status.isFinished { job.status = status }
            if let activity { job.activity = activity }
            request.onStatus?(job.status, job.activity)
        }

        while true {
            try Task.checkCancellation()

            switch job.budget.check(now: Date()) {
            case .proceed:
                break
            case .lastTurn:
                isFinalTurn = true
                messages.append(["role": "user", "content": "Step limit reached. Stop calling tools. Say in a sentence or two what you got done and what is left."])
            case .exhausted(let why):
                if isFinalTurn { throw AgentJobError(message: "The job \(why) before it could finish.") }
                isFinalTurn = true
                messages.append(["role": "user", "content": "This job has \(why). Stop calling tools. Say in a sentence or two what you got done and what is left."])
            }

            publish(job.steps.isEmpty && job.plan.steps.isEmpty ? .planning : .running, activity: isFinalTurn ? "Wrapping up" : "Thinking")
            let response = try await sendChatRequest(messages: messages, tools: isFinalTurn ? [] : tools)
            job.budget.recordIteration()

            let message = (response["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
            let content = message["content"] as? String
            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []

            guard !toolCalls.isEmpty else {
                if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content }
                if isFinalTurn { return "I ran out of steps before I could finish." }
                return "Done."
            }
            if isFinalTurn {
                // Asked for a final answer, got more tool calls: take whatever text there is.
                return content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? content! : "I ran out of steps before I could finish."
            }
            messages.append(sanitizedAssistantMessage(message))

            for toolCall in toolCalls {
                try Task.checkCancellation()
                let function = toolCall["function"] as? [String: Any]
                let toolName = function?["name"] as? String ?? ""
                let rawArguments = function?["arguments"] as? String ?? "{}"
                let toolCallID = toolCall["id"] as? String ?? ""
                func reply(_ text: Any) {
                    messages.append(["role": "tool", "tool_call_id": toolCallID, "content": text])
                }

                let arguments: [String: Any]
                if rawArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    arguments = [:]
                } else if let data = rawArguments.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    arguments = parsed
                } else {
                    reply("Invalid arguments JSON")
                    continue
                }

                if toolName == planToolName {
                    if request.usesPlan, let parsed = AgentPlan.parse(arguments: arguments) {
                        job.plan = parsed.plan
                        if let title = parsed.title { job.title = title }
                        publish(.running, activity: parsed.plan.currentStep?.text ?? "Working")
                        reply("Plan noted. Carry on.")
                    } else {
                        reply("update_plan needs steps (a list of short strings) and current_step.")
                    }
                    continue
                }

                if failures.isDead(toolName: toolName, argumentsJSON: rawArguments) {
                    failures.recordRefusedRepeat()
                    if failures.shouldGiveUp {
                        throw AgentJobError(message: "I kept hitting the same wall with \(toolName), so I stopped.")
                    }
                    reply("Not run: this exact call already failed twice the same way. Use a different approach, or stop and tell the user what is blocking you.")
                    continue
                }

                publish(.running, activity: AgentToolActivity.describe(toolName: toolName, arguments: arguments))
                let stepStart = Date()
                let invocation = await registry.invoke(
                    toolName: toolName,
                    arguments: arguments,
                    allowedToolNames: request.allowedToolNames,
                    job: job
                )
                try Task.checkCancellation()

                let resultText: String
                var visionResult: AgentToolResult?
                switch invocation {
                case .result(let result):
                    resultText = result.text
                    visionResult = result
                case .refused(let message):
                    resultText = message
                case .handBack(let line):
                    throw DriveHandBack(spokenLine: line)
                case .failed(let message):
                    switch failures.recordFailure(toolName: toolName, argumentsJSON: rawArguments, error: message) {
                    case .firstFailure:
                        resultText = "Error: \(message)"
                    case .abortApproach:
                        resultText = "Error: \(message)\nThis exact call has now failed twice the same way. Do not repeat it. Try a different approach, or stop and tell the user what is blocking you."
                    }
                }

                let step = AgentStep(
                    toolName: toolName,
                    arguments: rawArguments,
                    result: String(resultText.prefix(2000)),
                    duration: Date().timeIntervalSince(stepStart)
                )
                job.steps.append(step)
                request.onToolStep?(step)

                if let visionResult {
                    reply(toolResultContent(from: visionResult))
                } else {
                    reply(truncate(resultText))
                }
            }
        }
    }

    // MARK: Messages

    /// Keeps only the fields a chat-completions request accepts back.
    private static func sanitizedAssistantMessage(_ message: [String: Any]) -> [String: Any] {
        var cleaned: [String: Any] = ["role": "assistant"]
        cleaned["content"] = message["content"] ?? NSNull()
        if let toolCalls = message["tool_calls"] { cleaned["tool_calls"] = toolCalls }
        return cleaned
    }

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
        let text = truncate(result.text)
        guard let imageData = result.visionImageJPEGData else { return text }
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        if let label = result.visionImageLabel { blocks.append(["type": "text", "text": label]) }
        blocks.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"]])
        return blocks
    }

    private static func truncate(_ text: String) -> String {
        let limit = 12_000
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n\n[truncated — \(text.count - limit) more characters omitted]"
    }

    // MARK: Model call

    private static func sendChatRequest(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        var body: [String: Any] = [
            "max_tokens": 4096,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = false
        }
        let hasImages = messages.contains { message in
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains { ($0["type"] as? String) == "image_url" }
        }
        let data = try await TeachyAIRouter.sendJSON(job: .agent, hasImages: hasImages, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentJobError(message: "The AI sent back something Teachy could not read.")
        }
        return json
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
        case "capture_screen": return "Looking at the screen"
        case "web_search": return "Searching the web"
        case "web_fetch": return "Reading a page"
        case "read_file": return "Reading a file"
        case "write_file": return "Writing a file"
        case "bash": return "Running a command"
        case "run_applescript": return "Running a script"
        case "open_browser_tab", "control_browser": return "Working in the browser"
        case "control_app": return "Opening an app"
        case "authenticated_fetch": return "Reading a signed-in page"
        default: return "Using \(toolName.replacingOccurrences(of: "_", with: " "))"
        }
    }
}
