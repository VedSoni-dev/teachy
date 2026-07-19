//
//  ClickyCourse.swift
//  leanring-buddy
//
//  Goal-based Teachy Courses — durable learning outcomes, no hardcoded UI.
//  An auto-prompter feeds natural asks into the normal companion vision path
//  so courses still work when apps redesign.
//

import Foundation

// MARK: - Artifact

struct CourseArtifactSpec: Codable, Equatable {
    /// What kind of thing is being built — e.g. "githubRepo", "document", "video".
    let kind: String
    /// SF Symbol name for the artifact type.
    let icon: String
    /// Plain-language description of the starting state before the course begins.
    let initialState: String
    /// Plain-language description of what "done" looks like.
    let finalState: String
    /// Text shown in the HUD before any progress has been made.
    let previewIfNoProgress: String
}

struct CourseArtifactSnapshot: Codable, Equatable {
    /// The goal that produced this snapshot.
    let goalID: String
    /// Plain-language description of what the artifact looks like after this goal.
    let stateDescription: String
    /// When this snapshot was captured.
    let capturedAt: Date
}

// MARK: - Interactive lesson steps

/// An inline multiple-choice question rendered directly in the lesson UI —
/// no vision call, no off-screen action. First proof of the "interactive
/// widget" architecture (see `CourseLessonPhase.interactiveChoice`).
struct CourseInteractiveMultipleChoice: Codable, Equatable {
    let question: String
    let options: [String]
    let correctAnswerIndex: Int
    let explanation: String?
}

/// A self-attested checklist rendered directly in the lesson UI — no right/wrong
/// concept, purely a memory aid the learner checks off before moving on. Sibling
/// of `CourseInteractiveMultipleChoice`; see `CourseLessonPhase.interactiveChecklist`.
struct CourseInteractiveChecklist: Codable, Equatable {
    var prompt: String
    var items: [String]
}

/// An inline fill-in-the-blank question rendered directly in the lesson UI —
/// local exact-match verification (trimmed/lowercased), no vision call, no LLM
/// classifier. Sibling of `CourseInteractiveMultipleChoice`; see
/// `CourseLessonPhase.interactiveFillInBlank`.
struct CourseInteractiveFillInBlank: Codable, Equatable {
    var prompt: String
    var acceptableAnswers: [String]
    var explanation: String?
}

// MARK: - Course catalog

struct ClickyCourse: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let description: String
    let iconSystemName: String
    let estimatedMinutes: Int
    /// Soft start only (e.g. open a homepage). Not a UI layout contract.
    let startURL: String?
    /// Optional long-form intro (HLS/mp4) played beside Teachy once when the course starts.
    /// Prefer `teacherVideoURL` in new authoring; both keys work when decoding.
    let introVideoURL: String?
    /// Preferred authoring key for the course intro clip (aliases `introVideoURL`).
    let teacherVideoURL: String?
    /// Optional credit shown on the beside-cursor player (e.g. the course author's name).
    let teacherName: String?
    /// What the learner should be able to do by the end — shown to the model as north star.
    let learningOutcomes: [String]
    /// Ordered goals. Each is taught via a natural auto-prompt into companion vision.
    let goals: [CourseLearningGoal]
    /// Optional artifact spec — the thing being built across the course.
    let artifact: CourseArtifactSpec?
    /// Optional learning path — courses that build on each other (like a Khan Academy unit).
    let trackID: String?
    let trackTitle: String?
    /// 1-based order within the track.
    let trackOrder: Int?
    /// Soft prerequisites — suggested prior courses; not a hard lock.
    let prerequisiteCourseIDs: [String]?

    /// Alias so existing session/progress code can keep saying "steps".
    var steps: [CourseLearningGoal] { goals }
    var stepCount: Int { goals.count }

    /// Course-level teacher clip — `teacherVideoURL` wins, then legacy `introVideoURL`.
    var resolvedCourseTeacherVideoURL: String? {
        Self.firstNonEmptyVideoURL(teacherVideoURL, introVideoURL)
    }

    /// True when this path ships at least one beside-cursor teacher clip.
    var hasTeacherVideos: Bool {
        if resolvedCourseTeacherVideoURL != nil { return true }
        return goals.contains { $0.resolvedTeacherVideoURL != nil }
    }

    var trackPartLabel: String? {
        guard let trackTitle, let trackOrder else { return nil }
        return "\(trackTitle) · Part \(trackOrder)"
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        description: String,
        iconSystemName: String,
        estimatedMinutes: Int,
        startURL: String?,
        introVideoURL: String? = nil,
        teacherVideoURL: String? = nil,
        teacherName: String? = nil,
        learningOutcomes: [String],
        goals: [CourseLearningGoal],
        artifact: CourseArtifactSpec? = nil,
        trackID: String? = nil,
        trackTitle: String? = nil,
        trackOrder: Int? = nil,
        prerequisiteCourseIDs: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.iconSystemName = iconSystemName
        self.estimatedMinutes = estimatedMinutes
        self.startURL = startURL
        self.introVideoURL = introVideoURL
        self.teacherVideoURL = teacherVideoURL
        self.teacherName = teacherName
        self.learningOutcomes = learningOutcomes
        self.goals = goals
        self.artifact = artifact
        self.trackID = trackID
        self.trackTitle = trackTitle
        self.trackOrder = trackOrder
        self.prerequisiteCourseIDs = prerequisiteCourseIDs
    }

    static func firstNonEmptyVideoURL(_ candidates: String?...) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// One durable learning goal — never encodes button names, grid cells, or layout.
