//
//  CodingTools.swift
//  leanring-buddy
//
//  The agent tools for working on code the way Claude Code and Codex do:
//  edit_file (exact string replacement with a diff back), grep (content search,
//  ripgrep when installed), glob (find files by pattern, newest first) and
//  list_directory. read_file (with line numbers) and bash (with a working
//  folder) live in BackgroundAgentTool.swift.
//
//  Like every tool, these only run through BackgroundAgentToolRegistry.invoke,
//  after the permission gate. The pure parts (edit maths, diff, glob matching,
//  output shaping) are in CodingToolSupport.swift and tested standalone.
//

import Foundation

/// Small helpers the coding tools share.
enum CodingToolArguments {
    static func error(_ toolName: String, _ message: String) -> NSError {
        NSError(domain: toolName, code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Models send numbers as numbers or, now and then, as strings.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func boolean(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["true", "yes", "1"].contains(text.lowercased()) }
        return false
    }

    /// The folder a search starts in: the `path` argument, else the job's working folder
    /// (the project, or a named agent's files), else home. The gate uses the same rule.
    static func searchRoot(from arguments: [String: Any]) -> URL {
        if let path = arguments["path"] as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return AgentToolPaths.url(for: path)
        }
        return URL(fileURLWithPath: AgentToolPaths.defaultDirectory())
    }
}

// MARK: - edit_file

final class EditFileTool: BackgroundAgentTool {
    let name = "edit_file"
    let description = "Change part of a text file by exact string replacement. old_string must match the file exactly (indentation and line breaks included, without read_file's line-number prefixes) and occur once, unless replace_all is true. Read the file first. An empty old_string on a file that does not exist creates it. Returns a diff of the change. Relative paths start in the job's working folder."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The file to change: absolute, ~/…, or relative to the working folder"],
            "old_string": ["type": "string", "description": "The exact text to replace. Include enough surrounding lines to match one place."],
            "new_string": ["type": "string", "description": "The text to put in its place"],
            "replace_all": ["type": "boolean", "description": "Replace every occurrence of old_string (default false)"]
        ],
        "required": ["path", "old_string", "new_string"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw CodingToolArguments.error(name, "Missing 'path' argument")
        }
        guard let oldString = arguments["old_string"] as? String else {
            throw CodingToolArguments.error(name, "Missing 'old_string' argument")
        }
        guard let newString = arguments["new_string"] as? String else {
            throw CodingToolArguments.error(name, "Missing 'new_string' argument")
        }
        let replaceAll = CodingToolArguments.boolean(arguments["replace_all"])
        let url = AgentToolPaths.url(for: path)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        let fileExists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if fileExists && isDirectory.boolValue {
            throw CodingToolArguments.error(name, "\(url.path) is a folder, not a file.")
        }

        var originalText: String?
        var originalPermissions: Any?
        if fileExists {
            let data = try Data(contentsOf: url)
            if data.count > CodingFileReading.maximumFileBytes {
                throw CodingToolArguments.error(name, "\(url.path) is too large to edit here (\(CodingDirectoryListing.humanReadableSize(Int64(data.count)))).")
            }
            if CodingFileReading.looksBinary(data) {
                throw CodingToolArguments.error(name, "\(url.path) looks like a binary file; edit_file only changes text.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodingToolArguments.error(name, "\(url.path) is not UTF-8 text, so edit_file cannot change it safely.")
            }
            originalText = text
            originalPermissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
        }

        switch CodingEditApplication.apply(originalText: originalText, oldString: oldString, newString: newString, replaceAll: replaceAll) {
        case .failure(let message):
            throw CodingToolArguments.error(name, message)
        case .success(let newText, let replacementCount, let createsFile):
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newText.write(to: url, atomically: true, encoding: .utf8)
            // An atomic write replaces the file, which would drop an executable bit on a script.
            if let originalPermissions {
                try? fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: url.path)
            }
            let diff = CodingDiffSnippet.make(originalText: originalText ?? "", updatedText: newText, path: url.path)
            let headline: String
            if createsFile {
                headline = "Created \(url.path) (\(CodingFileReading.splitIntoLines(newText).count) lines)."
            } else {
                headline = "Edited \(url.path): \(replacementCount) replacement\(replacementCount == 1 ? "" : "s")."
            }
            return diff.isEmpty ? headline : headline + "\n" + diff
        }
    }
}

