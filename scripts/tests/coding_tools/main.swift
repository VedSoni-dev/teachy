// Tests for the coding tools' pure logic. Run with scripts/tests/run_coding_tools_tests.sh.

import Foundation

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func section(_ name: String) { print("— \(name)") }

// MARK: Reading with line numbers

section("read_file: numbered lines, offset and limit")
let fiveLines = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
let wholeFile = CodingFileReading.numberedExcerpt(text: fiveLines, offset: nil, limit: nil)
expect(wholeFile == "     1\talpha\n     2\tbeta\n     3\tgamma\n     4\tdelta\n     5\tepsilon", "whole file, no footer: got \(wholeFile.debugDescription)")
let middle = CodingFileReading.numberedExcerpt(text: fiveLines, offset: 2, limit: 2)
expect(middle.hasPrefix("     2\tbeta\n     3\tgamma\n"), "offset 2 limit 2 starts at beta: \(middle.debugDescription)")
expect(middle.contains("Showing lines 2–3 of 5") && middle.contains("offset=4"), "footer says how to read on: \(middle)")
let tail = CodingFileReading.numberedExcerpt(text: fiveLines, offset: 4, limit: nil)
expect(tail.hasPrefix("     4\tdelta\n     5\tepsilon") && tail.contains("End of file: 5 lines"), "tail read ends with end-of-file note: \(tail)")
expect(CodingFileReading.numberedExcerpt(text: fiveLines, offset: 9, limit: nil).contains("past the end"), "offset past the end is explained")
expect(CodingFileReading.numberedExcerpt(text: "", offset: nil, limit: nil) == "(the file is empty)", "empty file")
expect(CodingFileReading.splitIntoLines("a\r\nb\r\n") == ["a", "b"], "CRLF lines are split cleanly")
expect(CodingFileReading.splitIntoLines("a\nb") == ["a", "b"], "no final newline")
expect(CodingFileReading.splitIntoLines("a\n\n") == ["a", ""], "a blank last line is kept")
expect(CodingFileReading.numberedLine(number: 123456, content: "x") == "123456\tx", "wide numbers are not padded")
let longLine = String(repeating: "x", count: 5000)
let longExcerpt = CodingFileReading.numberedExcerpt(text: longLine, offset: nil, limit: nil)
expect(longExcerpt.contains("line cut at 2000") && longExcerpt.count < 2200, "very long lines are cut")
let manyLines = (1...5000).map { "line number \($0) with some text" }.joined(separator: "\n")
let budgeted = CodingFileReading.numberedExcerpt(text: manyLines, offset: nil, limit: nil)
expect(budgeted.count < 12_000, "output stays under the loop's 12k cut (\(budgeted.count))")
expect(budgeted.contains("more lines: call read_file again with offset="), "budget-cut output says how to continue")
expect(CodingFileReading.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])), "NUL byte means binary")
expect(!CodingFileReading.looksBinary(Data("plain text\n".utf8)), "text is not binary")

// MARK: Edits

