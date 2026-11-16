//
//  AgentToolRegistry.swift
//  leanring-buddy
//
//  The registry of agent tools AND the only way to run one.
//
//  `invoke` is the single door: it classifies the call (ToolPolicy), consults
//  what the user already said (ConsentLedger), asks when needed
//  (ConsentPrompter) and only then executes, under a per-call timeout. The
//  tools themselves are private to this file, so no caller can run a tool
//  without passing the gate.
//

import AppKit
import Foundation

/// Who asks the user. The app uses ConsentPrompter; a test harness can swap it.
@MainActor
protocol ConsentAsking: AnyObject {
    func ask(_ request: ConsentRequest) async -> ConsentChoice
}

/// The permission gate: policy + remembered answers + the question.
@MainActor
final class AgentToolGate {
    static let shared = AgentToolGate()

    /// Off by default. The same key as the "browser sign-ins" toggle in Privacy settings
    /// (`TeachySettingsKey.allowBrowserCookieTools`), so there is one switch, not two.
    static let allowBrowserCookiesDefaultsKey = "teachyAllowBrowserCookieTools"

    /// Auto mode is on unless the person turned it off (Settings > Privacy > Auto permissions).
    let ledger = ConsentLedger(store: UserDefaults.standard, isAutoModeOn: { TeachySettingsStorage.agentAutoPermissions() })
    var prompter: ConsentAsking = ConsentPrompter.shared

    enum Verdict {
        case run
        /// Do not run; this text goes back to the model.
        case refuse(String)
    }

    var settings: ToolPolicySettings {
        ToolPolicySettings(
            allowBrowserCookies: UserDefaults.standard.bool(forKey: Self.allowBrowserCookiesDefaultsKey),
            homeDirectory: NSHomeDirectory(),
            ownBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
    }

    /// The settings for one job: a job run as a named agent may read and write its own `files/` freely.
    func settings(for job: AgentJob) -> ToolPolicySettings {
        var settings = self.settings
        settings.agentFilesDirectory = job.workingDirectory ?? ""
        return settings
    }

    func authorize(toolName: String, arguments: [String: Any], tool: any BackgroundAgentTool, job: AgentJob) async -> Verdict {
        var context = ToolPolicyContext()
        context.connectorHTTPMethod = tool.httpMethodForPolicy ?? ""

        if ToolPolicy.driveActionToolNames.contains(toolName) {
            guard await job.drive.hasTarget else {
                return .refuse("Call drive_snapshot first so Teachy knows which app you mean and what is on screen.")
            }
            context = await job.drive.policyContext(toolName: toolName, arguments: arguments)
        }
        if toolName == "computer" {
            // Judge it by the app it would act on: under the point, else the app in front.
            let action = ToolPolicy.string(arguments["action"]).lowercased()
            if !ToolPolicy.computerLookOnlyActions.contains(action) {
                var target: (name: String, bundleID: String)?
                if arguments["x"] != nil, let point = try? await job.drive.globalPoint(arguments: arguments, xKey: "x", yKey: "y") {
                    target = ComputerEvents.appUnder(globalPoint: point)
                }
                if target == nil, let front = NSWorkspace.shared.frontmostApplication {
                    target = (front.localizedName ?? "", front.bundleIdentifier ?? "")
                }
                context.driveTargetAppName = target?.name ?? ""
                context.driveTargetBundleID = target?.bundleID ?? ""
            }
        }
        if toolName.hasPrefix("browser_") {
            context.browser = await BrowserBridge.shared.policyContext(toolName: toolName, arguments: arguments, jobID: job.id)
        }

        // Judge file tools by where the path really leads, not by how it is spelled.
        var argumentsForPolicy = arguments
        if toolName == "read_file" || toolName == "write_file", let path = arguments["path"] as? String {
            // A relative path starts in the job's working folder, exactly as the tool itself reads it.
            let absolute = PathPolicy.absolute(path, workingDirectory: job.workingDirectory, home: NSHomeDirectory())
            argumentsForPolicy["path"] = Self.resolvedPath(absolute)
        }

        let decision = ToolPolicy.classify(toolName: toolName, arguments: argumentsForPolicy, settings: settings(for: job), context: context)

        if job.isUnattended {
            // A routine run: there is nobody to ask, and a routine must never be able to say yes
            // to itself. Only safe calls and ones the person already always-allowed go through.
            switch ledger.resolveUnattended(decision) {
            case .allowed:
                return .run
            case .ask, .refused:
                if decision.risk == .blocked {
                    return .refuse("Blocked by Teachy's safety rules: \(decision.reason). Carry on without it.")
                }
                job.recordRefusal(ConsentLedger.unattendedRefusalNote(for: decision))
                return .refuse("Not run: this needs the person's yes (\(decision.summary)) and nobody is watching this routine run, so it was refused. Do not try another route to the same thing. Finish what you can without it and say in your answer that this part is waiting for them.")
            }
        }

        switch ledger.resolve(decision, jobID: job.id) {
        case .allowed:
            return .run
        case .refused(let why):
            if decision.risk == .blocked {
                return .refuse("Blocked by Teachy's safety rules: \(why). This cannot be approved. Do not try another route to the same thing; say plainly that Teachy does not do this, or carry on without it.")
            }
            return .refuse("Not run: \(why). Do not ask for this again in this job. Carry on without it if you can, otherwise stop and tell the user what is left for them to do.")
        case .ask:
            break
        }

        let request = ConsentRequest(
            jobID: job.id,
            jobTitle: job.title,
            headline: ConsentWording.headline(for: decision, currentPlanStep: job.plan.currentStep?.text),
            detail: decision.detail,
            reason: decision.risk == .alwaysAsk ? "I ask every time for this: \(decision.reason)." : "",
            offersAlwaysAllow: decision.risk == .needsConsent,
            isHighStakes: decision.risk == .alwaysAsk
        )

        let previousStatus = job.status
        job.status = .waitingForConsent
        job.budget.pause(now: Date())
        DriveTakeoverMonitor.shared.suspend()
        let choice = await prompter.ask(request)
        DriveTakeoverMonitor.shared.resume()
        job.budget.resume(now: Date())
        if !job.status.isFinished { job.status = previousStatus == .waitingForConsent ? .running : previousStatus }

        if Task.isCancelled || job.status.isFinished {
            return .refuse("The job was stopped.")
        }
        if ledger.record(choice, for: decision, jobID: job.id) {
            return .run
        }
        // Kept in the job's notes, so a long job still knows after its context is compacted.
        job.addRule("The person said not now to: \(decision.summary). Do not do it or ask again.")
        return .refuse("The user said not now to this (\(decision.summary)). Do not ask again in this job and do not try another route to the same thing. Carry on without it if you can, otherwise stop and tell them what is left to do.")
    }

    /// Follows symlinks as far as the path exists, so a link into ~/.ssh is judged as ~/.ssh.
    static func resolvedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().path
        }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }
}

