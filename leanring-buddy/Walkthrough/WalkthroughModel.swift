//
//  WalkthroughModel.swift
//  leanring-buddy / Walkthrough
//
//  The plain data of a walkthrough: the goal, the ordered steps, where the
//  person is, a running log of what was done and what failed, and the file it
//  is saved to so "continue" works after a pause or a relaunch.
//
//  Pure (Foundation + CoreGraphics). Tested by scripts/tests/run_walk_tests.sh.
//

import CoreGraphics
import Foundation

enum WalkthroughStepKind: String, Codable, CaseIterable {
    /// They click or choose one control.
    case click
    /// They type into one field.
    case type
    /// They wait for something to load or finish.
    case wait
    /// They only need to notice something.
    case look
}

/// A point in the planning screenshot, each axis 0–1000 (0,0 = top-left).
struct WalkthroughPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

/// The control a step is about: its accessibility role and label, plus where the
/// planner saw it (only when it was visible in the planning screenshot).
struct WalkthroughTarget: Codable, Equatable {
    /// A friendly role, as `AXSnapshotFormatter.friendlyRole` prints it ("button", "link", "text field").
    var role: String
    var label: String
    var point: WalkthroughPoint?
}

/// A check of `doneWhen` that can be answered from the accessibility snapshot alone.
struct WalkthroughCheck: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case appears, disappears, titleContains, focused, valueContains
    }

    var type: Kind
    var role: String?
    var label: String?
    var text: String?
}

struct WalkthroughStep: Codable, Equatable, Identifiable {
    var id: String
    /// One spoken sentence.
    var say: String
    var kind: WalkthroughStepKind
    var target: WalkthroughTarget?
    /// A short visible condition that is true once the step is done.
    var doneWhen: String
    var check: WalkthroughCheck?
    var failureCount: Int = 0

    init(id: String = WalkthroughStep.makeID(), say: String, kind: WalkthroughStepKind, target: WalkthroughTarget?, doneWhen: String, check: WalkthroughCheck? = nil, failureCount: Int = 0) {
        self.id = id
        self.say = say
        self.kind = kind
        self.target = target
        self.doneWhen = doneWhen
        self.check = check
        self.failureCount = failureCount
    }

    static func makeID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

enum WalkthroughStatus: String, Codable {
    /// Waiting for the planner (the first plan or a re-plan).
    case planning
    /// The step has been given; waiting for the person to do it.
    case waitingForUser
    /// Reading the screen before giving the next step.
    case checking
    case done
    /// Paused or ended early. Can be picked back up with "continue".
    case stopped
}

struct WalkthroughLogEntry: Codable, Equatable {
    enum Outcome: String, Codable {
        case done, skipped, failed, replanned, note
    }

    var at: Date
    /// 1-based, when the entry is about one step.
    var stepNumber: Int?
    var outcome: Outcome
    var text: String
}

struct WalkthroughSession: Codable, Equatable {
    static let maximumSteps = 15
    static let maximumReplans = 2
    /// Failures on one step before the remaining steps are planned again.
    static let failuresBeforeReplan = 2

    var id: String
    var goal: String
    var steps: [WalkthroughStep]
    var currentIndex: Int
    var log: [WalkthroughLogEntry]
    var status: WalkthroughStatus
    var replanCount: Int
    var appName: String
    var bundleID: String
    /// The display the plan was made on, in global CG coordinates (top-left origin).
    /// Fallback points are measured against it.
    var displayFrame: CGRect
    var createdAt: Date
    var updatedAt: Date

    init(goal: String, appName: String = "", bundleID: String = "", displayFrame: CGRect = .zero, now: Date = Date()) {
        self.id = UUID().uuidString.lowercased()
        self.goal = goal
        self.steps = []
        self.currentIndex = 0
        self.log = []
        self.status = .planning
        self.replanCount = 0
        self.appName = appName
        self.bundleID = bundleID
        self.displayFrame = displayFrame
        self.createdAt = now
        self.updatedAt = now
    }

    var currentStep: WalkthroughStep? {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }

    var isFinished: Bool { status == .done }

    /// A bare "continue" picks a paused walkthrough back up only this soon after it was last touched.
    static let casualResumeWindow: TimeInterval = 6 * 3600
    /// "Continue the walkthrough" works for this long.
    static let explicitResumeWindow: TimeInterval = 7 * 24 * 3600

