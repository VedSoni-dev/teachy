//
//  CodingToolSupport.swift
//  leanring-buddy
//
//  The pure logic behind the agent's coding tools (read_file with line numbers,
//  edit_file, grep, glob, list_directory) and the project context a coding job
//  gets in its system prompt. Foundation only: no AppKit, no live disk access
//  except where a caller passes a closure in, so all of it is testable
//  standalone by scripts/tests/run_coding_tools_tests.sh.
//
//  The tools themselves (I/O, the shell, the job context) live in CodingTools.swift.
//

import Foundation

// MARK: - Reading files with line numbers

nonisolated enum CodingFileReading {
    /// How many lines read_file shows when the model gives no limit.
    static let defaultLineLimit = 2000
    /// A single line longer than this is cut (minified files would otherwise flood the context).
    static let maximumLineLength = 2000
    /// The agent loop cuts every tool result at 12,000 characters. Stopping a little earlier
    /// keeps the "more lines remain" footer visible, so the model knows to page.
    static let outputCharacterBudget = 11_000
    /// Larger files are refused: they are logs or data, not source to read whole.
    static let maximumFileBytes = 20 * 1024 * 1024

    /// A NUL byte in the first 8 KB is the same test git and grep use for "binary".
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// The file's lines: "\r\n" and "\n" both end a line, and a final newline does not add an empty line.
    static func splitIntoLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// `   12\tcontent`: the number right-aligned in six columns, like `cat -n`.
    static func numberedLine(number: Int, content: String) -> String {
        let numberText = String(number)
        let padding = String(repeating: " ", count: max(0, 6 - numberText.count))
        return padding + numberText + "\t" + content
    }

    /// The lines from `offset` (1-based) on, at most `limit` of them, each with its line number.
    /// Ends with a note when lines were left out, so the model knows how to read on.
    static func numberedExcerpt(text: String, offset requestedOffset: Int?, limit requestedLimit: Int?) -> String {
        let lines = splitIntoLines(text)
        if lines.isEmpty { return "(the file is empty)" }

        let firstLineNumber = max(1, requestedOffset ?? 1)
        let lineLimit = max(1, requestedLimit ?? defaultLineLimit)
        guard firstLineNumber <= lines.count else {
            return "The file has \(lines.count) lines; offset \(firstLineNumber) is past the end."
        }

        var output: [String] = []
        var usedCharacters = 0
        var lastLineNumberShown = firstLineNumber - 1
        var anyLineWasCut = false
        let lastLineNumberAllowed = min(lines.count, firstLineNumber + lineLimit - 1)

        for lineNumber in firstLineNumber...lastLineNumberAllowed {
            var content = lines[lineNumber - 1]
            if content.count > maximumLineLength {
                content = String(content.prefix(maximumLineLength)) + " [line cut at \(maximumLineLength) characters]"
                anyLineWasCut = true
            }
            let numbered = numberedLine(number: lineNumber, content: content)
            // Always show at least one line, even a long one.
            if !output.isEmpty && usedCharacters + numbered.count + 1 > outputCharacterBudget { break }
            output.append(numbered)
            usedCharacters += numbered.count + 1
            lastLineNumberShown = lineNumber
        }

        var text = output.joined(separator: "\n")
        if lastLineNumberShown < lines.count {
            let remaining = lines.count - lastLineNumberShown
            text += "\n[Showing lines \(firstLineNumber)–\(lastLineNumberShown) of \(lines.count). \(remaining) more line\(remaining == 1 ? "" : "s"): call read_file again with offset=\(lastLineNumberShown + 1).]"
        } else if firstLineNumber > 1 {
            text += "\n[End of file: \(lines.count) lines.]"
        }
        if anyLineWasCut {
            text += "\n[Some very long lines were cut.]"
        }
        return text
    }
}

// MARK: - Exact string replacement (edit_file)