// MARK: - grep

final class GrepTool: BackgroundAgentTool {
    let name = "grep"
    let description = "Search file contents with a regular expression under a folder (default: the job's working folder). Skips .git, node_modules, build output and binary files. output_mode \"files\" (default) lists matching files; \"content\" shows path:line:text. Uses ripgrep when installed, else grep -E."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": ["type": "string", "description": "Regular expression to look for, e.g. \"func handle\\\\w+\" or \"TODO\""],
            "path": ["type": "string", "description": "Folder or file to search (default: the working folder)"],
            "glob": ["type": "string", "description": "Only files matching this glob, e.g. \"*.swift\" or \"*.{ts,tsx}\""],
            "case_insensitive": ["type": "boolean", "description": "Ignore case (default false)"],
            "output_mode": ["type": "string", "enum": ["files", "content"], "description": "\"files\" (default) or \"content\" with line numbers"],
            "max_results": ["type": "number", "description": "At most this many lines back (default 200)"]
        ],
        "required": ["pattern"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw CodingToolArguments.error(name, "Missing 'pattern' argument")
        }
        let searchRoot = CodingToolArguments.searchRoot(from: arguments)
        guard FileManager.default.fileExists(atPath: searchRoot.path) else {
            throw CodingToolArguments.error(name, "\(searchRoot.path) does not exist.")
        }
        let fileGlob = arguments["glob"] as? String
        let caseInsensitive = CodingToolArguments.boolean(arguments["case_insensitive"])
        let outputMode = CodingSearchCommand.OutputMode(rawValue: (arguments["output_mode"] as? String ?? "files").lowercased()) ?? .files
        let maximumResults = min(max(1, CodingToolArguments.integer(arguments["max_results"]) ?? CodingSearchCommand.defaultMaximumResults), 1000)

        let commandLine: String
        if let ripgrepPath = CodingExecutables.ripgrepPath {
            commandLine = CodingSearchCommand.commandLine(
                executable: ripgrepPath,
                arguments: CodingSearchCommand.ripgrepArguments(pattern: pattern, searchPath: searchRoot.path, fileGlob: fileGlob, caseInsensitive: caseInsensitive, outputMode: outputMode)
            )
        } else {
            commandLine = CodingSearchCommand.commandLine(
                executable: "/usr/bin/grep",
                arguments: CodingSearchCommand.grepArguments(pattern: pattern, searchPath: searchRoot.path, fileGlob: fileGlob, caseInsensitive: caseInsensitive, outputMode: outputMode)
            )
        }

        let worker = Task.detached(priority: .userInitiated) {
            try ShellRunner.run(command: commandLine, timeoutSeconds: 30, outputCap: 1_000_000, isCancelled: { Task.isCancelled })
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }

        if result.timedOut {
            throw CodingToolArguments.error(name, "The search took longer than 30 seconds. Search a smaller folder or add a glob.")
        }
        // Exit 1 = no matches. 2 = an error (a bad pattern, or unreadable files next to real matches).
        if result.standardOutput.isEmpty && result.exitCode >= 2 && !result.standardError.isEmpty {
            throw CodingToolArguments.error(name, "Search failed: \(result.standardError.prefix(500))")
        }
        var text = CodingSearchCommand.formatResults(
            rawOutput: result.standardOutput,
            outputMode: outputMode,
            maximumResults: maximumResults,
            isHiddenPath: { PathPolicy.looksLikeCredentialPath($0) }
        )
        if result.outputWasTruncated {
            text += "\n[The search printed more than Teachy keeps; narrow it to see everything.]"
        }
        return text
    }
}

// MARK: - glob

final class GlobTool: BackgroundAgentTool {
    let name = "glob"
    let description = "Find files by name pattern under a folder (default: the job's working folder), newest first. \"**\" matches any number of folders: \"**/*.swift\", \"src/**/*.{ts,tsx}\". A pattern without \"/\" matches file names at any depth. Skips .git, node_modules and build output; hidden folders only when the pattern names them."

