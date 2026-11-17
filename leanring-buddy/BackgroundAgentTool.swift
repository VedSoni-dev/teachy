import Foundation

// MARK: - Tool Protocol

protocol BackgroundAgentTool {
    var name: String { get }
    var description: String { get }
    var jsonSchema: [String: Any] { get }

    func execute(arguments: [String: Any]) async throws -> String

    /// A protocol requirement (not only an extension default) so tools that return an image,
    /// like capture_screen and browser_screenshot, are not flattened to text by the registry.
    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult

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

    /// Where bash runs and searches start when no folder is given: the job's working folder
    /// (the project it works on, or a named agent's files), else home.
    static func defaultDirectory() -> String {
        if let workingDirectory = AgentJobContext.current?.workingDirectory, !workingDirectory.isEmpty {
            return workingDirectory
        }
        return NSHomeDirectory()
    }
}

// MARK: - Bash Tool

final class BashTool: BackgroundAgentTool {
    let name = "bash"
    let description = "Run a shell command on the user's Mac (zsh), in the job's working folder unless working_directory says otherwise. Returns stdout, stderr and the exit code. Not interactive: nothing can be typed into the command. Output past about 200 KB is dropped."

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
            ],
            "working_directory": [
                "type": "string",
                "description": "Folder to run in: absolute, ~/…, or relative to the working folder. Default: the job's working folder (the project, if there is one), else home."
            ]
        ],
        "required": ["command"]
    ]

    static func timeoutSeconds(from arguments: [String: Any]) -> TimeInterval {
        let requested = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? defaultTimeoutSeconds
        return min(max(1, requested), maximumTimeoutSeconds)
    }

    /// The folder the command runs in. The permission gate judges the same folder.
    static func workingDirectory(from arguments: [String: Any]) throws -> String {
        let requested = (arguments["working_directory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directory = requested.isEmpty ? AgentToolPaths.defaultDirectory() : AgentToolPaths.url(for: requested).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            if requested.isEmpty { return NSHomeDirectory() }
            throw NSError(domain: "BashTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "working_directory \(directory) is not a folder."])
        }
        return directory
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            throw NSError(domain: "BashTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'command' argument"])
        }
        let timeout = Self.timeoutSeconds(from: arguments)
        let workingDirectory = try Self.workingDirectory(from: arguments)

        // Off the MainActor: the runner blocks its thread until the command ends.
        // It drains stdout and stderr while the command runs, caps what it keeps,
        // and on timeout or Stop kills the command's whole process group.
        let worker = Task.detached(priority: .userInitiated) {
            try ShellRunner.run(
                command: command,
                timeoutSeconds: timeout,
                workingDirectory: workingDirectory,
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
    let description = "Read a text file. Lines come back numbered (\"    12\\t…\"), up to 2000 at a time; use offset and limit to page through long files. Use an absolute path or ~/. A relative path is read from the job's working folder (the project, or your files folder if you are a named agent), otherwise from home."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Path to the file: absolute, ~/…, or relative (see the tool description)"
            ],
            "offset": [
                "type": "number",
                "description": "First line to read, counting from 1 (default 1)"
            ],
            "limit": [
                "type": "number",
                "description": "How many lines to read (default 2000)"
            ]
        ],
        "required": ["path"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'path' argument"])
        }
        let url = AgentToolPaths.url(for: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is a folder. Use list_directory or glob to see what is in it."])
        }
        if let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           byteCount > CodingFileReading.maximumFileBytes {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is \(CodingDirectoryListing.humanReadableSize(Int64(byteCount))), too large to read. Use grep to find the part you need, or bash with head/tail."])
        }
        let data = try Data(contentsOf: url)
        if CodingFileReading.looksBinary(data) {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) looks like a binary file (\(CodingDirectoryListing.humanReadableSize(Int64(data.count)))), not text. Use bash (file, xxd, plutil, sqlite3) if you need to look inside it."])
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ReadFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "File is not valid UTF-8 text"])
        }
        return CodingFileReading.numberedExcerpt(
            text: content,
            offset: CodingToolArguments.integer(arguments["offset"]),
            limit: CodingToolArguments.integer(arguments["limit"])
        )
    }
}

// MARK: - Write File Tool

final class WriteFileTool: BackgroundAgentTool {
    let name = "write_file"
    let description = "Write content to a file. Creates parent directories if needed. Overwrites existing files. Use an absolute path or ~/. A relative path is written in the job's working folder (the project, or your files folder if you are a named agent), otherwise in home. To change part of an existing file, use edit_file instead."

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
