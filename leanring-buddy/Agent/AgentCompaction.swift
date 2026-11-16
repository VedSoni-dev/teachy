//
//  AgentCompaction.swift
//  leanring-buddy
//
//  Long jobs outgrow the model's context. When the conversation passes a size
//  budget, older tool results are summarised into the job's notes file and
//  dropped from the message list; the notes (goal, the person's rules, what was
//  done) are then read back in. Pure: works on plain message dictionaries.
//
//  Tool-call / tool-result pairing is never broken: a dropped result keeps its
//  message, only its content becomes a one-line stub.
//

import Foundation

nonisolated enum AgentCompaction {
    struct Budget: Equatable, Sendable {
        /// Roughly characters of text; an image counts as `imageCost`. About 4 per token.
        var maxCost = 60_000
        /// Compaction brings the conversation down to this, not just under the maximum,
        /// so it does not run again on the very next step.
        var targetCost = 30_000
        /// The request body must also stay well under the router's size limit (images are big).
        var maxBytes = 2_800_000
        var targetBytes = 1_400_000
        var imageCost = 6_000
        /// The newest tool results always stay whole: the model is still working from them.
        var keepRecentToolResults = 3

        init() {}
    }

    /// What the budget logic needs to know about one message.
    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case system, user, assistant, tool }
        var kind: Kind
        var cost: Int
        var bytes: Int
        var hasImages: Bool
        /// Already a stub, or the notes message: nothing more to gain.
        var isCompacted: Bool
    }

    enum Action: Equatable, Sendable {
        /// Replace this tool result with a stub and put its summary in the notes.
        case dropToolResult(index: Int)
        /// Take the pictures out of this older user message, keep its words.
        case stripImages(index: Int)
    }

    static let droppedPrefix = "[Dropped to save room; summary kept in the job notes]"
    static let strippedImageText = "[screenshot removed to save room]"
    static let notesPrefix = "JOB NOTES"
    static let stubCost = 80

    // MARK: Measuring

    static func entry(for message: [String: Any], budget: Budget = Budget()) -> Entry {
        let kind: Entry.Kind
        switch message["role"] as? String {
        case "system": kind = .system
        case "assistant": kind = .assistant
        case "tool": kind = .tool
        default: kind = .user
        }
        var cost = 0, bytes = 0, hasImages = false, isCompacted = false
        if let text = message["content"] as? String {
            cost += text.count
            bytes += text.utf8.count
            isCompacted = text.hasPrefix(droppedPrefix) || text.hasPrefix(notesPrefix)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                if let text = block["text"] as? String {
                    cost += text.count
                    bytes += text.utf8.count
                } else if let image = block["image_url"] as? [String: Any], let url = image["url"] as? String {
                    cost += budget.imageCost
                    bytes += url.utf8.count
                    hasImages = true
                }
            }
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let function = call["function"] as? [String: Any]
                let size = ((function?["name"] as? String) ?? "").count + ((function?["arguments"] as? String) ?? "").utf8.count
                cost += size
                bytes += size
            }
        }
        return Entry(kind: kind, cost: cost, bytes: bytes, hasImages: hasImages, isCompacted: isCompacted)
    }

    static func total(_ entries: [Entry]) -> (cost: Int, bytes: Int) {
        entries.reduce((0, 0)) { ($0.0 + $1.cost, $0.1 + $1.bytes) }
    }

    // MARK: The budget rule

    /// Always: only the newest screenshot stays. Every model call re-sends the whole job,
    /// so a job that took a screenshot per step was paying for every old picture again on
    /// every later step; the model only ever acts on the newest one (its capture_id).
    /// Then, while over the maximum: drop tool results oldest first (never the newest few),
    /// then strip pictures from older user messages, until under the target.
    static func plan(_ entries: [Entry], budget: Budget = Budget()) -> [Action] {
        var (cost, bytes) = total(entries)
        var actions: [Action] = []
        var strippedIndices: Set<Int> = []

        let newestPictureIndex = entries.indices.last { entries[$0].hasImages }
        for index in entries.indices where entries[index].hasImages && index != newestPictureIndex {
            actions.append(.stripImages(index: index))
            strippedIndices.insert(index)
            cost -= min(entries[index].cost, budget.imageCost)
            bytes = max(0, bytes - entries[index].bytes)
        }

        guard cost > budget.maxCost || bytes > budget.maxBytes else { return actions }

        func isUnderTarget() -> Bool { cost <= budget.targetCost && bytes <= budget.targetBytes }

        let toolIndices = entries.indices.filter { entries[$0].kind == .tool }
        let protected = Set(toolIndices.suffix(max(0, budget.keepRecentToolResults)))
        for index in toolIndices where !protected.contains(index) && !entries[index].isCompacted {
            if isUnderTarget() { break }
            // A stub that is no smaller than the result saves nothing.
            guard entries[index].cost > stubCost || entries[index].bytes > stubCost else { continue }
            actions.append(.dropToolResult(index: index))
            cost -= max(0, entries[index].cost - stubCost)
            bytes -= max(0, entries[index].bytes - stubCost)
        }

        if !isUnderTarget() {
            let lastUser = entries.indices.last { entries[$0].kind == .user }
            for index in entries.indices where entries[index].kind == .user && entries[index].hasImages && index != lastUser && !strippedIndices.contains(index) {
                if isUnderTarget() { break }
                actions.append(.stripImages(index: index))
                // Only the pictures go; the words stay.
                let text = entries[index]
                cost -= min(text.cost, budget.imageCost)
                bytes = max(0, bytes - text.bytes)
            }
        }
        return actions
    }

    // MARK: Applying it

    struct Outcome: Equatable, Sendable {
        var didCompact = false
        /// One line per dropped tool result, oldest first, for the notes.
        var summaries: [String] = []
    }

    /// Applies `plan` to a real message list. Does not touch the notes message; the caller
    /// writes the summaries to the notes file and calls `readNotesBackIn`.
    static func compact(_ messages: inout [[String: Any]], budget: Budget = Budget()) -> Outcome {
        let actions = plan(messages.map { entry(for: $0, budget: budget) }, budget: budget)
        guard !actions.isEmpty else { return Outcome() }
        // Taking out old screenshots happens on most steps and loses no words, so only
        // dropped tool results count as compacting (that is what re-reads the notes).
        var outcome = Outcome()
        for action in actions {
            switch action {
            case .dropToolResult(let index):
                outcome.didCompact = true
                let summary = toolSummary(forToolMessageAt: index, in: messages)
                outcome.summaries.append(summary)
                messages[index]["content"] = droppedPrefix + " " + summary
            case .stripImages(let index):
                guard let blocks = messages[index]["content"] as? [[String: Any]] else { continue }
                var kept = blocks.filter { $0["image_url"] == nil }
                kept.append(["type": "text", "text": strippedImageText])
                messages[index]["content"] = kept
            }
        }
        return outcome
    }

    /// Puts the notes back in front of the model as the newest message, replacing any older copy.
    static func readNotesBackIn(_ notesText: String, messages: inout [[String: Any]], limit: Int = 8_000) {
        messages.removeAll { ($0["role"] as? String) == "user" && (($0["content"] as? String)?.hasPrefix(notesPrefix) ?? false) }
        let trimmed = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n[notes cut here]" : trimmed
        messages.append([
            "role": "user",
            "content": "\(notesPrefix) (older tool results were dropped to save room; this is what you wrote down). Read your goal and the person's rules again, then carry on from where you are. Do not redo finished work.\n\n\(clipped)"
        ])
    }

    /// "web_search {"query":"…"} → first words of the result".
    static func toolSummary(forToolMessageAt index: Int, in messages: [[String: Any]]) -> String {
        let message = messages[index]
        let callID = message["tool_call_id"] as? String ?? ""
        var name = "tool", arguments = ""
        search: for earlier in messages[..<index].reversed() {
            for call in (earlier["tool_calls"] as? [[String: Any]]) ?? [] where (call["id"] as? String) == callID {
                let function = call["function"] as? [String: Any]
                name = function?["name"] as? String ?? name
                arguments = function?["arguments"] as? String ?? ""
                break search
            }
        }
        var resultText = ""
        if let text = message["content"] as? String {
            resultText = text
        } else if let blocks = message["content"] as? [[String: Any]] {
            resultText = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return summaryLine(tool: name, arguments: arguments, result: resultText)
    }

    static func summaryLine(tool: String, arguments: String, result: String) -> String {
        func squeeze(_ text: String, _ limit: Int) -> String {
            let flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
        let shortArguments = squeeze(arguments, 90)
        let call = shortArguments.isEmpty || shortArguments == "{}" ? tool : "\(tool) \(shortArguments)"
        return "\(call) → \(squeeze(result, 200))"
    }
}

// MARK: - The notes file

/// The job's notes: the goal, the person's rules, what was done so far. Kept as Markdown
/// (the person can open it), edited losslessly with the same model the Brain uses.
nonisolated enum AgentJobNotes {
    static let goalSection = "Goal"
    static let rulesSection = "Rules from the person"
    static let doneSection = "Done so far"
    static let maxDoneLines = 40

    static func initial(request: String, title: String) -> String {
        """
        # Notes for the job \(title)

        ## \(goalSection)
        \(BrainText.singleLineNote(request, maximumCharacters: 2_000))

        ## \(rulesSection)

        ## \(doneSection)

        """
    }

    /// Something the person said after the start, or a "not now": a rule to keep to.
    static func addingRule(_ rule: String, to markdown: String) -> String {
        AgentMarkdown.appendingBullet(rule, toSection: rulesSection, in: markdown)
    }

    /// Adds summaries of dropped tool results, keeping only the newest `maxDoneLines`.
    static func addingDone(_ summaries: [String], to markdown: String) -> String {
        var text = markdown
        for summary in summaries {
            text = AgentMarkdown.appendingBullet(summary, toSection: doneSection, in: text, skipDuplicates: false)
        }
        return AgentMarkdown.keepingNewestBullets(maxDoneLines, inSection: doneSection, of: text)
    }
}

/// Small lossless edits on a sectioned Markdown file, on top of `BrainDocument`.
nonisolated enum AgentMarkdown {
    /// Adds `- text` at the end of the `## title` section (creating the section if needed).
    /// Everything else in the file stays byte for byte as it was.
    static func appendingBullet(_ rawText: String, toSection title: String, in markdown: String, skipDuplicates: Bool = true) -> String {
        let text = BrainText.singleLineNote(rawText)
        guard !text.isEmpty else { return markdown }
        var document = BrainDocument(markdown: markdown)
        let sectionIndex = document.sectionIndex(titled: title) ?? document.appendSection(titled: title)
        if skipDuplicates {
            let key = BrainText.comparisonKey(text)
            if document.items(inSectionAt: sectionIndex).contains(where: { BrainText.comparisonKey($0.text) == key }) {
                return markdown
            }
        }
        var lines = document.sections[sectionIndex].lines
        // After the last line that says something; trailing blank lines stay where they are.
        var insertAt = lines.count
        while insertAt > 0, lines[insertAt - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { insertAt -= 1 }
        lines.insert("- \(text)", at: insertAt)
        if insertAt == lines.count - 1 { lines.append("") }
        document.sections[sectionIndex].lines = lines
        return document.markdown
    }

    static func bullets(inSection title: String, of markdown: String) -> [String] {
        let document = BrainDocument(markdown: markdown)
        guard let sectionIndex = document.sectionIndex(titled: title) else { return [] }
        return document.items(inSectionAt: sectionIndex).filter(\.isBullet).map(\.text)
    }

    /// Drops the oldest bullets of a section past `limit`. Prose lines are left alone.
    static func keepingNewestBullets(_ limit: Int, inSection title: String, of markdown: String) -> String {
        var document = BrainDocument(markdown: markdown)
        guard let sectionIndex = document.sectionIndex(titled: title) else { return markdown }
        let bulletItems = document.items(inSectionAt: sectionIndex).filter(\.isBullet)
        guard bulletItems.count > limit else { return markdown }
        var lines = document.sections[sectionIndex].lines
        for item in bulletItems.prefix(bulletItems.count - limit).reversed() {
            lines.removeSubrange(item.range)
        }
        document.sections[sectionIndex].lines = lines
        return document.markdown
    }
}
