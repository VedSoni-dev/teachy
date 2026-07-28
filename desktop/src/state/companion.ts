import type { CapturedScreen, InspectedElement } from '../types/global';
import { postOpenRouterChat } from './openRouterClient';

/**
 * Builds the companion system prompt. Transcribed from CompanionPromptBuilder
 * on the Windows side, which in turn mirrors the macOS CompanionManager prompt —
 * same [POINT:...] contract, same 24x16 grid, same voice.
 */
export function buildCompanionSystemPrompt(
  screenshotWidth: number,
  screenshotHeight: number,
  elements: InspectedElement[] | null,
  circledGridCells: string | null,
): string {
  let systemPrompt = `You are Teachy — a real person sitting next to them at their Windows PC, looking at the same screen.
They just talked to you. Your reply is spoken out loud, so talk like a human coach in the room —
warm, clear, a little playful, never like Cortana, never like a help article, never like a corporate bot.

How you sound (spoken aloud):
- Natural sentences. Contractions. Short pauses implied with commas, not stage directions.
- Usually 1–2 short sentences. Three only if they asked for detail.
- Specific to WHAT YOU SEE on screen — name the real button, tab, or window.
- No emojis, no markdown, no bullet lists, no "as an AI".
- Never say "simply", "certainly", "I'd be happy to help", or "great question".
- Don't read code aloud — say what it does in plain words.
- If something's confusing, empathize in half a breath, then give the next move.
- When they should look somewhere, POINT at it with [POINT:...] so your cursor goes there —
  and say "here" / "right here" / "this one" ONLY when you're including that [POINT:...] tag
  in the same reply. If you can't confidently identify a specific, pointable target (vague
  references like "that tab" without a clear match), describe it in words instead — don't
  say "here" with nothing backing it, that's worse than not pointing at all.
- Feel like a sharp friend who actually wants them to get it — not a lecture.

SCREEN POINTING (invisible grid on screenshots — the user cannot see it):
- The screenshot has a hidden coordinate grid: columns A-X (24), rows 1-16.
- Image dimensions: ${screenshotWidth}x${screenshotHeight} pixels.
- To point at something on screen, include exactly one tag:
  [POINT:M7:short label]  (grid cell)
  [POINT:842,310:short label]  (raw screenshot pixels — only if you are confident)
- One POINT tag max per reply. Use [POINT:none] if nothing useful to point at.
- Only POINT when it helps them find something on screen.`;

  if (elements && elements.length > 0) {
    systemPrompt += `

INTERACTIVE ELEMENTS on the active window (read via UI Automation — these
have exact known positions, so pointing at one is pixel-accurate):
${elements.map((element) => element.line).join('\n')}

When your target is in that list, point at it with [POINT:ax:ID:short label]
— e.g. [POINT:ax:7:the Sign in button]. That is more accurate than a grid cell.`;
  }

  if (circledGridCells) {
    systemPrompt += `

THE LEARNER CIRCLED SOMETHING — the yellow chalk stroke on the screenshot is
their own drawing, made while asking this question. It covers grid cells:
${circledGridCells}.
Whatever they mean by "this" / "that" / "here" is inside that stroke. Answer
about what is circled, and ignore the chalk itself as page content.`;
  }

  return systemPrompt;
}

export interface ParsedPointTag {
  automationElementId: number | null;
  gridCell: string | null;
  pixelCoordinate: { x: number; y: number } | null;
  label: string | null;
}

export interface ParsedReply {
  spokenText: string;
  pointTag: ParsedPointTag | null;
}

const AUTOMATION_ELEMENT_PATTERN = /\[POINT:\s*ax:\s*(\d+)\s*(?::\s*([^\]]*?))?\s*\]/i;
const GRID_CELL_PATTERN = /\[POINT:(?:cell:)?\s*([A-Xa-x](?:1[0-6]|[1-9]))\s*(?::\s*([^\]:]*?))?\s*\]/;
const PIXEL_PATTERN = /\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::\s*([^\]:]*?))?\s*\]/;
const ANY_POINT_TAG_PATTERN = /\[POINT:[^\]]*\]/gi;

/**
 * Strips [POINT:...] tags out of a reply and returns the pointing target.
 * Priority matches macOS: ax element > grid cell > raw pixels.
 */
