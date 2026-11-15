//
//  AgentRoster.swift
//  leanring-buddy
//
//  Named agents. Each one is a folder the person can open and edit:
//
//      ~/.teachy/agents/<slug>/
//          AGENT.md    name, one-line role, instructions, preferred tools / connectors
//          MEMORY.md   what this agent has learned (its own notes, not the Brain's)
//          files/      its working folder; file tools default here
//
//  The Markdown is edited losslessly with the Brain's `BrainDocument`, so hand
//  edits survive. Foundation + Combine only; the root folder and the "move to
//  Trash" step are injected, so tests run in a temp directory.
//

import Combine
import Foundation

nonisolated struct AgentProfile: Equatable, Identifiable, Sendable {
    var slug: String
    var name: String
    var role: String
    var instructions: String
    var preferredTools: [String]
    var preferredConnectors: [String]

    var id: String { slug }

    static let instructionsSection = "Instructions"
    static let toolsSection = "Preferred tools"
    static let connectorsSection = "Preferred connectors"

    init(slug: String, name: String, role: String = "", instructions: String = "", preferredTools: [String] = [], preferredConnectors: [String] = []) {
        self.slug = slug
        self.name = name
        self.role = role
        self.instructions = instructions
        self.preferredTools = preferredTools
        self.preferredConnectors = preferredConnectors
    }

    /// Reads an AGENT.md. Anything missing falls back to something sensible; nothing throws.
    init(slug: String, markdown: String) {
        let document = BrainDocument(markdown: markdown)
        var name = ""
        var role = ""
        for line in document.preamble {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty, trimmed.hasPrefix("# ") {
                name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if role.isEmpty, trimmed.lowercased().hasPrefix("role:") {
                role = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        func body(_ title: String) -> String {
            guard let index = document.sectionIndex(titled: title) else { return "" }
            return document.sections[index].lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func bullets(_ title: String) -> [String] {
            guard let index = document.sectionIndex(titled: title) else { return [] }
            return document.items(inSectionAt: index).filter(\.isBullet).map(\.text).filter { !$0.isEmpty }
        }
        self.slug = slug
        self.name = name.isEmpty ? slug.replacingOccurrences(of: "-", with: " ").capitalized : name
        self.role = role
        self.instructions = body(Self.instructionsSection)
        self.preferredTools = bullets(Self.toolsSection)
        self.preferredConnectors = bullets(Self.connectorsSection)
    }

    /// A fresh AGENT.md.
    var markdown: String {
        var lines = ["# \(name)", "", "Role: \(role)", "", "## \(Self.instructionsSection)", instructions.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        lines += ["## \(Self.toolsSection)"] + preferredTools.map { "- \($0)" } + [""]
        lines += ["## \(Self.connectorsSection)"] + preferredConnectors.map { "- \($0)" } + [""]
        return lines.joined(separator: "\n")
    }

    /// Changes only the `# Name` line of an existing AGENT.md.
    static func renaming(markdown: String, to newName: String) -> String {
        var document = BrainDocument(markdown: markdown)
        if let index = document.preamble.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }) {
            document.preamble[index] = "# \(newName)"
        } else {
            document.preamble.insert(contentsOf: ["# \(newName)", ""], at: 0)
        }
        return document.markdown
    }
}

nonisolated struct AgentRosterError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

final class AgentRoster: ObservableObject {
    static let agentFileName = "AGENT.md"
    static let memoryFileName = "MEMORY.md"
    static let filesFolderName = "files"
    static let defaultsMarkerName = ".defaults-created"
    /// Folders under the root that are not agents.
    static let reservedSlugs: Set<String> = ["history", "notes", "routines", "files"]
    static let memorySection = "Notes"
    static let memoryPromptLimit = 3_000

    let root: URL
    private let trash: (URL) throws -> Void
    @Published private(set) var agents: [AgentProfile] = []
    private var hasLoaded = false

    init(root: URL, trash: @escaping (URL) throws -> Void) {
        self.root = root
        self.trash = trash
    }

    // MARK: Places

    func folder(for slug: String) -> URL { root.appendingPathComponent(slug, isDirectory: true) }
    func filesDirectory(for slug: String) -> URL { folder(for: slug).appendingPathComponent(Self.filesFolderName, isDirectory: true) }
    func memoryURL(for slug: String) -> URL { folder(for: slug).appendingPathComponent(Self.memoryFileName) }
    func agentFileURL(for slug: String) -> URL { folder(for: slug).appendingPathComponent(Self.agentFileName) }

    // MARK: Listing

    /// Reads the folders again. Creates the two starter agents the very first time.
    @discardableResult
    func reload() -> [AgentProfile] {
        hasLoaded = true
        createDefaultsIfFirstUse()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [AgentProfile] = []
        for folder in folders {
            let slug = folder.lastPathComponent
            guard !slug.hasPrefix("."), !Self.reservedSlugs.contains(slug) else { continue }
            guard let text = try? String(contentsOf: folder.appendingPathComponent(Self.agentFileName), encoding: .utf8) else { continue }
            found.append(AgentProfile(slug: slug, markdown: text))
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if found != agents { agents = found }
        return found
    }

    private func loadIfNeeded() {
        if !hasLoaded { reload() }
    }

    func agent(slug: String) -> AgentProfile? {
        loadIfNeeded()
        return agents.first { $0.slug == slug }
    }

    static let defaultAgents: [AgentProfile] = [
        AgentProfile(
            slug: "research-buddy",
            name: "Research buddy",
            role: "Finds things out and tells you what matters.",
            instructions: """
            Look things up on the public web and in connected apps, compare a few sources, and report what you found in plain words.
            Say where a fact came from when it matters. Say so when sources disagree or you could not confirm something.
            Save longer findings as a Markdown file in your files folder and say where it is.
            """,
            preferredTools: ["web_search", "web_fetch", "read_file", "write_file"]
        ),
        AgentProfile(
            slug: "builder",
            name: "Builder",
            role: "Builds small apps, scripts and sites on this Mac.",
            instructions: """
            Build what was asked in your files folder, one small step at a time, and run it to check it works before you say it is done.
            Prefer the simplest thing that works. Say what you built, where it is and how to open it.
            """,
            preferredTools: ["bash", "read_file", "write_file", "open_browser_tab"]
        )
    ]

    private func createDefaultsIfFirstUse() {
        let marker = root.appendingPathComponent(Self.defaultsMarkerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for agent in Self.defaultAgents where !FileManager.default.fileExists(atPath: folder(for: agent.slug).path) {
                try write(agent)
            }
            try Data().write(to: marker)
        } catch {
            // Nothing to do: the next reload tries again.
        }
    }

    private func write(_ agent: AgentProfile) throws {
        try FileManager.default.createDirectory(at: filesDirectory(for: agent.slug), withIntermediateDirectories: true)
        try agent.markdown.write(to: agentFileURL(for: agent.slug), atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: memoryURL(for: agent.slug).path) {
            try "# What \(agent.name) remembers\n\n## \(Self.memorySection)\n".write(to: memoryURL(for: agent.slug), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Changing

    /// "Research buddy" → "research-buddy". Letters, digits and hyphens only.
    static func slug(for name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return String(parts.joined(separator: "-").prefix(40))
    }

    private func freeSlug(for name: String, ignoring current: String? = nil) throws -> String {
        let base = Self.slug(for: name)
        guard !base.isEmpty else { throw AgentRosterError(message: "Give the agent a name with at least one letter or number.") }
        var candidate = Self.reservedSlugs.contains(base) ? base + "-agent" : base
        var counter = 2
        while candidate != current, FileManager.default.fileExists(atPath: folder(for: candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    @discardableResult
    func create(name: String, role: String = "", instructions: String = "", preferredTools: [String] = [], preferredConnectors: [String] = []) throws -> AgentProfile {
        loadIfNeeded()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if agents.contains(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) {
            throw AgentRosterError(message: "There is already an agent called \(cleanName).")
        }
        let slug = try freeSlug(for: cleanName)
        let agent = AgentProfile(
            slug: slug,
            name: cleanName,
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions,
            preferredTools: preferredTools,
            preferredConnectors: preferredConnectors
        )
        try write(agent)
        reload()
        return agent
    }

    /// New name in AGENT.md and a matching folder name. Memory and files move with it.
    @discardableResult
    func rename(slug: String, to newName: String) throws -> AgentProfile {
        loadIfNeeded()
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agents.contains(where: { $0.slug == slug }) else { throw AgentRosterError(message: "That agent is gone.") }
        if agents.contains(where: { $0.slug != slug && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) {
            throw AgentRosterError(message: "There is already an agent called \(cleanName).")
        }
        let newSlug = try freeSlug(for: cleanName, ignoring: slug)
        let existing = (try? String(contentsOf: agentFileURL(for: slug), encoding: .utf8)) ?? ""
        try AgentProfile.renaming(markdown: existing, to: cleanName).write(to: agentFileURL(for: slug), atomically: true, encoding: .utf8)
        if newSlug != slug {
            try FileManager.default.moveItem(at: folder(for: slug), to: folder(for: newSlug))
        }
        reload()
        guard let renamed = agents.first(where: { $0.slug == newSlug }) else { throw AgentRosterError(message: "The rename did not stick.") }
        return renamed
    }

    /// Moves the whole folder to the Trash (so it can be put back).
    func delete(slug: String) throws {
        loadIfNeeded()
        let target = folder(for: slug)
        guard !Self.reservedSlugs.contains(slug), !slug.isEmpty, !slug.contains("/"), !slug.hasPrefix("."),
              FileManager.default.fileExists(atPath: agentFileURL(for: slug).path) else {
            throw AgentRosterError(message: "That agent is gone.")
        }
        try trash(target)
        reload()
    }

    // MARK: Choosing

    /// The agent named in the request, or nil (run a plain job). A longer name wins over a
    /// shorter one inside it ("Research buddy two" over "Research buddy").
    static func bestMatch(for request: String, among agents: [AgentProfile]) -> AgentProfile? {
        func words(_ text: String) -> String {
            " " + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        }
        let spoken = words(request)
        return agents
            .filter { words($0.name).count > 2 && spoken.contains(words($0.name)) }
            .max { $0.name.count < $1.name.count }
    }

    func bestAgent(for request: String) -> AgentProfile? {
        loadIfNeeded()
        return Self.bestMatch(for: request, among: agents)
    }

    // MARK: Memory

    /// A note that states a password, key or token outright. Those never go in MEMORY.md
    /// (a plain file that is pasted into prompts).
    static func looksLikeSecret(_ note: String) -> Bool {
        let patterns = [
            #"(?i)\b(password|passcode|passwd|api[ _-]?key|secret|access[ _-]?token|auth[ _-]?token|bearer|private key)\b\s*(is|are|was|=|:)"#,
            #"\b(sk|pk|rk|ghp|gho|github_pat|xox[abprs])[-_][A-Za-z0-9_-]{16,}"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"#
        ]
        return patterns.contains { note.range(of: $0, options: .regularExpression) != nil }
    }

    func memoryText(for slug: String) -> String {
        (try? String(contentsOf: memoryURL(for: slug), encoding: .utf8)) ?? ""
    }

    /// Appends one dated bullet to the agent's MEMORY.md. Returns false when it was already there.
    @discardableResult
    func remember(_ note: String, slug: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Bool {
        guard FileManager.default.fileExists(atPath: folder(for: slug).path) else { throw AgentRosterError(message: "That agent is gone.") }
        let clean = BrainText.singleLineNote(note)
        guard !clean.isEmpty else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let before = memoryText(for: slug)
        let after = AgentMarkdown.appendingBullet("\(formatter.string(from: now)): \(clean)", toSection: Self.memorySection, in: before)
        guard after != before else { return false }
        try after.write(to: memoryURL(for: slug), atomically: true, encoding: .utf8)
        return true
    }

    /// What goes into the system prompt of a job run as this agent.
    func promptSection(for agent: AgentProfile) -> String {
        var memory = memoryText(for: agent.slug).trimmingCharacters(in: .whitespacesAndNewlines)
        if memory.count > Self.memoryPromptLimit {
            // The newest notes are at the end.
            memory = "[older notes left out]\n" + String(memory.suffix(Self.memoryPromptLimit))
        }
        return Self.promptSection(agent: agent, memory: memory, filesPath: filesDirectory(for: agent.slug).path)
    }

    static func promptSection(agent: AgentProfile, memory: String, filesPath: String) -> String {
        var lines = ["YOU ARE RUNNING AS THE AGENT \"\(agent.name)\"."]
        if !agent.role.isEmpty { lines.append("Your role: \(agent.role)") }
        if !agent.instructions.isEmpty { lines.append("Your instructions:\n\(agent.instructions)") }
        if !agent.preferredTools.isEmpty { lines.append("Tools you usually reach for first: \(agent.preferredTools.joined(separator: ", ")).") }
        if !agent.preferredConnectors.isEmpty { lines.append("Connected apps you usually use: \(agent.preferredConnectors.joined(separator: ", ")).") }
        lines.append("Your files folder is \(filesPath). read_file and write_file take paths relative to it, and writing inside it needs no permission. Keep your work there unless told otherwise.")
        if memory.isEmpty {
            lines.append("You have no saved notes yet.")
        } else {
            lines.append("What you remember from earlier jobs (your MEMORY.md):\n\(memory)")
        }
        lines.append("When you learn something worth keeping for next time (a preference, where something lives, what worked), call remember with one short sentence. Do not save secrets or one-off details.")
        return lines.joined(separator: "\n")
    }
}
