//
//  LessonPlayer.swift
//  leanring-buddy
//
//  Goal-based course auto-prompter. Feeds natural coach asks into a tutor path
//  with memory, pointing, and optional Mac actions (navigate / click for them).
//

import AppKit
import Combine
import Foundation

@MainActor
final class LessonPlayer: ObservableObject {
    @Published private(set) var phase: CourseLessonPhase = .idle
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var currentBeatIndex: Int = 0
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var yourTurnPrompt: String = ""

    private let coursesManager: CoursesManager
    private weak var host: CompanionManager?
    private var playerTask: Task<Void, Never>?
    private var yourTurnContinuation: CheckedContinuation<YourTurnAction, Never>?
    private var hintTimeoutTask: Task<Void, Never>?
    private var didOpenStartURL = false
    private var didPlayCourseIntroVideo = false
    private var didRunPlacementCheck = false
    private var placementAnswerContinuation: CheckedContinuation<String, Never>?
    private var understandingAnswerContinuation: CheckedContinuation<String, Never>?

    private enum YourTurnAction {
        case confirm
        case hint
        case doItForMe
        case skip
        case cancel
    }

    init(coursesManager: CoursesManager, host: CompanionManager) {
        self.coursesManager = coursesManager
        self.host = host
    }

    // MARK: - Public API

    func start() {
        stopInternal(clearSession: false)
        didOpenStartURL = false
        didPlayCourseIntroVideo = false
        didRunPlacementCheck = false
        guard coursesManager.activeSession != nil else { return }

        playerTask = Task { [weak self] in
            await self?.runCourseLoop()
        }
    }

    func stop() {
        stopInternal(clearSession: false)
        phase = .idle
        yourTurnPrompt = ""
        isRunning = false
        coursesManager.setCourseInteractionRunning(false)
        coursesManager.setCourseTeachingPhase(.idle)
    }

    func handleEmptyHotkey() async {
        resumeYourTurn(.confirm)
    }

    func handleVoiceTranscript(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if placementAnswerContinuation != nil {
            if trimmed.isEmpty {
                submitPlacementAnswer("I'm brand new — explain everything")
            } else {
                submitPlacementAnswer(trimmed)
            }
            return
        }

        if understandingAnswerContinuation != nil {
            if trimmed.isEmpty {
                submitUnderstandingAnswer("i think i get it")
            } else {
                submitUnderstandingAnswer(trimmed)
            }
            return
        }

        if host?.isCurriculumVideoPlaying == true {
            if trimmed.isEmpty || ClickyCourseVoiceCommands.isSkipVideoRequest(transcript: trimmed) {
                host?.skipCurriculumVideo()
            }
            return
        }

        if trimmed.isEmpty {
            await handleEmptyHotkey()
            return
        }
        if ClickyCourseVoiceCommands.isManualAdvanceRequest(transcript: trimmed) {
            resumeYourTurn(.confirm)
            return
        }
        if Self.isDoItForMeRequest(transcript: trimmed) {
            resumeYourTurn(.doItForMe)
            return
        }
        await answerUserQuestion(trimmed)
    }

    func requestHint() {
        resumeYourTurn(.hint)
    }

    func requestDoItForMe() {
        resumeYourTurn(.doItForMe)
    }

    func skipBeat() {
        resumeYourTurn(.skip)
    }

    func confirmBeat() {
        if placementAnswerContinuation != nil {
            submitPlacementAnswer("I'm ready — start from the beginning")
            return
        }
        if understandingAnswerContinuation != nil {
            submitUnderstandingAnswer("i get it — we did the goal")
            return
        }
        resumeYourTurn(.confirm)
    }

    /// Chip tap during knowledge check.
    func submitPlacementAnswer(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let continuation = placementAnswerContinuation else { return }
        placementAnswerContinuation = nil
        continuation.resume(returning: trimmed)
    }