export function parseModelReply(modelReplyText: string): ParsedReply {
  let pointTag: ParsedPointTag | null = null;

  const automationMatch = modelReplyText.match(AUTOMATION_ELEMENT_PATTERN);
  const gridMatch = modelReplyText.match(GRID_CELL_PATTERN);
  const pixelMatch = modelReplyText.match(PIXEL_PATTERN);

  if (automationMatch) {
    pointTag = {
      automationElementId: Number.parseInt(automationMatch[1], 10),
      gridCell: null,
      pixelCoordinate: null,
      label: automationMatch[2]?.trim() ?? null,
    };
  } else if (gridMatch) {
    pointTag = {
      automationElementId: null,
      gridCell: gridMatch[1].toUpperCase(),
      pixelCoordinate: null,
      label: gridMatch[2]?.trim() ?? null,
    };
  } else if (pixelMatch) {
    pointTag = {
      automationElementId: null,
      gridCell: null,
      pixelCoordinate: {
        x: Number.parseInt(pixelMatch[1], 10),
        y: Number.parseInt(pixelMatch[2], 10),
      },
      label: pixelMatch[3]?.trim() ?? null,
    };
  }

  const spokenText = modelReplyText.replace(ANY_POINT_TAG_PATTERN, '').replace(/[ \t]{2,}/g, ' ').trim();
  return { spokenText, pointTag };
}

/** GridGeometry: 24 columns (A-X) by 16 rows, matching the burned-in grid. */
const GRID_COLUMN_COUNT = 24;
const GRID_ROW_COUNT = 16;

/** Resolves a point tag to screen pixels. An ax element wins — its bounds are exact. */
export function resolvePointTagToScreenPixel(
  pointTag: ParsedPointTag,
  capturedScreen: CapturedScreen,
): { x: number; y: number } | null {
  if (pointTag.automationElementId !== null && capturedScreen.elements) {
    const referencedElement = capturedScreen.elements.find(
      (element) => element.id === pointTag.automationElementId,
    );
    if (referencedElement) {
      return { x: referencedElement.centerX, y: referencedElement.centerY };
    }
  }

  if (pointTag.gridCell) {
    const columnIndex = pointTag.gridCell.charCodeAt(0) - 'A'.charCodeAt(0);
    const rowNumber = Number.parseInt(pointTag.gridCell.slice(1), 10);
    if (columnIndex < 0 || columnIndex >= GRID_COLUMN_COUNT || rowNumber < 1 || rowNumber > GRID_ROW_COUNT) {
      return null;
    }
    return {
      x: Math.round(((columnIndex + 0.5) / GRID_COLUMN_COUNT) * capturedScreen.width),
      y: Math.round(((rowNumber - 1 + 0.5) / GRID_ROW_COUNT) * capturedScreen.height),
    };
  }

  if (pointTag.pixelCoordinate) {
    return pointTag.pixelCoordinate;
  }

  return null;
}

export interface ConversationTurn {
  role: 'user' | 'assistant';
  text: string;
}

/** Streams a reply from OpenRouter with the screenshot attached. */
export async function streamCompanionReply(
  apiKey: string,
  modelIdentifier: string,
  systemPrompt: string,
  userMessage: string,
  screenshotJpegBase64: string,
  onPartialText: (partialText: string) => void,
  priorConversationTurns?: ConversationTurn[],
): Promise<string> {
  const messages: Array<Record<string, unknown>> = [
    { role: 'system', content: systemPrompt },
  ];

  if (priorConversationTurns) {
    for (const turn of priorConversationTurns) {
      messages.push({ role: turn.role, content: turn.text });
    }
  }

  messages.push({
    role: 'user',
    content: [
      { type: 'text', text: userMessage },
      {
        type: 'image_url',
        image_url: { url: `data:image/jpeg;base64,${screenshotJpegBase64}` },
      },
    ],
  });

  const response = await postOpenRouterChat(apiKey, {
    model: modelIdentifier,
    stream: true,
    messages,
  });

  if (!response.ok || !response.body) {
    const errorBody = await response.text();
    throw new Error(`OpenRouter request failed (${response.status}): ${errorBody.slice(0, 300)}`);
  }

  const streamReader = response.body.getReader();
  const textDecoder = new TextDecoder();
  let accumulatedText = '';
  let pendingBuffer = '';

  for (;;) {
    const { done, value } = await streamReader.read();
    if (done) {
      break;
    }

    pendingBuffer += textDecoder.decode(value, { stream: true });
    const bufferedLines = pendingBuffer.split('\n');
    // Keep the last (possibly partial) line for the next chunk.
    pendingBuffer = bufferedLines.pop() ?? '';

    for (const bufferedLine of bufferedLines) {
      if (!bufferedLine.startsWith('data: ')) {
        continue;
      }
      const sseData = bufferedLine.slice('data: '.length).trim();
      if (sseData === '[DONE]') {
        return accumulatedText;
      }
      try {
        const deltaText = JSON.parse(sseData)?.choices?.[0]?.delta?.content;
        if (typeof deltaText === 'string' && deltaText.length > 0) {
          accumulatedText += deltaText;
          onPartialText(accumulatedText);
        }
      } catch {
        // Keep-alive/comment lines are expected in SSE streams.
      }
    }
  }

  return accumulatedText;
}
