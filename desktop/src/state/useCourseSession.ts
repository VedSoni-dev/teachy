import { useCallback, useRef, useState } from 'react';
import { GOALS_BY_COURSE_ID, type CourseLearningGoal } from '../data/courseGoals';
import type { CourseCatalogEntry } from '../data/courseCatalog';
import { verifyCourseGoal } from './courseVerifier';
import { runAgentLoop } from './agentLoop';
import {
  buildCompanionSystemPrompt,
  parseModelReply,
  resolvePointTagToScreenPixel,
  streamCompanionReply,
} from './companion';
import type { CapturedScreen, TeachyConfigSnapshot } from '../types/global';

const BRING_YOUR_OWN_KEY_MODEL = 'anthropic/claude-sonnet-4.6';

export interface CourseSessionState {
  course: CourseCatalogEntry;
  goals: CourseLearningGoal[];
  currentGoalIndex: number;
  coachLine: string;
  /** Set after a goal passes when it has a teach-back question pending. */
  isAwaitingTeachBack: boolean;
  isBusy: boolean;
}

export interface CourseProgressEntry {
  completedGoals: number;
  totalGoals: number;
  completed: boolean;
  lastActivityUtc: string;
}

/**
 * The LessonPlayer loop: coach the current goal against the live screen, gate
 * advancement on the goal's natural-language doneWhen, run soft teach-backs,
 * and persist progress so a course survives across days.
 */