struct CourseLearningGoal: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    /// What success looks like in plain language (survives UI redesigns).
    let goal: String
    /// Auto-prompt phrased like something a user would ask Teachy.
    let coachAsk: String
    /// Optional natural-language done check for vision verify.
    let doneWhen: String?
    /// Plain-language description of what this goal changes about the artifact.
    let artifactDelta: String?
    /// If set, jumping to this remediation goal on repeated failures before returning.
    let remediationGoalID: String?
    let tips: [String]?
    /// Optional part clip (HLS/mp4) played beside Teachy before coaching this goal.
    /// Prefer `teacherVideoURL` in new authoring; both keys work when decoding.
    let introVideoURL: String?
    /// Preferred authoring key for this part’s teacher clip (aliases `introVideoURL`).
    let teacherVideoURL: String?
    /// Optional credit override for this part (falls back to the course `teacherName`).
    let teacherName: String?
    /// Optional short notes / bullets of what the teacher said in the part clip — injected after playback.
    let teacherVideoNotes: String?
    /// Pedagogy brief: concepts, pitfalls, success examples, teach-back.
    let teachingContext: CourseTeachingContext?
    /// How willing Teachy should be to drive the Mac on this goal.
    let toolPolicy: CourseToolPolicy?
    /// One-line learning outcome shown in the HUD next to the goal title.
    let outcome: String?
    /// If set, this goal is rendered as an inline interactive widget (e.g. multiple
    /// choice) instead of the video → coach → vision-verify flow. A goal is
    /// "interactive" purely by having this set — `goal`/`coachAsk` stay required but
    /// become short authoring context rather than driving the lesson loop.
    let interactiveMultipleChoice: CourseInteractiveMultipleChoice?
    /// Self-attested checklist widget — sibling of `interactiveMultipleChoice`.
    /// A goal has at most one interactive type set.
    let interactiveChecklist: CourseInteractiveChecklist?
    /// Fill-in-the-blank widget — sibling of `interactiveMultipleChoice`.
    /// A goal has at most one interactive type set.
    let interactiveFillInBlank: CourseInteractiveFillInBlank?

    /// Back-compat names used by session/HUD copy.
    var instruction: String { goal }
    var completionCriteria: String { doneWhen ?? goal }

    /// Part clip URL — `teacherVideoURL` wins, then legacy `introVideoURL`.
    var resolvedTeacherVideoURL: String? {
        ClickyCourse.firstNonEmptyVideoURL(teacherVideoURL, introVideoURL)
    }

    /// Effective tool policy — goal override or default pointing-first.
    var resolvedToolPolicy: CourseToolPolicy {
        toolPolicy ?? .preferPointing
    }

    /// Autonomy-adjusted tool policy — the anti-dependency mechanic in course mode.
    /// A goal authored `canDoForThem` behaves as `helpWhenStuck` for a proficient
    /// learner, `helpWhenStuck` as `preferPointing`, and (only at `.handsOff`)
    /// `preferPointing` as `pointOnly`.
    ///
    /// INVARIANT — tighten only: this NEVER loosens the author's policy (it only
    /// ever makes Teachy less willing to act than the author allowed), and it NEVER
    /// touches the explicit spoken "do it for me" path — LessonPlayer's `doItForMe`
    /// action keeps building its prompt from the AUTHOR's `resolvedToolPolicy`, not
    /// this tightened one, so asking for help always still works.
    func resolvedToolPolicy(autonomyLevel: CoachAutonomyLevel) -> CourseToolPolicy {
        let basePolicy = resolvedToolPolicy

        // doForThem / doTogether learners get the author's policy unchanged.
        guard autonomyLevel >= .watchThem else { return basePolicy }

        // watchThem and above: step the policy one notch more restrictive.
        var tightenedPolicy: CourseToolPolicy
        switch basePolicy {
        case .canDoForThem:
            tightenedPolicy = .helpWhenStuck
        case .helpWhenStuck:
            tightenedPolicy = .preferPointing
        case .preferPointing, .pointOnly:
            tightenedPolicy = basePolicy
        }

        // handsOff: additionally collapse preferPointing down to pointOnly.
        if autonomyLevel == .handsOff, tightenedPolicy == .preferPointing {
            tightenedPolicy = .pointOnly
        }

        return tightenedPolicy
    }

    /// Whether this goal should run a teach-back after vision success.
    var shouldRunTeachBack: Bool {
        teachingContext?.skipTeachBack != true
    }

    init(
        id: String,
        title: String,
        goal: String,
        coachAsk: String,
        doneWhen: String? = nil,
        artifactDelta: String? = nil,
        remediationGoalID: String? = nil,
        tips: [String]? = nil,
        introVideoURL: String? = nil,
        teacherVideoURL: String? = nil,
        teacherName: String? = nil,
        teacherVideoNotes: String? = nil,
        teachingContext: CourseTeachingContext? = nil,
        toolPolicy: CourseToolPolicy? = nil,
        outcome: String? = nil,
        interactiveMultipleChoice: CourseInteractiveMultipleChoice? = nil,
        interactiveChecklist: CourseInteractiveChecklist? = nil,
        interactiveFillInBlank: CourseInteractiveFillInBlank? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.coachAsk = coachAsk
        self.doneWhen = doneWhen
        self.artifactDelta = artifactDelta
        self.remediationGoalID = remediationGoalID
        self.tips = tips
        self.introVideoURL = introVideoURL
        self.teacherVideoURL = teacherVideoURL
        self.teacherName = teacherName
        self.teacherVideoNotes = teacherVideoNotes
        self.teachingContext = teachingContext
        self.toolPolicy = toolPolicy
        self.outcome = outcome
        self.interactiveMultipleChoice = interactiveMultipleChoice
        self.interactiveChecklist = interactiveChecklist
        self.interactiveFillInBlank = interactiveFillInBlank
    }

    /// Credit line for the beside-cursor player.
    func resolvedTeacherCredit(courseTeacherName: String?) -> String? {
        let partName = teacherName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !partName.isEmpty { return partName }
        let courseName = courseTeacherName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !courseName.isEmpty { return courseName }
        return nil
    }

    /// Prompt block for the lesson brief + video notes.
    ///
    /// `autonomyLevel` is the anti-dependency hook: when non-nil, the TOOL POLICY
    /// line uses the autonomy-TIGHTENED policy instead of the author's, and a short
    /// autonomy guidance line is appended so the coach's tone matches. Nil (the
    /// default, and what the explicit "do it for me" path passes) keeps the author's
    /// policy verbatim — tighten only, never loosen, never refuse an explicit ask.
    func teachingBriefPromptSection(
        activeTeacherVideoNotes: String?,
        autonomyLevel: CoachAutonomyLevel? = nil
    ) -> String {
        var blocks: [String] = []

        if let why = teachingContext?.whyItMatters?.trimmingCharacters(in: .whitespacesAndNewlines),
           !why.isEmpty {
            blocks.append("Why it matters: \(why)")
        }
        if let concepts = teachingContext?.concepts, !concepts.isEmpty {
            blocks.append("Concepts to land: \(concepts.joined(separator: "; "))")
        }
        if let mistakes = teachingContext?.commonMistakes, !mistakes.isEmpty {
            blocks.append("Watch for: \(mistakes.joined(separator: "; "))")
        }
        if let examples = teachingContext?.successExamples, !examples.isEmpty {
            blocks.append("Success looks like: \(examples.joined(separator: "; "))")
        }
        // Tighten-only: when an autonomy level is supplied, use the adjusted policy
        // (never looser than the author's). The explicit "do it for me" path passes
        // nil here so it always sees the author's original policy.
        if let autonomyLevel {
            blocks.append(resolvedToolPolicy(autonomyLevel: autonomyLevel).coachInstructions)
            blocks.append(CoachAutonomy.promptGuidance(for: autonomyLevel))
        } else {
            blocks.append(resolvedToolPolicy.coachInstructions)
        }

        let notes = ClickyCourse.firstNonEmptyVideoURL(activeTeacherVideoNotes, teacherVideoNotes)
        if let notes {
            blocks.append("Teacher clip notes (reinforce — don’t re-lecture the whole video):\n\(notes)")
        }

        guard !blocks.isEmpty else { return "" }
        return """

        LESSON BRIEF for this goal:
        \(blocks.joined(separator: "\n"))
        """
    }
}