enum AgentToolInvocation {
    case result(AgentToolResult)
    /// The gate said no (blocked, not now, wrong phase). Text for the model; not a failure of the tool.
    case refused(String)
    case failed(String)
    /// Drive met a password / code / card field: the job ends and this line is spoken.
    case handBack(String)
}

@MainActor
final class BackgroundAgentToolRegistry {
    private var tools: [String: any BackgroundAgentTool] = [:]
    private var connectorToolNames: Set<String> = []

    init() {
        registerBuiltInTools()
    }

    private func registerBuiltInTools() {
        register(BashTool())
        register(ReadFileTool())
        register(WriteFileTool())
        register(RunAppleScriptTool())
        register(OpenBrowserTabTool())
        register(CaptureScreenTool())
        register(AuthenticatedFetchTool())
        register(WebSearchTool())
        register(WebFetchTool())
        register(ListBrowserSessionsTool())
        register(ControlAppTool())
        register(ControlBrowserTool())
        // Drive: accessibility-first control of one app. Replaces the old ui_action tool.
        register(DriveSnapshotTool())
        register(DrivePressTool())
        register(DriveSetTextTool())
        register(DriveMenuTool())
        register(DriveKeyTool())
        register(DriveScrollTool())
        register(DriveClickPointTool())
        register(ComputerUseTool())
        BrowserAgentTools.all.forEach { register($0) }
        // Named agents and routines.
        register(RememberTool())
        register(CreateRoutineTool())
        register(ListRoutinesTool())
        register(PauseRoutineTool())
        register(DeleteRoutineTool())
    }