    /// Whether "continue" should pick this walkthrough back up. `explicit` = they named the walkthrough.
    func isResumable(explicit: Bool, now: Date) -> Bool {
        guard status != .done else { return false }
        guard steps.isEmpty || currentIndex < steps.count else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age <= (explicit ? Self.explicitResumeWindow : Self.casualResumeWindow)
    }

    /// Says of every step that failed at least once. A re-plan must not repeat these word for word.
    var failedSays: [String] {
        var says = steps.filter { $0.failureCount > 0 }.map(\.say)
        // Steps replaced by an earlier re-plan are only in the log.
        for entry in log where entry.outcome == .failed {
            if let quoted = Self.quotedInstruction(in: entry.text), !says.contains(quoted) { says.append(quoted) }
        }
        return says
    }

    mutating func record(_ outcome: WalkthroughLogEntry.Outcome, _ text: String, stepNumber: Int? = nil, now: Date) {
        log.append(WalkthroughLogEntry(at: now, stepNumber: stepNumber, outcome: outcome, text: text))
        // The log is context for the planner, not an audit trail.
        if log.count > 80 { log.removeFirst(log.count - 80) }
        updatedAt = now
    }

    /// The log as the planner reads it, oldest first.
    var logText: String {
        guard !log.isEmpty else { return "(nothing yet)" }
        return log.map { entry in
            let prefix: String
            switch entry.outcome {
            case .done: prefix = "DONE"
            case .skipped: prefix = "ALREADY DONE"
            case .failed: prefix = "FAILED"
            case .replanned: prefix = "RE-PLANNED"
            case .note: prefix = "NOTE"
            }
            let step = entry.stepNumber.map { " step \($0)" } ?? ""
            return "- \(prefix)\(step): \(entry.text)"
        }.joined(separator: "\n")
    }

    /// For the voice prompt, so an unrelated question mid-walkthrough is answered in context.
    var promptSummary: String {
        guard status != .done else { return "" }
        var lines = ["WALKTHROUGH IN PROGRESS — goal: \"\(goal)\"."]
        if let step = currentStep {
            lines.append("They are on step \(currentIndex + 1) of \(steps.count): \"\(step.say)\" (done when: \(step.doneWhen)).")
        } else if status == .planning {
            lines.append("The steps are being worked out right now.")
        }
        if status == .stopped { lines.append("It is paused; they can say \"continue\" to pick it back up.") }
        lines.append("Teachy advances the steps by itself when they click the ringed control or say \"next\". Answer their question briefly; do not re-list the steps and do not add [WALK:] again for the same goal.")
        return lines.joined(separator: "\n")
    }

    /// Failed log entries are written as `"<say>" — <reason>`.
    static func failedLogText(say: String, reason: String) -> String {
        "\"\(say)\" — \(reason)"
    }

    private static func quotedInstruction(in text: String) -> String? {
        guard text.hasPrefix("\""), let end = text.range(of: "\" — ") else { return nil }
        return String(text[text.index(after: text.startIndex)..<end.lowerBound])
    }
}

// MARK: - Saving

/// Reads and writes `current.json` in one folder. The app uses `~/.teachy/walkthroughs`;
/// tests pass a temporary folder.
struct WalkthroughStore {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teachy/walkthroughs", isDirectory: true)
    }

    init(directory: URL = WalkthroughStore.defaultDirectory) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("current.json") }

    func save(_ session: WalkthroughSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: fileURL, options: .atomic)
    }

    func load() -> WalkthroughSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WalkthroughSession.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - What the person said

enum WalkthroughVoiceCommand: Equatable {
    case next
    case back
    case stop
    case repeatStep
    case stuck
    /// Pick a paused walkthrough back up. `explicit` when they named the walkthrough.
    case resume(explicit: Bool)
}

/// Decides whether something the person said is a walkthrough command. Deliberately
/// narrow: only short utterances that are nothing but the command, so a real question
/// ("what does done mean here?") still goes to the normal voice turn.
enum WalkthroughCommandParser {
    enum Context {
        /// A walkthrough is running.
        case active
        /// None is running, but one may be saved.
        case paused
    }

