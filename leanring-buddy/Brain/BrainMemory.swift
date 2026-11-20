//
//  BrainMemory.swift
//  leanring-buddy
//
//  The rules of Teachy's memory, applied to the two Markdown files in memory:
//  which section a note belongs in, de-duplication, replacing a note about the
//  same subject, trimming the short-lived sections, forgetting, and building the
//  budgeted text that goes into every model call. Pure — `BrainStore` does the IO.
//

import Foundation

/// The two memory files under `~/.teachy/brain/`.
nonisolated enum BrainFile: CaseIterable, Sendable {
    /// Durable: who the person is and how they like to be helped.
    case profile
    /// Current: what they are working on and what happened lately.
    case volatile

    var fileName: String {
        switch self {
        case .profile: return "PROFILE.md"
        case .volatile: return "VOLATILE.md"
        }
    }

    /// What a brand-new (or just-forgotten) file contains.
    var template: String {
        switch self {
        case .profile:
            return """
            # Teachy profile

            Teachy reads this before every answer. It is yours: change, add or delete anything. One "- " bullet per line.

            ## About me

            ## How I like answers

            ## How I like things done

            ## Likes and favourites

            ## Tools and apps I use

            ## Skills

            ## Things that keep catching me

            ## Words and names

            """
        case .volatile:
            return """
            # Teachy right now

            What you are working on and what happened lately. Teachy keeps this short and current. Screen memory is short text notes only, never pictures. Edit freely.

            ## Working on now

            ## Recently

            ## Screen memory

            """
        }
    }
}

/// What kind of thing is being remembered. Each kind lives in one section of one file.
nonisolated enum BrainKind: String, CaseIterable, Codable, Sendable {
    case aboutMe
    case answerStyle
    /// How they want Teachy to act: which browser, whether it may move the mouse, per-site habits.
    case howToDoThings
    /// Songs, artists, shows, food, brands: what "the one I like" points at.
    case likes
    case tools
    case skills
    case mistakes
    case words
    case project
    case recent
    case screen

    var file: BrainFile {
        switch self {
        case .aboutMe, .answerStyle, .howToDoThings, .likes, .tools, .skills, .mistakes, .words: return .profile
        case .project, .recent, .screen: return .volatile
        }
    }

    var sectionTitle: String {
        switch self {
        case .aboutMe: return "About me"
        case .answerStyle: return "How I like answers"
        case .howToDoThings: return "How I like things done"
        case .likes: return "Likes and favourites"
        case .tools: return "Tools and apps I use"
        case .skills: return "Skills"
        case .mistakes: return "Things that keep catching me"
        case .words: return "Words and names"
        case .project: return "Working on now"
        case .recent: return "Recently"
        case .screen: return "Screen memory"
        }
    }

    /// Dated sections keep the newest note at the top and are trimmed from the bottom.
    var isNewestFirst: Bool { self == .recent || self == .screen }

    /// How many bullets a short-lived section keeps. nil = never trimmed.
    var maximumBullets: Int? {
        switch self {
        case .recent: return 30
        case .screen: return 15
        default: return nil
        }
    }

    /// Whether "Subject: new value" replaces the older "Subject: old value" bullet.
    /// Off for mistakes (two different mistakes can share a subject) and for the
    /// dated sections (they are a log, not a set of facts).
    var replacesSameSubject: Bool { self != .mistakes && !isNewestFirst }

    /// Reads a kind the way a model might spell it ("answer_style", "Tools", "preference").
    static func parse(_ rawKind: String) -> BrainKind? {
        let compactKind = BrainText.normalized(rawKind).replacingOccurrences(of: " ", with: "")
        if let exactKind = allCases.first(where: { $0.rawValue.lowercased() == compactKind }) {
            return exactKind
        }
        switch compactKind {
        case "about", "me", "fact", "personal": return .aboutMe
        case "style", "preference", "preferences", "answers", "tone": return .answerStyle
        case "howtodo", "howtoact", "howtodothings", "workflow", "habit", "habits", "action", "actions": return .howToDoThings
        case "like", "favorite", "favorites", "favourite", "favourites", "taste", "music": return .likes
        case "tool", "app", "apps": return .tools
        case "skill": return .skills
        case "mistake", "gotcha", "gotchas": return .mistakes
        case "word", "name", "names", "spelling", "spellings": return .words
        case "projects", "workingon", "workingonnow": return .project
        case "recently", "note": return .recent
        case "screenmemory", "seen": return .screen
        default: return nil
        }
    }
}