nonisolated enum CodingEditApplication {
    enum Outcome: Equatable {
        case success(newText: String, replacementCount: Int, createsFile: Bool)
        case failure(String)
    }

    /// Counts non-overlapping, character-exact occurrences.
    static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: .literal, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Replaces the first (or every) exact occurrence. Uses `.literal` so "é" written two ways
    /// is not treated as the same text: the edit touches exactly what was asked for.
    static func replacing(_ needle: String, with replacement: String, in haystack: String, replaceAll: Bool) -> String {
        if replaceAll {
            return haystack.replacingOccurrences(of: needle, with: replacement, options: .literal)
        }
        guard let found = haystack.range(of: needle, options: .literal) else { return haystack }
        return haystack.replacingCharacters(in: found, with: replacement)
    }

    /// Works out the file's new text. `originalText` is nil when the file does not exist.
    static func apply(originalText: String?, oldString: String, newString: String, replaceAll: Bool) -> Outcome {
        if oldString == newString {
            return .failure("old_string and new_string are the same, so there is nothing to change.")
        }

        guard let originalText else {
            if oldString.isEmpty {
                return .success(newText: newString, replacementCount: 1, createsFile: true)
            }
            return .failure("The file does not exist. To create it, call edit_file with an empty old_string (or use write_file).")
        }

        if oldString.isEmpty {
            if originalText.isEmpty {
                return .success(newText: newString, replacementCount: 1, createsFile: false)
            }
            return .failure("old_string is empty but the file already has content. Give the exact text to replace, or use write_file to replace the whole file.")
        }

        var effectiveOldString = oldString
        var effectiveNewString = newString
        var count = occurrenceCount(of: effectiveOldString, in: originalText)

        // A Windows-style file read back with "\n" line ends: match it with "\r\n" instead.
        if count == 0, originalText.contains("\r\n"), oldString.contains("\n"), !oldString.contains("\r\n") {
            let crlfOldString = oldString.replacingOccurrences(of: "\n", with: "\r\n")
            let crlfCount = occurrenceCount(of: crlfOldString, in: originalText)
            if crlfCount > 0 {
                effectiveOldString = crlfOldString
                effectiveNewString = newString.replacingOccurrences(of: "\n", with: "\r\n")
                count = crlfCount
            }
        }

        if count == 0 {
            return .failure("old_string was not found in the file. Read the file again (read_file) and copy the text exactly, including indentation and line breaks; do not include the line-number prefixes.")
        }
        if count > 1 && !replaceAll {
            return .failure("old_string was found \(count) times. Include more surrounding lines so it matches exactly one place, or set replace_all to true to change every one.")
        }
        let newText = replacing(effectiveOldString, with: effectiveNewString, in: originalText, replaceAll: replaceAll)
        return .success(newText: newText, replacementCount: replaceAll ? count : 1, createsFile: false)
    }
}

// MARK: - Unified diff snippet

