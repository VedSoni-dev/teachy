//
//  ClickyCourse.swift
//  leanring-buddy
//
//  Goal-based Teachy Courses — durable learning outcomes, no hardcoded UI.
//  An auto-prompter feeds natural asks into the normal companion vision path
//  so courses still work when apps redesign.
//

import Foundation

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
    /// Optional long-form intro (HLS/mp4) played beside Teachy once when the course starts — same UX as Farza's onboarding clip.
    /// Prefer `teacherVideoURL` in new authoring; both keys work when decoding.
    let introVideoURL: String?
    /// Preferred authoring key for the course intro clip (aliases `introVideoURL`).
    let teacherVideoURL: String?
    /// Optional credit shown on the beside-cursor player (e.g. "Farza", "Maya").
    let teacherName: String?
    /// What the learner should be able to do by the end — shown to the model as north star.
    let learningOutcomes: [String]
    /// Ordered goals. Each is taught via a natural auto-prompt into companion vision.
    let goals: [CourseLearningGoal]
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
    let tips: [String]?
    /// Optional part clip (HLS/mp4) played beside Teachy before coaching this goal — Farza-style long-form, not a YouTube embed.
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
        tips: [String]? = nil,
        introVideoURL: String? = nil,
        teacherVideoURL: String? = nil,
        teacherName: String? = nil,
        teacherVideoNotes: String? = nil,
        teachingContext: CourseTeachingContext? = nil,
        toolPolicy: CourseToolPolicy? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.coachAsk = coachAsk
        self.doneWhen = doneWhen
        self.tips = tips
        self.introVideoURL = introVideoURL
        self.teacherVideoURL = teacherVideoURL
        self.teacherName = teacherName
        self.teacherVideoNotes = teacherVideoNotes
        self.teachingContext = teachingContext
        self.toolPolicy = toolPolicy
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
    func teachingBriefPromptSection(activeTeacherVideoNotes: String?) -> String {
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
        blocks.append(resolvedToolPolicy.coachInstructions)

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

/// Parsed coach line — info (explain) vs todo (do this now).
struct CourseCoachMessageParts: Equatable {
    let infoText: String?
    let todoText: String?
    /// Clean text for TTS / history (tags stripped, parts joined).
    let spokenText: String

    var hasStructuredParts: Bool { infoText != nil || todoText != nil }

    static func parse(from rawResponse: String) -> CourseCoachMessageParts {
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = extractTaggedSection(named: "INFO", from: trimmed)
            ?? extractPrefixedLine(named: "INFO", from: trimmed)
        let todo = extractTaggedSection(named: "TODO", from: trimmed)
            ?? extractPrefixedLine(named: "TODO", from: trimmed)

        if info == nil, todo == nil {
            let cleaned = stripCoachTags(from: trimmed)
            return CourseCoachMessageParts(infoText: nil, todoText: cleaned.isEmpty ? nil : cleaned, spokenText: cleaned)
        }

        var spokenPieces: [String] = []
        if let info, !info.isEmpty { spokenPieces.append(info) }
        if let todo, !todo.isEmpty { spokenPieces.append(todo) }
        let spoken = spokenPieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return CourseCoachMessageParts(
            infoText: info?.nilIfEmpty,
            todoText: todo?.nilIfEmpty,
            spokenText: spoken.isEmpty ? stripCoachTags(from: trimmed) : spoken
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
        var result = text
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

    var promptText: String? {
        if case .yourTurn(let prompt) = self { return prompt }
        if case .placement(let prompt) = self { return prompt }
        if case .understanding(let prompt) = self { return prompt }
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

    var currentStep: CourseLearningGoal {
        course.goals[currentStepIndex]
    }

    var currentGoal: CourseLearningGoal { currentStep }

    var isOnFinalStep: Bool {
        currentStepIndex >= course.goals.count - 1
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
        aiFirstWinCourse,
        aiToCodeCourse,
        youtubeBasicsCourse,
        khanAcademyBasicsCourse,
        githubBasicsCourse,
        githubGitFundamentalsCourse,
        githubMakeARepoCourse,
        githubCollaborateCourse,
    ]

    static let gitAndGitHubTrackID = "git-and-github"
    static let gitAndGitHubTrackTitle = "Git & GitHub"
    static let buildWithAITrackID = "build-with-ai"
    static let buildWithAITrackTitle = "Build with AI"

    /// Featured IDs shown first for new learners (First Win → flagship).
    static let featuredLearnerCourseIDs: [String] = [
        "ai-first-win",
        "ai-to-code",
    ]

    /// 10-minute on-ramp before the full Use AI to Code path.
    static let aiFirstWinCourse = ClickyCourse(
        id: "ai-first-win",
        title: "First Win with AI",
        subtitle: "10 minutes to something that runs",
        description: "The easiest Teachy on-ramp. Open an AI, ask for one tiny thing, and see it run — so you feel the loop before the full Use AI to Code path.",
        iconSystemName: "sparkle",
        estimatedMinutes: 10,
        startURL: "https://claude.ai",
        learningOutcomes: [
            "Open an AI that can help you write code",
            "Send one clear tiny prompt",
            "See a result run or preview on screen",
        ],
        goals: [
            CourseLearningGoal(
                id: "first-win-open",
                title: "Open your AI",
                goal: "Have Claude, ChatGPT, or Cursor open so you can ask it to build something tiny.",
                coachAsk: """
                They're starting First Win. Explain from zero if needed: an “AI chat” is a website or app \
                where you type what you want and it writes back — Claude (claude.ai) and ChatGPT are popular ones; \
                Cursor is an app that helps you write code with AI. Help them open whichever is easiest. \
                Point at what to click. Don't assume they know any of these names.
                """,
                doneWhen: "An AI chat or AI coding tool is open and recognizable on screen.",
                tips: [
                    "Claude or ChatGPT in the browser is perfect",
                    "Cursor works too if they already have it",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "AI chat = type a request, get text back",
                        "Claude / ChatGPT / Cursor are examples",
                    ],
                    commonMistakes: [
                        "Opening a random search page instead of the AI",
                        "Freezing on a permission dialog",
                    ],
                    successExamples: [
                        "Browser shows Claude or ChatGPT chat UI",
                        "Cursor is open with the AI panel visible",
                    ],
                    whyItMatters: "You can’t ask for a build until the AI is open on your Mac.",
                    teachBackPrompt: "in your words — what is an AI chat, and which one do you have open?",
                    skipTeachBack: false
                ),
                toolPolicy: .helpWhenStuck
            ),
            CourseLearningGoal(
                id: "first-win-prompt",
                title: "Ask for one tiny thing",
                goal: "Send one clear prompt for a tiny project — tip calculator, to-do, or hello page.",
                coachAsk: """
                Explain what a “prompt” is if needed — it's just the message you type to the AI, like asking a friend. \
                Help them send one clear tiny ask (suggest: make a single HTML tip calculator — HTML is a simple webpage file). \
                Point at where they type and how to send. Prompt chips may be on the HUD.
                """,
                doneWhen: "A clear tiny-project prompt is visible as typed or sent in the AI chat.",
                tips: [
                    "One feature only",
                    "Plain language beats jargon",
                ],
                teacherVideoNotes: """
                - A prompt is just a clear ask in plain English
                - Smaller asks work better than “build me an app”
                - Send / Enter is how the AI starts working
                """,
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Prompt = the message you send the AI",
                        "Tiny scope beats vague mega-projects",
                    ],
                    commonMistakes: [
                        "Writing a novel of requirements",
                        "Forgetting to send / press Enter",
                    ],
                    successExamples: [
                        "Chat shows a sent message asking for one tiny HTML thing",
                    ],
                    whyItMatters: "The AI only builds what you clearly ask for.",
                    teachBackPrompt: "what did you ask the AI to make — and why keep it tiny?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing
            ),
            CourseLearningGoal(
                id: "first-win-run",
                title: "See it run",
                goal: "Open or preview the result so something real is on screen.",
                coachAsk: """
                The AI should have answered with code or steps. Explain if needed: “running” means opening the result \
                so they can see it work — often save as a .html file and open it in a browser (Chrome, Safari, etc.). \
                Point at the next move to actually see it.
                """,
                doneWhen: "A running or previewed result is visible — browser page, preview, or clear live output.",
                tips: [
                    "HTML → save .html → open in browser",
                    "That’s a win — you’re done",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Code on screen isn’t done until you see it run",
                        "HTML files open in a browser to preview",
                    ],
                    commonMistakes: [
                        "Stopping after the AI replies without opening anything",
                        "Saving the file but never opening it",
                    ],
                    successExamples: [
                        "Browser shows their tiny page or tip calculator",
                    ],
                    whyItMatters: "The win is seeing something real work — not collecting code.",
                    teachBackPrompt: "how did you get from the AI’s answer to something running on screen?",
                    skipTeachBack: false
                ),
                toolPolicy: .helpWhenStuck
            ),
        ],
        trackID: buildWithAITrackID,
        trackTitle: buildWithAITrackTitle,
        trackOrder: 0,
        prerequisiteCourseIDs: nil
    )

    /// Flagship path — Use AI to Code. Ordinary-person skill of the moment.
    static let aiToCodeCourse = ClickyCourse(
        id: "ai-to-code",
        title: "Use AI to Code",
        subtitle: "From idea to something that runs — with AI",
        description: "The flagship Teachy path. Learn the real skill of 2026: describe what you want, get AI to build it, run it, and fix it when it’s wrong — on your Mac, with a 1:1 tutor beside you. No CS degree required.",
        iconSystemName: "laptopcomputer.and.arrow.down",
        estimatedMinutes: 45,
        startURL: "https://claude.ai",
        learningOutcomes: [
            "Open an AI that can help you write code",
            "Describe a tiny project in plain language",
            "Get a first working version from the AI",
            "Run or open the result so you can see it",
            "Ask for a change and verify it landed",
            "Save the project somewhere you’ll find again",
            "Say in one sentence what you built",
        ],
        goals: [
            CourseLearningGoal(
                id: "ai-open-tool",
                title: "Open your AI",
                goal: "Have an AI coding helper open — Claude, ChatGPT, Cursor, or similar — so you can start building.",
                coachAsk: """
                Explain from zero if needed: an AI coding helper is a chat where you describe what you want \
                and it writes code back — Claude (claude.ai) and ChatGPT are websites for that; Cursor is an app. \
                Help them open whichever is easiest. Point at how to get started. Don't assume they know the names.
                """,
                doneWhen: "An AI chat or AI coding tool is open and recognizable on screen (Claude, ChatGPT, Cursor, Copilot, or similar).",
                tips: [
                    "Browser Claude or ChatGPT is perfect for beginners",
                    "Cursor is great if you already have it",
                    "Signing in is OK if the tool asks",
                ]
            ),
            CourseLearningGoal(
                id: "ai-clear-ask",
                title: "Ask for something tiny",
                goal: "Send a clear first prompt for a tiny project — like a one-page site, a calculator, or a to-do list — in plain language.",
                coachAsk: """
                Explain what a “prompt” is if needed — the message you type to the AI, like asking a friend for help. \
                Help them write a clear first ask for something tiny (one page / one feature). Point at where to send it.
                """,
                doneWhen: "A clear project prompt is visible in the AI chat input or as a sent message (a small app, page, or script request).",
                tips: [
                    "Small is better: one page, one feature",
                    "Say what it should look like and what it should do",
                    "Example vibe: “Make a single HTML page with a tip calculator”",
                ]
            ),
            CourseLearningGoal(
                id: "ai-first-version",
                title: "Get a first version",
                goal: "Receive a first version of the project from the AI — code, files, or a scaffold you can use.",
                coachAsk: "The AI should give me a first version now. Point at the reply or code I should use, and tell me what to do next in one short beat.",
                doneWhen: "AI-generated code, files, or a clear project scaffold is visible in the conversation or editor.",
                tips: [
                    "If it asks clarifying questions, answer simply",
                    "You don’t need to understand every line yet",
                ]
            ),
            CourseLearningGoal(
                id: "ai-see-it-run",
                title: "See it run",
                goal: "Open or run the result so something real is on screen — a browser preview, a window, or output that proves it works.",
                coachAsk: "How do I actually see this thing run? Help me open a preview, save a file and open it, or run it — point at the next move.",
                doneWhen: "A running or previewed result is visible — browser page, app window, terminal output, or live preview of the project.",
                tips: [
                    "HTML often means save as .html and open in a browser",
                    "If the AI gave a link or preview, use that",
                    "“It runs” beats “it looks smart in the chat”",
                ]
            ),
            CourseLearningGoal(
                id: "ai-request-change",
                title: "Change something",
                goal: "Ask the AI to change the project — color, text, feature, or fix — and get an updated version.",
                coachAsk: "I want to change something about what we built. Help me ask the AI clearly, then point at where the update shows up.",
                doneWhen: "An updated AI response or edited project is visible that reflects a requested change.",
                tips: [
                    "One change at a time",
                    "Point at what you dislike: “make the button bigger” beats “make it better”",
                ]
            ),
            CourseLearningGoal(
                id: "ai-verify-change",
                title: "Verify the change",
                goal: "Confirm the change in the running project — refresh preview, re-open the file, or check the UI so you know it landed.",
                coachAsk: "How do I check that the change actually landed in the running thing? Point at what I should look at.",
                doneWhen: "The running or previewed project shows the requested change (or the learner has clearly checked the updated output).",
                tips: [
                    "Refresh the browser if it’s a web page",
                    "This is the habit that separates builders from copy-pasters",
                ]
            ),
            CourseLearningGoal(
                id: "ai-save-project",
                title: "Save it for later",
                goal: "Save the project somewhere durable on your Mac — a folder, file, or project you’ll find again.",
                coachAsk: "Help me save this project somewhere obvious on my Mac so I don’t lose it. Point at how I should save or where to put the files.",
                doneWhen: "The project is saved as a file, folder, or named project on disk (Finder, editor save dialog, or clearly saved project UI).",
                tips: [
                    "Desktop or a Documents/Projects folder is fine",
                    "Name it something you’ll recognize next week",
                ]
            ),
            CourseLearningGoal(
                id: "ai-say-what-you-built",
                title: "Name what you built",
                goal: "Write or say one clear sentence: what you built and that you used AI to do it.",
                coachAsk: "Last step — help me write one sentence that says what I built with AI. Point at a notes app, the chat, or anywhere I can type it.",
                doneWhen: "A short written sentence is visible describing what was built (notes, chat, doc, or similar).",
                tips: [
                    "Example: “I built a tip calculator webpage with AI.”",
                    "This is your proof — keep it",
                ]
            ),
        ],
        trackID: buildWithAITrackID,
        trackTitle: buildWithAITrackTitle,
        trackOrder: 1,
        prerequisiteCourseIDs: ["ai-first-win"]
    )

    /// YouTube Basics — goals only. No button names, grid cells, or layout contracts.
    static let youtubeBasicsCourse = ClickyCourse(
        id: "youtube-basics",
        title: "YouTube Basics",
        subtitle: "Search, watch, and find your way around",
        description: "Learn the essentials of watching videos on YouTube — Teachy coaches you toward each goal using whatever the site looks like today.",
        iconSystemName: "play.rectangle.fill",
        estimatedMinutes: 10,
        startURL: "https://www.youtube.com",
        learningOutcomes: [
            "Open YouTube in a browser",
            "Search for a video",
            "Open and play a video",
            "Use basic player controls (pause, volume, fullscreen)",
            "Get back to the homepage or main sections",
        ],
        goals: [
            CourseLearningGoal(
                id: "youtube-open",
                title: "Open YouTube",
                goal: "Have YouTube open in a browser so you can start watching.",
                coachAsk: "Help me get YouTube open in my browser and show me where I'd start looking around.",
                doneWhen: "YouTube is open and recognizable as the YouTube site (homepage or main feed).",
                tips: ["Any modern browser is fine", "Signing in is optional"]
            ),
            CourseLearningGoal(
                id: "youtube-search",
                title: "Search for a video",
                goal: "Find videos by searching for something you want to watch.",
                coachAsk: "How do I search on YouTube for a video I actually want to watch? Point at what I should use.",
                doneWhen: "Search results are showing — a list or grid of videos matching a search.",
                tips: ["Search for anything you like"]
            ),
            CourseLearningGoal(
                id: "youtube-play",
                title: "Play a video",
                goal: "Open a video and get it playing (or ready to play) on the watch page.",
                coachAsk: "How do I open a video from here and start watching it? Point at what I should click.",
                doneWhen: "A video watch page is open with a video player visible.",
                tips: ["Any video is fine for this step"]
            ),
            CourseLearningGoal(
                id: "youtube-controls",
                title: "Use the player controls",
                goal: "Use basic playback controls — pause/play, volume, or fullscreen.",
                coachAsk: "I'm on a YouTube video — how do I pause, change volume, or go fullscreen? Point at the controls I should try.",
                doneWhen: "The learner has used at least one player control, or the watch page controls are clearly available and they've confirmed they're done trying.",
                tips: ["Hover the video if controls are hidden"]
            ),
            CourseLearningGoal(
                id: "youtube-navigate",
                title: "Find your way around",
                goal: "Navigate back to the homepage or another main section of YouTube.",
                coachAsk: "How do I get back to the YouTube homepage or jump to another main section? Point at what I should use.",
                doneWhen: "The learner is on the YouTube homepage or another main section (not stuck on a single watch page).",
                tips: ["Logo and side navigation are common patterns — use whatever exists today"]
            ),
        ],
        trackID: nil,
        trackTitle: nil,
        trackOrder: nil,
        prerequisiteCourseIDs: nil
    )

    /// Khan Academy Basics — goals only. Works even if the site redesigns.
    static let khanAcademyBasicsCourse = ClickyCourse(
        id: "khan-academy-basics",
        title: "Khan Academy Basics",
        subtitle: "Find a subject, open a lesson, and try practice",
        description: "Get comfortable on Khan Academy — Teachy coaches you toward each goal using whatever the site looks like today.",
        iconSystemName: "book.fill",
        estimatedMinutes: 12,
        startURL: "https://www.khanacademy.org",
        learningOutcomes: [
            "Open Khan Academy in a browser",
            "Browse or search for a subject",
            "Open a lesson, video, or article",
            "Start a practice exercise if one is available",
            "Find your way back to courses or the homepage",
        ],
        goals: [
            CourseLearningGoal(
                id: "khan-open",
                title: "Open Khan Academy",
                goal: "Have Khan Academy open in a browser so you can start learning.",
                coachAsk: "Help me get Khan Academy open in my browser and show me where I'd start exploring.",
                doneWhen: "Khan Academy is open and recognizable as the Khan Academy site.",
                tips: ["Any modern browser is fine", "Signing in is optional for exploring"]
            ),
            CourseLearningGoal(
                id: "khan-find-subject",
                title: "Find a subject",
                goal: "Browse or search until you land on a subject or topic area you care about.",
                coachAsk: "How do I find a subject on Khan Academy — like math, science, or something else I'm into? Point at what I should use.",
                doneWhen: "A subject, course, or topic listing is visible (not just the generic marketing homepage).",
                tips: ["Any subject is fine", "Search or browse both work"]
            ),
            CourseLearningGoal(
                id: "khan-open-lesson",
                title: "Open a lesson",
                goal: "Open a lesson, video, or article so learning content is on screen.",
                coachAsk: "How do I open an actual lesson or video from here? Point at what I should click.",
                doneWhen: "A lesson, video player, article, or unit content page is open.",
                tips: ["Any lesson in the subject is fine"]
            ),
            CourseLearningGoal(
                id: "khan-try-practice",
                title: "Try practice",
                goal: "Start a practice exercise, quiz, or interactive problem — or clearly find where practice lives if one isn't available yet.",
                coachAsk: "I'd like to try a practice problem on Khan Academy. Point at how I start practice or an exercise from here.",
                doneWhen: "A practice exercise, quiz, or problem UI is visible, or the learner has confirmed they found where practice lives and are done trying.",
                tips: ["If this lesson has no practice, finding the practice entry point still counts"]
            ),
            CourseLearningGoal(
                id: "khan-navigate",
                title: "Find your way around",
                goal: "Navigate back to courses, subjects, or the Khan Academy homepage.",
                coachAsk: "How do I get back to courses or the Khan Academy homepage from here? Point at what I should use.",
                doneWhen: "The learner is on a main courses/subjects area or the Khan Academy homepage (not stuck inside one lesson).",
                tips: ["Logo and main navigation are common patterns — use whatever exists today"]
            ),
        ],
        trackID: nil,
        trackTitle: nil,
        trackOrder: nil,
        prerequisiteCourseIDs: nil
    )

    // MARK: - Git & GitHub track (progressive path)

    /// Part 1 — browse GitHub before touching the command line.
    static let githubBasicsCourse = ClickyCourse(
        id: "github-basics",
        title: "Explore GitHub",
        subtitle: "Repos, README, issues, and pull requests",
        description: "First stop on the Git & GitHub path — get comfortable browsing public projects before you touch git or create anything.",
        iconSystemName: "globe",
        estimatedMinutes: 15,
        startURL: "https://github.com",
        learningOutcomes: [
            "Open GitHub in a browser",
            "Find and open a public repository",
            "Read a repo's overview or code",
            "Find the Issues area",
            "Find Pull Requests and understand what they are for",
            "Get back to search or your main GitHub home",
        ],
        goals: [
            CourseLearningGoal(
                id: "github-open",
                title: "Open GitHub",
                goal: "Have GitHub open in a browser so you can start exploring.",
                coachAsk: "Help me get GitHub open in my browser and show me where I'd start looking around — this site feels dense.",
                doneWhen: "GitHub is open and recognizable as the GitHub site.",
                tips: ["Any modern browser is fine", "Signing in is optional for browsing public repos"]
            ),
            CourseLearningGoal(
                id: "github-find-repo",
                title: "Find a repository",
                goal: "Search or browse until a public repository page is open.",
                coachAsk: "How do I find a public repository on GitHub — like an open source project I care about? Point at what I should use.",
                doneWhen: "A repository page is open (code, overview, or files for a specific project).",
                tips: ["Any public repo is fine", "Try searching for something you know, like react or vscode"]
            ),
            CourseLearningGoal(
                id: "github-explore-code",
                title: "Explore the repo",
                goal: "Look around the repository — README, files, or overview — enough to see how the project is organized.",
                coachAsk: "I'm on a GitHub repo and it's a lot. Point at the README or main files area and help me figure out what I'm looking at.",
                doneWhen: "Repo content is visible — README, file tree, or code view — and the learner has confirmed they're oriented.",
                tips: ["You don't need to understand every file", "The README is usually the friendliest place to start"]
            ),
            CourseLearningGoal(
                id: "github-find-issues",
                title: "Find Issues",
                goal: "Open the Issues area for the repository and see how people report bugs and request features.",
                coachAsk: "Where are Issues on this GitHub repo? Point at how I open them and tell me what they're for in one casual sentence.",
                doneWhen: "The Issues list or Issues section for the repository is visible.",
                tips: ["Issues are how people track bugs and ideas", "Reading is enough — no need to file one"]
            ),
            CourseLearningGoal(
                id: "github-find-pull-requests",
                title: "Find Pull Requests",
                goal: "Open Pull Requests and get a plain-language sense of what they are (proposed code changes).",
                coachAsk: "Where are Pull Requests on this repo? Point at how I open them and explain what a pull request is like I'm new — keep it short.",
                doneWhen: "The Pull Requests list or Pull Requests section for the repository is visible.",
                tips: ["PRs are proposed changes waiting for review", "You can just look — contributing is optional"]
            ),
            CourseLearningGoal(
                id: "github-navigate",
                title: "Find your way around",
                goal: "Get back to GitHub search, explore, or the main homepage from inside a repo.",
                coachAsk: "How do I get out of this repo and back to searching or the main GitHub home? Point at what I should use.",
                doneWhen: "The learner is on GitHub search, explore, dashboard, or homepage — not stuck inside one repository.",
                tips: ["Logo and search are common escape hatches — use whatever exists today"]
            ),
        ],
        trackID: gitAndGitHubTrackID,
        trackTitle: gitAndGitHubTrackTitle,
        trackOrder: 1,
        prerequisiteCourseIDs: nil
    )

    /// Part 2 — real git on the Mac (Terminal), not just the website.
    static let githubGitFundamentalsCourse = ClickyCourse(
        id: "github-git-fundamentals",
        title: "Git on Your Mac",
        subtitle: "Clone, status, commit — in Terminal",
        description: "Part 2 of Git & GitHub — leave the website and use git locally. Teachy coaches you through Terminal using whatever's on your screen.",
        iconSystemName: "terminal",
        estimatedMinutes: 20,
        startURL: nil,
        learningOutcomes: [
            "Open Terminal (or another shell) on your Mac",
            "Confirm git is installed (or know how to get it)",
            "Clone a public repository to your computer",
            "Check status and see what changed",
            "Make a small edit and create a local commit",
        ],
        goals: [
            CourseLearningGoal(
                id: "git-open-terminal",
                title: "Open Terminal",
                goal: "Have a terminal window ready so you can run git commands.",
                coachAsk: "Help me open Terminal on my Mac and get to a prompt where I can type commands. Point at what I should use if I'm looking at the screen.",
                doneWhen: "A terminal or shell window is open and ready for typing.",
                tips: ["Terminal.app, iTerm, or Warp all work", "You just need a command prompt"]
            ),
            CourseLearningGoal(
                id: "git-check-installed",
                title: "Check that git works",
                goal: "Run a command that shows git is installed (or clearly see how to install it).",
                coachAsk: "How do I check whether git is installed on my Mac? Walk me through the command and point if something on screen helps.",
                doneWhen: "Terminal shows git version output, or the learner has started an install path and confirmed they're unblocked.",
                tips: ["git --version is the usual check", "macOS may prompt to install developer tools — that's okay"]
            ),
            CourseLearningGoal(
                id: "git-clone-repo",
                title: "Clone a repository",
                goal: "Clone a public GitHub repo onto your Mac so you have a local copy.",
                coachAsk: "Help me clone a public GitHub repository to my computer with git. I can pick any small public repo — guide me through clone and where the folder ends up.",
                doneWhen: "A clone completed successfully, or a local repo folder from the clone is visible in Terminal / Finder.",
                tips: ["Any small public repo is fine", "Pick a folder you're comfortable downloading into"]
            ),
            CourseLearningGoal(
                id: "git-status",
                title: "Check git status",
                goal: "Inside the cloned repo, run status (or equivalent) and understand what it's telling you.",
                coachAsk: "I'm in a cloned repo — how do I check git status and what does a clean vs dirty tree mean? Help me run it.",
                doneWhen: "git status (or clear status output) has been shown in the terminal for that repo.",
                tips: ["cd into the cloned folder first", "Clean usually means nothing to commit"]
            ),
            CourseLearningGoal(
                id: "git-make-commit",
                title: "Make a local commit",
                goal: "Change a file, stage it, and create a local commit with a message — no push required yet.",
                coachAsk: "Help me make a tiny edit in this repo, stage it, and create a local git commit. Keep it beginner-friendly and don't push yet.",
                doneWhen: "A new local commit exists (git log / status shows the commit), or the learner confirmed they completed commit.",
                tips: ["Editing README with a typo fix is perfect", "Push comes in the next course"]
            ),
        ],
        trackID: gitAndGitHubTrackID,
        trackTitle: gitAndGitHubTrackTitle,
        trackOrder: 2,
        prerequisiteCourseIDs: ["github-basics"]
    )

    /// Part 3 — create your own repo and get code onto GitHub.
    static let githubMakeARepoCourse = ClickyCourse(
        id: "github-make-a-repo",
        title: "Make a Repo & Push",
        subtitle: "Create on GitHub, connect remote, push",
        description: "Part 3 of Git & GitHub — create your own repository, wire up a remote, and push commits so your work lives on GitHub.",
        iconSystemName: "plus.rectangle.on.folder",
        estimatedMinutes: 25,
        startURL: "https://github.com/new",
        learningOutcomes: [
            "Create a new repository on GitHub",
            "Get a local project ready for git (init or existing folder)",
            "Connect the local repo to the GitHub remote",
            "Push commits so they appear on GitHub",
            "Confirm the code is visible on the GitHub repo page",
        ],
        goals: [
            CourseLearningGoal(
                id: "repo-create-on-github",
                title: "Create a repository",
                goal: "Create a new repository on GitHub (empty is fine).",
                coachAsk: "Help me create a new repository on GitHub. I'm signed in or ready to sign in — point at how to start a new repo and what to fill in at a high level.",
                doneWhen: "A new GitHub repository page exists (can be empty), or the create-repo form was completed.",
                tips: ["Public is fine for learning", "You can skip README if you already have local files"]
            ),
            CourseLearningGoal(
                id: "repo-local-ready",
                title: "Prepare a local project",
                goal: "Have a local folder that is a git repo (git init or an existing project) ready to connect.",
                coachAsk: "Help me get a local folder ready as a git repo — either init a new one with a simple file, or use a project I already have. No push yet.",
                doneWhen: "A local directory is a git repository with at least one commit (or clearly ready to connect).",
                tips: ["A folder with a single README is enough", "You can reuse work from Git on Your Mac"]
            ),
            CourseLearningGoal(
                id: "repo-add-remote",
                title: "Connect the remote",
                goal: "Add the GitHub repo as the remote for your local project.",
                coachAsk: "How do I connect my local git repo to the GitHub repo I just created? Walk me through adding the remote — look at my screen for Terminal or GitHub's suggested commands.",
                doneWhen: "A remote pointing at the GitHub repo is configured (e.g. git remote -v shows it), or the learner confirmed it's set.",
                tips: ["GitHub often shows the exact commands after create", "HTTPS or SSH both work — pick what you can auth with"]
            ),
            CourseLearningGoal(
                id: "repo-push",
                title: "Push to GitHub",
                goal: "Push your local commits so they land on GitHub.",
                coachAsk: "Help me push my local commits to GitHub. If auth pops up, coach me through whatever's on screen without assuming one login method.",
                doneWhen: "Push succeeded, or GitHub shows the commits/files from the local repo.",
                tips: ["Auth prompts are normal the first time", "If push fails, read the error together — don't panic"]
            ),
            CourseLearningGoal(
                id: "repo-confirm-online",
                title: "Confirm it's online",
                goal: "Open the GitHub repo page and see your files or latest commit there.",
                coachAsk: "Show me how to confirm my code is actually on GitHub — point at the repo page proof that the push worked.",
                doneWhen: "The GitHub repository page shows the pushed files or commit.",
                tips: ["Refresh the repo page if it still looks empty", "You're done when you can see your stuff online"]
            ),
        ],
        trackID: gitAndGitHubTrackID,
        trackTitle: gitAndGitHubTrackTitle,
        trackOrder: 3,
        prerequisiteCourseIDs: ["github-git-fundamentals"]
    )

    /// Part 4 — collaboration: branches, PRs, and contributing.
    static let githubCollaborateCourse = ClickyCourse(
        id: "github-collaborate",
        title: "Branches & Pull Requests",
        subtitle: "Branch, push, open a PR",
        description: "Part 4 of Git & GitHub — the collaboration loop: branch off main, push your branch, and open a pull request like real teams do.",
        iconSystemName: "arrow.triangle.branch",
        estimatedMinutes: 25,
        startURL: "https://github.com",
        learningOutcomes: [
            "Create a new git branch for a change",
            "Commit work on that branch",
            "Push the branch to GitHub",
            "Open a pull request",
            "Understand merge vs keeping the PR open for review",
        ],
        goals: [
            CourseLearningGoal(
                id: "collab-create-branch",
                title: "Create a branch",
                goal: "Create and switch to a new branch for a small change.",
                coachAsk: "Help me create a new git branch for a small change and switch to it. Keep the name simple — look at my Terminal if it's open.",
                doneWhen: "A new branch is checked out (git branch / status shows it).",
                tips: ["Something like fix-readme is a great name", "Stay off main/master for the experiment"]
            ),
            CourseLearningGoal(
                id: "collab-commit-on-branch",
                title: "Commit on the branch",
                goal: "Make a small change and commit it on your branch.",
                coachAsk: "Help me make a tiny change on this branch and commit it — same idea as before, just on the feature branch.",
                doneWhen: "At least one commit exists on the new branch.",
                tips: ["A README tweak is perfect"]
            ),
            CourseLearningGoal(
                id: "collab-push-branch",
                title: "Push the branch",
                goal: "Push your branch to GitHub so it exists remotely.",
                coachAsk: "Help me push this branch to GitHub so I can open a pull request next.",
                doneWhen: "The branch exists on the GitHub remote (push succeeded or branch visible on GitHub).",
                tips: ["First push of a branch often needs -u / upstream setup — coach whatever the tool suggests"]
            ),
            CourseLearningGoal(
                id: "collab-open-pr",
                title: "Open a pull request",
                goal: "Open a pull request from your branch into the default branch.",
                coachAsk: "Help me open a pull request on GitHub from my branch. Point at what I should use and explain what the PR is asking for in one casual sentence.",
                doneWhen: "A pull request page or create-PR flow is open for the branch.",
                tips: ["GitHub often shows a Compare & pull request banner after push", "Draft PRs are fine for learning"]
            ),
            CourseLearningGoal(
                id: "collab-understand-next",
                title: "Know what happens next",
                goal: "Understand merge vs leaving the PR open — and optionally merge if it's your own practice repo.",
                coachAsk: "I've got a pull request open — briefly explain merge vs leaving it for review, and point at the merge control if I want to finish on my own practice repo.",
                doneWhen: "The learner confirmed they understand the next step, or they merged the practice PR.",
                tips: ["On a throwaway practice repo, merging is fine", "On someone else's project, don't merge without permission"]
            ),
        ],
        trackID: gitAndGitHubTrackID,
        trackTitle: gitAndGitHubTrackTitle,
        trackOrder: 4,
        prerequisiteCourseIDs: ["github-make-a-repo"]
    )

    static func courseCoachSystemPrompt(
        for session: ClickyCourseSession,
        learnerProfile: CourseLearnerProfile = CourseLearnerProfile(),
        activeTeacherVideoNotes: String? = nil
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

        let lessonBrief = goal.teachingBriefPromptSection(activeTeacherVideoNotes: activeTeacherVideoNotes)
        let learnerSection = learnerProfile.promptSection

        return """
        you're teachy — a little blue buddy who lives in their menu bar. same energy as farza's intro: warm, playful, a little cheeky, always on their side.
        you're a 1:1 tutor on the mac. not a manual. not a lecture. not a corporate chatbot.
        you sit beside their cursor, look at their screen, and get THIS goal done — together.

        voice (this is you):
        - lowercase, casual, short. sound like texting a smart friend who actually cares.
        - one clear beat at a time. never a TED talk. never "certainly" / "simply" / "just".
        - celebrate tiny wins like they matter. roast confusion gently, never mock them.
        - specific > vague. if something's on screen, name it and POINT.
        - when stuck: empathy in half a breath, then the next move.
        - personality > polish. you'd rather be fun and clear than formal and "correct".

        COURSE: \(course.title)
        By the end they should be able to:
        \(outcomes)
        \(trackSection)

        CURRENT GOAL (\(session.currentStepIndex + 1) of \(course.stepCount)): \(goal.title)
        Success looks like: \(goal.goal)\(tipsSection)
        \(lessonBrief)
        \(learnerSection)

        \(TeachyCourseCapabilityCard.text)

        NEVER ASSUME THEY KNOW JARGON:
        - don't assume they know what Claude, ChatGPT, Cursor, HTML, a prompt, a browser tab, or a “chat” is.
        - introduce tools in one plain sentence the FIRST time you mention them
          (e.g. “Claude is a free AI website — you type what you want, and it writes back.”).
        - if learner model says they already know something, skip that explanation.
        - if they're advanced, stay short — don't lecture people who already get it.

        HOW YOU FORMAT EVERY REPLY (required):
        Always use BOTH tags so the app can style them differently:
        [INFO] one short plain-language explanation or context [/INFO]
        [TODO] one concrete action they should do next — the do-this-now beat [/TODO]
        - INFO = teaching / clarifying (not a button to click yet)
        - TODO = their move (click, type, open, paste, send)
        - one INFO + one TODO only. lowercase, warm. no markdown outside the tags.
        - still include [POINT:cell:label] when they should click something on screen (usually with TODO).
        - optionally append invisible memory tags (never speak them): [MEMORY:knows:short fact] or [MEMORY:confused:short fact]

        how you teach:
        - look at their screen RIGHT NOW. uis change — never assume old buttons or menus.
        - remember this session + learner model. don't re-explain what they just did or already know.
        - always leave them with ONE concrete next move in [TODO] — never two options, never a list.
        - urge them forward: if they're staring, off-track, or chatting idly, gently steer back to this goal.
        - default: [POINT:cell:label] at the real control and tell THEM to click it inside [TODO].
        - respect TOOL POLICY above when deciding whether to USE TOOLS.
        - never dump the curriculum. never say "simply" or "just".
        - if the goal is already done on screen, celebrate in [INFO] and tell them in [TODO] to say "next step".
        - when answering side questions: short [INFO] answer, then [TODO] that points them back to THIS goal.
        - if teacher clip notes are present, reference one beat from them — don't ignore the human teacher.

        \(ScreenGridAnnotationUtility.modelInstructions)
        """
    }

    static func voiceKeyterms(forCourseID courseID: String) -> [String] {
        let sharedAdvance = ["next step", "exit course", "i did it"]
        switch courseID {
        case youtubeBasicsCourse.id:
            return [
                "YouTube",
                "search",
                "fullscreen",
                "subscribe",
                "pause",
                "play",
            ] + sharedAdvance
        case khanAcademyBasicsCourse.id:
            return [
                "Khan Academy",
                "Khan",
                "subject",
                "lesson",
                "practice",
                "exercise",
                "math",
            ] + sharedAdvance
        case githubBasicsCourse.id:
            return [
                "GitHub",
                "repository",
                "repo",
                "issues",
                "pull request",
                "pull requests",
                "README",
                "search",
            ] + sharedAdvance
        case githubGitFundamentalsCourse.id:
            return [
                "git",
                "GitHub",
                "Terminal",
                "clone",
                "commit",
                "status",
                "repository",
            ] + sharedAdvance
        case githubMakeARepoCourse.id:
            return [
                "git",
                "GitHub",
                "repository",
                "remote",
                "push",
                "commit",
                "Terminal",
            ] + sharedAdvance
        case githubCollaborateCourse.id:
            return [
                "git",
                "GitHub",
                "branch",
                "pull request",
                "merge",
                "push",
                "commit",
            ] + sharedAdvance
        default:
            return sharedAdvance
        }
    }
}
