//
//  AgentLoop.swift
//  leanring-buddy
//
//  The model / tool loop of an agent job, with everything app-specific passed
//  in as hooks. No AppKit here, so the loop is unit-tested with a scripted
//  model and stub tools (scripts/tests/agents2) and timed against the real
//  model from a small harness.
//
//  Two things make it quick:
//  - The plan rides along. The model writes it as a line of text ("PLAN: …",
//    "STEP: 2") in the same turn as a tool call, so stating or updating the
//    plan costs no round trip. Still one tool per turn, parallel calls off.
//  - The model's reply is streamed. Sentences of the final answer are handed
//    to `answerSentence` as they complete, so speech starts before the answer
//    is finished.
//
//  Model calls go ONLY through TeachyAIRouter (job `.agent`); streams are read
//  through StreamIdleGuard.
//

import Foundation

struct AgentToolCall: Equatable {
    var id: String
    var name: String
    /// The arguments exactly as the model wrote them (a JSON object as text).
    var arguments: String
}

/// One reply from the model: text, tool calls, or both.
struct AgentAssistantTurn: Equatable {
    var content: String
    var toolCalls: [AgentToolCall]

    /// The reply in the shape a chat-completions request accepts back.
    var message: [String: Any] {
        var message: [String: Any] = ["role": "assistant"]
        message["content"] = content.isEmpty ? NSNull() : content
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { call -> [String: Any] in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments] as [String: Any]]
            }
        }
        return message
    }
}

// MARK: - Reading a streamed reply

