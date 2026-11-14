import Foundation

// MARK: - Tool Protocol

protocol BackgroundAgentTool {
    var name: String { get }
    var description: String { get }
    var jsonSchema: [String: Any] { get }

    func execute(arguments: [String: Any]) async throws -> String

    /// For tools that are one HTTP call (connectors): the method, so the permission
    /// gate can tell a read from a delete. nil for everything else.
    var httpMethodForPolicy: String? { get }
}

extension BackgroundAgentTool {
    var httpMethodForPolicy: String? { nil }
}

// MARK: - Bash Tool

final class BashTool: BackgroundAgentTool {
    let name = "bash"
    let description = "Run a shell command on the user's Mac (zsh). Returns stdout, stderr and the exit code. Not interactive: nothing can be typed into the command. Output past about 200 KB is dropped."

    static let defaultTimeoutSeconds: TimeInterval = 30
    static let maximumTimeoutSeconds: TimeInterval = 300

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "The shell command to execute"
            ],
            "timeout_seconds": [
                "type": "number",
                "description": "How long to let it run. Default 30, at most 300. Use more for installs and builds."
            ]
        ],
        "required": ["command"]
    ]

    static func timeoutSeconds(from arguments: [String: Any]) -> TimeInterval {
        let requested = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? defaultTimeoutSeconds
        return min(max(1, requested), maximumTimeoutSeconds)
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            throw NSError(domain: "BashTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'command' argument"])
        }
        let timeout = Self.timeoutSeconds(from: arguments)
        let home = NSHomeDirectory()

        // Off the MainActor: the runner blocks its thread until the command ends.
        // It drains stdout and stderr while the command runs, caps what it keeps,
        // and on timeout or Stop kills the command's whole process group.
        let worker = Task.detached(priority: .userInitiated) {
            try ShellRunner.run(
                command: command,
                timeoutSeconds: timeout,
                workingDirectory: home,
                isCancelled: { Task.isCancelled }
            )
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        return result.report
    }
}

// MARK: - Read File Tool

final class ReadFileTool: BackgroundAgentTool {
    let name = "read_file"
    let description = "Read the contents of a file at the given path."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file"
            ]
        ],
        "required": ["path"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'path' argument"])
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "File is not valid UTF-8 text"])
        }
        return content
    }
}

// MARK: - Write File Tool

final class WriteFileTool: BackgroundAgentTool {
    let name = "write_file"
    let description = "Write content to a file at the given path. Creates parent directories if needed. Overwrites existing files."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file"
            ],
            "content": [
                "type": "string",
                "description": "Content to write to the file"
            ]
        ],
        "required": ["path", "content"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "WriteFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'path' argument"])
        }
        guard let content = arguments["content"] as? String else {
            throw NSError(domain: "WriteFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'content' argument"])
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) characters to \(path)"
    }
}

// The tool registry (and the permission gate every call passes through) lives in Agent/AgentToolRegistry.swift.
