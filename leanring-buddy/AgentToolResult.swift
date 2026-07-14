//
//  AgentToolResult.swift
//  leanring-buddy
//
//  Tool results can include vision images (not just text paths) so the agent
//  loop sees the screen after capture_screen runs.
//

import Foundation

struct AgentToolResult {
    let text: String
    /// When set, attached to the tool_result message as an image block for the model.
    let visionImageJPEGData: Data?
    let visionImageLabel: String?

    static func textOnly(_ text: String) -> AgentToolResult {
        AgentToolResult(text: text, visionImageJPEGData: nil, visionImageLabel: nil)
    }

    static func withVisionImage(
        text: String,
        visionImageJPEGData: Data,
        visionImageLabel: String
    ) -> AgentToolResult {
        AgentToolResult(
            text: text,
            visionImageJPEGData: visionImageJPEGData,
            visionImageLabel: visionImageLabel
        )
    }
}

extension BackgroundAgentTool {
    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult {
        let text = try await execute(arguments: arguments)
        return .textOnly(text)
    }
}
