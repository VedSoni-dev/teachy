//
//  BrainMigration.swift
//  leanring-buddy
//
//  One-time import of what Teachy already knew into the Brain files.
//
//  Before the Brain there were three overlapping stores:
//    1. `~/.teachy/engine-state.json` — `learnerModel.datedPersonalFacts`,
//       `learnerModel.workflowSignals` and `projects`
//    2. UserDefaults `teachyGlobalLearnerProfile` — knows / confusedBy
//    3. UserDefaults `teachyCourseLearnerProfileByCourseID` — the same, per course
//
//  The import only reads them. The old stores are left exactly as they are, so
//  the course coach keeps working and nothing is lost if the import is wrong.
//  It reads the raw JSON with its own small lenient decoders (not the app's
//  model types) so it stays pure, testable, and safe when a file is missing,
//  half-written or from an older version.
//

import Foundation

nonisolated enum BrainMigration {
    static let didMigrateDefaultsKey = "teachyBrainDidImportLegacyMemoryV1"

    // These mirror the private keys in `CoursesManager`.
    static let globalLearnerProfileDefaultsKey = "teachyGlobalLearnerProfile"
    static let courseLearnerProfilesDefaultsKey = "teachyCourseLearnerProfileByCourseID"

    nonisolated struct Note: Equatable, Sendable {
        var kind: BrainKind
        var note: String
        var date: Date
    }

    // MARK: - Running it

    /// Imports the old stores once. Safe to call on every launch and when none
    /// of the old stores exist. The flag is only set after the notes were
    /// written, so a failed write is retried next launch.
    static func runIfNeeded(
        into store: BrainStore,
        defaults: UserDefaults = .standard,
        engineStateFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teachy/engine-state.json"),
        now: Date = Date()
    ) {
        guard !defaults.bool(forKey: didMigrateDefaultsKey) else { return }

        let notes = plan(
            engineStateJSON: try? Data(contentsOf: engineStateFileURL),
            globalLearnerProfileJSON: defaults.data(forKey: globalLearnerProfileDefaultsKey),
            courseLearnerProfilesJSON: defaults.data(forKey: courseLearnerProfilesDefaultsKey),
            now: now
        )
        if !notes.isEmpty {
            guard store.rememberAll(notes.map { (note: $0.note, kind: $0.kind, date: $0.date) }) else { return }
        }
        defaults.set(true, forKey: didMigrateDefaultsKey)
    }

    // MARK: - Mapping (pure)

    /// Turns the old stores' JSON into Brain notes, in the order they should be remembered.
    static func plan(
        engineStateJSON: Data?,
        globalLearnerProfileJSON: Data?,
        courseLearnerProfilesJSON: Data?,
        now: Date = Date()
    ) -> [Note] {
        var notes: [Note] = []
        let decoder = JSONDecoder()

        let engineState = engineStateJSON.flatMap { try? decoder.decode(LegacyEngineState.self, from: $0) }
        let learnerModel = engineState?.learnerModel

        // Personal facts → About me.
        for fact in learnerModel?.facts ?? [] {
            notes.append(Note(kind: .aboutMe, note: fact.text, date: fact.capturedAt ?? now))
        }

        // Apps they were seen working in → Tools (app name only, never the window title).
        var seenAppNames = Set<String>()
        for signal in learnerModel?.workflowSignals ?? [] {
            let appName = (signal.text.components(separatedBy: " — ").first ?? signal.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty, seenAppNames.insert(appName.lowercased()).inserted else { continue }
            notes.append(Note(kind: .tools, note: appName, date: signal.capturedAt ?? now))
        }

        // Projects → Working on now (active, paused) or Recently (shipped). Abandoned ones are dropped.
        let projectsOldestFirst = (engineState?.projects ?? []).sorted {
            ($0.lastWorkedAt ?? .distantPast) < ($1.lastWorkedAt ?? .distantPast)
        }
        for project in projectsOldestFirst {
            let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            switch project.status ?? "active" {
            case "active", "paused":
                var details = [project.status ?? "active"]
                if let deployedURL = project.deployedURL, !deployedURL.isEmpty { details.append(deployedURL) }
                if let stepCount = project.stepCount, stepCount > 0, let currentStepIndex = project.currentStepIndex {
                    details.append("step \(min(currentStepIndex + 1, stepCount)) of \(stepCount)")
                }
                if let goal = project.goalDescription, !goal.isEmpty {
                    details.append("goal: \(shortened(goal, to: 120))")
                }
                if let lastJournalEntry = project.stepJournal.last {
                    details.append("last: \(shortened(lastJournalEntry.text, to: 100))")
                }
                notes.append(Note(
                    kind: .project,
                    note: "\(title): \(details.joined(separator: "; "))",
                    date: project.lastWorkedAt ?? now
                ))
            case "shipped":
                let link = project.deployedURL.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
                notes.append(Note(kind: .recent, note: "Shipped \(title)\(link)", date: project.lastWorkedAt ?? now))
            default:
                continue
            }
        }

        // Course profiles → Skills and Things that keep catching me.
        var profiles: [LegacyLearnerProfile] = []
        if let globalProfile = globalLearnerProfileJSON.flatMap({
            try? decoder.decode(LegacyLearnerProfile.self, from: $0)
        }) {
            profiles.append(globalProfile)
        }
        if let courseProfiles = courseLearnerProfilesJSON.flatMap({
            try? decoder.decode([String: LegacyLearnerProfile].self, from: $0)
        }) {
            profiles.append(contentsOf: courseProfiles.sorted { $0.key < $1.key }.map(\.value))
        }

        for knownConcept in uniqueInOrder(profiles.flatMap(\.knows)) {
            notes.append(Note(kind: .skills, note: "Knows \(knownConcept)", date: now))
        }
        let knownConceptKeys = Set(profiles.flatMap(\.knows).map(BrainText.normalized))
        for confusingConcept in uniqueInOrder(profiles.flatMap(\.confusedBy))
        where !knownConceptKeys.contains(BrainText.normalized(confusingConcept)) {
            notes.append(Note(kind: .mistakes, note: "Confused by \(confusingConcept)", date: now))
        }

        // Hints vs. "just do it" → How I like answers.
        let prefersHints = learnerModel?.prefersHintsOverAutomation
            ?? profiles.compactMap(\.prefersHintsOverAutomation).first
        if let prefersHints {
            notes.append(Note(
                kind: .answerStyle,
                note: prefersHints
                    ? "Help style: give me hints and let me try before showing the answer"
                    : "Help style: just show me or do it for me",
                date: now
            ))
        }

        return notes
    }

    private static func shortened(_ text: String, to maximumCharacters: Int) -> String {
        let singleLine = BrainText.singleLineNote(text, maximumCharacters: maximumCharacters)
        // A ";" would read as the next field of the project line.
        return singleLine.replacingOccurrences(of: ";", with: ",")
    }

    private static func uniqueInOrder(_ texts: [String]) -> [String] {
        var seenKeys = Set<String>()
        return texts.compactMap { text in
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = BrainText.normalized(trimmedText)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { return nil }
            return trimmedText
        }
    }

    // MARK: - Lenient views of the old JSON

    /// Dates in the old files are JSONEncoder's default: seconds since 2001-01-01.
    nonisolated private struct LegacyFact: Decodable {
        var text: String
        var capturedAt: Date?

        private enum CodingKeys: String, CodingKey { case text, capturedAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            capturedAt = try? container.decodeIfPresent(Date.self, forKey: .capturedAt)
        }

        init(text: String) {
            self.text = text
            self.capturedAt = nil
        }
    }

    nonisolated private struct LegacyLearnerModel: Decodable {
        var facts: [LegacyFact]
        var workflowSignals: [LegacyFact]
        var prefersHintsOverAutomation: Bool?

        private enum CodingKeys: String, CodingKey {
            case datedPersonalFacts, personalFacts, workflowSignals, prefersHintsOverAutomation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let datedFacts = try? container.decodeIfPresent([LegacyFact].self, forKey: .datedPersonalFacts) {
                facts = datedFacts
            } else {
                // Oldest format: a flat list of strings.
                let flatFacts = (try? container.decodeIfPresent([String].self, forKey: .personalFacts)) ?? []
                facts = flatFacts.map { LegacyFact(text: $0) }
            }
            workflowSignals = (try? container.decodeIfPresent([LegacyFact].self, forKey: .workflowSignals)) ?? []
            prefersHintsOverAutomation = try? container.decodeIfPresent(Bool.self, forKey: .prefersHintsOverAutomation)
        }
    }

    nonisolated private struct LegacyProject: Decodable {
        var title: String
        var goalDescription: String?
        var status: String?
        var deployedURL: String?
        var currentStepIndex: Int?
        var stepCount: Int?
        var stepJournal: [LegacyFact]
        var lastWorkedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case title, goalDescription, status, deployedURL, currentStepIndex, steps, stepJournal, lastWorkedAt
        }

        /// Stands in for a course goal: we only need to count them.
        nonisolated private struct AnyStep: Decodable {
            init(from decoder: Decoder) throws {}
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            goalDescription = try? container.decodeIfPresent(String.self, forKey: .goalDescription)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            deployedURL = try? container.decodeIfPresent(String.self, forKey: .deployedURL)
            currentStepIndex = try? container.decodeIfPresent(Int.self, forKey: .currentStepIndex)
            stepCount = (try? container.decodeIfPresent([AnyStep].self, forKey: .steps))?.count
            stepJournal = (try? container.decodeIfPresent([LegacyFact].self, forKey: .stepJournal)) ?? []
            lastWorkedAt = try? container.decodeIfPresent(Date.self, forKey: .lastWorkedAt)
        }
    }

    nonisolated private struct LegacyEngineState: Decodable {
        var learnerModel: LegacyLearnerModel?
        var projects: [LegacyProject]

        private enum CodingKeys: String, CodingKey { case learnerModel, projects }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            learnerModel = try? container.decodeIfPresent(LegacyLearnerModel.self, forKey: .learnerModel)
            projects = (try? container.decodeIfPresent([LegacyProject].self, forKey: .projects)) ?? []
        }
    }

    nonisolated private struct LegacyLearnerProfile: Decodable {
        var knows: [String]
        var confusedBy: [String]
        var prefersHintsOverAutomation: Bool?

        private enum CodingKeys: String, CodingKey { case knows, confusedBy, prefersHintsOverAutomation }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            knows = (try? container.decodeIfPresent([String].self, forKey: .knows)) ?? []
            confusedBy = (try? container.decodeIfPresent([String].self, forKey: .confusedBy)) ?? []
            prefersHintsOverAutomation = try? container.decodeIfPresent(Bool.self, forKey: .prefersHintsOverAutomation)
        }
    }
}