nonisolated enum CodingDiffSnippet {
    private enum Operation: Equatable {
        case same(String)
        case removed(String)
        case added(String)

        var isChange: Bool {
            if case .same = self { return false }
            return true
        }
    }

    /// Middles bigger than this (old lines × new lines) are shown as all-removed then all-added,
    /// instead of running the quadratic line matcher.
    static let largestMatchedRegion = 4_000_000

    /// A short unified diff of the change: `@@` hunks with a few context lines, cut at `maximumLines`.
    /// Empty when the texts are the same.
    static func make(originalText: String, updatedText: String, path: String, contextLines: Int = 3, maximumLines: Int = 80) -> String {
        let originalLines = CodingFileReading.splitIntoLines(originalText)
        let updatedLines = CodingFileReading.splitIntoLines(updatedText)
        let operations = lineOperations(originalLines: originalLines, updatedLines: updatedLines)
        guard operations.contains(where: { $0.isChange }) else { return "" }

        // Old and new line numbers (1-based) at the start of each operation.
        var originalLineNumbers: [Int] = []
        var updatedLineNumbers: [Int] = []
        var originalCursor = 1
        var updatedCursor = 1
        for operation in operations {
            originalLineNumbers.append(originalCursor)
            updatedLineNumbers.append(updatedCursor)
            switch operation {
            case .same: originalCursor += 1; updatedCursor += 1
            case .removed: originalCursor += 1
            case .added: updatedCursor += 1
            }
        }

        // Group changes whose gap of unchanged lines is small enough to share context.
        let changeIndices = operations.indices.filter { operations[$0].isChange }
        var hunkRanges: [ClosedRange<Int>] = []
        var hunkStart = max(0, changeIndices[0] - contextLines)
        var hunkEnd = min(operations.count - 1, changeIndices[0] + contextLines)
        for changeIndex in changeIndices.dropFirst() {
            if changeIndex - contextLines <= hunkEnd + 1 {
                hunkEnd = min(operations.count - 1, changeIndex + contextLines)
            } else {
                hunkRanges.append(hunkStart...hunkEnd)
                hunkStart = max(0, changeIndex - contextLines)
                hunkEnd = min(operations.count - 1, changeIndex + contextLines)
            }
        }
        hunkRanges.append(hunkStart...hunkEnd)

        var output = ["--- a/\(path)", "+++ b/\(path)"]
        for hunkRange in hunkRanges {
            let hunkOperations = operations[hunkRange]
            let originalCount = hunkOperations.filter { if case .added = $0 { return false }; return true }.count
            let updatedCount = hunkOperations.filter { if case .removed = $0 { return false }; return true }.count
            // Unified diff convention: a side with no lines names the line before the hunk.
            let originalStart = originalCount == 0 ? originalLineNumbers[hunkRange.lowerBound] - 1 : originalLineNumbers[hunkRange.lowerBound]
            let updatedStart = updatedCount == 0 ? updatedLineNumbers[hunkRange.lowerBound] - 1 : updatedLineNumbers[hunkRange.lowerBound]
            output.append("@@ -\(originalStart),\(originalCount) +\(updatedStart),\(updatedCount) @@")
            for operation in hunkOperations {
                switch operation {
                case .same(let line): output.append(" " + clipped(line))
                case .removed(let line): output.append("-" + clipped(line))
                case .added(let line): output.append("+" + clipped(line))
                }
            }
        }

        if output.count > maximumLines {
            let hiddenCount = output.count - maximumLines
            output = Array(output.prefix(maximumLines))
            output.append("… (\(hiddenCount) more diff line\(hiddenCount == 1 ? "" : "s"))")
        }
        return output.joined(separator: "\n")
    }

    private static func clipped(_ line: String) -> String {
        line.count > 300 ? String(line.prefix(300)) + "…" : line
    }

    /// Same / removed / added per line: common head and tail are trimmed, the middle is
    /// matched by longest common subsequence when it is small enough.
    private static func lineOperations(originalLines: [String], updatedLines: [String]) -> [Operation] {
        var commonPrefixCount = 0
        while commonPrefixCount < originalLines.count, commonPrefixCount < updatedLines.count,
              originalLines[commonPrefixCount] == updatedLines[commonPrefixCount] {
            commonPrefixCount += 1
        }
        var commonSuffixCount = 0
        while commonSuffixCount < originalLines.count - commonPrefixCount,
              commonSuffixCount < updatedLines.count - commonPrefixCount,
              originalLines[originalLines.count - 1 - commonSuffixCount] == updatedLines[updatedLines.count - 1 - commonSuffixCount] {
            commonSuffixCount += 1
        }

        let originalMiddle = Array(originalLines[commonPrefixCount..<(originalLines.count - commonSuffixCount)])
        let updatedMiddle = Array(updatedLines[commonPrefixCount..<(updatedLines.count - commonSuffixCount)])

        var operations = originalLines.prefix(commonPrefixCount).map { Operation.same($0) }
        if originalMiddle.count * updatedMiddle.count <= largestMatchedRegion {
            operations += matchedMiddle(originalMiddle: originalMiddle, updatedMiddle: updatedMiddle)
        } else {
            operations += originalMiddle.map { Operation.removed($0) }
            operations += updatedMiddle.map { Operation.added($0) }
        }
        operations += originalLines.suffix(commonSuffixCount).map { Operation.same($0) }
        return operations
    }

    private static func matchedMiddle(originalMiddle: [String], updatedMiddle: [String]) -> [Operation] {
        let originalCount = originalMiddle.count
        let updatedCount = updatedMiddle.count
        if originalCount == 0 { return updatedMiddle.map { .added($0) } }
        if updatedCount == 0 { return originalMiddle.map { .removed($0) } }

        // commonLengthTable[i][j] = LCS length of originalMiddle[i...] and updatedMiddle[j...].
        let rowWidth = updatedCount + 1
        var commonLengthTable = [Int32](repeating: 0, count: (originalCount + 1) * rowWidth)
        for originalIndex in stride(from: originalCount - 1, through: 0, by: -1) {
            for updatedIndex in stride(from: updatedCount - 1, through: 0, by: -1) {
                if originalMiddle[originalIndex] == updatedMiddle[updatedIndex] {
                    commonLengthTable[originalIndex * rowWidth + updatedIndex] = commonLengthTable[(originalIndex + 1) * rowWidth + updatedIndex + 1] + 1
                } else {
                    commonLengthTable[originalIndex * rowWidth + updatedIndex] = max(
                        commonLengthTable[(originalIndex + 1) * rowWidth + updatedIndex],
                        commonLengthTable[originalIndex * rowWidth + updatedIndex + 1]
                    )
                }
            }
        }

        var operations: [Operation] = []
        var originalIndex = 0
        var updatedIndex = 0
        while originalIndex < originalCount && updatedIndex < updatedCount {
            if originalMiddle[originalIndex] == updatedMiddle[updatedIndex] {
                operations.append(.same(originalMiddle[originalIndex]))
                originalIndex += 1
                updatedIndex += 1
            } else if commonLengthTable[(originalIndex + 1) * rowWidth + updatedIndex] >= commonLengthTable[originalIndex * rowWidth + updatedIndex + 1] {
                operations.append(.removed(originalMiddle[originalIndex]))
                originalIndex += 1
            } else {
                operations.append(.added(updatedMiddle[updatedIndex]))
                updatedIndex += 1
            }
        }
        while originalIndex < originalCount { operations.append(.removed(originalMiddle[originalIndex])); originalIndex += 1 }
        while updatedIndex < updatedCount { operations.append(.added(updatedMiddle[updatedIndex])); updatedIndex += 1 }
        return operations
    }
}