    /// Teach-back answer (voice or HUD).
    func submitUnderstandingAnswer(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let continuation = understandingAnswerContinuation else { return }
        understandingAnswerContinuation = nil
        continuation.resume(returning: trimmed)
    }

    // MARK: - Loop

    private func runCourseLoop() async {
        isRunning = true
        coursesManager.setCourseInteractionRunning(true)

        if !didRunPlacementCheck, let session = coursesManager.activeSession {
            didRunPlacementCheck = true
            // Only run intake when starting at the first goal (not resume mid-path).
            if session.currentStepIndex == 0 {
                await runPlacementCheck(session: session)
            }
        }

        while !Task.isCancelled, let session = coursesManager.activeSession {
            currentStepIndex = session.currentStepIndex
            let goalCompleted = await runCurrentGoal(session: session)
            guard !Task.isCancelled, coursesManager.activeSession != nil else { break }

            if goalCompleted {
                let advanced = await advanceAfterSuccessfulGoal(session: session)
                if !advanced { break }
            } else {
                break
            }
        }

        isRunning = false
        coursesManager.setCourseInteractionRunning(false)
        if coursesManager.activeSession == nil {
            phase = .idle
            coursesManager.setCourseTeachingPhase(.idle)
        }
    }

    /// Ask what they already know; optional AI skip-ahead.
    private func runPlacementCheck(session: ClickyCourseSession) async {
        guard let host else { return }

        setPhase(.coaching)
        coursesManager.setCourseInteractionRunning(true)
        host.ensureOverlayVisibleForCoursePointing()
        host.setCourseVoiceStateProcessing()

        let introAsk = """
        Before we start "\(session.course.title)", do a 20-second knowledge check.
        Explain in plain words what this path is about (building something tiny with an AI chatbot — \
        a website where you type and it writes back). Don't dump steps.
        Then ask what they already know. Offer the vibe of: brand new / used ChatGPT or Claude / already builds with AI.
        Use [INFO] and [TODO] tags. TODO should tell them to tap a chip on the HUD or hold ctrl+option and say it.
        """
        _ = await runCoachAsk(session: session, ask: introAsk, host: host, allowActions: false)
        guard !Task.isCancelled, coursesManager.activeSession != nil else { return }

        let placementPrompt = "quick check — tap a chip or hold ctrl+option and tell me what you already know."
        setPhase(.placement(prompt: placementPrompt))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        let answer = await waitForPlacementAnswer()
        guard !Task.isCancelled, coursesManager.activeSession != nil else { return }

        setPhase(.coaching)
        coursesManager.setCourseInteractionRunning(true)
        host.setCourseVoiceStateProcessing()

        do {
            let assessment = try await host.assessCoursePlacement(
                course: session.course,
                learnerAnswer: answer
            )
            if assessment.startGoalIndex > 0 {
                coursesManager.jumpToGoalIndex(
                    assessment.startGoalIndex,
                    reason: "placement: \(assessment.summaryForMemory)"
                )
                host.setCourseVoiceStateResponding()
                try? await host.speechSynthesizer.speakText(
                    "got it — i'll skip what you already know and meet you where you are."
                )
            } else {
                coursesManager.rememberAcrossGoals("placement: \(assessment.summaryForMemory)")
                host.setCourseVoiceStateResponding()
                try? await host.speechSynthesizer.speakText(
                    "perfect — i'll explain things as we go. no rush."
                )
            }
            host.setCourseVoiceStateIdle()
        } catch {
            print("⚠️ Placement assess error: \(error)")
            coursesManager.rememberAcrossGoals("placement answer (unassessed): \(answer)")
            host.setCourseVoiceStateIdle()
        }
    }

    private func waitForPlacementAnswer() async -> String {
        await withCheckedContinuation { continuation in
            placementAnswerContinuation?.resume(returning: "I'm brand new — explain everything")
            placementAnswerContinuation = continuation
        }
    }