    static let maximumResults = 300
    static let maximumEntriesVisited = 200_000

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": ["type": "string", "description": "Glob pattern, e.g. \"**/*.swift\" or \"*Test*.ts\""],
            "path": ["type": "string", "description": "Folder to search (default: the working folder)"]
        ],
        "required": ["pattern"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw CodingToolArguments.error(name, "Missing 'pattern' argument")
        }
        let searchRoot = CodingToolArguments.searchRoot(from: arguments)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodingToolArguments.error(name, "\(searchRoot.path) is not a folder.")
        }

        let rootPath = searchRoot.path
        let worker = Task.detached(priority: .userInitiated) {
            CodingFileFinder.find(pattern: pattern, rootPath: rootPath, maximumEntriesVisited: GlobTool.maximumEntriesVisited)
        }
        let found = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        if found.matches.isEmpty {
            return "No files match \(pattern) in \(rootPath)." + (found.stoppedEarly ? " (Stopped after \(GlobTool.maximumEntriesVisited) entries; search a smaller folder.)" : "")
        }
        let newestFirst = found.matches.sorted { $0.modified > $1.modified }
        var lines = newestFirst.prefix(Self.maximumResults).map(\.path)
        if newestFirst.count > Self.maximumResults {
            lines.append("[\(newestFirst.count - Self.maximumResults) more files not shown. Use a narrower pattern or path.]")
        }
        if found.stoppedEarly {
            lines.append("[Stopped after \(GlobTool.maximumEntriesVisited) entries; there may be more. Search a smaller folder.]")
        }
        return lines.joined(separator: "\n")
    }
}

/// The disk walk behind glob. Off the main actor: it runs on a detached task.
nonisolated enum CodingFileFinder {
    struct Match: Sendable {
        var path: String
        var modified: Date
    }

    struct Result: Sendable {
        var matches: [Match]
        var stoppedEarly: Bool
    }

    static func find(pattern: String, rootPath: String, maximumEntriesVisited: Int) -> Result {
        // Hidden folders are skipped unless the pattern itself reaches into one (".github/**").
        let patternNamesHiddenEntries = pattern.hasPrefix(".") || pattern.contains("/.") || pattern.contains("{.")
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !patternNamesHiddenEntries { options.insert(.skipsHiddenFiles) }

        let rootURL = URL(fileURLWithPath: rootPath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: options) else {
            return Result(matches: [], stoppedEarly: false)
        }

        let rootPrefix = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
        var matches: [Match] = []
        var visitedCount = 0
        var stoppedEarly = false
        for case let fileURL as URL in enumerator {
            visitedCount += 1
            if visitedCount > maximumEntriesVisited || Task.isCancelled {
                stoppedEarly = true
                break
            }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if CodingGlobMatcher.skippedDirectoryNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let fullPath = fileURL.standardizedFileURL.path
            let relativePath = fullPath.hasPrefix(rootPrefix) ? String(fullPath.dropFirst(rootPrefix.count)) : fileURL.lastPathComponent
            if CodingGlobMatcher.matches(pattern: pattern, relativePath: relativePath) {
                matches.append(Match(path: fullPath, modified: values?.contentModificationDate ?? .distantPast))
            }
        }
        return Result(matches: matches, stoppedEarly: stoppedEarly)
    }
}

// MARK: - list_directory

final class ListDirectoryTool: BackgroundAgentTool {
    let name = "list_directory"
    let description = "List one folder (not recursive): sub-folders end with /, files show their size. Default: the job's working folder."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The folder to list (default: the working folder)"]
        ],
        "required": []
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let directoryURL = CodingToolArguments.searchRoot(from: arguments)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw CodingToolArguments.error(name, "\(directoryURL.path) does not exist.")
        }
        guard isDirectory.boolValue else {
            throw CodingToolArguments.error(name, "\(directoryURL.path) is a file, not a folder. Use read_file to read it.")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys, options: [])
        let entries = contents.map { entryURL -> CodingDirectoryListing.Entry in
            let values = try? entryURL.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true
            return CodingDirectoryListing.Entry(
                name: entryURL.lastPathComponent,
                isDirectory: isFolder,
                byteCount: isFolder ? nil : values?.fileSize.map { Int64($0) }
            )
        }
        return CodingDirectoryListing.format(entries: entries, directoryPath: directoryURL.path)
    }
}

// MARK: - Executables

nonisolated enum CodingExecutables {
    /// ripgrep, if it is installed. Apps launched from Finder get a short PATH, so the usual
    /// Homebrew places are checked first. Worked out once per launch.
    static let ripgrepPath: String? = {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin"] + pathDirectories
        for directory in candidates {
            let candidate = (directory as NSString).appendingPathComponent("rg")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()
}