section("edit_file: exact replacement")
func editText(_ outcome: CodingEditApplication.Outcome) -> String? {
    if case .success(let newText, _, _) = outcome { return newText }
    return nil
}
func editFailure(_ outcome: CodingEditApplication.Outcome) -> String? {
    if case .failure(let message) = outcome { return message }
    return nil
}
let source = "func a() {\n    return 1\n}\n\nfunc b() {\n    return 1\n}\n"
let uniqueEdit = CodingEditApplication.apply(originalText: source, oldString: "func a() {\n    return 1", newString: "func a() {\n    return 2", replaceAll: false)
expect(editText(uniqueEdit) == "func a() {\n    return 2\n}\n\nfunc b() {\n    return 1\n}\n", "unique match is replaced")
expect(editFailure(CodingEditApplication.apply(originalText: source, oldString: "return 1", newString: "return 3", replaceAll: false))?.contains("2 times") == true, "ambiguous match fails with a count")
let replaceAll = CodingEditApplication.apply(originalText: source, oldString: "return 1", newString: "return 3", replaceAll: true)
expect(editText(replaceAll) == source.replacingOccurrences(of: "return 1", with: "return 3"), "replace_all changes every match")
if case .success(_, let count, _) = replaceAll { expect(count == 2, "replace_all reports 2") } else { expect(false, "replace_all should succeed") }
expect(editFailure(CodingEditApplication.apply(originalText: source, oldString: "return 9", newString: "x", replaceAll: false))?.contains("not found") == true, "missing text fails")
expect(editFailure(CodingEditApplication.apply(originalText: source, oldString: "return 1", newString: "return 1", replaceAll: true))?.contains("same") == true, "no-op edit fails")
let created = CodingEditApplication.apply(originalText: nil, oldString: "", newString: "hello\n", replaceAll: false)
expect(created == .success(newText: "hello\n", replacementCount: 1, createsFile: true), "empty old_string creates a missing file")
expect(editFailure(CodingEditApplication.apply(originalText: nil, oldString: "x", newString: "y", replaceAll: false))?.contains("does not exist") == true, "editing a missing file explains how to create it")
expect(editFailure(CodingEditApplication.apply(originalText: "content", oldString: "", newString: "y", replaceAll: false)) != nil, "empty old_string on a non-empty file fails")
expect(editText(CodingEditApplication.apply(originalText: "", oldString: "", newString: "fresh", replaceAll: false)) == "fresh", "empty old_string fills an empty file")
let windowsText = "one\r\ntwo\r\nthree\r\n"
expect(editText(CodingEditApplication.apply(originalText: windowsText, oldString: "one\ntwo", newString: "one\n2", replaceAll: false)) == "one\r\n2\r\nthree\r\n", "\\n edits match a CRLF file and keep its line ends")
expect(CodingEditApplication.occurrenceCount(of: "aa", in: "aaaa") == 2, "occurrences do not overlap")
expect(editText(CodingEditApplication.apply(originalText: "café", oldString: "cafe\u{301}", newString: "x", replaceAll: false)) == nil, "literal match: a differently composed é is not the same text")

// MARK: Diff

section("diff snippet")
let diff = CodingDiffSnippet.make(originalText: source, updatedText: editText(uniqueEdit)!, path: "/p/a.swift")
expect(diff.hasPrefix("--- a//p/a.swift\n+++ b//p/a.swift\n@@ -1,5 +1,5 @@"), "header and hunk range: \(diff)")
expect(diff.contains("\n-    return 1\n+    return 2\n"), "removed then added line")
expect(diff.components(separatedBy: "\n").count == 9 && !diff.contains("    return 1\n }\n"), "three context lines, not the whole file: \(diff)")
expect(CodingDiffSnippet.make(originalText: "same\n", updatedText: "same\n", path: "x") == "", "no change, no diff")
let createdDiff = CodingDiffSnippet.make(originalText: "", updatedText: "a\nb\n", path: "new.txt")
expect(createdDiff.contains("@@ -0,0 +1,2 @@") && createdDiff.contains("+a\n+b"), "new file diff: \(createdDiff)")
let longFile = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
let twoChanges = longFile.replacingOccurrences(of: "line 10\n", with: "line ten\n").replacingOccurrences(of: "line 90\n", with: "line ninety\n")
let twoHunks = CodingDiffSnippet.make(originalText: longFile, updatedText: twoChanges, path: "f")
expect(twoHunks.components(separatedBy: "\n@@ ").count == 3, "far-apart changes make two hunks: \(twoHunks)")
expect(twoHunks.contains("@@ -87,7 +87,7 @@"), "second hunk numbered from line 87")
let insertion = CodingDiffSnippet.make(originalText: "a\nb\nc\n", updatedText: "a\nb\nnew\nc\n", path: "f")
expect(insertion.contains("@@ -1,3 +1,4 @@") && insertion.contains("+new") && !insertion.components(separatedBy: "\n").dropFirst(2).contains(where: { $0.hasPrefix("-") }), "pure insertion: \(insertion)")
let huge = CodingDiffSnippet.make(originalText: "", updatedText: (1...500).map(String.init).joined(separator: "\n"), path: "f", maximumLines: 20)
expect(huge.contains("more diff lines") && huge.components(separatedBy: "\n").count == 21, "diff is capped")

// MARK: Glob