export function useCourseSession() {
  const [session, setSession] = useState<CourseSessionState | null>(null);
  const sessionRef = useRef<CourseSessionState | null>(null);

  function updateSession(updater: (current: CourseSessionState) => CourseSessionState) {
    setSession((current) => {
      if (!current) return current;
      const next = updater(current);
      sessionRef.current = next;
      return next;
    });
  }

  /** Runs one coaching turn grounded in what is on screen right now. */
  const runCoachTurn = useCallback(async (coachAsk: string) => {
    const teachy = window.teachy;
    const activeSession = sessionRef.current;
    if (!teachy || !activeSession) {
      return;
    }

    updateSession((current) => ({ ...current, isBusy: true }));

    try {
      const apiKey = await teachy.invoke<string | null>('get-api-key');
      if (!apiKey) {
        updateSession((current) => ({
          ...current,
          isBusy: false,
          coachLine: 'Add your OpenRouter API key in Settings first.',
        }));
        return;
      }

      const capturedScreen = await teachy.invoke<CapturedScreen>('capture-screen', {
        includeElements: true,
      });
      const config = await teachy.invoke<TeachyConfigSnapshot>('get-config');
      const modelIdentifier = config.chatModel ?? BRING_YOUR_OWN_KEY_MODEL;

      const currentGoal = activeSession.goals[activeSession.currentGoalIndex];
      let systemPrompt = buildCompanionSystemPrompt(
        capturedScreen.width,
        capturedScreen.height,
        capturedScreen.elements,
        capturedScreen.circledGridCells,
      );

      // Course context keeps every turn pointed at the current goal rather than
      // answering generically — the macOS LessonPlayer behavior.
      systemPrompt += `

ACTIVE COURSE CONTEXT — you are running the course "${activeSession.course.title}".
Current goal (${activeSession.currentGoalIndex + 1} of ${activeSession.goals.length}): ${currentGoal.title}.
The learner is trying to: ${currentGoal.goal}
The goal is done when: ${currentGoal.doneWhen ?? 'the learner says they understand it'}
Coach them toward this goal from what you SEE on their screen right now —
one small concrete next step at a time, pointing at the real UI. Never dump
the whole plan. Celebrate real progress briefly, then move.`;

      const fullReply = await streamCompanionReply(
        apiKey,
        modelIdentifier,
        systemPrompt,
        coachAsk,
        capturedScreen.jpegBase64,
        (partialText) => {
          updateSession((current) => ({
            ...current,
            coachLine: parseModelReply(partialText).spokenText,
          }));
        },
      );

      const parsedReply = parseModelReply(fullReply);
      updateSession((current) => ({ ...current, coachLine: parsedReply.spokenText, isBusy: false }));

      void teachy.invoke('speak', { text: parsedReply.spokenText });

      if (parsedReply.pointTag) {
        const targetPoint = resolvePointTagToScreenPixel(parsedReply.pointTag, capturedScreen);
        if (targetPoint) {
          teachy.overlay.send({ type: 'point-at', point: targetPoint, label: parsedReply.pointTag.label });
        }
      }
    } catch (coachError) {
      const message = coachError instanceof Error ? coachError.message : String(coachError);
      updateSession((current) => ({ ...current, isBusy: false, coachLine: `Something went wrong: ${message}` }));
    }
  }, []);

  /** Starts (or resumes) a course, opening its soft-start URL if it has one. */
  const startCourse = useCallback(
    async (course: CourseCatalogEntry) => {
      const teachy = window.teachy;
      const goals = GOALS_BY_COURSE_ID[course.id];
      if (!teachy || !goals || goals.length === 0) {
        return;
      }

      // Resume where the learner left off — projects survive across days.
      let resumeGoalIndex = 0;
      try {
        const allProgress = await teachy.invoke<Record<string, CourseProgressEntry>>('get-progress');
        const courseProgress = allProgress?.[course.id];
        if (courseProgress && !courseProgress.completed) {
          resumeGoalIndex = Math.min(Math.max(courseProgress.completedGoals, 0), goals.length - 1);
        }
      } catch {
        // No saved progress is fine — start from the beginning.
      }

      if (course.startUrl) {
        void teachy.invoke('open-url', { url: course.startUrl }).catch(() => {
          // A failed browser launch must not block the coaching hand-off.
        });
      }

      const newSession: CourseSessionState = {
        course,
        goals,
        currentGoalIndex: resumeGoalIndex,
        coachLine: 'Getting your screen…',
        isAwaitingTeachBack: false,
        isBusy: true,
      };
      sessionRef.current = newSession;
      setSession(newSession);

      await runCoachTurn(goals[resumeGoalIndex].coachAsk);
    },
    [runCoachTurn],
  );

  const exitCourse = useCallback(() => {
    sessionRef.current = null;
    setSession(null);
    void window.teachy?.invoke('stop-speaking');
  }, []);

  const requestHint = useCallback(() => {
    const activeSession = sessionRef.current;
    if (!activeSession) return;
    const currentGoal = activeSession.goals[activeSession.currentGoalIndex];
    const tipsSuffix =
      currentGoal.tips.length > 0
        ? ` (Author tips you can draw from: ${currentGoal.tips.join('; ')})`
        : '';
    void runCoachTurn(
      `I'm stuck on: ${currentGoal.goal} Give me one concrete hint for my exact screen right now.${tipsSuffix}`,
    );
  }, [runCoachTurn]);

  /**
   * "Do it for me" — hands the current goal to the agent loop, which acts on
   * the real UI while narrating each step aloud before it happens.
   */
  const requestDoItForMe = useCallback(async () => {
    const teachy = window.teachy;
    const activeSession = sessionRef.current;
    if (!teachy || !activeSession || activeSession.isBusy) {
      return;
    }

    const currentGoal = activeSession.goals[activeSession.currentGoalIndex];
    const openingLine = "Okay — I'll do this part. Watch what I click.";
    updateSession((current) => ({ ...current, isBusy: true, coachLine: openingLine }));
    void teachy.invoke('speak', { text: openingLine });

    try {
      const apiKey = await teachy.invoke<string | null>('get-api-key');
      if (!apiKey) {
        updateSession((current) => ({
          ...current,
          isBusy: false,
          coachLine: 'Add your OpenRouter API key in Settings first.',
        }));
        return;
      }

      const config = await teachy.invoke<TeachyConfigSnapshot>('get-config');
      const initialScreen = await teachy.invoke<CapturedScreen>('capture-screen', {
        includeElements: true,
      });

      const finalSummary = await runAgentLoop({
        apiKey,
        modelIdentifier: config.chatModel ?? BRING_YOUR_OWN_KEY_MODEL,
        userGoal: `Do this step for the learner in the course "${activeSession.course.title}": ${currentGoal.goal} It is complete when: ${currentGoal.doneWhen ?? 'the learner can see it is done'}.`,
        initialScreen,
        onNarration: (narration) => {
          // Announce before the action lands, like the Mac agent.
          updateSession((current) => ({ ...current, coachLine: narration }));
          void teachy.invoke('speak', { text: narration });
        },
      });

      updateSession((current) => ({ ...current, isBusy: false, coachLine: finalSummary }));
    } catch (agentError) {
      const message = agentError instanceof Error ? agentError.message : String(agentError);
      updateSession((current) => ({
        ...current,
        isBusy: false,
        coachLine: `I couldn't finish that automatically: ${message}`,
      }));
    }
  }, []);

  /** Advances past the current goal, persisting progress. */
  const advanceToNextGoal = useCallback(
    async (whatWentWell: string) => {
      const teachy = window.teachy;
      const activeSession = sessionRef.current;
      if (!teachy || !activeSession) return;

      void teachy.invoke('record-goal-completed', {
        courseId: activeSession.course.id,
        completedGoals: activeSession.currentGoalIndex + 1,
        totalGoals: activeSession.goals.length,
      });

      const isFinalGoal = activeSession.currentGoalIndex >= activeSession.goals.length - 1;
      if (isFinalGoal) {
        const completionMessage = `That's the whole course — ${activeSession.course.title} done. ${whatWentWell}. Seriously nice work.`;
        updateSession((current) => ({ ...current, coachLine: completionMessage, isAwaitingTeachBack: false }));
        void teachy.invoke('speak', { text: completionMessage });
        return;
      }

      const nextGoalIndex = activeSession.currentGoalIndex + 1;
      const nextGoal = activeSession.goals[nextGoalIndex];

      const advanceMessage = `Nailed it — ${whatWentWell}. Next up: ${nextGoal.title}.`;
      void teachy.invoke('speak', { text: advanceMessage });

      const advancedSession: CourseSessionState = {
        ...activeSession,
        currentGoalIndex: nextGoalIndex,
        isAwaitingTeachBack: false,
        coachLine: advanceMessage,
      };
      sessionRef.current = advancedSession;
      setSession(advancedSession);

      await runCoachTurn(nextGoal.coachAsk);
    },
    [runCoachTurn],
  );

  /** "I did it" — verifies against the goal's doneWhen, or advances a concept goal. */
  const requestVerification = useCallback(async () => {
    const teachy = window.teachy;
    const activeSession = sessionRef.current;
    if (!teachy || !activeSession || activeSession.isBusy) return;

    const currentGoal = activeSession.goals[activeSession.currentGoalIndex];

    // While a teach-back is pending, "I did it" acts as skip — teach-backs are soft.
    if (activeSession.isAwaitingTeachBack) {
      await advanceToNextGoal("teach-back skipped, that's okay");
      return;
    }

    // Concept goals with no doneWhen advance on confirmation (requireUserAdvance).
    if (!currentGoal.doneWhen) {
      beginTeachBackOrAdvance(currentGoal, 'you confirmed it');
      return;
    }

    updateSession((current) => ({ ...current, isBusy: true, coachLine: 'Checking your screen…' }));

    try {
      const apiKey = await teachy.invoke<string | null>('get-api-key');
      if (!apiKey) return;

      const capturedScreen = await teachy.invoke<CapturedScreen>('capture-screen', {
        includeElements: false,
      });
      const config = await teachy.invoke<TeachyConfigSnapshot>('get-config');

      const verification = await verifyCourseGoal(
        apiKey,
        config.chatModel ?? BRING_YOUR_OWN_KEY_MODEL,
        currentGoal.doneWhen,
        capturedScreen.jpegBase64,
      );

      updateSession((current) => ({ ...current, isBusy: false }));

      // Mac parity: pass AND partial both advance; offTrack coaches the gap.
      if (verification.status === 'pass' || verification.status === 'partial') {
        beginTeachBackOrAdvance(currentGoal, verification.whatsGood);
      } else {
        const coachback =
          verification.suggestedNextAction ??
          verification.whatsMissing ??
          "Not quite there yet — keep going and press I did it when it's on screen.";
        updateSession((current) => ({ ...current, coachLine: coachback }));
        void teachy.invoke('speak', { text: coachback });
      }
    } catch (verifyError) {
      const message = verifyError instanceof Error ? verifyError.message : String(verifyError);
      updateSession((current) => ({ ...current, isBusy: false, coachLine: `Verification hiccup: ${message}` }));
    }

    function beginTeachBackOrAdvance(passedGoal: CourseLearningGoal, whatWentWell: string) {
      if (passedGoal.teachBackPrompt) {
        const teachBackAsk = `Nice — ${whatWentWell}. Quick teach-back before we move on: ${passedGoal.teachBackPrompt} Hold Ctrl+Alt and tell me — or press I did it to skip.`;
        updateSession((current) => ({ ...current, isAwaitingTeachBack: true, coachLine: teachBackAsk }));
        void teachy!.invoke('speak', { text: teachBackAsk });
      } else {
        void advanceToNextGoal(whatWentWell);
      }
    }
  }, [advanceToNextGoal]);

  return { session, startCourse, exitCourse, requestHint, requestVerification, requestDoItForMe };
}
