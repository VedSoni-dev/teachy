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

// MARK: - Paths

/// Where a file tool's `path` argument points. The permission gate works out the same answer
/// (`PathPolicy.absolute`), so what is approved is what is touched.
enum AgentToolPaths {
    static func url(for path: String) -> URL {
        URL(fileURLWithPath: PathPolicy.absolute(path, workingDirectory: AgentJobContext.current?.workingDirectory, home: NSHomeDirectory()))
    }
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
    let description = "Read the contents of a file. Use an absolute path or ~/. A relative path is read from your files folder if you are a named agent, otherwise from the home folder."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Path to the file: absolute, ~/…, or relative (see the tool description)"
            ]
        ],
        "required": ["path"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'path' argument"])
        }
        let url = AgentToolPaths.url(for: path)
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
    let description = "Write content to a file. Creates parent directories if needed. Overwrites existing files. Use an absolute path or ~/. A relative path is written in your files folder if you are a named agent, otherwise in the home folder."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Path to the file: absolute, ~/…, or relative (see the tool description)"
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
        let url = AgentToolPaths.url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) characters to \(url.path)"
    }
}

// The tool registry (and the permission gate every call passes through) lives in Agent/AgentToolRegistry.swift.
