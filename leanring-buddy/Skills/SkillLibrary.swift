//
//  SkillLibrary.swift
//  leanring-buddy / Skills
//
//  App skills: one short Markdown file per app or site that tells the model
//  where things are in that app (landmarks by their on-screen names, where the
//  most-asked actions live, gotchas, shortcuts). The right one is picked by the
//  bundle ID of the app the person is in, or by the site when that app is a
//  browser, and put into the voice prompt and the walkthrough planner.
//
//  A skill file is Markdown with a small front-matter block:
//
//      ---
//      name: Google Sheets
//      bundleIds: []
//      sites: [docs.google.com/spreadsheets, sheets.google.com]
//      summary: Spreadsheets in the browser.
//      ---
//      ## Layout
//      ...
//
//  `sites` entries are host suffixes, optionally followed by a path prefix.
//
//  Skills are loaded from the app bundle (files named `*.skill.md`; Xcode copies
//  resources flat, so the suffix is what tells them apart from other Markdown)
//  and from `~/.teachy/skills/*.md`. A file in the user folder replaces a
//  bundled skill with the same name. Skills from the Skill Market also carry
//  `id`, `version` and `author` in the front matter (see SkillMarket.swift).
//
//  Foundation only. Tested by scripts/tests/run_walk_tests.sh.
//

import Foundation

nonisolated struct Skill: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        /// The heading line without the leading `## `. Empty for text before the first heading.
        var title: String
        /// The section exactly as written, heading line included, no trailing blank lines.
        var text: String
    }

    var name: String
    var bundleIDs: [String]
    /// Lowercased `host` or `host/path` entries.
    var sites: [String]
    var summary: String
    var sections: [Section]
    /// Where it was loaded from: "bundled" or "user".
    var origin: String = "bundled"
    /// Skill Market listing ID (`id:` in the front matter), when it came from the market.
    var marketID: String? = nil
    /// `version:` in the front matter, for spotting updates to market skills.
    var version: String? = nil
    /// `author:` in the front matter.
    var author: String? = nil
    /// Library presentation (all optional, from the front matter): an emoji for the tile,
    /// a one-line pitch, who it is for, tags, and what is inside.
    var icon: String? = nil
    var headline: String? = nil
    var details: String? = nil
    var goodFor: [String] = []
    var highlights: [String] = []
    var category: String? = nil
    /// The file it was read from. Set by `SkillLibrary.load`.
    var fileURL: URL? = nil

    var body: String { sections.map(\.text).joined(separator: "\n\n") }
}

// MARK: - Parsing

nonisolated enum SkillParser {
    /// Parses one skill file. Nil when there is no front matter or no name.
    static func parse(_ text: String, origin: String = "bundled") -> Skill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // Leading blank lines and a byte-order mark are fine.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "").isEmpty {
            lines.removeFirst()
        }
        guard let opening = lines.first, isFence(opening) else { return nil }
        guard let closingOffset = lines.dropFirst().firstIndex(where: isFence) else { return nil }

        let fields = frontMatter(Array(lines[1..<closingOffset]))
        guard let name = fields["name"]?.first, !name.isEmpty else { return nil }

        let bodyLines = Array(lines[(closingOffset + 1)...])
        return Skill(
            name: name,
            bundleIDs: (fields["bundleids"] ?? []).filter { !$0.isEmpty },
            sites: (fields["sites"] ?? []).map(normalizeSite).filter { !$0.isEmpty },
            summary: fields["summary"]?.joined(separator: ", ") ?? "",
            sections: sections(from: bodyLines),
            origin: origin,
            marketID: fields["id"]?.first.flatMap { $0.isEmpty ? nil : $0.lowercased() },
            version: fields["version"]?.first.flatMap { $0.isEmpty ? nil : $0 },
            author: fields["author"]?.first.flatMap { $0.isEmpty ? nil : $0 },
            icon: fields["icon"]?.first.flatMap { $0.isEmpty ? nil : $0 },
            headline: fields["headline"]?.first.flatMap { $0.isEmpty ? nil : $0 },
            details: fields["description"]?.first.flatMap { $0.isEmpty ? nil : $0 },
            goodFor: (fields["goodfor"] ?? []).filter { !$0.isEmpty },
            highlights: (fields["highlights"] ?? []).filter { !$0.isEmpty },
            category: fields["category"]?.first.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func isFence(_ line: String) -> Bool {
        line.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces) == "---"
    }

    /// `key: value`, `key: [a, b]`, or `key:` followed by `- item` lines. Keys are lowercased.
    static func frontMatter(_ lines: [String]) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        var openListKey: String?
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- ") || line == "-" {
                guard let key = openListKey else { continue }
                let item = unquote(String(line.dropFirst(1)))
                if !item.isEmpty { fields[key, default: []].append(item) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.isEmpty {
                openListKey = key
                fields[key] = fields[key] ?? []
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                openListKey = nil
                fields[key] = value.dropFirst().dropLast()
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map { unquote(String($0)) }
                    .filter { !$0.isEmpty }
            } else {
                openListKey = nil
                // A scalar is kept whole: a summary may contain commas.
                fields[key] = [unquote(value)]
            }
        }
        return fields
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// `https://www.Docs.Google.com/spreadsheets/` → `docs.google.com/spreadsheets`.
    static func normalizeSite(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) { value = String(value[..<cut]) }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        if value.hasPrefix("*.") { value = String(value.dropFirst(2)) }
        while value.hasSuffix("/") { value.removeLast() }
        // Drop a port.
        let host = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        if let colon = host.firstIndex(of: ":") {
            value = String(host[..<colon]) + value.dropFirst(host.count)
        }
        return value
    }

    /// Splits the body at `## ` headings. Deeper headings stay inside their section.
    static func sections(from lines: [String]) -> [Skill.Section] {
        var result: [Skill.Section] = []
        var title = ""
        var current: [String] = []
        func flush() {
            var kept = current
            while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
            while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeFirst() }
            if !kept.isEmpty { result.append(Skill.Section(title: title, text: kept.joined(separator: "\n"))) }
        }
        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                current = [line]
            } else {
                current.append(line)
            }
        }
        flush()
        return result
    }
}

