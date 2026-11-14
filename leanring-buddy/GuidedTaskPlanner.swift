//
//  GuidedTaskPlanner.swift
//  leanring-buddy
//
//  The model calls behind a [GUIDE:] walkthrough:
//  - `GuidedTaskPlanner` plans the steps from a screenshot, and replans the rest
//    when a step goes off track.
//  - `GuidedStepScreenChecker` looks at a screenshot and says whether the current
//    step is done (pass / partial / off track), and whether an error is visible.
//

import Foundation

enum GuidedStepCheckStatus: String, Codable {
    case pass
    case partial
    case offTrack
}

struct GuidedStepCheckResult: Codable {
    let status: GuidedStepCheckStatus
    let whatsGood: String
    let whatsMissing: String?
    let suggestedNextAction: String?
    /// One plain-words sentence describing any error message, stack trace, or failure
    /// state visible on screen. Nil when no error is visible.
    let visibleErrorSummary: String?
}

@MainActor
enum GuidedStepScreenChecker {

    /// Checks one screenshot against a step's natural-language "done when" description.
    static func checkStep(
        doneWhenDescription: String,
        screenCapture: CompanionScreenCapture,
        claudeAPI: ClaudeAPI
    ) async -> GuidedStepCheckResult {
        let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
            originalJPEGData: screenCapture.imageData,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        ) ?? screenCapture.imageData

        let systemPrompt = """
        you check whether one step of a task is done. look at the screenshot only.

        reply with ONLY a JSON object:
        {"status":"pass"|"partial"|"offTrack","whatsGood":"short description of what IS correct on screen","whatsMissing":"what's still missing or wrong — null if pass","suggestedNextAction":"one specific next move the person should take — null if pass","visibleErrorSummary":"one plain-words sentence describing any error message, stack trace, or failure state visible on screen — null if none"}

        rules:
        - status "pass" = the step is clearly done on screen.
        - status "partial" = real progress but something specific is missing or incomplete. name what's right first, then what's missing.
        - status "offTrack" = the step is not meaningfully progressed or the screen shows something unrelated. still name any partial progress if it exists.
        - whatsGood should always name something concrete that is visible — never leave it empty.
        - suggestedNextAction should be one short, specific instruction — not a list.
        - be honest but kind. "close" is partial, not offTrack.
        - visibleErrorSummary: set this ONLY when an actual error message, exception, stack trace, or failure state is clearly visible on screen. null otherwise.
        """

        let userPrompt = """
        done when: \(doneWhenDescription)

        What is the current state on screen? Is this step done, partly done, or off track?
        """

        let rawResponse: String
        do {
            (rawResponse, _) = try await claudeAPI.analyzeImage(
                images: [(data: annotatedImageData, label: screenCapture.label)],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        } catch {
            print("⚠️ Guided step screen check error: \(error)")
            return GuidedStepCheckResult(
                status: .offTrack,
                whatsGood: "",
                whatsMissing: "screen check failed — \(error.localizedDescription)",
                suggestedNextAction: nil,
                visibleErrorSummary: nil
            )
        }

        return parseCheckResult(from: rawResponse)
    }

    private static func parseCheckResult(from rawText: String) -> GuidedStepCheckResult {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonCandidate: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            jsonCandidate = String(trimmed[start...end])
        } else {
            jsonCandidate = trimmed
        }

        guard let data = jsonCandidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("yes") || lowered.contains("\"status\": \"pass\"") || lowered.contains("\"status\":\"pass\"") {
                return GuidedStepCheckResult(
                    status: .pass,
                    whatsGood: "the screen shows the step is done",
                    whatsMissing: nil,
                    suggestedNextAction: nil,
                    visibleErrorSummary: nil
                )
            }
            return GuidedStepCheckResult(
                status: .offTrack,
                whatsGood: "",
                whatsMissing: "could not read the screen check response",
                suggestedNextAction: nil,
                visibleErrorSummary: nil
            )
        }

        let status: GuidedStepCheckStatus
        switch (object["status"] as? String)?.lowercased() ?? "offtrack" {
        case "pass": status = .pass
        case "partial": status = .partial
        default: status = .offTrack
        }

        return GuidedStepCheckResult(
            status: status,
            whatsGood: (object["whatsGood"] as? String) ?? "",
            whatsMissing: object["whatsMissing"] as? String,
            suggestedNextAction: object["suggestedNextAction"] as? String,
            visibleErrorSummary: object["visibleErrorSummary"] as? String
        )
    }
}