nonisolated enum BrainRememberOutcome: Equatable, Sendable {
    /// A new bullet was written.
    case added
    /// Already remembered; nothing changed.
    case duplicate
    /// A dated note that was already there moved back to the top with today's date.
    case refreshed
    /// A repeated mistake; its "(xN)" counter went up to `count`.
    case repeated(count: Int)
    /// Replaced the older bullet about the same subject.
    case replaced(previous: String)
    /// Empty or unusable note, or the memory file could not be read or written.
    case rejected
}

/// Both memory files, parsed. All memory rules are mutations on this value.
nonisolated struct BrainMemory: Equatable, Sendable {
    var profile: BrainDocument
    var volatile: BrainDocument

    /// Fresh, empty memory (the templates).
    init() {
        self.profile = BrainDocument(markdown: BrainFile.profile.template)
        self.volatile = BrainDocument(markdown: BrainFile.volatile.template)
    }

    init(profile: BrainDocument, volatile: BrainDocument) {
        self.profile = profile
        self.volatile = volatile
    }

    subscript(file: BrainFile) -> BrainDocument {
        get { file == .profile ? profile : volatile }
        set {
            if file == .profile { profile = newValue } else { volatile = newValue }
        }
    }

    /// How many things are remembered across both files.
    var itemCount: Int { profile.totalItemCount + volatile.totalItemCount }

    // MARK: - Remember

    @discardableResult
    mutating func remember(
        _ rawNote: String,
        kind: BrainKind,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> BrainRememberOutcome {
        var note = BrainText.singleLineNote(rawNote)
        let noteComparisonKey = BrainText.comparisonKey(note)
        guard !noteComparisonKey.isEmpty else { return .rejected }

        var document = self[kind.file]
        defer { self[kind.file] = document }

        let sectionIndex = document.sectionIndex(titled: kind.sectionTitle)
            ?? document.appendSection(titled: kind.sectionTitle)
        let existingItems = document.items(inSectionAt: sectionIndex)
        var outcome = BrainRememberOutcome.added

        if let sameItem = existingItems.first(where: { BrainText.comparisonKey($0.text) == noteComparisonKey }) {
            if kind == .mistakes {
                let (mistakeText, previousCount) = BrainText.splittingRepeatCount(sameItem.text)
                let newCount = previousCount + 1
                document.sections[sectionIndex].lines.replaceSubrange(
                    sameItem.range,
                    with: ["- \(mistakeText) (x\(newCount))"]
                )
                return .repeated(count: newCount)
            }
            guard kind.isNewestFirst else { return .duplicate }
            // A dated note said again: drop the old line and re-add it on top.
            document.sections[sectionIndex].lines.removeSubrange(sameItem.range)
            outcome = .refreshed
        } else if kind.replacesSameSubject,
                  let noteSubject = BrainText.leadingSubject(note),
                  let olderItem = existingItems.first(where: {
                      $0.isBullet && BrainText.leadingSubject($0.text) == noteSubject
                  }) {
            document.sections[sectionIndex].lines.replaceSubrange(olderItem.range, with: ["- \(note)"])
            return .replaced(previous: olderItem.text)
        }

        if kind.isNewestFirst && BrainText.removingDateStamp(note) == note {
            note = "\(Self.dateStamp(for: date, includingTime: kind == .screen, timeZone: timeZone)): \(note)"
        }

        let currentItems = document.items(inSectionAt: sectionIndex)
        let endOfItems = currentItems.last?.range.upperBound ?? 0
        let insertionIndex = kind.isNewestFirst
            ? (currentItems.first(where: \.isBullet)?.range.lowerBound ?? endOfItems)
            : endOfItems
        document.sections[sectionIndex].lines.insert("- \(note)", at: insertionIndex)

        if let maximumBullets = kind.maximumBullets {
            let bullets = document.items(inSectionAt: sectionIndex).filter(\.isBullet)
            for overflowingBullet in bullets.dropFirst(maximumBullets).reversed() {
                document.sections[sectionIndex].lines.removeSubrange(overflowingBullet.range)
            }
        }
        return outcome
    }

    static func dateStamp(for date: Date, includingTime: Bool, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = includingTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Forget

    /// Removes every remembered item (in any section, including ones the person
    /// added by hand) that mentions the phrase. Returns the removed texts.
    /// Matching ignores case and punctuation and must start at a word, so
    /// "art" removes "art school" but not "started".
    @discardableResult
    mutating func forget(matching phrase: String) -> [String] {
        let wantedPhrase = BrainText.normalized(phrase)
        guard wantedPhrase.count >= 3 else { return [] }

        var removedTexts: [String] = []
        for file in BrainFile.allCases {
            var document = self[file]
            for sectionIndex in document.sections.indices {
                let matchingItems = document.items(inSectionAt: sectionIndex).filter {
                    (" " + BrainText.normalized($0.text)).contains(" " + wantedPhrase)
                }
                removedTexts.append(contentsOf: matchingItems.map(\.text))
                for matchingItem in matchingItems.reversed() {
                    document.sections[sectionIndex].lines.removeSubrange(matchingItem.range)
                }
            }
            self[file] = document
        }
        return removedTexts
    }

    // MARK: - Prompt context

    /// Most important first. "How I like answers" is always included whole.
    static let promptPriority: [BrainKind] = [
        .answerStyle, .howToDoThings, .project, .aboutMe, .likes, .mistakes, .tools, .skills, .words, .recent, .screen,
    ]

    static let promptHeader =
        "What you remember about this person, from their own memory files (they can read and edit these):"

    nonisolated private struct PromptSection {
        var title: String
        /// One entry per remembered item: its raw line(s).
        var itemBlocks: [String]
        var isNewestFirst: Bool
        var isAlwaysWhole: Bool
    }

    /// The memory text for a model call, at most `budgetCharacters` long.
    ///
    /// Sections go in whole, in priority order. A section that does not fit is
    /// shortened to its most recent whole bullets plus a "(N more)" line — a
    /// heading never appears without bullets and a bullet is never cut.
    /// The one exception to the budget: "How I like answers" is always included
    /// in full, because losing it is what makes an assistant forget how to talk
    /// to someone. Sections the person added by hand come last.
    func promptContext(budgetCharacters: Int = 2400) -> String {
        var promptSections: [PromptSection] = []
        var usedSectionIndexes: [BrainFile: Set<Int>] = [.profile: [], .volatile: []]

        func collect(file: BrainFile, sectionIndex: Int, kind: BrainKind?) {
            let document = self[file]
            let section = document.sections[sectionIndex]
            let itemBlocks = document.items(inSectionAt: sectionIndex).map { item in
                section.lines[item.range]
                    .map { Self.trimmingTrailingWhitespace($0) }
                    .joined(separator: "\n")
            }
            guard !itemBlocks.isEmpty else { return }
            promptSections.append(PromptSection(
                title: section.title,
                itemBlocks: itemBlocks,
                isNewestFirst: kind?.isNewestFirst ?? false,
                isAlwaysWhole: kind == .answerStyle
            ))
        }

        for kind in Self.promptPriority {
            guard let sectionIndex = self[kind.file].sectionIndex(titled: kind.sectionTitle) else { continue }
            usedSectionIndexes[kind.file, default: []].insert(sectionIndex)
            collect(file: kind.file, sectionIndex: sectionIndex, kind: kind)
        }
        for file in BrainFile.allCases {
            for sectionIndex in self[file].sections.indices
            where !usedSectionIndexes[file, default: []].contains(sectionIndex) {
                collect(file: file, sectionIndex: sectionIndex, kind: nil)
            }
        }

        let sectionSeparator = "\n\n"
        var renderedSections: [String] = []
        var usedCharacters = Self.promptHeader.count

        for promptSection in promptSections {
            let remainingCharacters = budgetCharacters - usedCharacters - sectionSeparator.count
            let wholeSection = (["## \(promptSection.title)"] + promptSection.itemBlocks).joined(separator: "\n")

            if promptSection.isAlwaysWhole || wholeSection.count <= remainingCharacters {
                renderedSections.append(wholeSection)
                usedCharacters += sectionSeparator.count + wholeSection.count
                continue
            }

            let totalItems = promptSection.itemBlocks.count
            for keptItemCount in stride(from: totalItems - 1, through: 1, by: -1) {
                let keptItemBlocks = promptSection.isNewestFirst
                    ? Array(promptSection.itemBlocks.prefix(keptItemCount))
                    : Array(promptSection.itemBlocks.suffix(keptItemCount))
                let shortenedSection = (
                    ["## \(promptSection.title)"] + keptItemBlocks + ["(\(totalItems - keptItemCount) more)"]
                ).joined(separator: "\n")
                if shortenedSection.count <= remainingCharacters {
                    renderedSections.append(shortenedSection)
                    usedCharacters += sectionSeparator.count + shortenedSection.count
                    break
                }
            }
        }

        guard !renderedSections.isEmpty else { return "" }
        return ([Self.promptHeader] + renderedSections).joined(separator: sectionSeparator)
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var trimmedLine = Substring(line)
        while let lastCharacter = trimmedLine.last, lastCharacter.isWhitespace {
            trimmedLine = trimmedLine.dropLast()
        }
        return String(trimmedLine)
    }
}
