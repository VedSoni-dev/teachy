//
//  AgentJobModel.swift
//  leanring-buddy
//
//  The plain-data half of agent jobs: status, plan, budget accounting, the
//  "same failure twice" rule, and turning a model's final answer into
//  sentences that sound right when spoken. Pure: no AppKit, no network.
//

import Foundation

enum AgentJobStatus: Equatable {
    case planning
    case running
    case waitingForConsent
    case done
    case failed(String)
    case stopped(String)

    var isFinished: Bool {
        switch self {
        case .done, .failed, .stopped: return true
        case .planning, .running, .waitingForConsent: return false
        }
    }

    var label: String {
        switch self {
        case .planning: return "Planning"
        case .running: return "Working"
        case .waitingForConsent: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Couldn't finish"
        case .stopped: return "Stopped"
        }
    }
}

struct AgentPlanStep: Equatable, Identifiable {
    enum State: String, Equatable { case pending, current, done }
    let id: Int
    var text: String
    var state: State
}

/// The plan the model states first and keeps up to date.
struct AgentPlan: Equatable {
    var steps: [AgentPlanStep] = []

    var currentStep: AgentPlanStep? { steps.first { $0.state == .current } }

    /// Reads the arguments of the `update_plan` tool. `current_step` is 1-based;
    /// steps before it are done, steps after it are pending. 0 or past the end = all done.
    static func parse(arguments: [String: Any]) -> (title: String?, plan: AgentPlan)? {
        let rawSteps = (arguments["steps"] as? [Any])?.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let object = item as? [String: Any] { return (object["text"] as? String) ?? (object["step"] as? String) ?? (object["title"] as? String) }
            return nil
        } ?? []
        let cleaned = rawSteps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
        guard !cleaned.isEmpty else { return nil }

        let current: Int
        if let number = arguments["current_step"] as? NSNumber { current = number.intValue } else if let text = arguments["current_step"] as? String, let number = Int(text) { current = number } else { current = 1 }

        let allDone = current <= 0 || current > cleaned.count
        let steps = cleaned.enumerated().map { offset, text -> AgentPlanStep in
            let number = offset + 1
            let state: AgentPlanStep.State = allDone ? .done : (number < current ? .done : (number == current ? .current : .pending))
            return AgentPlanStep(id: number, text: String(text.prefix(140)), state: state)
        }
        let title = (arguments["title"] as? String).map(AgentJobTitle.tidy)
        return (title?.isEmpty == false ? title : nil, AgentPlan(steps: steps))
    }

    mutating func markAllDone() {
        steps = steps.map { AgentPlanStep(id: $0.id, text: $0.text, state: .done) }
    }
}

enum AgentJobTitle {
    /// Two or three words, title-cased, no punctuation.
    static func tidy(_ raw: String) -> String {
        let words = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let fillerWords: Set<String> = ["please", "can", "could", "you", "the", "a", "an", "my", "me", "to", "for", "and", "of", "in", "on", "this", "that", "now", "do", "i", "want", "need", "would", "like", "hey", "teachy", "complete", "step"]

    /// A stand-in title from the request, until the model names the job.
    static func fallback(from request: String) -> String {
        let words = request
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .prefix(3)
        let title = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return title.isEmpty ? "Quick Job" : title
    }
}

// MARK: - Budget

/// How much a job may spend: model round trips and wall-clock time. Time spent
/// waiting on the user's yes or no does not count.
struct AgentJobBudget: Equatable {
    static let defaultMaxIterations = 25
    static let defaultMaxWallTime: TimeInterval = 10 * 60

    let maxIterations: Int
    let maxWallTime: TimeInterval
    private(set) var iterationsUsed = 0
    private(set) var startedAt: Date
    private(set) var pausedTotal: TimeInterval = 0
    private var pauseStartedAt: Date?

    enum Verdict: Equatable {
        case proceed
        /// One round trip left: tell the model to wrap up, with no tools.
        case lastTurn
        case exhausted(String)
    }

    init(maxIterations: Int = defaultMaxIterations, maxWallTime: TimeInterval = defaultMaxWallTime, startedAt: Date) {
        self.maxIterations = max(1, maxIterations)
        self.maxWallTime = max(1, maxWallTime)
        self.startedAt = startedAt
    }

    func elapsed(now: Date) -> TimeInterval {
        var paused = pausedTotal
        if let pauseStartedAt { paused += now.timeIntervalSince(pauseStartedAt) }
        return max(0, now.timeIntervalSince(startedAt) - paused)
    }

    var iterationsLeft: Int { max(0, maxIterations - iterationsUsed) }