section("glob matching")
expect(CodingGlobMatcher.matches(pattern: "**/*.swift", relativePath: "Sources/App/main.swift"), "**/*.swift deep")
expect(CodingGlobMatcher.matches(pattern: "**/*.swift", relativePath: "main.swift"), "** matches zero folders")
expect(!CodingGlobMatcher.matches(pattern: "**/*.swift", relativePath: "main.swiftx"), "suffix must match")
expect(CodingGlobMatcher.matches(pattern: "*.swift", relativePath: "a/b/c.swift"), "no slash: file name at any depth")
expect(CodingGlobMatcher.matches(pattern: "src/*.ts", relativePath: "src/a.ts"), "single star one level")
expect(!CodingGlobMatcher.matches(pattern: "src/*.ts", relativePath: "src/x/a.ts"), "single star does not cross folders")
expect(CodingGlobMatcher.matches(pattern: "src/**/test_*.py", relativePath: "src/a/b/test_one.py"), "** in the middle")
expect(CodingGlobMatcher.matches(pattern: "src/**", relativePath: "src/a/b.txt"), "trailing **")
expect(CodingGlobMatcher.matches(pattern: "*.{ts,tsx}", relativePath: "ui/Button.tsx"), "braces")
expect(CodingGlobMatcher.matches(pattern: "{src,lib}/**/*.js", relativePath: "lib/x/y.js"), "braces on folders")
expect(CodingGlobMatcher.matches(pattern: "file?.txt", relativePath: "file1.txt") && !CodingGlobMatcher.matches(pattern: "file?.txt", relativePath: "file10.txt"), "question mark is one character")
expect(CodingGlobMatcher.matches(pattern: "[A-C]*.md", relativePath: "Brief.md") && !CodingGlobMatcher.matches(pattern: "[A-C]*.md", relativePath: "Zed.md"), "character ranges")
expect(CodingGlobMatcher.matches(pattern: "[!a]*", relativePath: "b") && !CodingGlobMatcher.matches(pattern: "[!a]*", relativePath: "a"), "negated class")
expect(CodingGlobMatcher.matches(pattern: "./docs/*.md", relativePath: "docs/x.md"), "leading ./ is ignored")
expect(CodingGlobMatcher.expandBraces("a{b,c{d,e}}f") == ["abf", "acdf", "acef"], "nested braces: \(CodingGlobMatcher.expandBraces("a{b,c{d,e}}f"))")
expect(CodingGlobMatcher.wildcardMatches(pattern: "*a*b*", text: "xxaxxbxx"), "multiple stars backtrack")
expect(!CodingGlobMatcher.wildcardMatches(pattern: "*a*b", text: "xxaxxbxxc"), "stars still anchor the end")
expect(CodingGlobMatcher.skippedDirectoryNames.isSuperset(of: [".git", "node_modules", "build", "DerivedData", ".build", "Pods"]), "heavy folders are skipped")

// MARK: Search

