//
//  BackgroundAgentToolStub.swift
//
//  The app's `BackgroundAgentTool` protocol lives in a file full of unrelated
//  tools (bash, AppleScript, screen capture) that these tests can't compile.
//  This is the same protocol, copied, so `ConnectorCenter` and its tool
//  adapters build and run here. Keep it identical to
//  leanring-buddy/BackgroundAgentTool.swift.
//

import Foundation

protocol BackgroundAgentTool {
    var name: String { get }
    var description: String { get }
    var jsonSchema: [String: Any] { get }

    func execute(arguments: [String: Any]) async throws -> String
}