// MARK: - Glob matching

nonisolated enum CodingGlobMatcher {
    /// Folders the file tools never walk into: version control, dependencies and build output.
    static let skippedDirectoryNames: Set<String> = [
        ".git", "node_modules", "build", "DerivedData", ".build", "Pods", ".venv", "__pycache__", ".next"
    ]

    /// `{a,b}` alternatives expanded into separate patterns (nested braces work).
    static func expandBraces(_ pattern: String) -> [String] {
        let characters = Array(pattern)
        guard let openIndex = characters.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var closeIndex: Int?
        var splitPoints: [Int] = []
        for index in openIndex..<characters.count {
            switch characters[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { closeIndex = index }
            case "," where depth == 1: splitPoints.append(index)
            default: break
            }
            if closeIndex != nil { break }
        }
        guard let closeIndex else { return [pattern] }

        let head = String(characters[..<openIndex])
        let tail = String(characters[(closeIndex + 1)...])
        var alternatives: [String] = []
        var alternativeStart = openIndex + 1
        for splitPoint in splitPoints + [closeIndex] {
            alternatives.append(String(characters[alternativeStart..<splitPoint]))
            alternativeStart = splitPoint + 1
        }
        return alternatives.flatMap { expandBraces(head + $0 + tail) }
    }

    /// True when `relativePath` (slash-separated, no leading slash) matches the glob.
    /// `**` matches any number of folders (also none). A pattern with no `/` matches the
    /// file name at any depth, so `*.swift` finds Swift files everywhere.
    static func matches(pattern: String, relativePath: String) -> Bool {
        let trimmedPattern = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        let pathSegments = relativePath.split(separator: "/").map(String.init)
        for expandedPattern in expandBraces(trimmedPattern) {
            if !expandedPattern.contains("/") {
                if let fileName = pathSegments.last, wildcardMatches(pattern: expandedPattern, text: fileName) { return true }
                continue
            }
            let patternSegments = expandedPattern.split(separator: "/").map(String.init)
            if segmentsMatch(patternSegments: patternSegments[...], pathSegments: pathSegments[...]) { return true }
        }
        return false
    }

    private static func segmentsMatch(patternSegments: ArraySlice<String>, pathSegments: ArraySlice<String>) -> Bool {
        guard let firstPattern = patternSegments.first else { return pathSegments.isEmpty }
        if firstPattern == "**" {
            let remainingPattern = patternSegments.dropFirst()
            // Let ** swallow zero, one, two … folders.
            var remainingPath = pathSegments
            while true {
                if segmentsMatch(patternSegments: remainingPattern, pathSegments: remainingPath) { return true }
                if remainingPath.isEmpty { return false }
                remainingPath = remainingPath.dropFirst()
            }
        }
        guard let firstPath = pathSegments.first, wildcardMatches(pattern: firstPattern, text: firstPath) else { return false }
        return segmentsMatch(patternSegments: patternSegments.dropFirst(), pathSegments: pathSegments.dropFirst())
    }

    /// One path segment against `*`, `?`, `[abc]`, `[a-z]`, `[!abc]` and `\` escapes.
    static func wildcardMatches(pattern: String, text: String) -> Bool {
        wildcardMatches(patternCharacters: Array(pattern)[...], textCharacters: Array(text)[...])
    }

    private static func wildcardMatches(patternCharacters: ArraySlice<Character>, textCharacters: ArraySlice<Character>) -> Bool {
        var patternIndex = patternCharacters.startIndex
        var textIndex = textCharacters.startIndex
        // Where to resume after the most recent `*` if a later part fails (classic backtracking).
        var starPatternIndex: Int?
        var starTextIndex = textCharacters.startIndex

        while textIndex < textCharacters.endIndex {
            if patternIndex < patternCharacters.endIndex {
                let patternCharacter = patternCharacters[patternIndex]
                if patternCharacter == "*" {
                    starPatternIndex = patternIndex
                    starTextIndex = textIndex
                    patternIndex += 1
                    continue
                }
                if patternCharacter == "?" {
                    patternIndex += 1
                    textIndex += 1
                    continue
                }
                if patternCharacter == "[", let (matched, nextPatternIndex) = bracketMatch(patternCharacters: patternCharacters, openIndex: patternIndex, character: textCharacters[textIndex]) {
                    if matched {
                        patternIndex = nextPatternIndex
                        textIndex += 1
                        continue
                    }
                } else {
                    var literal = patternCharacter
                    var literalLength = 1
                    if patternCharacter == "\\", patternIndex + 1 < patternCharacters.endIndex {
                        literal = patternCharacters[patternIndex + 1]
                        literalLength = 2
                    }
                    if literal == textCharacters[textIndex] {
                        patternIndex += literalLength
                        textIndex += 1
                        continue
                    }
                }
            }
            guard let starIndex = starPatternIndex else { return false }
            patternIndex = starIndex + 1
            starTextIndex += 1
            textIndex = starTextIndex
        }
        while patternIndex < patternCharacters.endIndex && patternCharacters[patternIndex] == "*" { patternIndex += 1 }
        return patternIndex == patternCharacters.endIndex
    }

    /// Matches `character` against the `[...]` class starting at `openIndex`.
    /// Returns nil when the bracket never closes (then `[` is an ordinary character).
    private static func bracketMatch(patternCharacters: ArraySlice<Character>, openIndex: Int, character: Character) -> (Bool, Int)? {
        var index = openIndex + 1
        var negated = false
        if index < patternCharacters.endIndex, patternCharacters[index] == "!" || patternCharacters[index] == "^" {
            negated = true
            index += 1
        }
        var matched = false
        var isFirstMember = true
        while index < patternCharacters.endIndex {
            let member = patternCharacters[index]
            if member == "]" && !isFirstMember {
                return (matched != negated, index + 1)
            }
            isFirstMember = false
            if index + 2 < patternCharacters.endIndex, patternCharacters[index + 1] == "-", patternCharacters[index + 2] != "]" {
                let rangeEnd = patternCharacters[index + 2]
                if member <= character && character <= rangeEnd { matched = true }
                index += 3
            } else {
                if member == character { matched = true }
                index += 1
            }
        }
        return nil
    }
}