section("grep: commands and output")
expect(CodingSearchCommand.shellQuoted("it's") == "'it'\\''s'", "single quotes are escaped")
let ripgrepArguments = CodingSearchCommand.ripgrepArguments(pattern: "foo(bar", searchPath: "/p", fileGlob: "*.swift", caseInsensitive: true, outputMode: .content)
expect(ripgrepArguments.suffix(4) == ["--regexp", "foo(bar", "--", "/p"], "pattern and path go last, after --")
expect(ripgrepArguments.contains("--ignore-case") && ripgrepArguments.contains("--line-number") && ripgrepArguments.contains("!node_modules"), "rg flags")
let grepFilesArguments = CodingSearchCommand.grepArguments(pattern: "-x", searchPath: "/p", fileGlob: "src/**/*.{ts,tsx}", caseInsensitive: false, outputMode: .files)
expect(grepFilesArguments.contains("-l") && !grepFilesArguments.contains("-n"), "files mode lists names")
expect(grepFilesArguments.contains("--include=*.ts") && grepFilesArguments.contains("--include=*.tsx"), "glob reduced to file-name patterns: \(grepFilesArguments)")
expect(grepFilesArguments.contains("--exclude-dir=.git") && grepFilesArguments.contains("-I"), "skips .git and binaries")
expect(grepFilesArguments.suffix(4) == ["-e", "-x", "--", "/p"], "a pattern starting with - is passed safely")
let commandLine = CodingSearchCommand.commandLine(executable: "/usr/bin/grep", arguments: ["-e", "a b", "--", "/p q"])
expect(commandLine == "'/usr/bin/grep' '-e' 'a b' '--' '/p q'", "command line is quoted: \(commandLine)")
let rawContent = "/p/a.swift:3:let x = 1\n/p/.env:1:API_KEY=abc\n/p/b.swift:10:let y = 2\n"
let shaped = CodingSearchCommand.formatResults(rawOutput: rawContent, outputMode: .content, maximumResults: 200, isHiddenPath: { $0.hasSuffix(".env") })
expect(shaped.contains("/p/a.swift:3:let x = 1") && shaped.contains("/p/b.swift:10") && !shaped.contains("API_KEY"), "secret files are dropped from results: \(shaped)")
expect(shaped.contains("1 result in files that may hold secrets"), "and the drop is mentioned")
let limited = CodingSearchCommand.formatResults(rawOutput: (1...50).map { "/p/f\($0).swift" }.joined(separator: "\n"), outputMode: .files, maximumResults: 10, isHiddenPath: { _ in false })
expect(limited.components(separatedBy: "\n").count == 11 && limited.contains("40 more results"), "max_results caps lines: \(limited)")
let crlfShaped = CodingSearchCommand.formatResults(rawOutput: "/p/a.txt:1:one\r\n/p/b.txt:2:two\r\n", outputMode: .content, maximumResults: 1, isHiddenPath: { _ in false })
expect(crlfShaped.hasPrefix("/p/a.txt:1:one\n[1 more result"), "CRLF output lines are split: \(crlfShaped.debugDescription)")
expect(CodingSearchCommand.formatResults(rawOutput: "", outputMode: .files, maximumResults: 5, isHiddenPath: { _ in false }) == "No matches.", "no matches")
expect(CodingSearchCommand.filePathOfContentLine("/a/b:c.txt:12:x:y") == "/a/b:c.txt", "path with a colon")

section("list_directory formatting")
let listing = CodingDirectoryListing.format(entries: [
    .init(name: "b.swift", isDirectory: false, byteCount: 2048),
    .init(name: "Sources", isDirectory: true, byteCount: nil),
    .init(name: "a.txt", isDirectory: false, byteCount: 12)
], directoryPath: "/p")
expect(listing == "/p/\n  Sources/\n  a.txt  (12 B)\n  b.swift  (2.0 KB)", "folders first, sizes shown: \(listing.debugDescription)")
expect(CodingDirectoryListing.format(entries: [], directoryPath: "/p") == "/p is empty.", "empty folder")

// MARK: Project detection

section("project detection from the request")
let testHome = "/Users/tester"
let gitFolders: Set<String> = ["/Users/tester/code/app", "/Users/tester/My Projects/site"]
let folders: Set<String> = gitFolders.union(["/Users/tester/code", "/Users/tester/code/app/Sources", "/Users/tester/Documents", "/Users/tester", "/Users/tester/My Projects"])
func detect(_ text: String) -> String? {
    CodingProjectDetection.projectDirectory(
        inRequestText: text,
        home: testHome,
        isDirectory: { folders.contains($0) },
        hasGitEntry: { gitFolders.contains($0) }
    )
}
expect(detect("fix the failing test in ~/code/app please") == "/Users/tester/code/app", "~/ path to a git folder")
expect(detect("look at /Users/tester/code/app/Sources.") == "/Users/tester/code/app", "a subfolder finds the repo root, trailing dot ignored")
expect(detect("bug in ~/code/app/Sources/main.swift line 4") == "/Users/tester/code/app", "a file path inside the repo")
expect(detect("open \"~/My Projects/site\" and fix the header") == "/Users/tester/My Projects/site", "quoted path with a space")
expect(detect("clean up ~/Documents") == nil, "a folder that is not in git")
expect(detect("in ~ do something") == nil, "home is never a project")
expect(detect("fix the bug in my app") == nil, "no path, no project")
expect(detect("compare ~/nowhere and ~/code/app") == "/Users/tester/code/app", "first path that is a project wins")
expect(CodingProjectDetection.candidatePaths(in: "see (~/code/app), then /tmp/x;") == ["~/code/app", "/tmp/x"], "candidate paths: \(CodingProjectDetection.candidatePaths(in: "see (~/code/app), then /tmp/x;"))")
expect(CodingProjectDetection.candidatePaths(in: "http://example.com/a/b").isEmpty, "URLs are not paths")

