//
//  RoutineInterpreter.swift
//  leanring-buddy
//
//  Turns "every weekday at 9 check my GitHub notifications" into a checked
//  schedule + task. One small model call (job `.quickCheck`) through
//  TeachyAIRouter; the reply is read by `RoutineDraft.parse`, which rejects
//  anything that is not one of the four schedule shapes.
//

import Foundation

@MainActor
enum RoutineInterpreter {
    static func requestBody(for sentence: String, agentNames: [String]) -> [String: Any] {
        var system = RoutineDraft.systemPrompt
        if !agentNames.isEmpty {
            system += "\nAgents that exist: \(agentNames.joined(separator: ", ")). Only name one of these, and only if the sentence does."
        }
        return [
            "max_tokens": 300,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": String(sentence.prefix(1_000))]
            ]
        ]
    }

    /// Throws a plain sentence when the model's reply is not a valid routine.
    static func interpret(_ sentence: String, agentNames: [String] = []) async throws -> RoutineDraft {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else {
            throw RoutineScheduleError(message: "Say when and what, like \"every weekday at 9, check my GitHub notifications\".")
        }
        let data = try await TeachyAIRouter.sendJSON(job: .quickCheck, hasImages: false, timeout: 45, body: requestBody(for: trimmed, agentNames: agentNames))
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        return try RoutineDraft.parse(modelReply: (message?["content"] as? String) ?? "")
    }
}
