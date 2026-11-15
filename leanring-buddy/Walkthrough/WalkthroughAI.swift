//
//  WalkthroughAI.swift
//  leanring-buddy / Walkthrough
//
//  The walkthrough's model calls, all through TeachyAIRouter:
//    plan / re-plan   job .plan        one call, one repair retry when the JSON is not usable
//    quick check      job .quickCheck  one YES/NO about a step's doneWhen
//    resume check     job .quickCheck  how many remaining steps were done while paused
//

import Foundation

enum WalkthroughPlanResult {
    case steps([WalkthroughStep])
    /// `spokenReason` is the planner's own one-sentence reason, when it gave one.
    case failed(spokenReason: String?)
}

enum WalkthroughAI {
    /// (job, hasImages, timeout, body) → response body. The app uses the router; a test can pass its own.
    typealias Send = (TeachyAIJob, Bool, TimeInterval, [String: Any]) async throws -> Data

    static let routerSend: Send = { job, hasImages, timeout, body in
        try await TeachyAIRouter.sendJSON(job: job, hasImages: hasImages, timeout: timeout, body: body)
    }

    /// Reasoning effort sent with each call. Nil leaves the router's default for the job.
    /// Measured 14 Nov 2026 on a synthetic LinkedIn settings page (screenshot + 22 controls):
    /// the router's default for .plan took 7–12 s, "low" 4.6 s and "minimal" 4.0 s, with the
    /// same route and valid JSON each time. "low" keeps a little thinking for unfamiliar apps.
    static let planEffort: String? = "low"
    /// Checks keep the router's default ("minimal"): about 1.7 s, and "low" answered the same.
    static let checkEffort: String? = nil

    static func plan(_ request: WalkthroughPlanRequest, screenshotJPEG: Data?, effort: String? = planEffort, send: Send? = nil) async -> WalkthroughPlanResult {
        var request = request
        request.hasScreenshot = screenshotJPEG != nil
        let firstAnswer: String
        do {
            firstAnswer = try await text(
                job: .plan,
                hasImages: screenshotJPEG != nil,
                timeout: 60,
                maxTokens: 4_096,
                messages: WalkthroughPrompts.planMessages(request, screenshotJPEG: screenshotJPEG),
                effort: effort,
                send: send
            )
        } catch {
            print("⚠️ Walkthrough plan failed: \(error.localizedDescription)")
            return .failed(spokenReason: nil)
        }

        let first = WalkthroughPlanParser.parse(firstAnswer, maximumSteps: request.maximumSteps, forbiddenSays: request.failedSays)
        if first.isValid { return result(from: first) }

        print("🧭 Walkthrough plan needs a repair: \(first.issues.map(\.text).joined(separator: "; "))")
        let repairedAnswer = try? await text(
            job: .plan,
            hasImages: false,
            timeout: 45,
            maxTokens: 4_096,
            messages: WalkthroughPrompts.repairMessages(request, badAnswer: firstAnswer, issues: first.issues),
            effort: effort,
            send: send
        )
        guard let repairedAnswer else { return salvage(first) }
        let repaired = WalkthroughPlanParser.parse(repairedAnswer, maximumSteps: request.maximumSteps, forbiddenSays: request.failedSays)
        return repaired.isValid ? result(from: repaired) : salvage(repaired)
    }

    private static func result(from outcome: WalkthroughPlanOutcome) -> WalkthroughPlanResult {
        if let problem = outcome.problem, outcome.steps.isEmpty { return .failed(spokenReason: problem) }
        return .steps(outcome.steps)
    }

    /// After the repair retry: a plan whose only fault is repeating failed instructions is used
    /// without those steps. Anything else is a failed plan.
    private static func salvage(_ outcome: WalkthroughPlanOutcome) -> WalkthroughPlanResult {
        let onlyRepeats = outcome.issues.allSatisfy {
            if case .repeatsFailedStep = $0 { return true }
            return false
        }
        if onlyRepeats, !outcome.steps.isEmpty { return .steps(outcome.steps) }
        return .failed(spokenReason: outcome.problem)
    }

    static func quickCheck(condition: String, controlList: String, screenshotJPEG: Data?, effort: String? = checkEffort, send: Send? = nil) async -> Bool? {
        guard screenshotJPEG != nil || !controlList.isEmpty else { return nil }
        let answer = try? await text(
            job: .quickCheck,
            hasImages: screenshotJPEG != nil,
            timeout: 15,
            maxTokens: 16,
            messages: WalkthroughPrompts.quickCheckMessages(condition: condition, controlList: controlList, screenshotJPEG: screenshotJPEG),
            effort: effort,
            send: send
        )
        return answer.flatMap(WalkthroughPlanParser.yesNo)
    }

    static func resumeCheck(goal: String, remaining: [WalkthroughStep], controlList: String, screenshotJPEG: Data?, effort: String? = checkEffort, send: Send? = nil) async -> Int? {
        guard !remaining.isEmpty, screenshotJPEG != nil || !controlList.isEmpty else { return nil }
        let answer = try? await text(
            job: .quickCheck,
            hasImages: screenshotJPEG != nil,
            timeout: 15,
            maxTokens: 16,
            messages: WalkthroughPrompts.resumeCheckMessages(goal: goal, remaining: remaining, controlList: controlList, screenshotJPEG: screenshotJPEG),
            effort: effort,
            send: send
        )
        return answer.flatMap { WalkthroughPlanParser.count($0, maximum: remaining.count) }
    }

    private static func text(job: TeachyAIJob, hasImages: Bool, timeout: TimeInterval, maxTokens: Int, messages: [[String: Any]], effort: String?, send: Send?) async throws -> String {
        var body: [String: Any] = ["max_tokens": maxTokens, "stream": false, "messages": messages]
        // When this is absent the router fills in its own default for the job.
        if let effort { body["reasoning_effort"] = effort }
        let data = try await (send ?? routerSend)(job, hasImages, timeout, body)
        guard let text = WalkthroughPrompts.assistantText(from: data) else {
            throw NSError(domain: "Walkthrough", code: -1, userInfo: [NSLocalizedDescriptionKey: "The answer had no text."])
        }
        return text
    }
}