// MARK: - Content search (grep)

nonisolated enum CodingSearchCommand {
    enum OutputMode: String {
        /// Only the paths of files that match.
        case files
        /// Matching lines as path:line:text.
        case content
    }

    static let defaultMaximumResults = 200
    static let outputCharacterBudget = 11_000

    /// Single-quotes a word for zsh: `it's` becomes `'it'\''s'`.
    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func ripgrepArguments(pattern: String, searchPath: String, fileGlob: String?, caseInsensitive: Bool, outputMode: OutputMode) -> [String] {
        var arguments = ["--no-heading", "--color", "never", "--no-messages", "--max-columns", "400", "--max-columns-preview"]
        if outputMode == .files {
            arguments.append("--files-with-matches")
        } else {
            arguments += ["--line-number", "--with-filename"]
        }
        if caseInsensitive { arguments.append("--ignore-case") }
        if let fileGlob, !fileGlob.isEmpty { arguments += ["--glob", fileGlob] }
        for skipped in CodingGlobMatcher.skippedDirectoryNames.sorted() {
            arguments += ["--glob", "!\(skipped)"]
        }
        arguments += ["--regexp", pattern, "--", searchPath]
        return arguments
    }

    /// The same search with the grep every Mac has. `--include` only understands a file name
    /// pattern, so a glob like `src/**/*.swift` is reduced to `*.swift`.
    static func grepArguments(pattern: String, searchPath: String, fileGlob: String?, caseInsensitive: Bool, outputMode: OutputMode) -> [String] {
        var arguments = ["-r", "-E", "-I", "-s"]
        arguments.append(outputMode == .files ? "-l" : "-n")
        if outputMode == .content { arguments.append("-H") }
        if caseInsensitive { arguments.append("-i") }
        if let fileGlob, !fileGlob.isEmpty {
            for expanded in CodingGlobMatcher.expandBraces(fileGlob) {
                let fileNamePattern = expanded.split(separator: "/").last.map(String.init) ?? expanded
                arguments.append("--include=\(fileNamePattern)")
            }
        }
        for skipped in CodingGlobMatcher.skippedDirectoryNames.sorted() {
            arguments.append("--exclude-dir=\(skipped)")
        }
        arguments += ["-e", pattern, "--", searchPath]
        return arguments
    }

    static func commandLine(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// Turns raw search output into the tool's answer: drops lines from files whose path looks
    /// like credentials (a project's .env must not reach the model through a search), keeps at
    /// most `maximumResults` lines, cuts long lines, and stays under the character budget.
    static func formatResults(
        rawOutput: String,
        outputMode: OutputMode,
        maximumResults: Int,
        isHiddenPath: (String) -> Bool
    ) -> String {
        var keptLines: [String] = []
        var hiddenCount = 0
        var droppedForLimitCount = 0
        var usedCharacters = 0
        for rawLine in rawOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let filePath = outputMode == .files ? line : filePathOfContentLine(line)
            if isHiddenPath(filePath) {
                hiddenCount += 1
                continue
            }
            let shownLine = line.count > 400 ? String(line.prefix(400)) + "…" : line
            if keptLines.count >= max(1, maximumResults) || usedCharacters + shownLine.count + 1 > outputCharacterBudget {
                droppedForLimitCount += 1
                continue
            }
            keptLines.append(shownLine)
            usedCharacters += shownLine.count + 1
        }

        if keptLines.isEmpty {
            return hiddenCount > 0 ? "No matches (\(hiddenCount) in files that may hold secrets were left out)." : "No matches."
        }
        var text = keptLines.joined(separator: "\n")
        if droppedForLimitCount > 0 {
            text += "\n[\(droppedForLimitCount) more result\(droppedForLimitCount == 1 ? "" : "s") not shown. Narrow the pattern, path or glob.]"
        }
        if hiddenCount > 0 {
            text += "\n[\(hiddenCount) result\(hiddenCount == 1 ? "" : "s") in files that may hold secrets were left out.]"
        }
        return text
    }

    /// `path:12:text` → `path`. Paths with colons are rare; the line number anchors the split.
    static func filePathOfContentLine(_ line: String) -> String {
        if let match = line.range(of: #":[0-9]+:"#, options: .regularExpression) {
            return String(line[..<match.lowerBound])
        }
        return line
    }
}