    func register(_ tool: any BackgroundAgentTool) {
        tools[tool.name] = tool
    }

    func registerConnectorTools(_ connectorTools: [any BackgroundAgentTool]) {
        for connectorTool in connectorTools {
            register(connectorTool)
            connectorToolNames.insert(connectorTool.name)
        }
    }

    func unregisterAllConnectorTools() {
        for connectorToolName in connectorToolNames {
            tools.removeValue(forKey: connectorToolName)
        }
        connectorToolNames.removeAll()
    }

    /// Tool names in a fixed order (the same request always lists tools the same way).
    func toolNames(allowed: Set<String>?) -> [String] {
        AgentToolOrdering.sortedNames(tools.keys.filter { allowed == nil || allowed!.contains($0) })
    }

    /// OpenAI-style tool definitions, in that fixed order.
    func toolDefinitions(allowed: Set<String>?) -> [[String: Any]] {
        toolNames(allowed: allowed).compactMap { name -> [String: Any]? in
            guard let tool = tools[name] else { return nil }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.jsonSchema
                ] as [String: Any]
            ]
        }
    }

    /// THE way to run a tool: gate first, then execute under a timeout.
    func invoke(
        toolName: String,
        arguments: [String: Any],
        allowedToolNames: Set<String>?,
        job: AgentJob
    ) async -> AgentToolInvocation {
        guard let tool = tools[toolName] else {
            return .refused("Unknown tool: \(toolName). Tools you have: \(toolNames(allowed: allowedToolNames).joined(separator: ", ")).")
        }
        if let allowedToolNames, !allowedToolNames.contains(toolName) {
            return .refused("Tool \(toolName) is not available here. Use only: \(toolNames(allowed: allowedToolNames).joined(separator: ", ")).")
        }

        switch await AgentToolGate.shared.authorize(toolName: toolName, arguments: arguments, tool: tool, job: job) {
        case .refuse(let message):
            return .refused(message)
        case .run:
            break
        }

        do {
            let result = try await AgentJobContext.$current.withValue(job) {
                try await Self.runWithTimeout(seconds: Self.timeout(forTool: toolName, arguments: arguments)) {
                    try await tool.executeReturningRichResult(arguments: arguments)
                }
            }
            return .result(result)
        } catch let handBack as DriveHandBack {
            return .handBack(handBack.spokenLine)
        } catch is CancellationError {
            return .failed("Stopped.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Per-call timeout

    static func timeout(forTool toolName: String, arguments: [String: Any]) -> TimeInterval {
        switch toolName {
        case "bash": return BashTool.timeoutSeconds(from: arguments) + 5
        case "web_fetch", "web_search": return 30
        case "authenticated_fetch": return 50
        case "run_applescript", "control_app", "control_browser", "open_browser_tab": return 45
        case "capture_screen": return 20
        case "computer": return 40
        case _ where toolName.hasPrefix("drive_"): return 25
        default: return 70
        }
    }

    private final class Race<Value>: @unchecked Sendable {
        // Swift 6.3.3 crashes in EarlyPerfInliner on this generic destructor under
        // Release WMO. Keep just its destruction unoptimized; tool work stays optimized.
        @_optimize(none) deinit {}

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func set(work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            self.work = work
            self.timer = timer
            lock.unlock()
        }

        func cancelTasks() {
            lock.lock()
            let tasks = [work, timer]
            lock.unlock()
            tasks.forEach { $0?.cancel() }
        }

        /// First caller wins; later calls do nothing.
        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            if early != nil { lock.unlock(); return }
            early = result
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    /// Runs `operation`, giving up after `seconds`. The caller is released on time even if the
    /// tool ignores cancellation (its work is cancelled and left to wind down).
    static func runWithTimeout<Value>(seconds: TimeInterval, operation: @escaping () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                race.attach(continuation)
                // Task { } keeps the job context (task-local) the tool needs.
                let work = Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                    race.cancelTasks()
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    race.finish(.failure(NSError(domain: "AgentTool", code: -3, userInfo: [NSLocalizedDescriptionKey: "Timed out after \(Int(seconds)) seconds."])))
                    race.cancelTasks()
                }
                race.set(work: work, timer: timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
            race.cancelTasks()
        }
    }
}