// MARK: - Legacy typealiases (session / HUD still say "step")

typealias ClickyCourseStep = CourseLearningGoal

struct CourseCatalogSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let courses: [ClickyCourse]
}

/// Soft chalk celebration when a course goal verifies.
struct CourseSuccessCelebration: Equatable {
    let screenPoint: CGPoint
    let displayFrame: CGRect?
}

/// Shown in Learn after a path completes — prove the outcome.
struct CourseCompletionCelebration: Equatable, Identifiable {
    var id: String { courseID }
    let courseID: String
    let title: String
    let message: String
    let recap: String
    let nextSteps: [String]
}

/// Suggested prompts for First Win blank-chat avoidance.
enum TeachyPromptChips {
    static let firstWinPromptChips: [String] = [
        "Make a single HTML tip calculator",
        "Make a hello page with my name on it",
        "Make a simple to-do list webpage",
    ]

    /// Intake chips — what do they already know? Drives skip-ahead.
    static let placementChips: [String] = [
        "I'm brand new — explain everything",
        "I've used ChatGPT or Claude before",
        "I already build stuff with AI",
    ]

    static func chips(forGoalID goalID: String) -> [String] {
        switch goalID {
        case "first-win-prompt", "ai-clear-ask":
            return firstWinPromptChips
        default:
            return []
        }
    }
}

/// Extracts and strips `[REMEMBER: the fact]` tags from any coach response text —
/// shared by course lesson turns (`CourseCoachMessageParts`, below) and the
/// free-form companion voice path (`CompanionManager.sendCompanionChatResponse`).
/// The tag must never reach the learner spoken or displayed; the extracted facts
/// are fed into `TeachyEngine.processEvent(.personalFactShared)`.
enum CoachRememberTagParser {
    /// Returns the personal facts tagged in `text`, in order of appearance, with
    /// every `[REMEMBER: ...]` occurrence removed from `cleanedText` (not just the first —
    /// someone can share two facts in one turn).
    static func extractFactsAndStrip(from text: String) -> (cleanedText: String, facts: [String]) {
        guard let regex = try? NSRegularExpression(pattern: "\\[REMEMBER:\\s*([^\\]]+)\\]", options: [.caseInsensitive]) else {
            return (text, [])
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let facts = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2, let contentRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, facts)
    }
}

/// Parsed coach line — info (explain) vs todo (do this now).
struct CourseCoachMessageParts: Equatable {
    let infoText: String?
    let todoText: String?
    /// Clean text for TTS / history (tags stripped, parts joined).
    let spokenText: String
    /// Personal facts the coach tagged `[REMEMBER: …]` in this turn — stripped
    /// from `spokenText`/`infoText`/`todoText`, never shown or spoken to the
    /// learner. Fed into `TeachyEngine.processEvent(.personalFactShared)`.
    let rememberedFacts: [String]

    var hasStructuredParts: Bool { infoText != nil || todoText != nil }

    static func parse(from rawResponse: String) -> CourseCoachMessageParts {
        let trimmedRaw = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract REMEMBER facts before any other parsing, then strip them out
        // so they never leak into INFO/TODO extraction or the spoken fallback.
        let (trimmed, rememberedFacts) = CoachRememberTagParser.extractFactsAndStrip(from: trimmedRaw)

        let info = extractTaggedSection(named: "INFO", from: trimmed)
            ?? extractPrefixedLine(named: "INFO", from: trimmed)
        let todo = extractTaggedSection(named: "TODO", from: trimmed)
            ?? extractPrefixedLine(named: "TODO", from: trimmed)

        if info == nil, todo == nil {
            let cleaned = stripCoachTags(from: trimmed)
            return CourseCoachMessageParts(
                infoText: nil,
                todoText: cleaned.isEmpty ? nil : cleaned,
                spokenText: cleaned,
                rememberedFacts: rememberedFacts
            )
        }

        var spokenPieces: [String] = []
        if let info, !info.isEmpty { spokenPieces.append(info) }
        if let todo, !todo.isEmpty { spokenPieces.append(todo) }
        let spoken = spokenPieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return CourseCoachMessageParts(
            infoText: info?.nilIfEmpty,
            todoText: todo?.nilIfEmpty,
            spokenText: spoken.isEmpty ? stripCoachTags(from: trimmed) : spoken,
            rememberedFacts: rememberedFacts
        )
    }