section("project prompt section")
let promptSection = CodingProjectDetection.promptSection(projectDirectory: "/p", instructionFiles: [("AGENTS.md", "Use tabs.\n"), ("CLAUDE.md", String(repeating: "y", count: 9000))])
expect(promptSection.contains("PROJECT: you are working in the code project at /p"), "names the project")
expect(promptSection.contains("edit_file") && promptSection.contains("git push") && promptSection.contains("summary of the files you changed"), "coding guide is there")
expect(promptSection.contains("AGENTS.md (instructions") && promptSection.contains("Use tabs."), "AGENTS.md included")
expect(promptSection.contains("[… cut here; read_file CLAUDE.md for the rest]"), "instructions are capped")
expect(promptSection.count < 6_000 + 2_000, "prompt section stays small (\(promptSection.count))")
expect(!CodingProjectDetection.promptSection(projectDirectory: "/p", instructionFiles: []).contains("instructions from the project owner"), "no files, no instructions block")

// MARK: Policy

section("policy: coding tools")
let home = testHome
let plainSettings = ToolPolicySettings(allowBrowserCookies: false, homeDirectory: home, ownBundleIdentifier: "so.teachy.app")
var projectSettings = plainSettings
projectSettings.projectDirectory = "/Users/tester/code/app"
var outsideHomeProjectSettings = plainSettings
outsideHomeProjectSettings.projectDirectory = "/Volumes/Work/site"
var agentSettings = plainSettings
agentSettings.agentFilesDirectory = "/Users/tester/.teachy/agents/helper/files"

func risk(_ name: String, _ arguments: [String: Any], _ settings: ToolPolicySettings = plainSettings) -> ToolRisk {
    ToolPolicy.classify(toolName: name, arguments: arguments, settings: settings).risk
}

for readTool in ["read_file", "grep", "glob", "list_directory"] {
    expect(risk(readTool, ["path": "~/code/other/src", "pattern": "x"]) == .safe, "\(readTool): plain home path is safe")
    expect(risk(readTool, ["path": "~/.ssh", "pattern": "x"]) == .alwaysAsk, "\(readTool): ~/.ssh always asks")
    expect(risk(readTool, ["path": "~/Library/Mail", "pattern": "x"]) == .needsConsent, "\(readTool): Library needs consent")
    expect(risk(readTool, ["path": "/etc", "pattern": "x"]) == .needsConsent, "\(readTool): outside home needs consent")
    expect(risk(readTool, ["path": "/Users/tester/code/app/.github/workflows", "pattern": "x"], projectSettings) == .safe, "\(readTool): hidden folder inside the project is safe")
    expect(risk(readTool, ["path": "/Users/tester/code/app", "pattern": "x"], projectSettings) == .safe, "\(readTool): the project folder itself is safe")
    expect(risk(readTool, ["path": "/Users/tester/code/app/.env", "pattern": "x"], projectSettings) == .alwaysAsk, "\(readTool): the project's .env always asks")
    expect(risk(readTool, ["path": "/Volumes/Work/site/src", "pattern": "x"], outsideHomeProjectSettings) == .safe, "\(readTool): a project outside home is still readable")
    expect(risk(readTool, ["path": "/Users/tester/.teachy/agents/helper/files", "pattern": "x"], agentSettings) == .safe, "\(readTool): the agent's own folder is safe")
}
expect(risk("grep", ["path": home, "pattern": "password"]) == .needsConsent, "searching all of home needs a yes")
let grepDecision = ToolPolicy.classify(toolName: "grep", arguments: ["path": "/Users/tester/code/app", "pattern": "TODO"], settings: projectSettings)
expect(grepDecision.detail == "TODO in /Users/tester/code/app" && grepDecision.summary == "search files", "grep shows pattern and folder: \(grepDecision.detail)")
expect(risk("read_file", ["path": "~/Documents/notes.txt"]) == .safe, "read_file unchanged for a plain file")
expect(risk("read_file", ["path": "~/.zshrc"]) == .needsConsent, "read_file unchanged for a hidden file")

