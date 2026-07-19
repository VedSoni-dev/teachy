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
    private var interactiveChoiceContinuation: CheckedContinuation<Int, Never>?
    private var interactiveChecklistContinuation: CheckedContinuation<Bool, Never>?
    private var interactiveFillInBlankContinuation: CheckedContinuation<String, Never>?

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

    func handleTextQuestion(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
        coursesManager.detectMoodFromUserResponse(trimmed)
        host?.teachyEngine.detectMood(from: trimmed)
        host?.teachyEngine.updateHumorReceptivity(from: trimmed)
        continuation.resume(returning: trimmed)
    }

    /// Teach-back answer (voice or HUD).
    func submitUnderstandingAnswer(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let continuation = understandingAnswerContinuation else { return }
        understandingAnswerContinuation = nil
        coursesManager.detectMoodFromUserResponse(trimmed)
        host?.teachyEngine.detectMood(from: trimmed)
        host?.teachyEngine.updateHumorReceptivity(from: trimmed)
        continuation.resume(returning: trimmed)
    }

    /// Option tap on an inline interactive multiple-choice widget.
    func submitInteractiveChoiceAnswer(_ index: Int) {
        guard let continuation = interactiveChoiceContinuation else { return }
        interactiveChoiceContinuation = nil
        continuation.resume(returning: index)
    }

    /// "Done" tap on an inline self-attested checklist widget.
    func submitInteractiveChecklistCompletion(_ completed: Bool) {
        guard let continuation = interactiveChecklistContinuation else { return }
        interactiveChecklistContinuation = nil
        continuation.resume(returning: completed)
    }

    /// "Continue" tap on an inline fill-in-the-blank widget.
    func submitInteractiveFillInBlankAnswer(_ text: String) {
        guard let continuation = interactiveFillInBlankContinuation else { return }
        interactiveFillInBlankContinuation = nil
        continuation.resume(returning: text)
    }

    // MARK: - Loop

    private func runCourseLoop() async {
        isRunning = true
        coursesManager.setCourseInteractionRunning(true)

        if !didRunPlacementCheck, let session = coursesManager.activeSession {
            didRunPlacementCheck = true
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
        NotificationCenter.default.post(name: .clickySwitchToCoursesTab, object: nil)

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

        if !didOpenStartURL, let startURL = session.course.startURL {
            setPhase(.settingUp)
            await CourseUIGrounder.openSetupURLIfNeeded(startURL)
            didOpenStartURL = true
            coursesManager.rememberAcrossGoals("opened start URL \(startURL)")
            try? await Task.sleep(for: .milliseconds(1400))
        }

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
            coursesManager.setActiveTeacherVideoNotes(notes)
        }

        if let multipleChoice = goal.interactiveMultipleChoice {
            return await runInteractiveChoiceStep(goal: goal, multipleChoice: multipleChoice, session: session, host: host)
        } else if let checklist = goal.interactiveChecklist {
            return await runInteractiveChecklistStep(goal: goal, checklist: checklist, session: session, host: host)
        } else if let fillInBlank = goal.interactiveFillInBlank {
            return await runInteractiveFillInBlankStep(goal: goal, fillInBlank: fillInBlank, session: session, host: host)
        }

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

            Be Teachy — warm, playful, teachy-energy. One clear next move only — point at the real control. \
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
            let turnPrompt = "your turn — \(goal.title). hold ctrl+option, or say \"next step\" when you've got it."
            yourTurnPrompt = turnPrompt
            setPhase(.yourTurn(prompt: turnPrompt))
            coursesManager.setCourseInteractionRunning(false)
            host.setCourseVoiceStateIdle()
            NotificationCenter.default.post(name: .clickySwitchToCoursesTab, object: nil)

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
                    let structuredResult = await CourseVerifier.verifyStructured(
                        criteria: CourseSuccessCriteria(
                            visionDescription: goal.doneWhen ?? goal.goal,
                            urlContains: nil,
                            requireUserAdvance: true
                        ),
                        claudeAPI: host.claudeAPI,
                        treatAsUserAdvance: true
                    )

                    Task { _ = await host.teachyEngine.processEvent(.goalAttempted(
                        goalID: goal.id,
                        attemptDescription: structuredResult.status.rawValue
                    )) }

                    switch structuredResult.status {
                    case .pass:
                        if goal.artifactDelta != nil, session.course.artifact != nil {
                            coursesManager.appendArtifactSnapshotFromVerifyResult(
                                goalID: goal.id,
                                result: structuredResult
                            )
                        }
                        let understood = await runUnderstandingBeatIfNeeded(
                            session: session,
                            goal: goal,
                            verifyResult: structuredResult,
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

                    case .partial:
                        if goal.artifactDelta != nil, session.course.artifact != nil {
                            coursesManager.appendArtifactSnapshotFromVerifyResult(
                                goalID: goal.id,
                                result: structuredResult
                            )
                        }
                        let missingDetail: String
                        if let missing = structuredResult.whatsMissing {
                            missingDetail = "What's still missing: \(missing)"
                        } else {
                            missingDetail = "Something specific is incomplete — look closely."
                        }
                        let nextAction: String
                        if let action = structuredResult.suggestedNextAction {
                            nextAction = "Suggested next move: \(action)"
                        } else {
                            nextAction = "Point them at the one remaining piece."
                        }
                        setPhase(.coaching)
                        host.setCourseVoiceStateResponding()
                        try? await host.speechSynthesizer.speakText(
                            "you're close — here's what's still needed."
                        )
                        let partialAsk = """
                        The screen check came back PARTIAL for "\(goal.title)".
                        What they got right: \(structuredResult.whatsGood)
                        \(missingDetail)
                        \(nextAction)
                        Acknowledge what they did right first, then guide them to the ONE missing piece. \
                        Point at it. Don't re-teach what already worked.
                        """
                        _ = await runCoachAsk(
                            session: session,
                            ask: partialAsk,
                            host: host,
                            allowActions: true
                        )
                        didOfferHint = true

                    case .offTrack:
                        let failureCount = coursesManager.incrementFailureCount(forGoalID: goal.id)

                        if failureCount >= 2, let remediationGoalID = goal.remediationGoalID {
                            let jumped = await runRemediationGoal(
                                session: session,
                                remediationGoalID: remediationGoalID,
                                originalGoal: goal,
                                host: host
                            )
                            if jumped {
                                didOfferHint = true
                                continue
                            }
                        }

                        setPhase(.failed(hint: nil))
                        host.setCourseVoiceStateResponding()
                        try? await host.speechSynthesizer.speakText(
                            "not quite yet — let me help you finish this."
                        )
                        let offTrackAsk: String
                        if failureCount >= 2, goal.toolPolicy == .canDoForThem || goal.toolPolicy == .helpWhenStuck {
                            offTrackAsk = """
                            They've tried this goal "\(goal.title)" multiple times and are still off track.
                            What they got right: \(structuredResult.whatsGood)
                            What's missing: \(structuredResult.whatsMissing ?? "the goal isn't done yet")
                            They seem frustrated. Since tool policy allows it, offer to do the specific \
                            automatable part for them — then explain what you did so they still learn. \
                            Be direct and kind.
                            """
                        } else {
                            offTrackAsk = """
                            They tried to move on but this goal isn't done: \(goal.goal).
                            What they got right: \(structuredResult.whatsGood)
                            What's missing: \(structuredResult.whatsMissing ?? "the goal isn't done yet")
                            Acknowledge what they did right, then help them finish — point at what still matters, \
                            or do a small action if they're stuck.
                            """
                        }
                        _ = await runCoachAsk(
                            session: session,
                            ask: offTrackAsk,
                            host: host,
                            allowActions: true
                        )
                        didOfferHint = true
                    }
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
            let relationshipMemory = host.teachyEngine.getLearnerModel()
            // Compute temporal continuity lines from existing data — how long since
            // last session, streak, stale skills, personality trend. `daysSinceLastSession`
            // was captured in `TeachyEngine.startSession` before `recordActivity` ran,
            // so it reflects the actual gap between sessions, not today's overwritten date.
            let temporalContinuityLines = LearnerTemporalContext.continuityLines(
                model: relationshipMemory,
                daysSinceLastSession: host.teachyEngine.daysSinceLastSession
            )
            let systemPrompt = coursesManager.buildCourseSystemPrompt(
                for: session,
                personalFacts: relationshipMemory.personalFacts,
                humorReceptivity: relationshipMemory.humorReceptivity,
                temporalContinuityLines: temporalContinuityLines
            )
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
            _ = coursesManager.ingestCoachMemoryTags(from: turn.fullResponseText)
            let cleanedForSpeech = coursesManager.ingestCoachMemoryTags(from: turn.spokenText)
            let coachParts = CourseCoachMessageParts.parse(from: cleanedForSpeech)
            if !coachParts.rememberedFacts.isEmpty {
                let factsToRemember = coachParts.rememberedFacts
                Task {
                    for fact in factsToRemember {
                        _ = await host.teachyEngine.processEvent(.personalFactShared(factText: fact))
                    }
                }
            }
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

    // MARK: - Interactive multiple choice

    /// Inline interactive widget step — no vision call, no off-screen action. Always
    /// advances after showing feedback (formative concept check, not a hard gate); see
    /// the "Architecture decision" note above `CourseInteractiveMultipleChoice`.
    private func runInteractiveChoiceStep(
        goal: CourseLearningGoal,
        multipleChoice: CourseInteractiveMultipleChoice,
        session: ClickyCourseSession,
        host: CompanionManager
    ) async -> Bool {
        setPhase(.interactiveChoice(prompt: multipleChoice.question))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()
        NotificationCenter.default.post(name: .clickySwitchToCoursesTab, object: nil)

        let selectedIndex = await waitForInteractiveChoiceAnswer()
        guard selectedIndex >= 0, coursesManager.activeSession != nil else { return false }

        let isCorrect = selectedIndex == multipleChoice.correctAnswerIndex
        Task { _ = await host.teachyEngine.processEvent(.goalAttempted(
            goalID: goal.id,
            attemptDescription: isCorrect ? "pass" : "offTrack"
        )) }

        host.flashCourseSuccessCelebration()
        host.setCourseVoiceStateIdle()
        setPhase(.celebrating)
        try? await Task.sleep(for: .milliseconds(900))
        return true
    }

    // MARK: - Interactive checklist

    /// Inline self-attested checklist step — sibling of `runInteractiveChoiceStep`. No
    /// right/wrong concept; checking items is a memory aid, not a gate, so "Done" always
    /// advances regardless of what (if anything) got checked.
    private func runInteractiveChecklistStep(
        goal: CourseLearningGoal,
        checklist: CourseInteractiveChecklist,
        session: ClickyCourseSession,
        host: CompanionManager
    ) async -> Bool {
        setPhase(.interactiveChecklist(prompt: checklist.prompt))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()
        NotificationCenter.default.post(name: .clickySwitchToCoursesTab, object: nil)

        let completed = await waitForInteractiveChecklistCompletion()
        guard completed, coursesManager.activeSession != nil else { return false }

        // Self-attested — there's no incorrect outcome, so this is always a "pass".
        Task { _ = await host.teachyEngine.processEvent(.goalAttempted(
            goalID: goal.id,
            attemptDescription: "pass"
        )) }

        host.flashCourseSuccessCelebration()
        host.setCourseVoiceStateIdle()
        setPhase(.celebrating)
        try? await Task.sleep(for: .milliseconds(900))
        return true
    }

    // MARK: - Interactive fill-in-the-blank

    /// Inline fill-in-the-blank step — sibling of `runInteractiveChoiceStep`. Local
    /// exact-match verification (trimmed/lowercased against `acceptableAnswers`) — no
    /// vision call, no LLM classifier. Always advances after showing feedback (formative
    /// concept check, not a hard gate), matching the multiple-choice widget's philosophy.
    private func runInteractiveFillInBlankStep(
        goal: CourseLearningGoal,
        fillInBlank: CourseInteractiveFillInBlank,
        session: ClickyCourseSession,
        host: CompanionManager
    ) async -> Bool {
        setPhase(.interactiveFillInBlank(prompt: fillInBlank.prompt))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()
        NotificationCenter.default.post(name: .clickySwitchToCoursesTab, object: nil)

        let submittedAnswer = await waitForInteractiveFillInBlankAnswer()
        let normalizedAnswer = submittedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAnswer.isEmpty, coursesManager.activeSession != nil else { return false }

        let isCorrect = fillInBlank.acceptableAnswers.contains { acceptable in
            acceptable.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedAnswer
        }
        Task { _ = await host.teachyEngine.processEvent(.goalAttempted(
            goalID: goal.id,
            attemptDescription: isCorrect ? "pass" : "offTrack"
        )) }

        host.flashCourseSuccessCelebration()
        host.setCourseVoiceStateIdle()
        setPhase(.celebrating)
        try? await Task.sleep(for: .milliseconds(900))
        return true
    }

    // MARK: - Adaptive teach-back (up to 3 turns)

    private func runUnderstandingBeatIfNeeded(
        session: ClickyCourseSession,
        goal: CourseLearningGoal,
        verifyResult: CourseVerificationResult,
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

        let initialQuestion = buildTeachBackQuestion(
            goal: goal,
            verifyResult: verifyResult,
            session: session
        )

        var previousAnswers: [String] = []

        for turnIndex in 0..<3 {
            guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }

            setPhase(.coaching)
            coursesManager.setCourseInteractionRunning(true)

            let coachPrompt: String
            if turnIndex == 0 {
                coachPrompt = """
                The screen check passed for "\(goal.title)". Before we move on, run a 10-second understanding beat.
                Ask them this (warm, lowercase): \(initialQuestion)
                Use [INFO] with the question vibe and [TODO] telling them to hold ctrl+option and answer, or tap "I get it" if they're sure.
                Do not advance them yourself — just ask.
                """
            } else {
                coachPrompt = """
                Follow up on the teach-back for "\(goal.title)".
                Previous answers: \(previousAnswers.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                Ask ONE focused follow-up question that helps them self-correct — don't re-explain the whole goal. \
                Use [INFO] to name what they got right, then [TODO] with one question.
                """
            }

            _ = await runCoachAsk(
                session: session,
                ask: coachPrompt,
                host: host,
                allowActions: false
            )
            guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }

            setPhase(.understanding(prompt: initialQuestion))
            coursesManager.setCourseInteractionRunning(false)
            host.setCourseVoiceStateIdle()
            NotificationCenter.default.post(name: .clickySwitchToCoursesTab, object: nil)

            let answer = await waitForUnderstandingAnswer()
            guard !Task.isCancelled, coursesManager.activeSession != nil else { return false }
            previousAnswers.append(answer)

            setPhase(.checking)
            coursesManager.setCourseInteractionRunning(true)
            host.setCourseVoiceStateProcessing()

            let assessment: CourseUnderstandingResult
            do {
                assessment = try await CourseUnderstandingVerifier.assessTeachBack(
                    goal: goal,
                    learnerAnswer: answer,
                    previousAnswers: previousAnswers,
                    claudeAPI: host.claudeAPI
                )
            } catch {
                print("⚠️ LessonPlayer teach-back assessment error: \(error)")
                host.setCourseVoiceStateIdle()
                setPhase(.coaching)
                break
            }
            for concept in assessment.learnedConcepts {
                coursesManager.noteLearnerKnows(concept)
            }
            for item in assessment.remainingConfusion {
                coursesManager.noteLearnerConfusedBy(item)
            }

            Task {
                let engineOutputs = await host.teachyEngine.processEvent(.teachBackResponse(responseText: answer))
                host.captureEngineOutputs(engineOutputs)
            }

            if assessment.understood {
                if let concepts = goal.teachingContext?.concepts {
                    for concept in concepts.prefix(2) {
                        coursesManager.noteLearnerKnows(concept)
                    }
                }
                coursesManager.rememberAcrossGoals("understood: \(goal.title)")
                host.setCourseVoiceStateResponding()
                let affirmation = assessment.learnedConcepts.first.map { concept in
                    "nice — you clearly get \(concept)."
                } ?? "love that — you actually get it."
                try? await host.speechSynthesizer.speakText(affirmation)
                host.setCourseVoiceStateIdle()
                return true
            }

            if turnIndex < 2 {
                coursesManager.noteLearnerConfusedBy(goal.title)
                host.setCourseVoiceStateResponding()
                try? await host.speechSynthesizer.speakText("almost — let me tighten that up.")
            }
        }

        coursesManager.rememberAcrossGoals("teach-back soft-passed after 3 turns: \(goal.title)")
        host.setCourseVoiceStateResponding()
        try? await host.speechSynthesizer.speakText("alright — let's keep moving, you'll solidify this as we go.")
        host.setCourseVoiceStateIdle()
        return true
    }

    private func buildTeachBackQuestion(
        goal: CourseLearningGoal,
        verifyResult: CourseVerificationResult,
        session: ClickyCourseSession
    ) -> String {
        if verifyResult.status == .partial, let missing = verifyResult.whatsMissing {
            return "you got partway there — can you walk me through what's still needed to finish \(goal.title)?"
        }

        let relatedConfusion = goal.teachingContext?.concepts?.filter { concept in
            coursesManager.learnerProfile.confusedBy.contains { confused in
                confused.localizedCaseInsensitiveContains(concept)
            }
        } ?? []

        if let confusedConcept = relatedConfusion.first {
            return "you mentioned being shaky on \(confusedConcept) earlier — how does it connect to what we just did?"
        }

        let authored = goal.teachingContext?.teachBackPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let authored, !authored.isEmpty {
            return authored
        }

        return "quick check — in your words, what did we just do and why did it work?"
    }

    // MARK: - Remediation

    private func runRemediationGoal(
        session: ClickyCourseSession,
        remediationGoalID: String,
        originalGoal: CourseLearningGoal,
        host: CompanionManager
    ) async -> Bool {
        guard let remediationGoal = session.course.goals.first(where: { $0.id == remediationGoalID }) else {
            return false
        }

        coursesManager.rememberAcrossGoals("entering remediation: \(remediationGoal.title) for \(originalGoal.title)")
        host.setCourseVoiceStateResponding()
        try? await host.speechSynthesizer.speakText(
            "let me walk you through this part step by step."
        )
        host.setCourseVoiceStateIdle()

        let remediationCoached = await runCoachAsk(
            session: session,
            ask: """
            \(remediationGoal.coachAsk)

            This is a focused remediation for a goal they're struggling with: \(originalGoal.goal).
            Be extra concrete. Show them exactly what to do, step by step. \
            Use [POINT:cell:label] aggressively. Respect TOOL POLICY.
            """,
            host: host,
            allowActions: true
        )
        guard remediationCoached else { return false }

        setPhase(.yourTurn(prompt: "follow the steps above — then say \"next step\""))
        coursesManager.setCourseInteractionRunning(false)
        host.setCourseVoiceStateIdle()

        let action = await waitForYourTurnAction()
        host.clearCoursePresenceBubble()

        switch action {
        case .confirm, .skip:
            coursesManager.rememberAcrossGoals("completed remediation: \(remediationGoal.title)")
            host.setCourseVoiceStateResponding()
            try? await host.speechSynthesizer.speakText("alright — now let's get back to the main goal.")
            host.setCourseVoiceStateIdle()
            return true
        case .cancel:
            return false
        case .hint, .doItForMe:
            return await runRemediationGoal(
                session: session,
                remediationGoalID: remediationGoalID,
                originalGoal: originalGoal,
                host: host
            )
        }
    }

    // MARK: - Waiting

    private func waitForUnderstandingAnswer() async -> String {
        await withCheckedContinuation { continuation in
            understandingAnswerContinuation?.resume(returning: "i think i get it")
            understandingAnswerContinuation = continuation
        }
    }

    private func waitForInteractiveChoiceAnswer() async -> Int {
        await withCheckedContinuation { continuation in
            interactiveChoiceContinuation?.resume(returning: -1)
            interactiveChoiceContinuation = continuation
        }
    }

    private func waitForInteractiveChecklistCompletion() async -> Bool {
        await withCheckedContinuation { continuation in
            interactiveChecklistContinuation?.resume(returning: false)
            interactiveChecklistContinuation = continuation
        }
    }

    private func waitForInteractiveFillInBlankAnswer() async -> String {
        await withCheckedContinuation { continuation in
            interactiveFillInBlankContinuation?.resume(returning: "")
            interactiveFillInBlankContinuation = continuation
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
        yourTurnPrompt = "your turn — \(session.currentGoal.title). hold ctrl+option to ask, or say \"next step\" when done."
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

        Task {
            let engineOutputs = await host.teachyEngine.processEvent(.goalCompleted(
                goalID: session.currentGoal.id,
                verificationSummary: "completed: \(session.currentGoal.title)"
            ))
            host.captureEngineOutputs(engineOutputs)
        }

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
        if let interactiveChoiceContinuation {
            self.interactiveChoiceContinuation = nil
            interactiveChoiceContinuation.resume(returning: -1)
        }
        if let interactiveChecklistContinuation {
            self.interactiveChecklistContinuation = nil
            interactiveChecklistContinuation.resume(returning: false)
        }
        if let interactiveFillInBlankContinuation {
            self.interactiveFillInBlankContinuation = nil
            interactiveFillInBlankContinuation.resume(returning: "")
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