    /// Ask before every model round trip.
    func check(now: Date) -> Verdict {
        if iterationsUsed >= maxIterations { return .exhausted("used all \(maxIterations) steps") }
        let timeLeft = maxWallTime - elapsed(now: now)
        if timeLeft <= 0 { return .exhausted("ran past \(Int(maxWallTime / 60)) minutes") }
        if iterationsUsed == maxIterations - 1 { return .lastTurn }
        return .proceed
    }

    mutating func recordIteration() { iterationsUsed += 1 }

    mutating func pause(now: Date) {
        if pauseStartedAt == nil { pauseStartedAt = now }
    }

    mutating func resume(now: Date) {
        guard let started = pauseStartedAt else { return }
        pausedTotal += max(0, now.timeIntervalSince(started))
        pauseStartedAt = nil
    }
}

// MARK: - Repeated failures

/// A tool error goes back to the model once. The same call failing the same way a
/// second time means that approach is dead: the model is told to change tack, and
/// the identical call is refused from then on.
struct ToolFailureTracker {
    enum Verdict: Equatable {
        case firstFailure
        case abortApproach
    }

    private var failures: [String: Int] = [:]
    private var deadCalls: Set<String> = []
    private(set) var refusedRepeats = 0
    /// After this many refused repeats the job gives up rather than loop.
    static let maxRefusedRepeats = 3

    static func signature(toolName: String, argumentsJSON: String) -> String {
        // Whitespace differences must not make two identical calls look different.
        let compact = argumentsJSON.filter { !$0.isWhitespace }
        return toolName + "|" + compact
    }

    func isDead(toolName: String, argumentsJSON: String) -> Bool {
        deadCalls.contains(Self.signature(toolName: toolName, argumentsJSON: argumentsJSON))
    }

    mutating func recordFailure(toolName: String, argumentsJSON: String, error: String) -> Verdict {
        let call = Self.signature(toolName: toolName, argumentsJSON: argumentsJSON)
        let key = call + "|" + error.prefix(200)
        failures[key, default: 0] += 1
        if failures[key, default: 0] >= 2 {
            deadCalls.insert(call)
            return .abortApproach
        }
        return .firstFailure
    }

    mutating func recordRefusedRepeat() { refusedRepeats += 1 }

    var shouldGiveUp: Bool { refusedRepeats >= Self.maxRefusedRepeats }
}

// MARK: - Speech

enum AgentSpeechFormatter {
    /// Turns a model's written answer into natural sentences for the voice:
    /// markdown, links and list markers go; capitals and identifiers stay.
    static func naturalSentences(_ text: String) -> String {
        var result = text

        // Code fences: keep what is inside, drop the fence lines.
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*```[A-Za-z0-9_+-]*[ \t]*\n?"#, with: "", options: .regularExpression)

        // [title](url) → title
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)

        // Bare URLs are not for reading aloud.
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)

        // Horizontal rules.
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*([-*_][ \t]*){3,}$\n?"#, with: "", options: .regularExpression)

        // Bullets and numbered items become plain lines.
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*[-*•][ \t]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*\d+[.)][ \t]+"#, with: "", options: .regularExpression)

        // Headings and block quotes.
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*#{1,6}[ \t]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*>[ \t]?"#, with: "", options: .regularExpression)

        // Emphasis: **bold**, __bold__, *italic*, _italic_ — only when the marker
        // hugs a word from outside. snake_case, file_name.txt, __init__ and 3*4 are left alone
        // (double underscores only count as bold around a phrase with a space in it).
        result = result.replacingOccurrences(of: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![A-Za-z0-9_])__(?=\S)([^_\n]*\s[^_\n]*)(?<=\S)__(?![A-Za-z0-9_])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![A-Za-z0-9*])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![A-Za-z0-9*])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![A-Za-z0-9_])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![A-Za-z0-9_])"#, with: "$1", options: .regularExpression)
        // Inline code ticks.
        result = result.replacingOccurrences(of: "`", with: "")

        // A line that ends without punctuation gets a full stop, so joined lines stay sentences.
        let lines = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sentences = lines.map { line -> String in
            guard let last = line.last else { return line }
            return ".!?:;,…".contains(last) ? line : line + "."
        }
        result = sentences.joined(separator: " ")

        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" +([.,!?;:])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tool ordering

enum AgentToolOrdering {
    /// The same list in the same order on every request (stable prompts cache; random order does not).
    static func sortedNames(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            return left == right ? lhs < rhs : left < right
        }
    }

    private static func rank(_ name: String) -> Int {
        if name == "update_plan" { return 0 }
        if name.hasPrefix("drive_") { return 1 }
        return 2
    }
}
