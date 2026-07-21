import { useCallback, useEffect, useRef } from 'react';
import {
  buildCompanionSystemPrompt,
  parseModelReply,
  resolvePointTagToScreenPixel,
  streamCompanionReply,
  type ConversationTurn,
} from './companion';
import type { CapturedScreen, TeachyConfigSnapshot } from '../types/global';

const BRING_YOUR_OWN_KEY_MODEL = 'anthropic/claude-sonnet-4.6';
const MAX_REMEMBERED_TURNS = 20;

/**
 * The always-on voice loop. Push-to-talk and transcription happen in the C#
 * sidecar; this hook takes the finished transcript and runs the rest of the
 * turn: capture the screen, ask the model, speak the reply, point at the target.
 *
 * Lives in the notch window (one instance) and drives the overlay over IPC.
 */
export function useCompanionLoop(courseTeachBackCallback?: (userAnswer: string) => void) {
  const isHandlingTurnRef = useRef(false);
  const conversationHistoryRef = useRef<ConversationTurn[]>([]);

  const runCompanionTurnRef = useRef<(userQuestion: string, isUserInitiated: boolean) => Promise<void>>();

  useEffect(() => {
    const teachy = window.teachy;
    if (!teachy) {
      return;
    }

    let restingOverlayMode: 'idle' | 'hidden' = 'idle';

    function setOverlay(mode: string, statusText?: string, bodyText?: string) {
      teachy?.overlay.send({ type: 'set-mode', mode, statusText, bodyText });
    }

    function restOverlay() {
      setOverlay(restingOverlayMode);
    }

    void (async () => {
      try {
        const config = await teachy.invoke<TeachyConfigSnapshot>('get-config');
        restingOverlayMode = config.showTeachyCursor ? 'idle' : 'hidden';
        restOverlay();
      } catch {
        restOverlay();
      }
    })();

    function rememberTurn(role: 'user' | 'assistant', text: string) {
      conversationHistoryRef.current.push({ role, text });
      while (conversationHistoryRef.current.length > MAX_REMEMBERED_TURNS) {
        conversationHistoryRef.current.shift();
      }
    }

    async function runCompanionTurn(userQuestion: string, isUserInitiated: boolean) {
      if (isHandlingTurnRef.current) {
        return;
      }
      isHandlingTurnRef.current = true;

      try {
        const apiKey = await teachy!.invoke<string | null>('get-api-key');
        if (!apiKey) {
          setOverlay('responding', undefined, 'Add your free OpenRouter API key in the Teachy panel first.');
          window.setTimeout(restOverlay, 6000);
          return;
        }

        setOverlay('thinking', 'looking at your screen…');

        const capturedScreen = await teachy!.invoke<CapturedScreen>('capture-screen', {
          includeElements: true,
        });

        setOverlay('thinking', 'thinking…');

        const config = await teachy!.invoke<TeachyConfigSnapshot>('get-config');
        const modelIdentifier = config.chatModel ?? BRING_YOUR_OWN_KEY_MODEL;

        const systemPrompt = buildCompanionSystemPrompt(
          capturedScreen.width,
          capturedScreen.height,
          capturedScreen.elements,
          capturedScreen.circledGridCells,
        );

        const fullReplyText = await streamCompanionReply(
          apiKey,
          modelIdentifier,
          systemPrompt,
          userQuestion,
          capturedScreen.jpegBase64,
          (partialText) => {
            setOverlay('responding', undefined, parseModelReply(partialText).spokenText);
          },
          conversationHistoryRef.current,
        );

        const parsedReply = parseModelReply(fullReplyText);
        setOverlay('responding', undefined, parsedReply.spokenText);

        rememberTurn('user', userQuestion);
        rememberTurn('assistant', parsedReply.spokenText);

        void teachy!.invoke('speak', { text: parsedReply.spokenText });

        if (parsedReply.pointTag) {
          const targetPoint = resolvePointTagToScreenPixel(parsedReply.pointTag, capturedScreen);
          if (targetPoint) {
            teachy!.overlay.send({
              type: 'point-at',
              point: targetPoint,
              label: parsedReply.pointTag.label,
            });
          }
        }

        // If a course teach-back is pending and this was user-initiated (voice/typed),
        // the user just answered — notify the course session to advance.
        if (isUserInitiated && courseTeachBackCallback) {
          courseTeachBackCallback(userQuestion);
        }

        const wordCount = parsedReply.spokenText.split(/\s+/).filter(Boolean).length;
        const estimatedSpeechSeconds = Math.min(30, Math.max(3, 1.5 + wordCount * 0.38));
        window.setTimeout(restOverlay, estimatedSpeechSeconds * 1000);
      } catch (turnError) {
        const message = turnError instanceof Error ? turnError.message : String(turnError);
        setOverlay('responding', undefined, `Something went wrong: ${message}`);
        window.setTimeout(restOverlay, 7000);
      } finally {
        isHandlingTurnRef.current = false;
      }
    }

    runCompanionTurnRef.current = runCompanionTurn;

    const unsubscribePressed = teachy.on('ptt-pressed', () => {
      setOverlay('listening', 'listening…');
    });

    const unsubscribeError = teachy.on('ptt-error', (payload) => {
      const message = (payload as { message?: string })?.message ?? 'Microphone unavailable.';
      setOverlay('responding', undefined, message);
      window.setTimeout(restOverlay, 6000);
    });

    const unsubscribeTranscript = teachy.on('transcript', (payload) => {
      const transcript = payload as { ok: boolean; text?: string; message?: string };

      if (!transcript.ok || !transcript.text) {
        setOverlay('responding', undefined, transcript.message ?? "I couldn't catch that.");
        window.setTimeout(restOverlay, 6000);
        return;
      }

      void runCompanionTurn(transcript.text, true);
    });

    return () => {
      unsubscribePressed?.();
      unsubscribeError?.();
      unsubscribeTranscript?.();
    };
  }, [courseTeachBackCallback]);

  const handleTypedQuestion = useCallback((typedQuestion: string) => {
    if (runCompanionTurnRef.current) {
      void runCompanionTurnRef.current(typedQuestion, true);
    }
  }, []);

  return { handleTypedQuestion };
}