    private static let fillers: Set<String> = [
        "ok", "okay", "alright", "please", "teachy", "hey", "um", "uh", "yeah", "yes", "yep", "now", "so", "and", "cool", "great", "thanks", "then"
    ]

    private static let nextPhrases: Set<String> = [
        "next", "next step", "next one", "done", "im done", "i am done", "did it", "i did it", "i did that", "got it",
        "continue", "keep going", "go on", "carry on", "whats next", "what is next", "finished", "im finished", "thats done", "that is done",
        "its done", "move on", "skip", "skip it", "skip this", "skip this step", "skip that", "go ahead", "ready", "im ready",
        "what next", "all done", "done with that", "i clicked it", "clicked it", "clicked"
    ]
    private static let backPhrases: Set<String> = [
        "back", "go back", "previous", "previous step", "back one", "go back a step", "back a step", "go back one", "go back one step",
        "last step", "the step before", "back up", "undo that step"
    ]
    private static let stopPhrases: Set<String> = [
        "stop", "stop it", "stop the walkthrough", "stop walkthrough", "stop guiding", "stop guiding me", "cancel", "cancel that", "cancel the walkthrough",
        "quit", "exit", "end the walkthrough", "end walkthrough", "never mind", "nevermind", "pause", "pause it", "pause the walkthrough",
        "thats enough", "that is enough", "ill take it from here", "i will take it from here", "ive got it from here", "i got it from here", "forget it"
    ]
    private static let repeatPhrases: Set<String> = [
        "repeat", "repeat that", "repeat the step", "say that again", "say it again", "again", "what was that", "come again", "one more time",
        "pardon", "sorry what", "what do i do", "what now", "what do i do now", "what was the step", "tell me again", "where was i", "where were we"
    ]
    private static let stuckPhrases: Set<String> = [
        "im stuck", "i am stuck", "stuck", "help", "help me", "im lost", "i am lost", "im confused", "i am confused",
        "it didnt work", "that didnt work", "didnt work", "it doesnt work", "nothing happened", "nothing is happening",
        "i cant find it", "i cant see it", "i dont see it", "i dont see that", "its not there", "it is not there", "thats not there",
        "where is it", "where is that", "i cant find that", "theres no such button", "there is no such button", "wrong", "thats wrong"
    ]
    private static let stuckPrefixes: [String] = [
        "im stuck", "i am stuck", "i cant find", "i cant see", "i dont see", "it didnt work", "that didnt work", "theres no", "there is no", "i dont have"
    ]
    private static let resumePhrases: Set<String> = [
        "continue", "resume", "keep going", "carry on", "lets continue", "let us continue", "pick up where we left off", "pick it back up",
        "continue where we left off", "where were we", "lets keep going", "back to it", "lets pick it back up"
    ]
    private static let explicitResumePhrases: Set<String> = [
        "continue the walkthrough", "resume the walkthrough", "continue walkthrough", "resume walkthrough", "back to the walkthrough",
        "continue the steps", "continue the guide", "resume the guide", "continue with the walkthrough", "lets continue the walkthrough",
        "pick the walkthrough back up", "continue walking me through it", "keep walking me through it"
    ]

    /// Lowercased words with punctuation removed and filler words trimmed from both ends.
    static func normalize(_ transcript: String) -> String {
        let lowered = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        var words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        while let first = words.first, fillers.contains(first), words.count > 1 { words.removeFirst() }
        while let last = words.last, fillers.contains(last), words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func parse(_ transcript: String, context: Context) -> WalkthroughVoiceCommand? {
        let text = normalize(transcript)
        guard !text.isEmpty else { return nil }
        let wordCount = text.split(separator: " ").count

        switch context {
        case .paused:
            if explicitResumePhrases.contains(text) { return .resume(explicit: true) }
            if resumePhrases.contains(text) { return .resume(explicit: false) }
            return nil
        case .active:
            if explicitResumePhrases.contains(text) { return .next }
            if stopPhrases.contains(text) { return .stop }
            if nextPhrases.contains(text) { return .next }
            if backPhrases.contains(text) { return .back }
            if repeatPhrases.contains(text) { return .repeatStep }
            if stuckPhrases.contains(text) { return .stuck }
            if wordCount <= 8, stuckPrefixes.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) { return .stuck }
            return nil
        }
    }
}