// MARK: - Matching

nonisolated enum SkillMatcher {
    /// How well `site` (a normalized `host` or `host/path` entry) matches a page. 0 = no match;
    /// higher = more specific (longer host suffix, then longer path prefix).
    static func siteScore(_ site: String, host: String, path: String) -> Int {
        let parts = site.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let siteHost = parts.first.map(String.init), !siteHost.isEmpty else { return 0 }
        guard host == siteHost || host.hasSuffix("." + siteHost) else { return 0 }
        var score = siteHost.count * 1000
        if parts.count > 1 {
            let sitePath = "/" + parts[1]
            guard path == sitePath || path.hasPrefix(sitePath + "/") else { return 0 }
            score += sitePath.count
        }
        return score
    }

    /// Splits whatever the host knows about the page (a bare host, `host/path`, or a full URL)
    /// into a lowercased host without `www.` and a path that starts with `/`.
    static func hostAndPath(from browserLocation: String) -> (host: String, path: String)? {
        let normalized = SkillParser.normalizeSite(browserLocation)
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first.map(String.init), host.contains(".") || host == "localhost" else { return nil }
        let path = parts.count > 1 ? "/" + parts[1] : "/"
        return (host, path)
    }

    /// A site skill for the page wins over the browser's own skill; otherwise the app's skill.
    static func bestSkill(in skills: [Skill], bundleID: String?, browserLocation: String?) -> Skill? {
        if let browserLocation, let page = hostAndPath(from: browserLocation) {
            var best: (skill: Skill, score: Int)?
            for skill in skills {
                let score = skill.sites.map { siteScore($0, host: page.host, path: page.path) }.max() ?? 0
                if score > 0, score > (best?.score ?? 0) { best = (skill, score) }
            }
            if let best { return best.skill }
        }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let wanted = bundleID.lowercased()
        return skills.first { $0.bundleIDs.contains { $0.lowercased() == wanted } }
    }

    /// Pulls the URL out of the line `BrowserActiveTabReader` produces:
    /// `Safari tab: "Title" — https://example.com/page`.
    static func browserLocation(fromTabContext context: String?) -> String? {
        guard let context else { return nil }
        guard let scheme = context.range(of: "://", options: .backwards) else { return nil }
        // Walk back over the scheme name.
        var start = scheme.lowerBound
        while start > context.startIndex {
            let previous = context.index(before: start)
            guard context[previous].isLetter else { break }
            start = previous
        }
        let url = context[start...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
        return url?.isEmpty == false ? url : nil
    }
}

// MARK: - Prompt text

nonisolated enum SkillPrompt {
    /// The skill as prompt text within `budgetCharacters`. Sections are added whole, in order;
    /// one that does not fit is left out (a later, shorter one may still fit). Never cuts a line.
    /// Empty when not even the heading line fits.
    static func section(for skill: Skill, budgetCharacters: Int) -> String {
        var header = "APP SKILL: \(skill.name)"
        if !skill.summary.isEmpty { header += " — \(skill.summary)" }
        header += "\n(Maintained notes on where things are in this app. Trust what is on screen over these notes if they differ.)"
        guard header.count <= budgetCharacters else { return "" }

        var text = header
        var included = 0
        for section in skill.sections {
            let addition = "\n\n" + section.text
            if text.count + addition.count <= budgetCharacters {
                text += addition
                included += 1
            }
        }
        // A heading with nothing under it is not worth the tokens.
        return included == 0 && !skill.sections.isEmpty ? "" : text
    }
}

// MARK: - Library

/// Safe to use from any thread (the cache is behind a lock).
nonisolated final class SkillLibrary: @unchecked Sendable {
    static let shared = SkillLibrary()

    /// Bundled skill files end in this; files in the user folder only need `.md`.
    static let bundledFileSuffix = ".skill.md"
    /// Enough for every bundled skill in full (the longest is about 2,700 characters with its heading).
    static let defaultPromptBudget = 2_800

    static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teachy/skills", isDirectory: true)
    }

    private let bundledDirectories: [URL]
    private let userDirectory: URL?
    private let lock = NSLock()
    private var cached: [Skill]?
    private var cachedUserStamp = ""

    /// `bundledDirectories` are searched for `*.skill.md`; `userDirectory` for any `*.md`.
    init(bundledDirectories: [URL]? = nil, userDirectory: URL? = SkillLibrary.userDirectory) {
        if let bundledDirectories {
            self.bundledDirectories = bundledDirectories
        } else {
            var directories: [URL] = []
            if let resources = Bundle.main.resourceURL {
                directories.append(resources)
                directories.append(resources.appendingPathComponent("skills", isDirectory: true))
            }
            self.bundledDirectories = directories
        }
        self.userDirectory = userDirectory
    }

    /// Every skill, bundled first, with user skills replacing bundled ones of the same name.
    /// Re-reads when a file in the user folder is added, removed or edited.
    var skills: [Skill] {
        let stamp = Self.stamp(of: userDirectory)
        lock.lock()
        defer { lock.unlock() }
        if let cached, stamp == cachedUserStamp { return cached }
        let loaded = Self.load(bundledDirectories: bundledDirectories, userDirectory: userDirectory)
        cached = loaded
        cachedUserStamp = stamp
        return loaded
    }

    /// Only the skills the person added (from a file or the Skill Market), in file-name order.
    var userSkills: [Skill] {
        guard let userDirectory else { return [] }
        return Self.load(bundledDirectories: [], userDirectory: userDirectory)
    }

    /// Only the skills that ship with Teachy, before any user file replaces them.
    var bundledSkills: [Skill] {
        Self.load(bundledDirectories: bundledDirectories, userDirectory: nil)
    }

    func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// The skill for the app the person is in. `browserHost` may be a bare host, `host/path` or a
    /// full URL; pass it only when the front app is a browser. A matching site skill wins.
    func skill(forBundleID bundleID: String?, browserHost: String?) -> Skill? {
        SkillMatcher.bestSkill(in: skills, bundleID: bundleID, browserLocation: browserHost)
    }

    func promptSection(for skill: Skill, budgetCharacters: Int = SkillLibrary.defaultPromptBudget) -> String {
        SkillPrompt.section(for: skill, budgetCharacters: budgetCharacters)
    }

    /// One call for the voice prompt: the front app's bundle ID plus the line
    /// `BrowserActiveTabReader.activeTabContext()` returned (or nil). Empty when no skill matches.
    func promptSection(frontmostBundleID: String?, browserTabContext: String?, budgetCharacters: Int = SkillLibrary.defaultPromptBudget) -> String {
        let location = SkillMatcher.browserLocation(fromTabContext: browserTabContext)
        guard let skill = skill(forBundleID: frontmostBundleID, browserHost: location) else { return "" }
        return promptSection(for: skill, budgetCharacters: budgetCharacters)
    }

    // MARK: Loading

    static func load(bundledDirectories: [URL], userDirectory: URL?) -> [Skill] {
        var skills: [Skill] = []
        var positionByName: [String: Int] = [:]

        func add(_ skill: Skill) {
            let key = skill.name.lowercased()
            if let position = positionByName[key] {
                skills[position] = skill
            } else {
                positionByName[key] = skills.count
                skills.append(skill)
            }
        }

        for directory in bundledDirectories {
            for file in markdownFiles(in: directory) where file.lastPathComponent.lowercased().hasSuffix(bundledFileSuffix) {
                if let text = try? String(contentsOf: file, encoding: .utf8), var skill = SkillParser.parse(text, origin: "bundled") {
                    skill.fileURL = file
                    add(skill)
                }
            }
        }
        if let userDirectory {
            for file in markdownFiles(in: userDirectory) {
                if let text = try? String(contentsOf: file, encoding: .utf8), var skill = SkillParser.parse(text, origin: "user") {
                    skill.fileURL = file
                    add(skill)
                }
            }
        }
        return skills
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        // The folder may be a link (for example ~/.teachy/skills pointing at a clone of the skills repo).
        let files = (try? FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Names and modification times of the user's skill files: cheap enough to check every turn.
    private static func stamp(of directory: URL?) -> String {
        guard let directory else { return "" }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { file -> String in
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return "\(file.lastPathComponent):\(modified)"
            }
            .sorted()
            .joined(separator: "|")
    }
}
