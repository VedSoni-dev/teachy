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
    private var currentTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// OpenRouter model ID sent on each agent request.
    var selectedModel: String


    private static let baseSystemPrompt = """
    You are Teachy, the user's Mac teaching companion. You can execute real tasks by calling tools.

    The user's first message may include live screenshots of their screen(s). You can see them directly — the cursor screen is labeled as primary focus. Use capture_screen if you need a fresher look mid-task.

    Web tools:
    - web_search: Search the web for current information. Use 1–2 focused queries, then answer.
    - web_fetch: Fetch the readable text of a public URL found during search.

    Mac tools (run locally on the device):
    - bash: Run shell commands (terminal, scripts, git, npm, etc.)
    - read_file / write_file: Read and write files
    - authenticated_fetch: Fetch logged-in websites using the user's browser cookies (Gmail, GitHub, Notion, Slack, etc.)
    - list_browser_sessions: See which browsers (Chrome, Brave, Arc, Edge, Safari) have cookies available
    - run_applescript: Control Mac apps via AppleScript (Finder, Mail, Calendar, Safari, Notes)
    - open_browser_tab: Open a URL in Safari, Chrome, Arc, Brave, Edge, or the default browser
    - ui_action: Click, type, press keys, or read the frontmost app/window (requires Accessibility) — last resort when no app connector exists
    - capture_screen: Screenshot the desktop and save JPEGs — use before acting on visual tasks

    BUILD & AUTOMATE ON THE MAC (like Cursor / Claude Code):
    - You have full CLI control via bash — mkdir, npm, pip, swift, git, curl, etc.
    - Use write_file to create source files, configs, and project scaffolding
    - Use read_file to inspect existing code before editing
    - Default new projects to ~/clicky-builds/<project-name>/ unless the user specifies a path
    - For Mac apps: scaffold Swift/SwiftUI projects (Package.swift or .xcodeproj structure), tell user to open in Xcode
    - For web apps: npm create, vite, etc. via bash — then open_browser_tab to localhost when dev server runs
    - Open docs, GitHub repos, and API references with open_browser_tab while building
    - Break builds into small tool steps: scaffold → write files → install deps → verify → summarize
    - Never use interactive terminal commands (vim, nano, less)

    Strategy:
    - For questions needing current info: web_search first, then web_fetch only if you need more detail from a specific URL.
    - Do not repeat the same search query. After 1–2 searches, synthesize an answer from what you found.
    - For logged-in websites, ALWAYS use authenticated_fetch (not web_fetch).
    - Call list_browser_sessions first if you are unsure which browser has the session.
    - When an app connector is available for the task, ALWAYS prefer its tools over ui_action, run_applescript, or screenshots.
    - Use capture_screen + frontmost_app to understand context before clicking only when no connector tool applies.
    - Use run_applescript for native Mac app tasks; ui_action for precise clicks and typing only as fallback.
    - Break complex tasks into small steps. Never use interactive terminal commands (vim, nano, less).
    - Use absolute paths or ~/ for files.
    - Never print or expose raw cookie values. Do not exfiltrate credentials.

    IMPORTANT — your final answer is spoken aloud via text-to-speech. write the way you'd actually talk to a friend, NOT a written report or transcript.

    voice rules for your final answer:
    - all lowercase, casual, warm. like "yoo, today's world cup games are brazil vs japan at two, argentina vs france at five..."
    - write for the ear, not the eye. short flowing sentences. NO lists, bullet points, markdown, dashes, headers, numbered items, or citations.
    - never dump or transcribe raw search results. synthesize the info into a natural spoken summary.
    - don't read out URLs, source names, or "according to..." unless the user asked for sources.
    - one to three sentences for simple questions. go longer only if they asked for detail.
    - no emojis. no "here's what i found" or "based on my search" — just answer like a human would.
    - for task completion ("i created the file"), still keep it casual: "done, i made the file at ~/projects/foo.txt"

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

    func runTask(
        transcript: String,
        screenCaptures: [CompanionScreenCapture] = [],
        mouseOutlineContext: CompanionMouseOutlineContext? = nil
    ) {
        currentTask?.cancel()
        currentTask = nil
        stepLog = []
        status = .reasoning

        currentTask = Task {
            defer {
                if !Task.isCancelled {
                    if case .running = status { status = .idle }
                }
            }

            do {
                await appConnectorManager.refreshConnectors()

                let result = try await executeToolLoop(
                    transcript: transcript,
                    screenCaptures: screenCaptures,
                    mouseOutlineContext: mouseOutlineContext,
                    maxIterations: 20
                )
                if !Task.isCancelled {
                    status = .completed(result: result)
                }
            } catch is CancellationError {
                status = .idle
            } catch {
                status = .failed(error: error.localizedDescription)
            }
        }
    }

    func cancelTask() {
        currentTask?.cancel()
        currentTask = nil
        status = .idle
    }

    /// Runs a course-mode interaction with full tool access (bash, screen capture, AppleScript, etc.).
    /// Used by Teachy Courses so the tutor can inspect the Mac, open download pages, and guide on screen.
    func runCourseInteraction(
        userPrompt: String,
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        screenCaptures: [CompanionScreenCapture],
        mouseOutlineContext: CompanionMouseOutlineContext?,
        onToolStep: ((AgentStep) -> Void)? = nil
    ) async throws -> String {
        return try await executeToolLoop(
            transcript: userPrompt,
            screenCaptures: screenCaptures,
            mouseOutlineContext: mouseOutlineContext,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            maxIterations: 10,
            onToolStep: onToolStep,
            updatePublishedStatus: false
        )
    }

    /// Navigation-only phase for courses — bash / AppleScript / browser, no vision in the first message.
    func runCourseNavigationPhase(
        userPrompt: String,
        systemPrompt: String,
        onToolStep: ((AgentStep) -> Void)? = nil
    ) async throws -> String {
        return try await executeToolLoop(
            transcript: userPrompt,
            screenCaptures: [],
            mouseOutlineContext: nil,
            systemPrompt: systemPrompt,
            conversationHistory: [],
            maxIterations: 5,
            onToolStep: onToolStep,
            updatePublishedStatus: false,
            allowedToolNames: ["bash", "run_applescript", "open_browser_tab"]
        )
    }

    // MARK: - Tool Loop

    private func executeToolLoop(
        transcript: String,
        screenCaptures: [CompanionScreenCapture],
        mouseOutlineContext: CompanionMouseOutlineContext?,
        systemPrompt: String? = nil,
        conversationHistory: [(userTranscript: String, assistantResponse: String)] = [],
        maxIterations: Int = 12,
        onToolStep: ((AgentStep) -> Void)? = nil,
        updatePublishedStatus: Bool = true,
        allowedToolNames: Set<String>? = nil
    ) async throws -> String {
        let loopModelID = OpenRouterModelOption.resolvedModelID(
            preferredModelID: selectedModel,
            hasScreenCaptures: !screenCaptures.isEmpty
        )
        if loopModelID != selectedModel {
            print("👁️ Routing \(selectedModel) → \(loopModelID) (screen attached)")
        }

        let userMessageContent = buildUserMessageContent(
            transcript: transcript,
            screenCaptures: screenCaptures,
            mouseOutlineContext: mouseOutlineContext
        )

        let resolvedSystemPrompt = systemPrompt ?? buildSystemPrompt()
        var messages: [[String: Any]] = [
            ["role": "system", "content": resolvedSystemPrompt]
        ]

        for historyEntry in conversationHistory {
            messages.append(["role": "user", "content": historyEntry.userTranscript])
            messages.append(["role": "assistant", "content": historyEntry.assistantResponse])
        }

        messages.append(["role": "user", "content": userMessageContent])

        for iterationIndex in 0..<maxIterations {
            try Task.checkCancellation()

            let isFinalIteration = iterationIndex == maxIterations - 1
            if isFinalIteration {
                messages.append([
                    "role": "user",
                    "content": "Step limit reached. Stop calling tools and give your best final answer now based on everything you have learned so far."
                ])
            }

            let toolsJSON = isFinalIteration ? [] : buildToolsPayload(allowedToolNames: allowedToolNames)
            let response = try await sendChatRequest(
                messages: messages,
                tools: toolsJSON,
                model: loopModelID
            )
            let choice = response["choices"] as? [[String: Any]]
            let message = choice?.first?["message"] as? [String: Any]
            let content = message?["content"] as? String
            let toolCalls = message?["tool_calls"] as? [[String: Any]]

            messages.append(message ?? [:])

            // Standard agent loop: only finish when the model stops requesting tools.
            guard let toolCalls, !toolCalls.isEmpty else {
                if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return content
                }
                return "Task completed (no response)"
            }

            for toolCall in toolCalls {
                try Task.checkCancellation()

                let function = toolCall["function"] as? [String: Any]
                let toolName = function?["name"] as? String ?? ""
                let rawArgs = function?["arguments"] as? String ?? "{}"
                let toolCallID = toolCall["id"] as? String ?? ""

                guard let tool = toolRegistry.tool(named: toolName) else {
                    messages.append(["role": "tool", "tool_call_id": toolCallID, "content": "Unknown tool: \(toolName)"])
                    continue
                }

                if let allowedToolNames, !allowedToolNames.contains(toolName) {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": toolCallID,
                        "content": "Tool \(toolName) is not allowed in this phase. Use only: \(allowedToolNames.sorted().joined(separator: ", "))"
                    ])
                    continue
                }

                guard let argsData = rawArgs.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
                    messages.append(["role": "tool", "tool_call_id": toolCallID, "content": "Invalid arguments JSON"])
                    continue
                }

                if updatePublishedStatus {
                    status = .running(toolName: toolName)
                }
                let stepStart = Date()

                let richResult: AgentToolResult
                do {
                    richResult = try await tool.executeReturningRichResult(arguments: args)
                } catch {
                    richResult = .textOnly("Error: \(error.localizedDescription)")
                }

                let duration = Date().timeIntervalSince(stepStart)
                let step = AgentStep(
                    toolName: toolName,
                    arguments: rawArgs,
                    result: richResult.text.prefix(2000).description,
                    duration: duration
                )
                if updatePublishedStatus {
                    stepLog.append(step)
                }
                onToolStep?(step)
                if updatePublishedStatus {
                    objectWillChange.send()
                }

                let toolMessageContent = Self.buildToolResultContentForModel(from: richResult)
                messages.append([
                    "role": "tool",
                    "tool_call_id": toolCallID,
                    "content": toolMessageContent
                ])
            }
        }

        return "Task reached maximum iterations without completion."
    }

    private func buildUserMessageContent(
        transcript: String,
        screenCaptures: [CompanionScreenCapture],
        mouseOutlineContext: CompanionMouseOutlineContext?
    ) -> Any {
        guard !screenCaptures.isEmpty else {
            return transcript
        }

        let capturesForMessage = screenCaptures.filter(\.isCursorScreen)
        let capturesToAttach = capturesForMessage.isEmpty ? screenCaptures : capturesForMessage

        var contentBlocks: [[String: Any]] = []

        for screenCapture in capturesToAttach {
            let outlinePointsForCapture = screenCapture.isCursorScreen
                ? (mouseOutlineContext?.outlinePointsInScreenshotSpace ?? [])
                : []
            let highlightedCellsForCapture = screenCapture.isCursorScreen
                ? (mouseOutlineContext?.touchedGridCellLabels ?? [])
                : []

            var dimensionInfo = " (image dimensions: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) pixels, grid overlay: columns A-T, rows 1-12)"
            if let spatialContextLabel = mouseOutlineContext?.spatialContextLabel,
               screenCapture.isCursorScreen {
                dimensionInfo += "; \(spatialContextLabel)"
            }

            let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
                originalJPEGData: screenCapture.imageData,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels,
                mouseOutlinePointsInScreenshotSpace: outlinePointsForCapture,
                highlightedGridCellLabels: highlightedCellsForCapture
            ) ?? screenCapture.imageData

            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(annotatedImageData.base64EncodedString())"
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": screenCapture.label + dimensionInfo
            ])
        }

        var transcriptWithSpatialHint = transcript
        if let spatialContextLabel = mouseOutlineContext?.spatialContextLabel {
            transcriptWithSpatialHint += "\n\n[\(spatialContextLabel) — the user circled this region on screen while asking.]"
        }

        contentBlocks.append([
            "type": "text",
            "text": transcriptWithSpatialHint
        ])

        return contentBlocks
    }

    private func extractAssistantText(from response: [String: Any]) -> String? {
        let choices = response["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String
    }

    /// Strips written-formatting artifacts so agent answers sound natural when spoken aloud.
    static func formatFinalResponseForSpeech(_ text: String) -> String {
        let textWithoutDrawTags = ScreenGridDrawParser.responseTextByRemovingDrawTags(from: text)
        let pointingParseResult = CompanionManager.parsePointingCoordinates(from: textWithoutDrawTags)
        var result = pointingParseResult.spokenText

        // Drop markdown links but keep the label: [title](url) → title
        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )

        // Remove bare URLs
        result = result.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )

        // Remove markdown emphasis markers
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "_", with: "")

        // Remove horizontal rules and divider lines
        result = result.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*_]{3,}[ \t]*\n?"#,
            with: "",
            options: .regularExpression
        )

        // Flatten bullet / numbered list prefixes into flowing speech
        result = result.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*•][ \t]+"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)^[ \t]*\d+[.)][ \t]+"#,
            with: "",
            options: .regularExpression
        )

        // Remove markdown heading markers
        result = result.replacingOccurrences(
            of: #"(?m)^[ \t]*#{1,6}[ \t]+"#,
            with: "",
            options: .regularExpression
        )

        // Newlines → spaces so TTS doesn't pause awkwardly between list items
        result = result.replacingOccurrences(
            of: #"\n+"#,
            with: " ",
            options: .regularExpression
        )

        // Collapse repeated spaces and trim
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.lowercased()
    }

    /// Builds OpenAI-compatible tool result content — multipart when a tool returns a vision image.
    private static func buildToolResultContentForModel(from richResult: AgentToolResult) -> Any {
        let truncatedText = truncateToolResultForModel(richResult.text)

        guard let visionImageJPEGData = richResult.visionImageJPEGData else {
            return truncatedText
        }

        var contentBlocks: [[String: Any]] = [
            ["type": "text", "text": truncatedText]
        ]

        if let visionImageLabel = richResult.visionImageLabel {
            contentBlocks.append(["type": "text", "text": visionImageLabel])
        }

        contentBlocks.append([
            "type": "image_url",
            "image_url": [
                "url": "data:image/jpeg;base64,\(visionImageJPEGData.base64EncodedString())"
            ]
        ])

        return contentBlocks
    }

    /// Keeps tool output within a reasonable context budget for the model.
    private static func truncateToolResultForModel(_ result: String) -> String {
        let maxCharacters = 12_000
        guard result.count > maxCharacters else { return result }
        let truncated = result.prefix(maxCharacters)
        return "\(truncated)\n\n[truncated — \(result.count - maxCharacters) more characters omitted]"
    }

    // MARK: - API Request

    private func sendChatRequest(
        messages: [[String: Any]],
        tools: [[String: Any]],
        model: String
    ) async throws -> [String: Any] {
        // `model` is ignored: TeachyAIRouter picks the publik tier for agent work.
        var body: [String: Any] = [
            "max_tokens": 4096,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = false
        }

        let data = try await TeachyAIRouter.sendJSON(
            job: .agent,
            hasImages: Self.messagesContainImages(messages),
            body: body
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "BackgroundAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        return json
    }

    private static func messagesContainImages(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains { ($0["type"] as? String) == "image_url" }
        }
    }

    // MARK: - Tool Definitions

    private func buildToolsPayload(allowedToolNames: Set<String>? = nil) -> [[String: Any]] {
        let localFunctionTools = toolRegistry.allTools()
            .filter { tool in
                guard let allowedToolNames else { return true }
                return allowedToolNames.contains(tool.name)
            }
            .map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.jsonSchema
                ]
            ] as [String: Any]
        }

        return localFunctionTools
    }
}