    private static func extractTaggedSection(named name: String, from text: String) -> String? {
        let pattern = "\\[\(name)\\]([\\s\\S]*?)\\[/\(name)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let contentRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractPrefixedLine(named name: String, from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixes = ["[\(name)]", "\(name):", "\(name) -"]
            for prefix in prefixes {
                if stripped.lowercased().hasPrefix(prefix.lowercased()) {
                    return String(stripped.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func stripCoachTags(from text: String) -> String {
        // Defense-in-depth: REMEMBER tags are already stripped in `parse(from:)`
        // before this is reached, but strip again here in case this is ever
        // called directly on unprocessed text.
        var result = CoachRememberTagParser.extractFactsAndStrip(from: text).cleanedText
        for name in ["INFO", "TODO"] {
            if let regex = try? NSRegularExpression(
                pattern: "\\[/?\(name)\\]",
                options: [.caseInsensitive]
            ) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result
            .replacingOccurrences(of: #"\n{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Result of the knowledge-check intake — may jump over goals they already own.
struct CoursePlacementAssessment: Equatable {
    /// 0-based index of the first goal they still need. Clamp to course length.
    let startGoalIndex: Int
    let summaryForMemory: String
}

// MARK: - Live phase

enum CourseLessonPhase: Equatable {
    case idle
    case settingUp
    case watchingVideo
    case coaching
    case speaking
    /// Asking what they already know before goals (skip-ahead).
    case placement(prompt: String)
    case yourTurn(prompt: String)
    /// Soft teach-back after vision success — confirm they get *why*.
    case understanding(prompt: String)
    /// Inline interactive widget (e.g. multiple choice) rendered directly in the lesson UI.
    case interactiveChoice(prompt: String)
    /// Inline self-attested checklist widget — sibling of `interactiveChoice`.
    case interactiveChecklist(prompt: String)
    /// Inline fill-in-the-blank widget — sibling of `interactiveChoice`.
    case interactiveFillInBlank(prompt: String)
    case checking
    case celebrating
    case failed(hint: String?)

    var displayLabel: String {
        switch self {
        case .idle: return "course mode"
        case .settingUp: return "setting up…"
        case .watchingVideo: return "teacher clip…"
        case .coaching: return "coaching…"
        case .speaking: return "talking…"
        case .placement: return "quick check"
        case .yourTurn: return "your turn"
        case .understanding: return "got it?"
        case .interactiveChoice: return "quick check"
        case .interactiveChecklist: return "checklist"
        case .interactiveFillInBlank: return "fill in the blank"
        case .checking: return "checking…"
        case .celebrating: return "nice!"
        case .failed: return "try again"
        }
    }

    var systemImageName: String {
        switch self {
        case .idle: return "graduationcap.fill"
        case .settingUp: return "arrow.up.forward.app"
        case .watchingVideo: return "play.rectangle.fill"
        case .coaching: return "hand.point.up.left.fill"
        case .speaking: return "waveform"
        case .placement: return "person.crop.circle.badge.questionmark"
        case .yourTurn: return "person.fill"
        case .understanding: return "lightbulb.fill"
        case .interactiveChoice: return "list.bullet.circle.fill"
        case .interactiveChecklist: return "checklist"
        case .interactiveFillInBlank: return "text.cursor"
        case .checking: return "checkmark.circle"
        case .celebrating: return "star.fill"
        case .failed: return "arrow.counterclockwise"
        }
    }

    var isYourTurn: Bool {
        if case .yourTurn = self { return true }
        return false
    }

    var isWatchingVideo: Bool {
        if case .watchingVideo = self { return true }
        return false
    }

    var isPlacement: Bool {
        if case .placement = self { return true }
        return false
    }

    var isUnderstanding: Bool {
        if case .understanding = self { return true }
        return false
    }

    var isInteractiveChoice: Bool {
        if case .interactiveChoice = self { return true }
        return false
    }

    var isInteractiveChecklist: Bool {
        if case .interactiveChecklist = self { return true }
        return false
    }

    var isInteractiveFillInBlank: Bool {
        if case .interactiveFillInBlank = self { return true }
        return false
    }

    var promptText: String? {
        if case .yourTurn(let prompt) = self { return prompt }
        if case .placement(let prompt) = self { return prompt }
        if case .understanding(let prompt) = self { return prompt }
        if case .interactiveChoice(let prompt) = self { return prompt }
        if case .interactiveChecklist(let prompt) = self { return prompt }
        if case .interactiveFillInBlank(let prompt) = self { return prompt }
        return nil
    }

    var yourTurnPrompt: String {
        promptText ?? ""
    }
}

typealias CourseTeachingPhase = CourseLessonPhase

// MARK: - Progress

struct ClickyCourseProgress: Codable, Equatable {
    var completedStepIDs: [String]
    var isFullyCompleted: Bool
    var lastAccessedAt: Date?

    var completedStepCount: Int { completedStepIDs.count }
}

// MARK: - Active session

struct ClickyCourseStepExchange: Equatable {
    let userTranscript: String
    let assistantResponse: String
}

struct ClickyCourseSession: Equatable {
    let course: ClickyCourse
    var currentStepIndex: Int
    var startedAt: Date
    var stepConversationHistory: [ClickyCourseStepExchange]
    var artifactHistory: [CourseArtifactSnapshot]
    var failureCountByGoalID: [String: Int]

    var currentStep: CourseLearningGoal {
        course.goals[currentStepIndex]
    }

    var currentGoal: CourseLearningGoal { currentStep }

    var isOnFinalStep: Bool {
        currentStepIndex >= course.goals.count - 1
    }

    /// Number of non-remediation goals in the course.
    var mainGoalCount: Int {
        course.goals.filter { $0.remediationGoalID == nil }.count
    }

    /// Number of non-remediation goals completed so far (requires progress from CoursesManager).
    func completedMainGoalCount(completedStepIDs: [String]) -> Int {
        let completedIDs = Set(completedStepIDs)
        return course.goals.filter { goal in
            goal.remediationGoalID == nil && completedIDs.contains(goal.id)
        }.count
    }

    var progressFraction: Double {
        guard course.stepCount > 0 else { return 0 }
        return Double(currentStepIndex) / Double(course.stepCount)
    }
}

// MARK: - Voice commands

enum ClickyCourseVoiceCommands {
    static let exitPhrases = [
        "leave course",
        "exit course",
        "stop course",
        "quit course",
        "end course",
        "cancel course",
    ]

    static let advancePhrases = [
        "next step",
        "i'm done",
        "im done",
        "done with this step",
        "ready for next",
        "move on",
        "next",
        "continue",
        "i'm ready",
        "im ready",
        "i did it",
        "i did that",
    ]

    static let skipVideoPhrases = [
        "skip video",
        "skip this video",
        "skip the video",
        "skip intro",
        "skip this",
        "skip",
    ]

    static func isExitRequest(transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return exitPhrases.contains { normalized.contains($0) }
    }

    static func isManualAdvanceRequest(transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return advancePhrases.contains { normalized == $0 || normalized.hasPrefix($0) }
    }

    static func isSkipVideoRequest(transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skipVideoPhrases.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }
    }
}

enum ClickyCourseResponseTags {
    static let stepComplete = "[STEP_COMPLETE]"

    static func stripStepCompleteTag(from responseText: String) -> (spokenText: String, stepCompleted: Bool) {
        let stepCompleted = responseText.contains(stepComplete)
        let spokenText = responseText
            .replacingOccurrences(of: stepComplete, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (spokenText, stepCompleted)
    }
}

// MARK: - Bundled catalog

enum ClickyCourseCatalog {
    static let bundledCourses: [ClickyCourse] = [
        buildAWebsiteCourse,
    ]

    static let webFundamentalsTrackID = "web-fundamentals"
    static let webFundamentalsTrackTitle = "Web Fundamentals"

    /// Featured IDs shown first for new learners.
    static let featuredLearnerCourseIDs: [String] = [
        "build-a-website",
    ]

    static let buildAWebsiteCourse = ClickyCourse(
        id: "build-a-website",
        title: "Build & Deploy a Website",
        subtitle: "From zero to a live site the world can visit",
        description: "Build a real personal website from scratch with HTML & CSS, then deploy it to GitHub Pages so anyone on the internet can see it.",
        iconSystemName: "display",
        estimatedMinutes: 45,
        startURL: "https://github.com/new",
        learningOutcomes: [
            "Understand how websites work (HTML structure, CSS styling, browser rendering)",
            "Write real HTML with headings, paragraphs, links, images, and navigation",
            "Style a site with CSS — colors, fonts, spacing, and responsive layout",
            "Use Git to track changes and push code to GitHub",
            "Deploy a live website to GitHub Pages with a public URL",
            "Share a real link that anyone in the world can open",
        ],
        goals: [
            CourseLearningGoal(
                id: "plan-your-site",
                title: "Plan your site",
                goal: "Decide what your website is about and what content goes on it — even a rough sketch is enough.",
                coachAsk: "Help me plan a personal website. I'm not sure where to start — what should I think about before writing any code?",
                doneWhen: "The learner can describe in one sentence what their site is about and roughly what will be on it.",
                artifactDelta: "Site planned",
                tips: [
                    "A personal site only needs one page to start",
                    "Think: who is this for? what do they need to see?",
                    "Keep it simple — you can always add more later",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "what a website actually is (files a browser reads)",
                        "the difference between HTML (structure) and CSS (style)",
                        "pages, navigation, and content hierarchy",
                    ],
                    commonMistakes: [
                        "trying to plan every pixel before writing any code",
                        "making it too complicated — multiple pages, forms, databases",
                        "not choosing a topic and getting stuck in analysis paralysis",
                    ],
                    successExamples: [
                        "I want a simple page about my cat with a photo, a bio, and a contact email",
                        "I want a portfolio with my name, what I do, and three project cards",
                    ],
                    whyItMatters: "A clear plan means every line of code has a purpose — no wasted effort.",
                    teachBackPrompt: "what is your site about, and who is it for?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "You know what your site is called, what it's about, and roughly what goes on the page."
            ),
            CourseLearningGoal(
                id: "create-html-file",
                title: "Create your first HTML file",
                goal: "Set up a project folder and write a valid HTML file that opens in a browser.",
                coachAsk: "Help me create my first HTML file. I have a plan for my site — now I need to set up a folder and write the code. Open Terminal or Finder and walk me through it.",
                doneWhen: "A file named index.html exists in a project folder and opens in a browser showing visible content.",
                artifactDelta: "HTML file created",
                remediationGoalID: "plan-your-site",
                tips: [
                    "index.html is the standard name for a homepage",
                    "You can open any .html file by double-clicking it",
                    "Don't worry about making it pretty yet — just get text on screen",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "HTML document skeleton (doctype, html, head, body)",
                        "what goes in head (title, charset, viewport) vs body (visible content)",
                        "opening the file in a browser to preview",
                    ],
                    commonMistakes: [
                        "forgetting the closing body or html tags",
                        "putting visible content inside head instead of body",
                        "naming the file something other than index.html and getting confused later",
                    ],
                    successExamples: [
                        "Double-click index.html and you see your text in the browser",
                        "The browser tab shows your page title",
                    ],
                    whyItMatters: "Every website starts with a single HTML file — this is the foundation everything else builds on.",
                    teachBackPrompt: "what are the main parts of an HTML document and what goes in each?",
                    skipTeachBack: false
                ),
                toolPolicy: .helpWhenStuck,
                outcome: "A file called index.html that opens in your browser and shows some text."
            ),
            CourseLearningGoal(
                id: "add-content",
                title: "Add real content",
                goal: "Fill the page with actual content — a heading, paragraphs, a link, and an image.",
                coachAsk: "My HTML file exists but it's mostly empty. Help me add real content — a heading, some paragraphs, maybe a link and an image.",
                doneWhen: "The page has at least a heading, a paragraph, one link, and one image (or clear placeholder).",
                artifactDelta: "Content added",
                remediationGoalID: "create-html-file",
                tips: [
                    "Use h1 for the main title, h2 for section headings",
                    "Images need both a file and alt text",
                    "Links use a tag with href",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "heading hierarchy (h1 through h6 — don't skip levels)",
                        "paragraphs with p",
                        "anchor links with a href",
                        "images with img src and alt text",
                        "what alt text is for (accessibility plus broken image fallback)",
                    ],
                    commonMistakes: [
                        "using headings just to make text big (use CSS for that)",
                        "forgetting alt text on images",
                        "putting block content inside inline elements",
                        "using absolute URLs for local images that won't work when deployed",
                    ],
                    successExamples: [
                        "The page clearly tells a story: title, intro, details, link",
                        "Images load and have descriptive alt text",
                    ],
                    whyItMatters: "Content is why people visit your site. Without real content, it is just an empty frame.",
                    teachBackPrompt: "what content does your page have and why did you choose those elements?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "The page has a title, some text about you or your topic, a clickable link, and an image."
            ),
            CourseLearningGoal(
                id: "style-with-css",
                title: "Style with CSS",
                goal: "Make the page look intentional with colors, fonts, spacing, and layout.",
                coachAsk: "My page has content but it looks like a plain document. Help me add CSS to make it look like a real website — colors, fonts, and layout.",
                doneWhen: "The page has custom colors, fonts, spacing, and at least one layout technique (centering, flexbox, or grid).",
                artifactDelta: "CSS styles applied",
                remediationGoalID: "add-content",
                tips: [
                    "A style tag in head is the fastest way to start",
                    "body with font-family: system-ui gives you a modern font for free",
                    "margin: 0 auto centers content; max-width keeps it readable",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "CSS selectors (element, class, id)",
                        "the box model (margin, border, padding, content)",
                        "flexbox for layout (display: flex, justify-content, align-items)",
                        "responsive units (rem, percent, max-width) vs fixed pixels",
                        "color: hex vs named colors vs rgb",
                    ],
                    commonMistakes: [
                        "using !important to fix specificity issues instead of learning selectors",
                        "hardcoding pixel widths that break on different screens",
                        "putting CSS inline instead of in a stylesheet or style block",
                        "not testing at different browser widths",
                    ],
                    successExamples: [
                        "The page looks clean and intentional at desktop width",
                        "Content is centered and has breathing room",
                        "Fonts are readable and consistent",
                    ],
                    whyItMatters: "CSS is the difference between a document and a designed experience. It is what makes people stay.",
                    teachBackPrompt: "what is the box model and how does flexbox help you layout a page?",
                    skipTeachBack: false
                ),
                toolPolicy: .helpWhenStuck,
                outcome: "The page has a background color, readable fonts, proper spacing, and looks designed rather than raw."
            ),
            CourseLearningGoal(
                id: "make-it-responsive",
                title: "Make it responsive",
                goal: "Ensure the site looks good on phones, tablets, and desktops.",
                coachAsk: "My site looks good on my laptop but probably breaks on a phone. Help me make it responsive so it works everywhere.",
                doneWhen: "The site looks usable at 320px width (phone) and 1200px plus (desktop) with no horizontal scrolling.",
                artifactDelta: "Responsive layout",
                remediationGoalID: "style-with-css",
                tips: [
                    "The viewport meta tag is required",
                    "max-width: 100% on images prevents overflow",
                    "Media queries change styles at different breakpoints",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "the viewport meta tag (without it, phones render at 960px)",
                        "mobile-first design (style for small screens first, add complexity for large)",
                        "media queries (min-width breakpoints)",
                        "flexible units (percent, vw, rem) vs fixed pixels",
                        "flex-wrap for multi-item layouts",
                    ],
                    commonMistakes: [
                        "forgetting the viewport meta tag entirely",
                        "using fixed pixel widths on containers",
                        "designing for desktop first and bolting on mobile later",
                        "not testing on an actual phone or narrow browser window",
                    ],
                    successExamples: [
                        "Open the site on your phone and it looks like it was made for it",
                        "Resize the browser window and content reflows smoothly",
                        "No horizontal scrollbar at any width",
                    ],
                    whyItMatters: "Over half of web traffic is mobile. A site that only works on desktop is broken for most people.",
                    teachBackPrompt: "what is the viewport meta tag and why is it the first thing you need for mobile?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "The site adapts to different screen sizes — text is readable, nothing overflows, images scale."
            ),
            CourseLearningGoal(
                id: "add-more-pages",
                title: "Add more pages",
                goal: "Create a second page and link between pages with a consistent navigation menu.",
                coachAsk: "My one page looks great. Help me add a second page — like an About or Projects page — and link them together so visitors can navigate.",
                doneWhen: "A second .html file exists with real content, and a nav element on both pages links between them.",
                artifactDelta: "Multi-page site",
                remediationGoalID: "make-it-responsive",
                tips: [
                    "Copy index.html as a starting point for the new page",
                    "Keep the nav identical on both pages (same links, same order)",
                    "Use relative links — not absolute paths",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "relative vs absolute paths",
                        "consistent navigation across pages",
                        "the nav semantic element",
                        "copy-paste as a starting point (DRY comes later)",
                    ],
                    commonMistakes: [
                        "using different nav structures on different pages",
                        "broken links because of wrong file paths",
                        "putting the nav inside the wrong element",
                        "copying the page but forgetting to update the title",
                    ],
                    successExamples: [
                        "Clicking About in the nav takes you to about.html and back",
                        "Both pages share the same visual style and nav layout",
                        "The browser tab title is different on each page",
                    ],
                    whyItMatters: "A website with one page is a flyer. Multiple pages with navigation is a site.",
                    teachBackPrompt: "what is the difference between relative and absolute paths in links?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "At least two pages exist (e.g. index.html plus about.html) with a nav that links between them."
            ),
            CourseLearningGoal(
                id: "push-to-github",
                title: "Push to GitHub",
                goal: "Initialize a Git repo and push your site to GitHub so it is backed up and ready to deploy.",
                coachAsk: "My site is done locally. Help me put it on GitHub so it is saved online and ready to deploy.",
                doneWhen: "A GitHub repository exists with all site files committed and pushed.",
                artifactDelta: "Code on GitHub",
                remediationGoalID: "add-more-pages",
                tips: [
                    "git init then git add . then git commit then git push",
                    "Add a .gitignore with just .DS_Store to keep macOS junk out",
                    "Name the repo something simple like my-website",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Git tracks changes to files over time",
                        "git init, git add, git commit, git push — the core loop",
                        "GitHub is where your Git repo lives online",
                        "README.md is the file GitHub shows on the repo homepage",
                    ],
                    commonMistakes: [
                        "running git commands in the wrong directory",
                        "committing before adding files (git add first)",
                        "forgetting to create the GitHub repo before pushing",
                        "pushing to main vs main branch naming confusion",
                    ],
                    successExamples: [
                        "git status shows nothing to commit and git remote -v shows your GitHub URL",
                        "Opening github.com/YOU/repo-name shows all your files",
                    ],
                    whyItMatters: "Git is your safety net — you can always go back. GitHub is where your code lives before it goes live.",
                    teachBackPrompt: "what are the four git commands in the core workflow and what does each one do?",
                    skipTeachBack: false
                ),
                toolPolicy: .helpWhenStuck,
                outcome: "Your site code is on GitHub in a repository with all your files committed."
            ),
            CourseLearningGoal(
                id: "deploy-to-github-pages",
                title: "Deploy to GitHub Pages",
                goal: "Turn your GitHub repo into a live website with a public URL anyone can visit.",
                coachAsk: "My code is on GitHub. Help me deploy it to GitHub Pages so I can share a live link with anyone.",
                doneWhen: "The GitHub Pages URL loads in a browser and shows the deployed site.",
                artifactDelta: "Live on the internet",
                remediationGoalID: "push-to-github",
                tips: [
                    "Settings then Pages then Source: main branch then Save",
                    "It takes 1-2 minutes to deploy the first time",
                    "If it 404s, check that your main file is named index.html",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "GitHub Pages serves your repo as a website for free",
                        "Settings then Pages then choose your branch",
                        "the deployment URL format: username.github.io/repo-name",
                        "pushing a new commit triggers automatic redeployment",
                    ],
                    commonMistakes: [
                        "forgetting to enable GitHub Pages in Settings",
                        "selecting the wrong branch (use main, not a feature branch)",
                        "naming the file something other than index.html",
                        "not waiting long enough for the first deploy",
                    ],
                    successExamples: [
                        "The URL loads and shows your site exactly as it looks locally",
                        "You can share the link and someone else can open it",
                        "Pushing a change to GitHub updates the live site within minutes",
                    ],
                    whyItMatters: "This is the moment your work becomes real — a URL you can put in your bio, share with friends, or add to a resume.",
                    teachBackPrompt: "what is GitHub Pages and how does pushing a commit update the live site?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "Your site is live at a public URL anyone can visit."
            ),
            CourseLearningGoal(
                id: "share-your-site",
                title: "Share your site",
                goal: "Open your live site, verify everything works, and share the link.",
                coachAsk: "My site is deployed! Help me open it, check that everything looks right, and grab the link so I can share it.",
                doneWhen: "The learner has opened their live site, verified the content and navigation work, and can state their URL.",
                artifactDelta: "Site shared",
                tips: [
                    "Open in a private/incognito window to see the fresh version",
                    "Test every link and page",
                    "Copy the URL — you earned it",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "cache busting (hard refresh or incognito for fresh deploys)",
                        "testing navigation across pages on the live version",
                        "what to share: the URL in a bio, message, or social post",
                    ],
                    commonMistakes: [
                        "checking the cached old version and thinking deploy failed",
                        "forgetting to test links on the live site (not just locally)",
                        "not saving the URL",
                    ],
                    successExamples: [
                        "The live site loads with correct content, styling, and navigation",
                        "All links work on the live version",
                        "You have the URL copied and ready to share",
                    ],
                    whyItMatters: "Building something is great. Sharing it is what makes it matter.",
                    teachBackPrompt: "what is the URL of your site and how would you describe it to someone?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "You can open your live site, confirm it looks right, and share the URL with anyone."
            ),
        ],
        artifact: CourseArtifactSpec(
            kind: "website",
            icon: "globe",
            initialState: "no files, no site, nothing exists yet",
            finalState: "a live personal website deployed on GitHub Pages with a public URL",
            previewIfNoProgress: "No website yet — let's build one"
        ),
        trackID: webFundamentalsTrackID,
        trackTitle: webFundamentalsTrackTitle,
        trackOrder: nil,
        prerequisiteCourseIDs: nil
    )

    static func courseCoachSystemPrompt(
        for session: ClickyCourseSession,
        learnerProfile: CourseLearnerProfile = CourseLearnerProfile(),
        globalLearnerProfile: CourseLearnerProfile? = nil,
        activeTeacherVideoNotes: String? = nil,
        /// Personal facts remembered about this person via `TeachyEngine`'s `LearnerModel`
        /// (relationship memory) — additive alongside `learnerProfile`'s skill-level memory,
        /// not a replacement for it.
        personalFacts: [String] = [],
        /// Adaptive humor read from `TeachyEngine`'s `LearnerModel`, also additive.
        humorReceptivity: HumorReceptivity? = nil,
        /// Temporal continuity phrases from `LearnerTemporalContext.continuityLines` —
        /// tells the coach how long since last session, streak, stale skills, personality
        /// trend. Defaults to empty so all existing callers compile unchanged.
        temporalContinuityLines: [String] = [],
        /// Derived autonomy level (anti-dependency mechanic). When non-nil the goal's
        /// TOOL POLICY line is TIGHTENED to match — never loosened. Nil (the default,
        /// and what the explicit "do it for me" turn passes) keeps the author's policy.
        autonomyLevel: CoachAutonomyLevel? = nil
    ) -> String {
        let course = session.course
        let goal = session.currentGoal
        let outcomes = course.learningOutcomes.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let trackSection: String
        if let trackPartLabel = course.trackPartLabel {
            trackSection = """

            LEARNING PATH: \(trackPartLabel)
            This course builds on earlier ones — meet them where they are; don't assume mastery.
            """
        } else {
            trackSection = ""
        }

        let tipsSection: String
        if let tips = goal.tips, !tips.isEmpty {
            tipsSection = "\nSoft tips (optional): \(tips.joined(separator: "; "))"
        } else {
            tipsSection = ""
        }

        let lessonBrief = goal.teachingBriefPromptSection(
            activeTeacherVideoNotes: activeTeacherVideoNotes,
            autonomyLevel: autonomyLevel
        )
        let learnerSection = learnerProfile.promptSection
        let globalLearnerSection: String
        if let globalProfile = globalLearnerProfile, globalProfile != CourseLearnerProfile() {
            globalLearnerSection = globalProfile.globalPromptSection
        } else {
            globalLearnerSection = ""
        }

        // Additive alongside learnerSection/globalLearnerSection above — this is the
        // relationship memory (who they are, not what they know), sourced from
        // TeachyEngine's LearnerModel rather than the legacy CourseLearnerProfile.
        let relationshipMemorySection: String = {
            var lines: [String] = []
            if !personalFacts.isEmpty {
                lines.append("What you remember about them: \(personalFacts.joined(separator: "; "))")
            }
            switch humorReceptivity {
            case .warm:
                lines.append("They've enjoyed banter before — feel free to joke and callback to what they've shared.")
            case .efficient:
                lines.append("They move fast and stay focused — keep it light but don't force jokes.")
            case .neutral, .none:
                break
            }
            guard !lines.isEmpty else { return "" }
            return """

            \(lines.joined(separator: "\n"))
            """
        }()

        // Temporal continuity block — surfaces how long since the last session,
        // the learner's streak, and stale skills. Injected right after relationship
        // memory so the coach can open with informed warmth rather than a cold start.
        let continuitySectionText: String = {
            guard !temporalContinuityLines.isEmpty else { return "" }
            let joinedLines = temporalContinuityLines.joined(separator: "\n")
            return """

            CONTINUITY (use to open naturally — do not list these aloud verbatim):
            \(joinedLines)
            """
        }()

        let artifactSection: String
        if let artifact = course.artifact {
            let historySnippet: String
            if !session.artifactHistory.isEmpty {
                let recent = session.artifactHistory.suffix(3)
                historySnippet = recent.map { "  - after \($0.goalID): \($0.stateDescription)" }.joined(separator: "\n")
            } else {
                historySnippet = "  - starting state: \(artifact.initialState)"
            }
            artifactSection = """

            ARTIFACT (\(artifact.kind)):
            Starting state: \(artifact.initialState)
            Final state: \(artifact.finalState)
            Progress so far:
            \(historySnippet)
            \(goal.artifactDelta.map { "This goal should change the artifact: \($0)" } ?? "")
            """
        } else {
            artifactSection = ""
        }

        return """
        You are Teachy — sitting right next to them at their computer, looking at the same screen.
        You are not a manual, not a lecture, not a chatbot. You are a calm, sharp human coach
        helping them get THIS goal done by doing it on their real Mac.

        Teachy IS AI fluency: teaching people to use real AI tools and to actually ship work —
        ChatGPT, Claude, agents, Wispr Flow, websites, whatever is on their screen — by practice, not videos.

        How you talk (this is spoken out loud — sound human):
        - Warm, natural full sentences. Contractions. Like a friend who knows their stuff.
        - One clear beat at a time. Never a TED talk. Never "certainly" / "simply" / robotic filler.
        - Specific > vague. If it's on screen, name it and POINT at the real control.
        - Celebrate real tiny wins. When they're lost: half a breath of empathy, then the next move.
        - Personality never overrides clarity. Stuck? Drop the jokes and be plainly specific.

        COURSE: \(course.title)
        By the end they should be able to:
        \(outcomes)
        \(trackSection)

        CURRENT GOAL (\(session.currentStepIndex + 1) of \(course.stepCount)): \(goal.title)
        Success looks like: \(goal.goal)\(tipsSection)
        \(lessonBrief)
        \(artifactSection)
        \(learnerSection)
        \(globalLearnerSection)
        \(relationshipMemorySection)
        \(continuitySectionText)

        \(TeachyCourseCapabilityCard.text)

        NEVER ASSUME THEY KNOW JARGON:
        - Don't assume they know Claude, ChatGPT, Cursor, HTML, a prompt, a browser tab, or "chat".
        - Introduce tools in one plain sentence the FIRST time
          (e.g. "Claude is an AI website — you type what you want, and it writes back.").
        - If the learner model says they already know something, skip that explanation.
        - If they're advanced, stay short — don't lecture people who already get it.

        HOW YOU FORMAT EVERY REPLY (required):
        Always use BOTH tags so the app can style them differently:
        [INFO] one short plain-language explanation or context [/INFO]
        [TODO] one concrete action they should do next — the do-this-now beat [/TODO]
        - INFO = teaching / clarifying (not a button to click yet)
        - TODO = their move (click, type, open, paste, send)
        - one INFO + one TODO only. Warm spoken English. No markdown outside the tags.
        - Include [POINT:cell:label] or better [POINT:x,y:label] when they should click something,
          and phrase [TODO] as "click here" / "right here" / "this one" ONLY when you're including
          that [POINT:...] tag in the same reply. If you can't confidently identify a specific,
          pointable target, describe it in words instead ("the option that says X") — don't say
          "here" with nothing backing it, that's worse than not pointing at all.
        - Optionally append invisible memory tags (never speak them): [MEMORY:knows:…] or [MEMORY:confused:…]
        - If they share something personal — their job, an interest, a joke, a life detail — tag it [REMEMBER: the fact] in your reply. This is stripped before speaking, never shown to them.

        How you teach:
        - Look at their screen RIGHT NOW. UIs change — never assume old buttons or menus.
        - Remember this session + learner model. Don't re-explain what they just did.
        - Always leave them with ONE concrete next move in [TODO] — never two options, never a list.
        - Default: POINT at the real control and tell THEM to click it inside [TODO].
        - Respect TOOL POLICY when deciding whether to USE TOOLS / do it for them.
        - If the goal is already done on screen, celebrate in [INFO] and [TODO] say "next step".
        - Side questions: short [INFO], then [TODO] back to THIS goal.

        Non-negotiable:
        - Default socratic, not answers — unless toolPolicy is canDoForThem or they asked twice.
        - Acknowledge before correcting (name what they got right first).
        - Use the learner profile — skip what they already know; address confusions.
        - One question at a time in teach-back.
        - No fake praise — only specific real things they did.
        - After 2 failed attempts, offer to do the automatable part if policy allows.

        MOOD:
        - frustrated: warm, concrete, one action, offer help sooner.
        - bored: faster, skip the obvious, add a challenge.
        - confused: slower, simpler words, one tiny check.
        - engaged: match energy, keep moving.

        MULTI-STEP tasks: map steps in [INFO], then one step at a time with POINT + TODO.
        Keep the step count honest.

        \(ScreenGridAnnotationUtility.modelInstructions)
        """
    }

    static func voiceKeyterms(forCourseID courseID: String) -> [String] {
        let sharedAdvance = ["next step", "exit course", "i did it"]
        switch courseID {
        case buildAWebsiteCourse.id:
            return [
                "website",
                "HTML",
                "CSS",
                "deploy",
                "GitHub",
                "page",
                "code",
                "browser",
                "responsive",
            ] + sharedAdvance
        default:
            return sharedAdvance
        }
    }
}
