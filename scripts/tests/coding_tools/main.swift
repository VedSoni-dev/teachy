import Foundation

// Hermetic contracts for coding helpers. Paths and file contents are fixtures;
// no filesystem reads, shell execution, model calls, or user data are needed.
var checks = 0
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func failedEdit(_ result: CodingEditApplication.Outcome) -> Bool {
    if case .failure = result { return true }
    return false
}

let original = "let count = 1\nprint(count)\n"
expect(CodingEditApplication.apply(originalText: original, oldString: "count = 1", newString: "count = 2", replaceAll: false)
    == .success(newText: "let count = 2\nprint(count)\n", replacementCount: 1, createsFile: false), "an exact edit preserves surrounding source")
expect(failedEdit(CodingEditApplication.apply(originalText: original, oldString: "missing", newString: "replacement", replaceAll: false)), "missing text refuses the edit")
expect(failedEdit(CodingEditApplication.apply(originalText: "a a", oldString: "a", newString: "b", replaceAll: false)), "ambiguous text refuses a single replacement")
expect(CodingEditApplication.apply(originalText: "a a", oldString: "a", newString: "b", replaceAll: true)
    == .success(newText: "b b", replacementCount: 2, createsFile: false), "replace_all intentionally updates every match")
expect(CodingEditApplication.apply(originalText: nil, oldString: "", newString: "new file\n", replaceAll: false)
    == .success(newText: "new file\n", replacementCount: 1, createsFile: true), "empty old text creates a missing file")
expect(failedEdit(CodingEditApplication.apply(originalText: nil, oldString: "old", newString: "new", replaceAll: false)), "missing files cannot pretend to contain old text")
expect(failedEdit(CodingEditApplication.apply(originalText: original, oldString: "", newString: "replacement", replaceAll: false)), "empty old text cannot overwrite a populated file")
expect(CodingEditApplication.apply(originalText: "one\r\ntwo\r\n", oldString: "one\ntwo", newString: "first\nsecond", replaceAll: false)
    == .success(newText: "first\r\nsecond\r\n", replacementCount: 1, createsFile: false), "multiline edits preserve Windows line endings")
expect(failedEdit(CodingEditApplication.apply(originalText: "caf\u{00e9}", oldString: "cafe\u{0301}", newString: "coffee", replaceAll: false)), "visually equivalent Unicode is not silently treated as an exact edit")

expect(CodingFileReading.splitIntoLines("one\r\ntwo\r\n") == ["one", "two"], "reading normalizes CRLF without a phantom trailing line")
let excerpt = CodingFileReading.numberedExcerpt(text: "one\ntwo\nthree\n", offset: 2, limit: 1)
expect(excerpt.contains("2\ttwo") && !excerpt.contains("1\tone") && excerpt.contains("offset=3"), "paged reading returns the requested line and continuation offset")
expect(CodingFileReading.numberedExcerpt(text: "one", offset: 5, limit: nil).contains("past the end"), "out-of-range reads explain the file boundary")
expect(CodingFileReading.looksBinary(Data([65, 0, 66])) && !CodingFileReading.looksBinary(Data("source".utf8)), "binary content is distinguished from source text")
let diff = CodingDiffSnippet.make(originalText: "keep\nold\nend\n", updatedText: "keep\nnew\nend\n", path: "file.swift")
expect(diff.contains("--- a/file.swift") && diff.contains("-old") && diff.contains("+new") && diff.contains(" keep"), "diff records changes with surrounding context")
expect(CodingDiffSnippet.make(originalText: original, updatedText: original, path: "file.swift").isEmpty, "unchanged files have no diff")

for path in ["main.swift", "Sources/main.swift", "Sources/Nested/main.swift"] {
    expect(CodingGlobMatcher.matches(pattern: "**/*.swift", relativePath: path), "recursive glob matches \(path)")
}
expect(!CodingGlobMatcher.matches(pattern: "src/*.swift", relativePath: "src/deep/main.swift"), "single star cannot cross folder boundaries")
expect(CodingGlobMatcher.matches(pattern: "src/*.{swift,m}", relativePath: "src/main.m"), "brace alternatives match either source extension")
expect(CodingGlobMatcher.matches(pattern: "file[0-9]?.txt", relativePath: "file3a.txt"), "glob ranges and one-character wildcards work")
expect(!CodingGlobMatcher.matches(pattern: "file[!0-9].txt", relativePath: "file3.txt"), "negated glob classes reject excluded characters")