    private func runCurrentGoal(session: ClickyCourseSession) async -> Bool {
        guard let host else { return false }
        let goal = session.currentGoal

        // Soft start once per course — open a homepage URL if provided (not a UI contract).
        if !didOpenStartURL, let startURL = session.course.startURL {
            setPhase(.settingUp)
            await CourseUIGrounder.openSetupURLIfNeeded(startURL)
            didOpenStartURL = true
            coursesManager.rememberAcrossGoals("opened start URL \(startURL)")
            try? await Task.sleep(for: .milliseconds(1400))
        }

        // Optional course-level long-form intro (Farza-style, beside Teachy) — once per session.
        if !didPlayCourseIntroVideo,
           let courseIntroVideoURL = session.course.resolvedCourseTeacherVideoURL {
            didPlayCourseIntroVideo = true
            setPhase(.watchingVideo)
            await host.playCurriculumVideoBesideCursor(
                urlString: courseIntroVideoURL,
                teacherCredit: session.course.teacherName ?? "course intro"
            )
            guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }
        }

        // Optional per-goal teacher clip before coaching — same beside-cursor player.
        if let goalTeacherVideoURL = goal.resolvedTeacherVideoURL {
            setPhase(.watchingVideo)
            let credit = goal.resolvedTeacherCredit(courseTeacherName: session.course.teacherName)
                ?? "part \(session.currentStepIndex + 1)"
            await host.playCurriculumVideoBesideCursor(
                urlString: goalTeacherVideoURL,
                teacherCredit: credit
            )
            guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }
            if let notes = goal.teacherVideoNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                coursesManager.setActiveTeacherVideoNotes(notes)
                coursesManager.rememberAcrossGoals("watched teacher clip for \(goal.title)")
            }
        } else if let notes = goal.teacherVideoNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !notes.isEmpty {
            // Author shipped notes without a stream URL — still useful teaching context.
            coursesManager.setActiveTeacherVideoNotes(notes)
        }

        // First teach: allow light actions (open/setup) + memory + pointing.
        let promptChipCue: String = {
            let chips = TeachyPromptChips.chips(forGoalID: goal.id)
            guard !chips.isEmpty else { return "" }
            let chipList = chips.prefix(3).joined(separator: " / ")
            return " Prompt chips are on the HUD (\(chipList)). If the chat is blank, urge them to tap a chip or paste one."
        }()
        let coached = await runCoachAsk(
            session: session,
            ask: """
            \(goal.coachAsk)

            Be Teachy — warm, playful, farza-energy. One clear next move only — point at the real control. \
            Urge them to do it now. If the wrong app/page is open, open the right one, then point. \
            Use the LESSON BRIEF and any teacher clip notes. Respect TOOL POLICY.\
            \(promptChipCue)
            """,
            host: host,
            allowActions: true
        )
        guard coached else { return false }

        var didOfferHint = false
        while !Task.isCancelled, coursesManager.activeSession != nil {
            let turnPrompt = "your turn — \(goal.title). hold ctrl+option, or say “next step” when you’ve got it."
            yourTurnPrompt = turnPrompt
            setPhase(.yourTurn(prompt: turnPrompt))
            coursesManager.setCourseInteractionRunning(false)
            host.setCourseVoiceStateIdle()
            // Invisible shell: panel out of the way — HUD + cursor carry the lesson.
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            scheduleHintTimeout(alreadyOffered: didOfferHint)
            let action = await waitForYourTurnAction()
            cancelHintTimeout()
            host.clearCoursePresenceBubble()

            switch action {
            case .cancel:
                return false

            case .skip:
                return true

            case .hint:
                didOfferHint = true
                coursesManager.recordHintPreference()
                let hintAsk = """
                They're stuck or idle on this goal: \(goal.goal). \
                Look at the screen. Urge them with ONE next click — point at it. \
                If they're offline-track or really blocked, do a small action, then point at the result. \
                Respect TOOL POLICY. Use LESSON BRIEF.
                """
                _ = await runCoachAsk(
                    session: session,
                    ask: hintAsk,
                    host: host,
                    allowActions: true
                )
                continue

            case .doItForMe:
                didOfferHint = true
                coursesManager.recordDoItForMePreference()
                let doItAsk = """
                They asked you to DO IT FOR THEM on this goal: \(goal.goal). \
                Use tools — navigate, click, type, or run terminal commands as needed (respect TOOL POLICY). \
                Then point at the result and explain in one short spoken sentence what you did so they still learn.
                """
                _ = await runCoachAsk(
                    session: session,
                    ask: doItAsk,
                    host: host,
                    allowActions: true
                )
                coursesManager.rememberAcrossGoals("did an action for them on: \(goal.title)")
                continue

            case .confirm:
                setPhase(.checking)
                coursesManager.setCourseInteractionRunning(true)
                host.setCourseVoiceStateProcessing()

                do {
                    let verifyResult = try await CourseVerifier.verify(
                        criteria: CourseSuccessCriteria(
                            visionDescription: goal.doneWhen ?? goal.goal,
                            urlContains: nil,
                            requireUserAdvance: true
                        ),
                        claudeAPI: host.claudeAPI,
                        treatAsUserAdvance: true
                    )

                    if verifyResult.passed {
                        let understood = await runUnderstandingBeatIfNeeded(
                            session: session,
                            goal: goal,
                            host: host
                        )
                        guard understood else {
                            didOfferHint = true
                            continue
                        }
                        host.flashCourseSuccessCelebration()
                        host.setCourseVoiceStateIdle()
                        setPhase(.celebrating)
                        try? await Task.sleep(for: .milliseconds(900))
                        return true
                    }

                    setPhase(.failed(hint: nil))
                    host.setCourseVoiceStateResponding()
                    try? await host.speechSynthesizer.speakText(
                        "not quite yet — i'll help you finish this."
                    )
                    let retryAsk = """
                    They tried to move on but this goal isn't done: \(goal.goal). \
                    Help them finish — point at what still matters, or do a small action if they're stuck.
                    """
                    _ = await runCoachAsk(
                        session: session,
                        ask: retryAsk,
                        host: host,
                        allowActions: true
                    )
                    didOfferHint = true
                } catch {
                    print("⚠️ LessonPlayer verify error: \(error)")
                    host.speakCourseError(error)
                    return false
                }
            }
        }

        return false
    }

    private func runCoachAsk(
        session: ClickyCourseSession,
        ask: String,
        host: CompanionManager,
        allowActions: Bool
    ) async -> Bool {
        setPhase(.coaching)
        coursesManager.setCourseInteractionRunning(true)
        host.ensureOverlayVisibleForCoursePointing()
        host.setCourseVoiceStateProcessing()

        do {
            let systemPrompt = coursesManager.buildCourseSystemPrompt(for: session)
            let conversationHistory = coursesManager.tutorConversationHistory(for: session)
            let turn = try await host.runCourseTutorTurn(
                userPrompt: ask,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                allowActions: allowActions
            )

            guard !Task.isCancelled else { return false }

            if let screenCapture = turn.screenCapture {
                host.applyPointingFromResponse(
                    turn.fullResponseText,
                    screenCapture: screenCapture
                )
                try? await Task.sleep(for: .milliseconds(450))
            }

            setPhase(.speaking)
            // Pull memory tags from both streams — TTS formatting may drop some brackets.
            _ = coursesManager.ingestCoachMemoryTags(from: turn.fullResponseText)
            let cleanedForSpeech = coursesManager.ingestCoachMemoryTags(from: turn.spokenText)
            let coachParts = CourseCoachMessageParts.parse(from: cleanedForSpeech)
            if !coachParts.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                host.setCourseVoiceStateResponding()
                try await host.speechSynthesizer.speakText(coachParts.spokenText)
            }

            coursesManager.appendStepConversation(
                userTranscript: ask,
                assistantResponse: cleanedForSpeech
            )
            host.setCourseVoiceStateIdle()
            return true
        } catch is CancellationError {
            return false
        } catch {
            print("⚠️ LessonPlayer coach ask error: \(error)")
            host.speakCourseError(error)
            return false
        }
    }

    /// Soft teach-back after vision success. Returns true if they can advance.
    private func runUnderstandingBeatIfNeeded(
        session: ClickyCourseSession,
        goal: CourseLearningGoal,
        host: CompanionManager
    ) async -> Bool {
        guard goal.shouldRunTeachBack else {
            if let concepts = goal.teachingContext?.concepts {
                for concept in concepts.prefix(3) {
                    coursesManager.noteLearnerKnows(concept)
                }
            }
            return true
        }

        let question = goal.teachingContext?.teachBackPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (question?.isEmpty == false)
            ? question!
            : "quick check — in your words, what did we just do?"

        setPhase(.coaching)
        coursesManager.setCourseInteractionRunning(true)
        _ = await runCoachAsk(
            session: session,
            ask: """
            The screen check passed for "\(goal.title)". Before we move on, run a 10-second understanding beat.
            Ask them this (warm, lowercase): \(prompt)
            Use [INFO] with the question vibe and [TODO] telling them to hold ctrl+option and answer, or tap “I get it” if they’re sure.
            Do not advance them yourself — just ask.
            """,
            host: host,
            allowActions: false
        )
        guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }

        setPhase(.understanding(prompt: prompt))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        let answer = await waitForUnderstandingAnswer()
        guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }

        setPhase(.checking)
        coursesManager.setCourseInteractionRunning(true)
        host.setCourseVoiceStateProcessing()

        do {
            let result = try await CourseUnderstandingVerifier.assessTeachBack(
                goal: goal,
                learnerAnswer: answer,
                claudeAPI: host.claudeAPI
            )
            for concept in result.learnedConcepts {
                coursesManager.noteLearnerKnows(concept)
            }
            for item in result.remainingConfusion {
                coursesManager.noteLearnerConfusedBy(item)
            }

            if result.understood {
                if let concepts = goal.teachingContext?.concepts {
                    for concept in concepts.prefix(2) {
                        coursesManager.noteLearnerKnows(concept)
                    }
                }
                coursesManager.rememberAcrossGoals("understood: \(goal.title)")
                host.setCourseVoiceStateResponding()
                try? await host.speechSynthesizer.speakText("love that — you actually get it.")
                host.setCourseVoiceStateIdle()
                return true
            }

            coursesManager.noteLearnerConfusedBy(goal.title)
            host.setCourseVoiceStateResponding()
            try? await host.speechSynthesizer.speakText(
                "almost — let me tighten that up real quick."
            )
            _ = await runCoachAsk(
                session: session,
                ask: """
                Their teach-back didn't show understanding yet for "\(goal.title)".
                They said: \(answer)
                Reason: \(result.reason)
                Re-teach the ONE missing idea in plain words using [INFO], then [TODO] asking them to try one more short explanation \
                or tap “I get it” if they can restate it. Keep them on this goal.
                """,
                host: host,
                allowActions: true
            )
            // Soft pass after one re-teach so we don't soft-lock.
            coursesManager.rememberAcrossGoals("retaught then soft-passed: \(goal.title)")
            return true
        } catch {
            print("⚠️ Teach-back assess error: \(error)")
            // Don't block progress on assess failure.
            return true
        }
    }

    private func waitForUnderstandingAnswer() async -> String {
        await withCheckedContinuation { continuation in
            understandingAnswerContinuation?.resume(returning: "i think i get it")
            understandingAnswerContinuation = continuation
        }
    }

    private func answerUserQuestion(_ question: String) async {
        guard let host, let session = coursesManager.activeSession else { return }
        let ask = """
        During the course they asked: \(question). \
        Current goal only: \(session.currentGoal.title) — \(session.currentGoal.goal). \
        Answer briefly like Teachy — warm, playful, short. Use LESSON BRIEF. Then urge them back — POINT at the one correct next control for THIS goal. \
        Don't wander into other goals. If they're ready to move on, tell them to say "next step".
        """
        _ = await runCoachAsk(session: session, ask: ask, host: host, allowActions: true)
        yourTurnPrompt = "your turn — \(session.currentGoal.title). hold ctrl+option to ask, or say “next step” when done."
        setPhase(.yourTurn(prompt: yourTurnPrompt))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()
    }

    private func advanceAfterSuccessfulGoal(session: ClickyCourseSession) async -> Bool {
        guard let host else { return false }

        ClickyAnalytics.trackCourseStepCompleted(
            courseID: session.course.id,
            stepID: session.currentGoal.id,
            stepIndex: session.currentStepIndex,
            voiceInitiated: true
        )

        if coursesManager.advanceToNextStep() != nil {
            host.setCourseVoiceStateResponding()
            try? await host.speechSynthesizer.speakText("bet, next one — i got you.")
            host.setCourseVoiceStateIdle()
            return true
        }

        ClickyAnalytics.trackCourseCompleted(
            courseID: session.course.id,
            courseTitle: session.course.title
        )
        coursesManager.presentCompletionCelebration(for: session.course)
        host.playTeachyUISound(.celebration)
        let completionText = coursesManager.spokenCourseCompletion(for: session.course)
        host.setCourseVoiceStateResponding()
        try? await host.speechSynthesizer.speakText(completionText)
        host.setCourseVoiceStateIdle()
        host.handleLessonPlayerCourseFinished()
        return false
    }

    // MARK: - Your-turn waiting

    private func waitForYourTurnAction() async -> YourTurnAction {
        await withCheckedContinuation { continuation in
            yourTurnContinuation?.resume(returning: .cancel)
            yourTurnContinuation = continuation
        }
    }

    private func resumeYourTurn(_ action: YourTurnAction) {
        guard let continuation = yourTurnContinuation else { return }
        yourTurnContinuation = nil
        continuation.resume(returning: action)
    }

    private func scheduleHintTimeout(alreadyOffered: Bool) {
        cancelHintTimeout()
        guard !alreadyOffered else { return }
        hintTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled else { return }
            self?.resumeYourTurn(.hint)
        }
    }

    private func cancelHintTimeout() {
        hintTimeoutTask?.cancel()
        hintTimeoutTask = nil
    }

    private func stopInternal(clearSession: Bool) {
        playerTask?.cancel()
        playerTask = nil
        cancelHintTimeout()
        if let placementAnswerContinuation {
            self.placementAnswerContinuation = nil
            placementAnswerContinuation.resume(returning: "I'm brand new — explain everything")
        }
        if let understandingAnswerContinuation {
            self.understandingAnswerContinuation = nil
            understandingAnswerContinuation.resume(returning: "i think i get it")
        }
        host?.clearCoursePresenceBubble()
        host?.courseSuccessCelebration = nil
        resumeYourTurn(.cancel)
        host?.skipCurriculumVideo()
        coursesManager.clearActiveTeacherVideoNotes()
        if clearSession {
            coursesManager.exitCourse()
        }
    }

    private func setPhase(_ newPhase: CourseLessonPhase) {
        phase = newPhase
        coursesManager.setCourseTeachingPhase(newPhase)
        if let prompt = newPhase.promptText {
            yourTurnPrompt = prompt
        }
    }

    private static func isDoItForMeRequest(transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phrases = [
            "do it for me",
            "do it yourself",
            "you do it",
            "can you do it",
            "click it for me",
            "open it for me",
            "just do it",
            "go ahead and do it",
        ]
        return phrases.contains { normalized == $0 || normalized.contains($0) }
    }
}
