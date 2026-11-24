// Stand-ins for the app types ImageRedactionTool.swift leans on, so it compiles alone.
import Foundation
protocol BackgroundAgentTool {
    var name: String { get }
    var description: String { get }
    var jsonSchema: [String: Any] { get }
    func execute(arguments: [String: Any]) async throws -> String
    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult
}
struct AgentToolResult {
    let text: String
    let visionImageJPEGData: Data?
    let visionImageLabel: String?
}
enum AgentToolPaths {
    static func url(for path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
}