expect(risk("edit_file", ["path": "/Users/tester/code/app/Sources/main.swift"], projectSettings) == .needsConsent, "edit in project needs a yes (auto mode)")
expect(risk("edit_file", ["path": "/Users/tester/code/app/.env"], projectSettings) == .alwaysAsk, "edit of project .env always asks")
expect(risk("edit_file", ["path": "/Users/tester/code/app/.zshrc"], projectSettings) == .alwaysAsk, "persistence file in project always asks")
expect(risk("edit_file", ["path": "/Volumes/Work/site/index.html"], outsideHomeProjectSettings) == .needsConsent, "edit in a project outside home needs a yes, not always-ask")
expect(risk("edit_file", ["path": "/Volumes/Other/x.txt"], outsideHomeProjectSettings) == .alwaysAsk, "outside the project and home still always asks")
expect(risk("edit_file", ["path": "~/Documents/a.txt"]) == .needsConsent, "plain edit needs a yes")
expect(risk("edit_file", ["path": "~/.ssh/config"]) == .alwaysAsk, "edit of ssh config always asks")
expect(risk("edit_file", ["path": "~/Library/LaunchAgents/x.plist"]) == .alwaysAsk, "edit of a launch agent always asks")
expect(risk("edit_file", ["path": "/Users/tester/.teachy/agents/helper/files/notes.md"], agentSettings) == .safe, "edit in the agent's own folder is safe")
expect(risk("write_file", ["path": "/Users/tester/code/app/new.swift"], projectSettings) == .needsConsent, "write in project needs a yes")
expect(risk("write_file", ["path": "~/Documents/a.txt"]) == .needsConsent, "write_file unchanged")
expect(risk("edit_file", ["path": "/Users/tester/code/app/x"], projectSettings) != .safe, "edits are never safe in a project")

section("policy: bash working folder")
expect(risk("bash", ["command": "ls"]) == .safe, "bash without a folder unchanged")
expect(risk("bash", ["command": "cat config", "working_directory": "/Users/tester/.ssh"]) == .alwaysAsk, "reading in ~/.ssh always asks")
expect(risk("bash", ["command": "ls", "working_directory": "/Users/tester/Library/Cookies"]) == .alwaysAsk, "cookie folder always asks")
expect(risk("bash", ["command": "ls", "working_directory": "/Users/tester/Library/Mail"]) == .needsConsent, "Library folder needs a yes")
expect(risk("bash", ["command": "git status", "working_directory": "/Users/tester/code/app"], projectSettings) == .safe, "git status in the project is safe")
expect(risk("bash", ["command": "ls", "working_directory": "/Users/tester/code/app/.build"], projectSettings) == .safe, "hidden folder inside the project is fine")
expect(risk("bash", ["command": "rm -rf build", "working_directory": "/Users/tester/code/app"], projectSettings) == .alwaysAsk, "deleting still always asks")
expect(risk("bash", ["command": "git push --force", "working_directory": "/Users/tester/code/app"], projectSettings) >= .alwaysAsk, "force push still asks every time")
let bashDecision = ToolPolicy.classify(toolName: "bash", arguments: ["command": "make", "working_directory": "/Users/tester/code/app"], settings: projectSettings)
expect(bashDecision.detail == "(in /Users/tester/code/app) make", "the folder is shown with the command: \(bashDecision.detail)")

section("policy: sets")
expect(PathPolicy.isSameOrInside(path: "/a/b", directory: "/a/b", home: home) && PathPolicy.isSameOrInside(path: "/a/b/c", directory: "/a/b", home: home), "same or inside")
expect(!PathPolicy.isSameOrInside(path: "/a/bc", directory: "/a/b", home: home) && !PathPolicy.isSameOrInside(path: "/a", directory: "", home: home), "not a prefix trick, empty never contains")
expect(ToolPolicy.guidedStepToolNames.isDisjoint(with: ["edit_file", "write_file", "bash"]), "guided steps cannot edit")

// MARK: Contract checks (added on main alongside the CRLF fix)

section("contracts: edits, reading, globs, search, projects, policy")
func failedEdit(_ result: CodingEditApplication.Outcome) -> Bool {
    if case .failure = result { return true }
    return false
}

do {
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

}

print("")
print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILURES: \(failures)")
    exit(1)
}
print("ALL PASSED")