/// Puts a streamed chat-completions reply back together: text deltas, and tool calls whose
/// name and arguments arrive in pieces. Pure.
nonisolated struct AgentStreamAccumulator {
    private(set) var content = ""
    private(set) var finishReason: String?
    private(set) var sawDoneMarker = false
    private(set) var errorMessage: String?
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    init() {}

    /// The reply is complete: stop reading even if the server keeps the stream open.
    var isComplete: Bool { sawDoneMarker || finishReason != nil || errorMessage != nil }

    var hasToolCalls: Bool { !calls.isEmpty }

    var toolCalls: [AgentToolCall] {
        calls.keys.sorted().compactMap { index -> AgentToolCall? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return AgentToolCall(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments)
        }
    }

    /// Feeds one line of the stream. Returns true when the answer text grew.
    @discardableResult
    mutating func ingest(line rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            sawDoneMarker = true
            return false
        }
        guard let data = payload.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let error = json["error"] as? [String: Any] {
            errorMessage = (error["message"] as? String) ?? "The AI reported an error."
            return false
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return false }

        var grew = false
        // Most servers send `delta`; a few send the whole `message` in one chunk.
        let part = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
        if let text = part["content"] as? String, !text.isEmpty {
            content += text
            grew = true
        }
        for (position, call) in ((part["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
            let index = (call["index"] as? NSNumber)?.intValue ?? position
            var entry = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
            let function = call["function"] as? [String: Any]
            if let name = function?["name"] as? String, !name.isEmpty {
                // Usually the whole name arrives once; some servers repeat it, a few send it in pieces.
                if entry.name.isEmpty { entry.name = name } else if entry.name != name { entry.name += name }
            }
            if let arguments = function?["arguments"] as? String { entry.arguments += arguments }
            calls[index] = entry
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
        return grew
    }

    var turn: AgentAssistantTurn { AgentAssistantTurn(content: content, toolCalls: toolCalls) }

    /// A line that shows the model has started its reply (text or a tool call), which lets the
    /// stream watchdog use its short idle limit.
    static let lineStartsReply: @Sendable (String) -> Bool = { line in
        guard line.hasPrefix("data:") else { return false }
        if line.contains("\"tool_calls\"") { return true }
        return (line.contains("\"content\":\"") && !line.contains("\"content\":\"\"")) || (line.contains("\"content\": \"") && !line.contains("\"content\": \"\""))
    }
}

// MARK: - One tool per turn

nonisolated enum AgentTurnPolicy {
    enum Disposition: Equatable, Sendable {
        /// An `update_plan` call: handled at once, runs nothing.
        case plan
        case run
        /// A second real tool in the same turn: not run, the model is told to send it again.
        case deferred
    }

    static let planToolName = "update_plan"

    /// What to do with the tool calls of one turn. The new loop (`inlinePlan`) runs ONE real
    /// tool per turn even if the model sends more; the old loop ran whatever it was given.
    static func dispositions(for toolNames: [String], inlinePlan: Bool) -> [Disposition] {
        var hasRunOne = false
        return toolNames.map { name in
            if name == planToolName { return .plan }
            guard inlinePlan else { return .run }
            if hasRunOne { return .deferred }
            hasRunOne = true
            return .run
        }
    }

    static let deferredReply = "Not run: one tool per turn. If you still need this call, send it in your next turn."
}

// MARK: - The plan as a line of text

/// The model keeps the plan card up to date with a line of text in the same turn as a tool call:
///
///     PLAN: Umbrella Check | Find the forecast; Read the calendar; Compare
///     STEP: 2
///
/// Pure. These lines are read for the card and are never spoken or shown as the answer.
nonisolated enum AgentPlanText {
    struct Update: Equatable, Sendable {
        var title: String?
        /// nil = the steps did not change.
        var steps: [String]?
        /// 1-based. nil = not stated (a new PLAN: starts at step 1).
        var currentStep: Int?
    }

    static let planMarker = "PLAN:"
    static let stepMarker = "STEP:"

    private static func marker(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(planMarker) { return planMarker }
        if trimmed.hasPrefix(stepMarker) { return stepMarker }
        return nil
    }

    /// The plan update in a turn's text, if it has one. The last PLAN: and the last STEP: win.
    static func parse(_ content: String) -> Update? {
        var update = Update()
        var found = false
        for line in content.components(separatedBy: .newlines) {
            guard let marker = marker(of: line) else { continue }
            let body = String(line.trimmingCharacters(in: .whitespaces).dropFirst(marker.count))
            if marker == planMarker {
                let halves = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let stepsText = halves.count == 2 ? halves[1] : halves[0]
                let steps = stepsText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !steps.isEmpty else { continue }
                update.steps = steps
                update.title = halves.count == 2 && !halves[0].isEmpty ? halves[0] : nil
                update.currentStep = nil
                found = true
            } else {
                let digits = body.drop { !$0.isNumber }.prefix { $0.isNumber }
                guard let number = Int(digits) else { continue }
                update.currentStep = number
                found = true
            }
        }
        return found ? update : nil
    }

    /// The text with its PLAN: / STEP: lines taken out. While the reply is still streaming
    /// (`isComplete` false), a last line that might yet turn into one of them is held back, so
    /// "PL" is never spoken before it becomes "PLAN: …". What this returns only ever grows as
    /// the reply grows.
    static func withoutPlanLines(_ content: String, isComplete: Bool) -> String {
        guard content.contains("P") || content.contains("S") else { return content }
        var lines = content.components(separatedBy: "\n")
        var heldBack = false
        if !isComplete, let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            let mightBecomeMarker = !trimmed.isEmpty && (planMarker.hasPrefix(trimmed) || stepMarker.hasPrefix(trimmed))
            if mightBecomeMarker || marker(of: last) != nil {
                lines.removeLast()
                heldBack = true
            }
        }
        let kept = lines.filter { marker(of: $0) == nil }
        var text = kept.joined(separator: "\n")
        // Keep the line break before a held-back line, so sentence boundaries stay where they were.
        if heldBack, !kept.isEmpty { text += "\n" }
        return text
    }
}

// MARK: - Hooks

enum AgentLoopToolOutcome {
    /// `content` is what goes back to the model (text, or blocks with a picture).
    case result(text: String, content: Any)
    /// The permission gate said no. Not a failure of the tool.
    case refused(String)
    case failed(String)
    /// Drive met a password / code / card field: the job ends and this line is spoken.
    case handBack(String)
}

struct AgentLoopHandBack: Error {
    let spokenLine: String
}

struct AgentLoopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AgentModelRequest {
    var messages: [[String: Any]]
    var tools: [[String: Any]]
    var parallelToolCalls: Bool
    var streams: Bool
    /// Called with the whole answer text so far each time it grows (streaming only).
    var onContent: ((String) -> Void)?
}

struct AgentLoopConfig {
    /// Tool definitions, WITHOUT update_plan (the loop adds it when `usesPlan`).
    var tools: [[String: Any]] = []
    var usesPlan = false
    /// The plan is a PLAN: / STEP: line of text in the same turn as a tool call (no extra round
    /// trip). Off = the old loop, where `update_plan` is a tool call with a turn of its own.
    var inlinePlan = true
    var streams = true
    var compaction = AgentCompaction.Budget()
    /// The plan so far when a finished job is picked up again, so the model can send just a step number.
    var knownPlanSteps: [String] = []

    init() {}
}

@MainActor
struct AgentLoopHooks {
    /// One model round trip. The app passes `AgentModelClient.send`; tests pass a script.
    var model: (AgentModelRequest) async throws -> AgentAssistantTurn
    var checkBudget: () -> AgentJobBudget.Verdict
    var recordIteration: () -> Void
    /// Status (nil = leave it) and a few words about what is happening.
    var publish: (AgentJobStatus?, String?) -> Void = { _, _ in }
    var planChanged: (String?, AgentPlan) -> Void = { _, _ in }
    var runTool: (AgentToolCall, [String: Any]) async -> AgentLoopToolOutcome
    var stepFinished: (AgentToolCall, String, TimeInterval) -> Void = { _, _, _ in }
    /// Things the person said since the last model call. Taking them removes them.
    var takeFollowUps: () -> [String] = { [] }
    /// Older tool results were dropped; these are their summaries. Return the notes text to read back in.
    var compacted: ([String]) -> String? = { _ in nil }
    /// A sentence of the final answer, ready to be spoken, as soon as it is complete.
    var answerSentence: ((String) -> Void)?
    /// The sentences just handed over turned out not to be the answer (the model went on to call a tool).
    var answerRetracted: (() -> Void)?
    var describeActivity: (String, [String: Any]) -> String = { name, _ in "Using \(name.replacingOccurrences(of: "_", with: " "))" }

    init(
        model: @escaping (AgentModelRequest) async throws -> AgentAssistantTurn,
        checkBudget: @escaping () -> AgentJobBudget.Verdict,
        recordIteration: @escaping () -> Void,
        runTool: @escaping (AgentToolCall, [String: Any]) async -> AgentLoopToolOutcome
    ) {
        self.model = model
        self.checkBudget = checkBudget
        self.recordIteration = recordIteration
        self.runTool = runTool
    }
}

// MARK: - The loop

@MainActor
enum AgentLoop {
    static let planToolName = AgentTurnPolicy.planToolName

    /// Only offered by the old "plan first" loop. The loop still understands the call if a model sends it.
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

    /// The plan is one line of text in the same turn as a tool call, so it never costs a round
    /// trip. (Measured 14 Nov 2026: asked to send an `update_plan` call alongside the real call,
    /// the smart tier still sent it alone, a full extra round each time. It does reliably write
    /// a line of text and call a tool in one turn.)
    static let planGuide = """
    SHOW YOUR PLAN WITHOUT SPENDING A TURN ON IT. The person watches a plan card while you work. You keep it up to date with one short line of text, written in the SAME turn as a tool call, just before the call:
    - First turn:   PLAN: <2-3 word title> | <step>; <step>; <step>      (2 to 6 short plain steps, then call your first tool in that same turn)
    - Moving on:    STEP: <number of the step you are starting>          (then call that step's tool in that same turn)
    - Plan changed: write a new PLAN: line.
    Example of a first turn: the text "PLAN: Umbrella Check | Find the forecast; Read the calendar; Compare" and a web_search call together.
    Those lines are the only text allowed in a turn that calls a tool. Never send a turn that has a PLAN: or STEP: line and no tool call. Call exactly one tool per turn. Everything else you want to say waits for your final answer.
    """

    /// The old rule, kept so the two loops can be timed against each other.
    static let legacyPlanGuide = """
    PLAN FIRST: your very first tool call must be update_plan, with a 2-3 word title and 2-6 short steps. \
    Call update_plan again each time you move to the next step. Keep steps short and plain; the user reads them.
    """

    static func planGuide(for config: AgentLoopConfig) -> String {
        config.inlinePlan ? planGuide : legacyPlanGuide
    }

    /// Runs the loop on `messages` (system + history + request already in it) until the model
    /// gives its final answer. `messages` is left holding the whole conversation, so a
    /// follow-up can pick it up later.
    static func run(messages: inout [[String: Any]], config: AgentLoopConfig, hooks: AgentLoopHooks) async throws -> String {
        var tools = config.tools
        let plansInText = config.usesPlan && config.inlinePlan
        if config.usesPlan, !config.inlinePlan { tools.insert(planToolDefinition, at: 0) }

        var failures = ToolFailureTracker()
        /// The steps last stated, so a later update can be just a step number.
        var knownPlanSteps = config.knownPlanSteps
        var knownCurrentStep = 1
        var isFinalTurn = false
        var hasPublishedWork = false

        /// Takes a plan update (from a PLAN: / STEP: line or an update_plan call). False when it says nothing usable.
        func applyPlan(title: Any?, steps: Any?, currentStep: Any?) -> Bool {
            var arguments: [String: Any] = [:]
            if let title { arguments["title"] = title }
            let statedSteps = (steps as? [Any]) ?? []
            arguments["steps"] = statedSteps.isEmpty ? knownPlanSteps : statedSteps
            arguments["current_step"] = currentStep ?? (statedSteps.isEmpty ? knownCurrentStep : 1)
            guard config.usesPlan, let parsed = AgentPlan.parse(arguments: arguments) else { return false }
            hasPublishedWork = true
            knownPlanSteps = parsed.plan.steps.map(\.text)
            knownCurrentStep = (parsed.plan.currentStep?.id) ?? (parsed.plan.steps.count + 1)
            hooks.planChanged(parsed.title, parsed.plan)
            hooks.publish(.running, parsed.plan.currentStep?.text ?? "Working")
            return true
        }

        func append(followUps: [String]) {
            for text in followUps {
                messages.append(["role": "user", "content": "The person just added this while you were working. Take it into account from here on:\n\(text)"])
            }
        }

        while true {
            try Task.checkCancellation()
            append(followUps: hooks.takeFollowUps())

            switch hooks.checkBudget() {
            case .proceed:
                break
            case .lastTurn:
                isFinalTurn = true
                messages.append(["role": "user", "content": "Step limit reached. Stop calling tools. Say in a sentence or two what you got done and what is left."])
            case .exhausted(let why):
                if isFinalTurn { throw AgentLoopError(message: "The job \(why) before it could finish.") }
                isFinalTurn = true
                messages.append(["role": "user", "content": "This job has \(why). Stop calling tools. Say in a sentence or two what you got done and what is left."])
            }

            let compaction = AgentCompaction.compact(&messages, budget: config.compaction)
            if compaction.didCompact, let notes = hooks.compacted(compaction.summaries) {
                AgentCompaction.readNotesBackIn(notes, messages: &messages)
            }

            hooks.publish(hasPublishedWork ? .running : .planning, isFinalTurn ? "Wrapping up" : "Thinking")

            // Speak the answer as it arrives. Text in a turn that goes on to call a tool is not the answer.
            var segmenter = StreamingSpeechSegmenter()
            var spokenSentences = 0
            var latestContent = ""
            func speak(_ sentences: [String]) {
                for sentence in sentences {
                    let natural = AgentSpeechFormatter.naturalSentences(sentence)
                    guard !natural.isEmpty else { continue }
                    spokenSentences += 1
                    hooks.answerSentence?(natural)
                }
            }

            var request = AgentModelRequest(
                messages: messages,
                tools: isFinalTurn ? [] : tools,
                // One tool per turn. The plan needs no second call: it is a line of text.
                parallelToolCalls: false,
                streams: config.streams
            )
            var planShownWhileStreaming: AgentPlanText.Update?
            if config.streams, plansInText || hooks.answerSentence != nil {
                request.onContent = { accumulated in
                    latestContent = accumulated
                    if plansInText {
                        // The plan line comes before the tool call: put it on the card the moment
                        // the line is complete, while the model is still writing the call.
                        if let lineEnd = accumulated.lastIndex(of: "\n"),
                           let update = AgentPlanText.parse(String(accumulated[..<lineEnd])), update != planShownWhileStreaming {
                            planShownWhileStreaming = update
                            _ = applyPlan(title: update.title, steps: update.steps, currentStep: update.currentStep)
                        }
                    }
                    guard hooks.answerSentence != nil else { return }
                    // PLAN: / STEP: lines are for the card, never for the voice.
                    let speakable = plansInText ? AgentPlanText.withoutPlanLines(accumulated, isComplete: false) : accumulated
                    speak(segmenter.feed(accumulated: speakable))
                }
            }
            let turn = try await hooks.model(request)
            hooks.recordIteration()
            try Task.checkCancellation()

            if plansInText, let update = AgentPlanText.parse(turn.content), update != planShownWhileStreaming {
                _ = applyPlan(title: update.title, steps: update.steps, currentStep: update.currentStep)
            }
            let content = plansInText ? AgentPlanText.withoutPlanLines(turn.content, isComplete: true) : turn.content
            let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if turn.toolCalls.isEmpty || isFinalTurn {
                // The final answer. If the person spoke while it was being written, carry on instead.
                let lateFollowUps = isFinalTurn ? [] : hooks.takeFollowUps()
                if !lateFollowUps.isEmpty {
                    if spokenSentences > 0 { hooks.answerRetracted?() }
                    if hasText { messages.append(["role": "assistant", "content": content]) }
                    append(followUps: lateFollowUps)
                    continue
                }
                let answer: String
                if hasText {
                    answer = content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    answer = isFinalTurn ? "I ran out of steps before I could finish." : "Done."
                }
                if hooks.answerSentence != nil {
                    if latestContent == turn.content, hasText {
                        speak(segmenter.finish(accumulated: content))
                    } else if spokenSentences == 0 {
                        // Not streamed (or nothing came through the stream): say it all now.
                        var whole = StreamingSpeechSegmenter()
                        speak(whole.finish(accumulated: answer))
                    }
                }
                // The work is finished, so the plan on the card is too.
                if !isFinalTurn, !knownPlanSteps.isEmpty, knownCurrentStep <= knownPlanSteps.count {
                    _ = applyPlan(title: nil, steps: nil, currentStep: knownPlanSteps.count + 1)
                }
                messages.append(["role": "assistant", "content": answer])
                return answer
            }

            if spokenSentences > 0 { hooks.answerRetracted?() }
            messages.append(turn.message)

            let dispositions = AgentTurnPolicy.dispositions(for: turn.toolCalls.map(\.name), inlinePlan: config.usesPlan && config.inlinePlan)
            for (call, disposition) in zip(turn.toolCalls, dispositions) {
                try Task.checkCancellation()
                func reply(_ content: Any) {
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": content])
                }

                let arguments: [String: Any]
                if call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    arguments = [:]
                } else if let data = call.arguments.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    arguments = parsed
                } else {
                    reply("Invalid arguments JSON")
                    continue
                }

                switch disposition {
                case .plan:
                    if applyPlan(title: arguments["title"], steps: arguments["steps"], currentStep: arguments["current_step"]) {
                        reply(plansInText ? "Plan noted. Next time write it as a PLAN: or STEP: line of text in the same turn as a tool call instead; that saves a turn." : "Plan noted. Carry on.")
                    } else {
                        reply("update_plan needs steps (a list of short strings) and current_step.")
                    }
                    continue
                case .deferred:
                    reply(AgentTurnPolicy.deferredReply)
                    continue
                case .run:
                    break
                }

                if failures.isDead(toolName: call.name, argumentsJSON: call.arguments) {
                    failures.recordRefusedRepeat()
                    if failures.shouldGiveUp {
                        throw AgentLoopError(message: "I kept hitting the same wall with \(call.name), so I stopped.")
                    }
                    reply("Not run: this exact call already failed twice the same way. Use a different approach, or stop and tell the user what is blocking you.")
                    continue
                }

                hasPublishedWork = true
                hooks.publish(.running, hooks.describeActivity(call.name, arguments))
                let stepStart = Date()
                let outcome = await hooks.runTool(call, arguments)
                try Task.checkCancellation()

                let resultText: String
                var richContent: Any?
                switch outcome {
                case .result(let text, let content):
                    resultText = text
                    richContent = content
                case .refused(let message):
                    resultText = message
                case .handBack(let line):
                    throw AgentLoopHandBack(spokenLine: line)
                case .failed(let message):
                    switch failures.recordFailure(toolName: call.name, argumentsJSON: call.arguments, error: message) {
                    case .firstFailure:
                        resultText = "Error: \(message)"
                    case .abortApproach:
                        resultText = "Error: \(message)\nThis exact call has now failed twice the same way. Do not repeat it. Try a different approach, or stop and tell the user what is blocking you."
                    }
                }

                hooks.stepFinished(call, resultText, Date().timeIntervalSince(stepStart))
                reply(richContent ?? truncate(resultText))
            }
        }
    }

    static func truncate(_ text: String, limit: Int = 12_000) -> String {
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n\n[truncated — \(text.count - limit) more characters omitted]"
    }
}