// MARK: - Directory listing

nonisolated enum CodingDirectoryListing {
    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
        var byteCount: Int64?
    }

    static let maximumEntries = 500

    static func humanReadableSize(_ byteCount: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(byteCount)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(byteCount) B" }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// Folders first (marked with `/`), then files with their size, each group by name.
    static func format(entries: [Entry], directoryPath: String) -> String {
        if entries.isEmpty { return "\(directoryPath) is empty." }
        let sorted = entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        var lines = ["\(directoryPath)/"]
        for entry in sorted.prefix(maximumEntries) {
            if entry.isDirectory {
                lines.append("  \(entry.name)/")
            } else if let byteCount = entry.byteCount {
                lines.append("  \(entry.name)  (\(humanReadableSize(byteCount)))")
            } else {
                lines.append("  \(entry.name)")
            }
        }
        if sorted.count > maximumEntries {
            lines.append("[\(sorted.count - maximumEntries) more entries not shown]")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Project detection and project context

nonisolated enum CodingProjectDetection {
    /// Instruction files a coding agent should follow, in the order they are read.
    static let instructionFileNames = ["AGENTS.md", "CLAUDE.md"]
    /// How much of those files goes into the system prompt, in characters.
    static let instructionCharacterBudget = 6_000

    /// Absolute and `~/` paths written in a request, quoted or bare. Trailing punctuation
    /// ("look at ~/code/app.") is not part of the path.
    static func candidatePaths(in requestText: String) -> [String] {
        var candidates: [String] = []
        // Quoted paths may contain spaces.
        let quotedPattern = #"[\"'`“‘]((?:~|/)[^\"'`”’\n]+)[\"'`”’]"#
        // Bare paths end at whitespace or a closing bracket or quote.
        let barePattern = #"(?:^|[\s(\[{<=:,])((?:~/|/)[^\s\"'`()\[\]{}<>,;]+|~(?=$|[\s.,;!?]))"#
        for pattern in [quotedPattern, barePattern] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(requestText.startIndex..., in: requestText)
            for match in expression.matches(in: requestText, range: fullRange) {
                guard let range = Range(match.range(at: 1), in: requestText) else { continue }
                var candidate = String(requestText[range])
                while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
                while candidate.count > 1, candidate.hasSuffix("/") { candidate.removeLast() }
                if !candidate.isEmpty, !candidates.contains(candidate) { candidates.append(candidate) }
            }
        }
        return candidates
    }

    /// The git project a request points at: the first path in the text that is (or is inside)
    /// a folder with a `.git` entry. A path to a file inside a project counts too. The home
    /// folder and `/` are never a project, even when someone keeps their dotfiles in git.
    static func projectDirectory(
        inRequestText requestText: String,
        home: String,
        isDirectory: (String) -> Bool,
        hasGitEntry: (String) -> Bool
    ) -> String? {
        let normalizedHome = normalize(home, home: home)
        for candidate in candidatePaths(in: requestText) {
            var directory = normalize(candidate, home: home)
            if !isDirectory(directory) {
                // A file path: start from the folder it is in, if that exists.
                directory = (directory as NSString).deletingLastPathComponent
                guard isDirectory(directory) else { continue }
            }
            var current = directory
            while current != "/" && current != normalizedHome && !current.isEmpty {
                if hasGitEntry(current) { return current }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    /// Expands ~ and squashes "." and ".." without touching the disk (the same rule as
    /// `PathPolicy.normalize`, repeated here so this enum stays free of the main actor).
    static func normalize(_ path: String, home: String) -> String {
        var expanded = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if expanded == "~" { expanded = home } else if expanded.hasPrefix("~/") { expanded = home + String(expanded.dropFirst(1)) }
        if !expanded.hasPrefix("/") { expanded = home + "/" + expanded }
        var parts: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The system prompt section for a job working in a project: where it is, the project's
    /// own instructions (AGENTS.md / CLAUDE.md, capped), and how to work on code.
    /// `instructionFiles` are (file name, contents) pairs in reading order.
    static func promptSection(projectDirectory: String, instructionFiles: [(name: String, contents: String)]) -> String {
        var section = """
        PROJECT: you are working in the code project at \(projectDirectory). bash, grep, glob and list_directory start there, and relative file paths are taken from there.

        How to work on code:
        - Explore before you change anything: list_directory, glob ("**/*.swift") and grep to find the code, then read_file the parts you need. read_file shows line numbers; never copy those prefixes into an edit.
        - Read a file before you edit it. Use edit_file for changes to existing files (exact text in old_string, enough context to match one place). Use write_file only for new files or a full rewrite.
        - Follow the project's own conventions and instructions below. Keep changes to what was asked.
        - After changing code, run the project's build or tests with bash (for example the test script, npm test, swift build, cargo test) and fix what breaks. Say so if you could not run them.
        - Never git push, force anything (push --force, reset --hard, clean -f), delete branches or rewrite history without asking. Do not commit unless asked.
        - Finish with a short summary of the files you changed and what you checked.
        """

        var remainingBudget = instructionCharacterBudget
        for file in instructionFiles {
            let trimmedContents = file.contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContents.isEmpty, remainingBudget > 0 else { continue }
            var shownContents = trimmedContents
            if shownContents.count > remainingBudget {
                shownContents = String(shownContents.prefix(remainingBudget)) + "\n[… cut here; read_file \(file.name) for the rest]"
            }
            remainingBudget -= min(trimmedContents.count, remainingBudget)
            section += "\n\nThe project's \(file.name) (instructions from the project owner; follow them):\n\(shownContents)"
        }
        return section
    }
}
