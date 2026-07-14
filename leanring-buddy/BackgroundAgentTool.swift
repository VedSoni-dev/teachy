import Foundation

// MARK: - Tool Protocol

protocol BackgroundAgentTool {
    var name: String { get }
    var description: String { get }
    var jsonSchema: [String: Any] { get }

    func execute(arguments: [String: Any]) async throws -> String
}

// MARK: - Bash Tool

final class BashTool: BackgroundAgentTool {
    let name = "bash"
    let description = "Run a shell command on the user's Mac. Returns stdout + stderr. Use for file operations, git, npm, scripting, etc."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "The shell command to execute"
            ]
        ],
        "required": ["command"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            throw NSError(domain: "BashTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'command' argument"])
        }

        // Run off the MainActor — waitUntilExit would freeze the UI (course spinner stuck).
        return try await Task.detached(priority: .userInitiated) {
            try Self.runShellCommand(command, timeoutSeconds: 20)
        }.value
    }

    private static func runShellCommand(_ command: String, timeoutSeconds: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let timeoutDeadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > timeoutDeadline {
                process.terminate()
                throw NSError(
                    domain: "BashTool",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Command timed out after \(Int(timeoutSeconds))s"]
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        let exitCode = process.terminationStatus
        var result = ""
        if !output.isEmpty { result += "stdout:\n\(output)\n" }
        if !errorOutput.isEmpty { result += "stderr:\n\(errorOutput)\n" }
        result += "exit code: \(exitCode)"
        return result
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

// MARK: - Tool Registry

final class BackgroundAgentToolRegistry {
    private var tools: [String: any BackgroundAgentTool] = [:]
    private var connectorToolNames: Set<String> = []

    init() {
        registerBuiltInTools()
    }

    private func registerBuiltInTools() {
        register(BashTool())
        register(ReadFileTool())
        register(WriteFileTool())
        register(RunAppleScriptTool())
        register(OpenBrowserTabTool())
        register(UIActionTool())
        register(CaptureScreenTool())
        register(AuthenticatedFetchTool())
        register(ListBrowserSessionsTool())
    }

    func register(_ tool: any BackgroundAgentTool) {
        tools[tool.name] = tool
    }

    func registerConnectorTools(_ connectorTools: [any BackgroundAgentTool]) {
        for connectorTool in connectorTools {
            register(connectorTool)
            connectorToolNames.insert(connectorTool.name)
        }
    }

    func unregisterAllConnectorTools() {
        for connectorToolName in connectorToolNames {
            tools.removeValue(forKey: connectorToolName)
        }
        connectorToolNames.removeAll()
    }

    func allTools() -> [any BackgroundAgentTool] {
        Array(tools.values)
    }

    func tool(named name: String) -> (any BackgroundAgentTool)? {
        tools[name]
    }
}
