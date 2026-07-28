import { useCallback, useEffect, useRef, useState } from 'react';
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
import { DEFAULT_CHAT_MODEL } from './models';
import { describeFailureForLearner } from './failureMessages';

const AUTO_HINT_TIMEOUT_MS = 22_000;

export interface CourseSessionState {
  course: CourseCatalogEntry;
  goals: CourseLearningGoal[];
  currentGoalIndex: number;
  coachLine: string;
  isAwaitingTeachBack: boolean;
  isBusy: boolean;
}

export interface CourseProgressEntry {
  completedGoals: number;
  totalGoals: number;
  completed: boolean;
  lastActivityUtc: string;
}

export function useCourseSession() {
  const [session, setSession] = useState<CourseSessionState | null>(null);
  const sessionRef = useRef<CourseSessionState | null>(null);
  const goalFailureCountRef = useRef(0);
  const autoHintTimerRef = useRef<number | null>(null);

  function updateSession(updater: (current: CourseSessionState) => CourseSessionState) {
    setSession((current) => {
      if (!current) return current;
      const next = updater(current);
      sessionRef.current = next;
      return next;
    });
  }

  function clearAutoHintTimer() {
    if (autoHintTimerRef.current !== null) {
      window.clearTimeout(autoHintTimerRef.current);
      autoHintTimerRef.current = null;
    }
  }

  function startAutoHintTimer(hintCallback: () => void) {
    clearAutoHintTimer();
    autoHintTimerRef.current = window.setTimeout(() => {
      const activeSession = sessionRef.current;
      if (activeSession && !activeSession.isBusy && !activeSession.isAwaitingTeachBack) {
        hintCallback();
      }
    }, AUTO_HINT_TIMEOUT_MS);
  }

  useEffect(() => {
    return () => clearAutoHintTimer();
  }, []);

  const runCoachTurn = useCallback(async (coachAsk: string) => {
    const teachy = window.teachy;
    const activeSession = sessionRef.current;
    if (!teachy || !activeSession) {
      return;
    }

    clearAutoHintTimer();
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
      const modelIdentifier = config.chatModel ?? DEFAULT_CHAT_MODEL;

      const currentGoal = activeSession.goals[activeSession.currentGoalIndex];
      let systemPrompt = buildCompanionSystemPrompt(
        capturedScreen.width,
        capturedScreen.height,
        capturedScreen.elements,
        capturedScreen.circledGridCells,
      );

      systemPrompt += `

ACTIVE COURSE CONTEXT — you are running the course "${activeSession.course.title}".
Current goal (${activeSession.currentGoalIndex + 1} of ${activeSession.goals.length}): ${currentGoal.title}.
The learner is trying to: ${currentGoal.goal}
The goal is done when: ${currentGoal.doneWhen ?? 'the learner says they understand it'}

Be Teachy — warm, playful, teachy-energy. One clear next move only — point at
the real control. Urge them to do it now. If the wrong app or page is open,
tell them to open the right one, then point.
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

      // Start auto-hint timer after each coaching turn completes.
      startAutoHintTimer(() => {
        const currentSession = sessionRef.current;
        if (currentSession) {
          const goal = currentSession.goals[currentSession.currentGoalIndex];
          const autoHintLine = `Still working on this? Here's a nudge — ${goal.title}.`;
          updateSession((s) => ({ ...s, coachLine: autoHintLine }));
          void teachy.invoke('speak', { text: autoHintLine });
          void runCoachTurn(
            `The learner has been quiet for a while on: ${goal.goal}. Give them one concrete hint for their exact screen right now.`,
          );
        }
      });
    } catch (coachError) {
      updateSession((current) => ({
        ...current,
        isBusy: false,
        coachLine: describeFailureForLearner(coachError, 'get to your screen just then'),
      }));
    }
  }, []);

  const startCourse = useCallback(
    async (course: CourseCatalogEntry) => {
      const teachy = window.teachy;
      const goals = GOALS_BY_COURSE_ID[course.id];
      if (!teachy || !goals || goals.length === 0) {
        return;
      }

      let resumeGoalIndex = 0;
      try {
        const allProgress = await teachy.invoke<Record<string, CourseProgressEntry>>('get-progress');
        const courseProgress = allProgress?.[course.id];
        if (courseProgress && !courseProgress.completed) {
          resumeGoalIndex = Math.min(Math.max(courseProgress.completedGoals, 0), goals.length - 1);
        }
      } catch {
        // No saved progress — start from the beginning.
      }

      if (course.startUrl) {
        void teachy.invoke('open-url', { url: course.startUrl }).catch(() => {});
      }

      goalFailureCountRef.current = 0;

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
    clearAutoHintTimer();
    goalFailureCountRef.current = 0;
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

  const requestDoItForMe = useCallback(async () => {
    const teachy = window.teachy;
    const activeSession = sessionRef.current;
    if (!teachy || !activeSession || activeSession.isBusy) {
      return;
    }

    clearAutoHintTimer();
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
        modelIdentifier: config.chatModel ?? DEFAULT_CHAT_MODEL,
        userGoal: `Do this step for the learner in the course "${activeSession.course.title}": ${currentGoal.goal} It is complete when: ${currentGoal.doneWhen ?? 'the learner can see it is done'}.`,
        initialScreen,
        onNarration: (narration) => {
          updateSession((current) => ({ ...current, coachLine: narration }));
          void teachy.invoke('speak', { text: narration });
        },
      });

      updateSession((current) => ({ ...current, isBusy: false, coachLine: finalSummary }));
    } catch (agentError) {
      updateSession((current) => ({
        ...current,
        isBusy: false,
        coachLine: describeFailureForLearner(agentError, 'finish that step for you'),
      }));
    }
  }, []);

  const advanceToNextGoal = useCallback(
    async (whatWentWell: string) => {
      const teachy = window.teachy;
      const activeSession = sessionRef.current;
      if (!teachy || !activeSession) return;

      clearAutoHintTimer();
      goalFailureCountRef.current = 0;

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

  const requestVerification = useCallback(async () => {
    const teachy = window.teachy;
    const activeSession = sessionRef.current;
    if (!teachy || !activeSession || activeSession.isBusy) return;

    const currentGoal = activeSession.goals[activeSession.currentGoalIndex];

    if (activeSession.isAwaitingTeachBack) {
      await advanceToNextGoal("teach-back skipped, that's okay");
      return;
    }

    if (!currentGoal.doneWhen) {
      beginTeachBackOrAdvance(currentGoal, 'you confirmed it');
      return;
    }

    clearAutoHintTimer();
    updateSession((current) => ({ ...current, isBusy: true, coachLine: 'Checking your screen…' }));

    try {
      const apiKey = await teachy.invoke<string | null>('get-api-key');
      if (!apiKey) {
        // Returning here used to leave isBusy true, so the panel sat on
        // "Checking your screen…" forever with no way out.
        updateSession((current) => ({
          ...current,
          isBusy: false,
          coachLine: 'Add your OpenRouter API key in Settings, then press I did it again.',
        }));
        return;
      }

      const capturedScreen = await teachy.invoke<CapturedScreen>('capture-screen', {
        includeElements: false,
      });
      const config = await teachy.invoke<TeachyConfigSnapshot>('get-config');

      const verification = await verifyCourseGoal(
        apiKey,
        config.chatModel ?? DEFAULT_CHAT_MODEL,
        currentGoal.doneWhen,
        capturedScreen.jpegBase64,
      );

      updateSession((current) => ({ ...current, isBusy: false }));

      if (verification.status === 'checkFailed') {
        // We never got an answer, so we know nothing about their screen. Do NOT
        // count this against their failure streak — it was not their step that failed.
        const checkFailedLine =
          verification.suggestedNextAction ?? "I couldn't check your screen just then. Try I did it again.";
        updateSession((current) => ({ ...current, coachLine: checkFailedLine }));
        void teachy.invoke('speak', { text: checkFailedLine });
      } else if (verification.status === 'pass') {
        goalFailureCountRef.current = 0;
        beginTeachBackOrAdvance(currentGoal, verification.whatsGood);
      } else if (verification.status === 'partial') {
        // Partial does NOT advance — coach the gap, matching Mac behavior.
        const partialCoach = verification.whatsMissing
          ? `You're close — ${verification.whatsGood}. Still needed: ${verification.whatsMissing}`
          : `Almost there — ${verification.suggestedNextAction ?? "keep going and press I did it when it's fully done."}`;
        updateSession((current) => ({ ...current, coachLine: partialCoach }));
        void teachy.invoke('speak', { text: partialCoach });
      } else {
        // offTrack — increment failure count.
        goalFailureCountRef.current += 1;

        if (goalFailureCountRef.current >= 2) {
          // After 2+ failures, offer to do it for them.
          const offerLine = verification.suggestedNextAction
            ? `${verification.suggestedNextAction} — or if you're stuck, press "Do it for me" and I'll handle this step.`
            : "Not quite there yet — want me to do this one for you? Press \"Do it for me\" and I'll take over.";
          updateSession((current) => ({ ...current, coachLine: offerLine }));
          void teachy.invoke('speak', { text: offerLine });
        } else {
          const coachback =
            verification.suggestedNextAction ??
            verification.whatsMissing ??
            "Not quite there yet — keep going and press I did it when it's on screen.";
          updateSession((current) => ({ ...current, coachLine: coachback }));
          void teachy.invoke('speak', { text: coachback });
        }
      }
    } catch (verifyError) {
      updateSession((current) => ({
        ...current,
        isBusy: false,
        coachLine: describeFailureForLearner(verifyError, 'check that step off'),
      }));
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

  const handleVoiceTeachBackAnswer = useCallback(() => {
    const activeSession = sessionRef.current;
    if (activeSession?.isAwaitingTeachBack) {
      void advanceToNextGoal('teach-back done');
    }
  }, [advanceToNextGoal]);

  return { session, startCourse, exitCourse, requestHint, requestVerification, requestDoItForMe, handleVoiceTeachBackAnswer };
}