let rgArgs = CodingSearchCommand.ripgrepArguments(pattern: "--dangerous-pattern", searchPath: "-odd folder", fileGlob: "*.swift", caseInsensitive: true, outputMode: .content)
expect(Array(rgArgs.suffix(4)) == ["--regexp", "--dangerous-pattern", "--", "-odd folder"], "search pattern and dash-prefixed path are passed as data")
expect(rgArgs.contains("--line-number") && rgArgs.contains("--ignore-case") && rgArgs.contains("!node_modules"), "content search includes line numbers, case option, and dependency exclusion")
let grepArgs = CodingSearchCommand.grepArguments(pattern: "needle", searchPath: "/fixture/repo", fileGlob: "src/*.{swift,m}", caseInsensitive: false, outputMode: .files)
expect(grepArgs.contains("-l") && grepArgs.contains("--include=*.swift") && grepArgs.contains("--include=*.m"), "fallback grep retains file mode and expanded globs")
let command = CodingSearchCommand.commandLine(executable: "/usr/bin/rg", arguments: ["it's $(not a command)"])
expect(command == "'/usr/bin/rg' 'it'\\''s $(not a command)'", "shell quoting protects apostrophes and command-looking input")
let search = CodingSearchCommand.formatResults(rawOutput: "src/a.swift:3:match\n.env:1:secret\nsrc/b.swift:4:match", outputMode: .content, maximumResults: 1, isHiddenPath: { $0 == ".env" })
expect(search.contains("src/a.swift:3:match") && !search.contains(":secret") && !search.contains("src/b.swift:4"), "result shaping omits secrets and limits ordinary results")
expect(search.contains("more result") && search.contains("secrets were left out"), "truncated and hidden results are reported")

let fakeHome = "/Users/fixture"
let directories: Set<String> = [fakeHome, fakeHome + "/code", fakeHome + "/code/My App", fakeHome + "/code/My App/Sources", "/fixture", "/fixture/repo"]
let gitDirectories: Set<String> = [fakeHome, fakeHome + "/code/My App", "/fixture/repo"]
func project(_ question: String) -> String? {
    CodingProjectDetection.projectDirectory(inRequestText: question, home: fakeHome,
                                            isDirectory: { directories.contains($0) },
                                            hasGitEntry: { gitDirectories.contains($0) })
}
expect(project("Fix '~/code/My App/Sources/main.swift'") == fakeHome + "/code/My App", "a quoted file path with spaces resolves to its enclosing git project")
expect(project("Work in /fixture/repo.") == "/fixture/repo", "a project outside home can be explicitly selected")
expect(project("Look at ~") == nil && project("Look at /") == nil, "home and filesystem root are never selected as projects")
expect(project("Explain this code without a path") == nil, "a request without a project does not invent one")
let prompt = CodingProjectDetection.promptSection(projectDirectory: "/fixture/repo", instructionFiles: [(name: "AGENTS.md", contents: "Use the test runner.")])
expect(prompt.contains("/fixture/repo") && prompt.contains("Use the test runner.") && prompt.contains("read_file"), "project context contains the folder, owner instructions, and coding guidance")

let policySettings = ToolPolicySettings(homeDirectory: fakeHome, projectDirectory: "/fixture/repo")
for tool in ["read_file", "grep", "glob", "list_directory"] {
    let path = tool == "read_file" ? "/fixture/repo/src/main.swift" : "/fixture/repo"
    expect(ToolPolicy.classify(toolName: tool, arguments: ["path": path, "pattern": "needle"], settings: policySettings).risk == .safe, "\(tool) can read the selected project")
    expect(ToolPolicy.classify(toolName: tool, arguments: ["path": "/fixture/repo/.env", "pattern": "needle"], settings: policySettings).risk == .alwaysAsk, "\(tool) still protects project credentials")
}
expect(ToolPolicy.classify(toolName: "edit_file", arguments: ["path": "/fixture/repo/src/main.swift"], settings: policySettings).risk == .needsConsent, "project edits require consent")
expect(ToolPolicy.classify(toolName: "edit_file", arguments: ["path": "/fixture/repo/.env"], settings: policySettings).risk == .alwaysAsk, "editing project credentials always asks")
expect(ToolPolicy.classify(toolName: "read_file", arguments: ["path": "/fixture/other/main.swift"], settings: policySettings).risk == .needsConsent, "outside-project reads do not inherit project permission")
expect(ToolPolicy.classify(toolName: "bash", arguments: ["command": "pwd", "working_directory": "/fixture/repo"], settings: policySettings).risk == .safe, "a read-only shell command can use the selected project")
expect(ToolPolicy.classify(toolName: "bash", arguments: ["command": "cat config", "working_directory": fakeHome + "/.ssh"], settings: policySettings).risk == .alwaysAsk, "working-directory context protects credential reads")

print("Coding tools: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
