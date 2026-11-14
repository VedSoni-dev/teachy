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
    /// When true, "next step" / I did it advances without requiring the screen to
    /// match `doneWhen` (conversational / interview goals with nothing to verify).
    let advanceOnUserConfirm: Bool?

    /// Back-compat names used by session/HUD copy.
    var instruction: String { goal }
    var completionCriteria: String { doneWhen ?? goal }

    /// True when this goal advances on confirm without a vision gate.
    var advancesOnUserConfirmWithoutVision: Bool {
        advanceOnUserConfirm == true
    }

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
        interactiveFillInBlank: CourseInteractiveFillInBlank? = nil,
        advanceOnUserConfirm: Bool? = nil
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
        self.advanceOnUserConfirm = advanceOnUserConfirm
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
        case "intake":
            return [
                "Portfolio for job apps",
                "Page for my hustle / business",
                "I want Replit, keep it simple",
            ]
        case "write-the-prompt":
            return [
                "Ask me the planning questions",
                "Open ChatGPT and paste it",
                "Plan is good — next",
            ]
        case "mock-landing":
            return [
                "Generate the landing mock",
                "I already have a Figma mock",
            ]
        case "build-it":
            return [
                "Open my build tool",
                "Paste the build prompt",
            ]
        case "ship-on-vercel":
            return [
                "Open Vercel and deploy",
                "Show me my live URL",
            ]
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
        title: "Make a Website",
        subtitle: "Plan in ChatGPT. Build. Live on Vercel.",
        description: "Teachy runs the interview you skip, writes a great ChatGPT prompt, helps you mock and build, then ships a live Vercel URL you can text someone.",
        iconSystemName: "display",
        estimatedMinutes: 45,
        startURL: nil,
        learningOutcomes: [
            "Answer sharp intake questions so an AI gets real context — not a vague one-liner",
            "Use a Teachy-written prompt in ChatGPT to produce a concrete site plan",
            "Generate a landing mock (and more pages only if image quota allows)",
            "Build the site in Replit or a coding agent matched to what they already pay for",
            "Deploy to Vercel and share a live URL",
        ],
        goals: [
            CourseLearningGoal(
                id: "intake",
                title: "Figure out your path",
                goal: "Say what the site is for, what you already have, and whether you want Replit (vibe) or a coding agent.",
                coachAsk: "Help me start Make a Website. Ask me the intake questions one at a time — goal, who gets the link, what I already have, Replit vs coding agent — and if I pick agent, ask whether I pay for ChatGPT, Claude, or Cursor.",
                doneWhen: "The learner has stated (1) site goal, (2) who they will text the link to, (3) what they already have, and (4) Replit vs coding agent — and if agent, which paid AI they use or that they are unpaid / willing to pay.",
                artifactDelta: "Path chosen",
                tips: [
                    "One question at a time — never dump the whole intake",
                    "Remember their answers for later goals (build tool + paid AI)",
                    "If they already have Figma/Canva, note that — we may skip image gens",
                    "If they only have a domain, still ship *.vercel.app first",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "intake before tools — route the path before opening tabs",
                        "Replit = vibe build in the browser; agent = Cursor / Claude Code / Codex",
                        "agent routing: Cursor→Cursor, Claude→Claude Code, ChatGPT→Codex/ChatGPT, unpaid→Codex free, willing to pay→Claude Code",
                    ],
                    commonMistakes: [
                        "opening ChatGPT before knowing the goal",
                        "pushing a paid tool when they picked Replit",
                        "asking every question at once",
                    ],
                    successExamples: [
                        "I want a portfolio for job apps, I have nothing, I want Replit",
                        "Hustle page, I have ChatGPT HTML in Downloads, I pay for Cursor",
                    ],
                    whyItMatters: "The path only works if we know where they are starting and which tool they will build in.",
                    teachBackPrompt: nil,
                    skipTeachBack: true
                ),
                toolPolicy: .preferPointing,
                outcome: "You and Teachy agree on goal, starting point, and build tool.",
                advanceOnUserConfirm: true
            ),
            CourseLearningGoal(
                id: "write-the-prompt",
                title: "Plan in ChatGPT",
                goal: "Interview for context, write a sharp prompt, open ChatGPT, paste it, and lock a concrete site plan.",
                coachAsk: """
Intake is done. Do this in ONE flow — do not wait for them to say next step between beats:
1) Ask planning questions ONE at a time (who it's for, 10-second feeling, pages, must-haves, tone) until you have enough context.
2) Write the perfect first ChatGPT prompt from their answers and briefly say what makes it good.
3) IMMEDIATELY open https://chatgpt.com (open_browser_tab) and paste the full prompt for them — they must not retype or hunt the link.
4) Help them refine until the plan is solid (purpose, page list, landing outline). When they say the plan is good, tell them to say next step.
""",
                doneWhen: "ChatGPT shows a concrete site plan (purpose, page list, landing outline) on screen, or the learner confirmed the plan is good.",
                artifactDelta: "Plan locked",
                remediationGoalID: "intake",
                tips: [
                    "After enough answers, OPEN ChatGPT and paste in the SAME turn — never leave them hanging",
                    "Normies give broad prompts — YOU ask the context they skip",
                    "Free image gens come later — this goal is plan text only",
                    "If they are logged out, help sign in, then paste",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "good prompts need context — Teachy runs the interview",
                        "Teachy opens ChatGPT and pastes — learner decides and reacts",
                        "done means they endorse the plan — then next step",
                    ],
                    commonMistakes: [
                        "finishing the interview and waiting instead of opening ChatGPT",
                        "accepting make me a portfolio with no follow-ups",
                        "leaving them to find chatgpt.com themselves",
                    ],
                    successExamples: [
                        "ChatGPT is open with a pasted prompt and a solid page plan on screen",
                    ],
                    whyItMatters: "Context in → useful plan out. They feel a good prompt work, then see it in ChatGPT.",
                    teachBackPrompt: "what made your prompt better than just saying make me a website?",
                    skipTeachBack: true
                ),
                toolPolicy: .canDoForThem,
                outcome: "A ChatGPT site plan you have approved."
            ),
            CourseLearningGoal(
                id: "mock-landing",
                title: "Mock the landing",
                goal: "Generate a ChatGPT image of the landing page from the plan (or use an existing Figma/Canva mock).",
                coachAsk: "Plan is good. Write an image prompt for the LANDING page from our plan, open ChatGPT if needed, generate the mock, and help me save it. If I already have Figma/Canva, use that instead of burning image gens.",
                doneWhen: "A landing-page visual mock is visible (ChatGPT image or existing design file) that matches the planned landing.",
                artifactDelta: "Landing mock",
                remediationGoalID: "write-the-prompt",
                tips: [
                    "Free ChatGPT image gens are scarce (~2–3 per rolling 24h) — landing FIRST",
                    "Only generate 1–2 more page mocks if quota remains; otherwise continue with landing alone",
                    "If they hit the limit, wait or proceed to build with the plan text + one mock",
                    "OPEN ChatGPT and paste the image prompt for them",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "visual mock reduces build thrash",
                        "image quota is limited on free ChatGPT — prioritize landing",
                        "existing design mocks count — do not force gens",
                    ],
                    commonMistakes: [
                        "burning all free gens on random styles before landing",
                        "skipping save/download so the mock disappears",
                        "generating ten pages on free tier",
                    ],
                    successExamples: [
                        "Landing mock image saved in Downloads or visible in the ChatGPT thread",
                        "Figma frame used as the mock — no gen needed",
                    ],
                    whyItMatters: "Build tools need a picture. Landing is the one that matters most.",
                    teachBackPrompt: nil,
                    skipTeachBack: true
                ),
                toolPolicy: .canDoForThem,
                outcome: "A landing mock you can show the build tool."
            ),
            CourseLearningGoal(
                id: "build-it",
                title: "Build it",
                goal: "Open Replit or the recommended coding agent, paste plan + mock context, and get a working preview.",
                coachAsk: "Open my build tool based on intake (Replit, or Cursor / Claude Code / Codex from what I pay for), paste a build prompt with the plan and mock, and help me iterate until the preview looks right.",
                doneWhen: "A working preview of the site is visible in Replit or the agent environment and roughly matches the plan and landing mock.",
                artifactDelta: "Site preview",
                remediationGoalID: "mock-landing",
                tips: [
                    "Replit: open https://replit.com — paste plan + mock refs",
                    "Paying Cursor → Cursor; Claude → Claude Code; ChatGPT → Codex/ChatGPT; unpaid → Codex free; willing to pay → Claude Code",
                    "OPEN the tool URL for them — do not send them googling",
                    "If they already have AI HTML or a repo, adapt — do not rebuild from zero unless broken",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "build tool follows intake routing — do not switch stacks mid-course without reason",
                        "prompt the builder with plan + mock, not make a website",
                        "preview before deploy",
                    ],
                    commonMistakes: [
                        "opening the wrong tool vs intake",
                        "building without referencing the mock",
                        "deploying before preview looks intentional",
                    ],
                    successExamples: [
                        "Replit preview shows landing matching the mock",
                        "Cursor/Codex/Claude Code preview of the site running locally or in preview pane",
                    ],
                    whyItMatters: "This is where the plan becomes a real site — still before hosting.",
                    teachBackPrompt: "which build tool did you use and why?",
                    skipTeachBack: true
                ),
                toolPolicy: .canDoForThem,
                outcome: "A preview of your site that matches the plan."
            ),
            CourseLearningGoal(
                id: "ship-on-vercel",
                title: "Ship on Vercel",
                goal: "Deploy to Vercel and open your live *.vercel.app URL.",
                coachAsk: "Open Vercel for me, help me deploy this project, and get a live *.vercel.app link. If I have a custom domain, we attach it AFTER the vercel.app URL works.",
                doneWhen: "A public https://*.vercel.app URL loads the learner's site in a browser.",
                artifactDelta: "Live on Vercel",
                remediationGoalID: "build-it",
                tips: [
                    "OPEN https://vercel.com or https://vercel.com/new for them",
                    "First win is always *.vercel.app — never block on DNS",
                    "Custom domain only after the vercel.app link works",
                    "Have them text the URL to someone — that is the trophy",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Vercel hosts the site on the public internet",
                        "vercel.app is enough to share today",
                        "custom domains are optional and later",
                    ],
                    commonMistakes: [
                        "fiddling with DNS before the first deploy works",
                        "deploying the wrong project/folder",
                        "not opening the live URL to verify",
                    ],
                    successExamples: [
                        "Incognito window loads their landing at a vercel.app URL",
                        "They copy the link and can text it",
                    ],
                    whyItMatters: "A link you can text is the finish line — not a local preview.",
                    teachBackPrompt: "what is your live URL?",
                    skipTeachBack: false
                ),
                toolPolicy: .canDoForThem,
                outcome: "A live Vercel URL you can text someone."
            ),
        ],
        artifact: CourseArtifactSpec(
            kind: "website",
            icon: "globe",
            initialState: "no plan, no site, nothing live",
            finalState: "a live personal site on Vercel with a public URL",
            previewIfNoProgress: "No website yet — let's plan one"
        ),
        trackID: nil,
        trackTitle: nil,
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

        // Flagship "Make a Website" — Teachy is the active prompter; open links; Vercel.
        let flagshipWebsiteCourseSection: String
        if course.id == buildAWebsiteCourse.id {
            flagshipWebsiteCourseSection = """

            FLAGSHIP COURSE RULES (Make a Website):
            - You run the interview normies skip. Ask ONE question at a time. Never accept a vague "make me a website" without context.
            - YOU write the perfect ChatGPT prompt from their answers, then OPEN chatgpt.com and PASTE it in the SAME turn (open_browser_tab / tools). Never finish the interview and wait for "next step" to open ChatGPT — open as soon as the prompt is ready. Do not make them hunt links or retype the prompt.
            - Remember intake forever this session: goal, what they have, Replit vs agent, paid AI (Cursor/Claude/ChatGPT/none/willing to pay). Route the build tool from that — do not invent a new stack.
            - Agent routing: Cursor→Cursor; Claude→Claude Code; ChatGPT→Codex/ChatGPT; unpaid→Codex free beginner tier; willing to pay→Claude Code; vibe→Replit (skip paid quiz).
            - Host is Vercel (*.vercel.app). Never GitHub Pages. Custom domain only AFTER vercel.app works.
            - Free ChatGPT image gens are scarce (~2–3 / 24h). Landing mock FIRST. More pages only if quota left.
            - When they say "plan is good", move on — do not endless-refine.
            """
        } else {
            flagshipWebsiteCourseSection = ""
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
        \(flagshipWebsiteCourseSection)

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
                "ChatGPT",
                "prompt",
                "Replit",
                "Vercel",
                "Codex",
                "Claude",
                "Cursor",
                "mock",
                "deploy",
                "landing",
                "plan is good",
            ] + sharedAdvance
        default:
            return sharedAdvance
        }
    }
}