@MainActor
enum GuidedTaskPlanner {

    /// Shape every planner reply must follow, shared by the plan and replan prompts.
    private static let stepsJSONShapeDescription = """
    Return ONLY a JSON object with this exact structure (no markdown fences, no explanation):
    {
        "steps": [
            {
                "id": "step-1",
                "title": "Step Title",
                "goal": "Success looks like: ...",
                "coachAsk": "What Teachy should say to move them through this step",
                "doneWhen": "Natural-language description of what 'done' looks like on screen",
                "executionMode": "coach"
            }
        ]
    }
    """

    private static let executionModeRules = """
    executionMode rules — think carefully:
    - "coach": the person does it, Teachy guides. Use this for anything that needs their judgment,
      their accounts or choices, is risky, irreversible, or financial.
    - "act": Teachy does this step itself (click, navigate, fill a field) — only for purely
      mechanical, unambiguous setup (open a URL, go to a specific page, click an obvious button
      to reach a starting point).
    - Default to "coach" whenever in doubt. Never mark anything destructive, irreversible, or
      financial as "act".
    """

    /// Plans a walkthrough against what is actually on screen right now, with the reasoning
    /// model. Each step comes back tagged `coach` or `act`.
    static func planSteps(
        taskDescription: String,
        screenCapture: CompanionScreenCapture?,
        groundingKnowledge: String?,
        apiClient: ClaudeAPI
    ) async throws -> [AgenticStep] {
        let systemPrompt = """
        You are the planning brain for Teachy, a macOS assistant that helps people get things done
        on their Mac. Look at what's ACTUALLY on the person's screen right now and break the task
        into a concrete, screen-grounded plan.

        \(stepsJSONShapeDescription)

        \(executionModeRules)

        Planning rules:
        - 2-5 steps, each building on the previous
        - Ground each step in what you can actually SEE on screen right now — real UI elements,
          current state, and any obstacles visible (login walls, wrong page, etc.)
        - Each step must be verifiable by looking at the screen
        - doneWhen: short natural-language description of what "done" looks like visually
        """

        let userPrompt = "Plan the walkthrough for: \(taskDescription)\(groundingContextLine(groundingKnowledge))"

        let rawJSONResponse = try await apiClient.generateReasonedPlanJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imageJPEGData: screenCapture?.imageData,
            imageLabel: screenCapture?.label,
            screenshotWidthInPixels: screenCapture?.screenshotWidthInPixels ?? 0,
            screenshotHeightInPixels: screenCapture?.screenshotHeightInPixels ?? 0,
            modelID: OpenRouterModelOption.reasoningPlannerModelID
        )
        return try parseAgenticSteps(fromRawJSONResponse: rawJSONResponse)
    }

    /// Fast fallback when the reasoning planner fails: one plain text call, no screenshot.
    /// Every step comes back as `coach`.
    static func planStepsWithoutScreen(
        taskDescription: String,
        groundingKnowledge: String?,
        apiClient: ClaudeAPI
    ) async throws -> [AgenticStep] {
        let systemPrompt = """
        You are helping Teachy, a macOS assistant, put together a short walkthrough for a spoken
        request — just enough concrete steps to guide someone through a task on their screen.

        \(stepsJSONShapeDescription)

        Rules:
        - 2-5 steps, each building on the previous
        - Each step must be concrete and verifiable by looking at the screen
        - executionMode is always "coach" here
        """

        let response = try await apiClient.generateText(
            systemPrompt: systemPrompt,
            userPrompt: "Create short walkthrough steps for: \(taskDescription)\(groundingContextLine(groundingKnowledge))"
        )
        return try parseAgenticSteps(fromRawJSONResponse: response).map { step in
            AgenticStep(goal: step.goal, executionMode: .coach)
        }
    }

    /// Called when a step diverged (screen check off track, or a step Teachy tried to do
    /// failed). Returns replacement steps from the current step onward; the caller keeps
    /// the steps already done.
    static func replanRemainingSteps(
        taskTitle: String,
        allSteps: [AgenticStep],
        currentStepIndex: Int,
        whatWentWrong: String,
        screenCapture: CompanionScreenCapture?,
        apiClient: ClaudeAPI
    ) async throws -> [AgenticStep] {
        let planSummaryLines = allSteps.enumerated().map { index, agenticStep in
            let statusMarker: String
            if index < currentStepIndex {
                statusMarker = "[DONE]"
            } else if index == currentStepIndex {
                statusMarker = "[CURRENT — DIVERGED]"
            } else {
                statusMarker = "[REMAINING]"
            }
            return "\(statusMarker) \(index + 1). \(agenticStep.goal.title) (\(agenticStep.executionMode.rawValue)): \(agenticStep.goal.goal)"
        }.joined(separator: "\n")

        let systemPrompt = """
        You are the replanning brain for Teachy, a macOS assistant. A step in a walkthrough just
        went off track and the plan needs revising.

        You get the task title, the current plan (done / diverged / remaining), what went wrong,
        and a fresh screenshot. Return revised steps from the CURRENT STEP ONWARD (never include
        steps already done). You may insert a prerequisite step, replace the current step with a
        different approach, reorder the rest, or keep steps that are still right.

        \(stepsJSONShapeDescription)

        \(executionModeRules)

        Keep the revised plan tight — 2-5 steps from the current point onward.
        """

        let userPrompt = """
        Task: \(taskTitle)

        Current plan:
        \(planSummaryLines)

        What went wrong: \(whatWentWrong)

        Please revise the plan from the current step onward.
        """

        let rawJSONResponse = try await apiClient.generateReasonedPlanJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imageJPEGData: screenCapture?.imageData,
            imageLabel: screenCapture?.label,
            screenshotWidthInPixels: screenCapture?.screenshotWidthInPixels ?? 0,
            screenshotHeightInPixels: screenCapture?.screenshotHeightInPixels ?? 0,
            modelID: OpenRouterModelOption.reasoningPlannerModelID
        )
        return try parseAgenticSteps(fromRawJSONResponse: rawJSONResponse)
    }

    private static func groundingContextLine(_ groundingKnowledge: String?) -> String {
        guard let groundingKnowledge, !groundingKnowledge.isEmpty else { return "" }
        return "\n\nGround the steps in this real knowledge about the tool being used: \(groundingKnowledge)"
    }

    /// Reads `{"steps": [...]}` (markdown fences tolerated). Each step's goal fields and its
    /// `executionMode` come from the same JSON object, so a dropped malformed step can never
    /// shift another step's mode. `executionMode` defaults to `coach` — never act when unsure.
    private static func parseAgenticSteps(fromRawJSONResponse rawJSONResponse: String) throws -> [AgenticStep] {
        let jsonStringForParsing = rawJSONResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let responseData = jsonStringForParsing.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let stepsJSON = json["steps"] as? [[String: Any]] else {
            throw NSError(
                domain: "GuidedTaskPlanner",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse walkthrough steps from the planner response"]
            )
        }

        return stepsJSON.compactMap { stepJSON -> AgenticStep? in
            guard let id = stepJSON["id"] as? String,
                  let title = stepJSON["title"] as? String,
                  let goal = stepJSON["goal"] as? String,
                  let coachAsk = stepJSON["coachAsk"] as? String,
                  let doneWhen = stepJSON["doneWhen"] as? String else {
                return nil
            }
            let stepGoal = GuidedStepGoal(id: id, title: title, goal: goal, coachAsk: coachAsk, doneWhen: doneWhen)
            let rawExecutionMode = stepJSON["executionMode"] as? String ?? "coach"
            let executionMode = GuidedStepExecutionMode(rawValue: rawExecutionMode) ?? .coach
            return AgenticStep(goal: stepGoal, executionMode: executionMode)
        }
    }
}
