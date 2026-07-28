import type { CapturedScreen, InspectedElement } from '../types/global';
import { postOpenRouterChat } from './openRouterClient';

/**
 * The "Do it for me" agent loop — port of the macOS BackgroundAgentManager
 * tool-calling loop. The model sees the screen plus the UI Automation element
 * list, requests one concrete action at a time, and observes the result before
 * deciding again. The sidecar performs the actions.
 */

/**
 * Deliberately narrow vocabulary: screen-level actions a learner could perform
 * by hand. There is no shell tool and no filesystem tool, so a confused model
 * can only do what the learner could have done themselves.
 */
const AGENT_TOOL_SCHEMAS = [
  buildToolSchema(
    'click_element',
    'Click one interactive element from the element list, by its id number. Prefer this over coordinates — it clicks the real control.',
    { element_id: { type: 'integer', description: 'The [id] of the element to click, from the element list.' } },
    ['element_id'],
  ),
  buildToolSchema(
    'type_text',
    'Type text into a text field. Give the element id of the field; it is focused first.',
    {
      element_id: { type: 'integer', description: 'The [id] of the text field to type into.' },
      text: { type: 'string', description: 'The exact text to type.' },
    },
    ['element_id', 'text'],
  ),
  buildToolSchema(
    'press_key',
    'Press a single key: enter, tab, escape, backspace, delete, up, down, left, right, home, end, space.',
    { key: { type: 'string', description: 'The key name to press.' } },
    ['key'],
  ),
  buildToolSchema(
    'scroll',
    'Scroll the window under the pointer. Positive scrolls up, negative scrolls down.',
    { notches: { type: 'integer', description: 'Wheel notches, e.g. -3 to scroll down a bit.' } },
    ['notches'],
  ),
  buildToolSchema(
    'open_url',
    "Open a web page in the learner's default browser.",
    { url: { type: 'string', description: 'The full https:// URL to open.' } },
    ['url'],
  ),
  buildToolSchema(
    'observe_screen',
    'Take a fresh screenshot and re-read the interactive elements. Use this after the screen changes on its own (a page loading, a dialog appearing).',
    {},
    [],
  ),
];

function buildToolSchema(
  name: string,
  description: string,
  properties: Record<string, { type: string; description: string }>,
  required: string[],
) {
  return {
    type: 'function' as const,
    function: { name, description, parameters: { type: 'object', properties, required } },
  };
}

/**
 * Mirrors the macOS "do it for me" contract: narrate before acting, one small
 * step at a time, teach while doing rather than silently completing the work.
 */
export const AGENT_SYSTEM_PROMPT = `You are Teachy, doing a step FOR the learner because they asked you to — but you
are still a tutor, not a silent macro.

How to work:
- Before each action, say in one short sentence what you're about to do and why.
  That sentence is spoken aloud to the learner, so keep it natural and brief.
- Take ONE small action at a time, then look at the result before deciding again.
- Prefer click_element / type_text with element ids from the element list — those
  click the real control. Only fall back to other tools when no element fits.
- If the screen doesn't look like you expected, call observe_screen and re-read it
  rather than guessing.
- Stop as soon as the learner's immediate goal is met. Do not keep going into
  extra steps they didn't ask for.
- Never enter passwords, payment details, or personal information. Never accept
  terms, submit a purchase, or send a message on the learner's behalf. If a step
  needs any of that, stop and tell the learner to do that part themselves.
- When you're done, say what you did in one sentence and what they should look at.`;

/** Ceiling on actions per request so a confused model cannot flail forever. */
const MAXIMUM_AGENT_STEPS = 12;

export function formatElementList(elements: InspectedElement[] | null): string {
  if (!elements || elements.length === 0) {
    return '(no interactive elements could be read from this window — rely on the screenshot)';
  }
  return elements.map((element) => element.line).join('\n');
}

interface AgentMessage {
  role: string;
  content: unknown;
  tool_calls?: unknown;
  tool_call_id?: string;
}

/**
 * Runs the loop until the model stops requesting actions (or the step cap trips).
 * `onNarration` receives the model's spoken-aloud commentary as it works.
 */
export async function runAgentLoop({
  apiKey,
  modelIdentifier,
  userGoal,
  initialScreen,
  onNarration,
}: {
  apiKey: string;
  modelIdentifier: string;
  userGoal: string;
  initialScreen: CapturedScreen;
  onNarration: (narration: string) => void;
}): Promise<string> {
  const teachy = window.teachy;
  if (!teachy) {
    throw new Error('Teachy bridge unavailable.');
  }

  const conversation: AgentMessage[] = [
    { role: 'system', content: AGENT_SYSTEM_PROMPT },
    {
      role: 'user',
      content: [
        {
          type: 'text',
          text: `${userGoal}\n\nInteractive elements on the active window right now:\n${formatElementList(initialScreen.elements)}`,
        },
        {
          type: 'image_url',
          image_url: { url: `data:image/jpeg;base64,${initialScreen.jpegBase64}` },
        },
      ],
    },
  ];

  for (let stepIndex = 0; stepIndex < MAXIMUM_AGENT_STEPS; stepIndex++) {
    const assistantMessage = await requestNextAssistantMessage(apiKey, modelIdentifier, conversation);
    conversation.push(assistantMessage);

    const narration = typeof assistantMessage.content === 'string' ? assistantMessage.content : '';
    if (narration.trim().length > 0) {
      onNarration(narration);
    }

    const toolCalls = assistantMessage.tool_calls as
      | { id: string; function: { name: string; arguments: string } }[]
      | undefined;

    if (!toolCalls || toolCalls.length === 0) {
      // No more actions requested — the model considers the task done.
      return narration || 'Done.';
    }

    for (const toolCall of toolCalls) {
      const outcome = await executeAgentTool(toolCall.function.name, toolCall.function.arguments);

      conversation.push({
        role: 'tool',
        tool_call_id: toolCall.id,
        content: outcome.resultText,
      });

      // Re-observing costs a message but is what keeps the loop honest — the
      // model sees what its own action actually did, not what it intended.
      if (outcome.screenshotJpegBase64) {
        conversation.push({
          role: 'user',
          content: [
            { type: 'text', text: 'Here is the screen after that action.' },
            {
              type: 'image_url',
              image_url: { url: `data:image/jpeg;base64,${outcome.screenshotJpegBase64}` },
            },
          ],
        });
      }
    }
  }

  return "I've done as much as I safely can in one go — take a look and tell me what to do next.";
}

async function requestNextAssistantMessage(
  apiKey: string,
  modelIdentifier: string,
  conversation: AgentMessage[],
): Promise<AgentMessage> {
  const response = await postOpenRouterChat(apiKey, {
    model: modelIdentifier,
    messages: conversation,
    tools: AGENT_TOOL_SCHEMAS,
    tool_choice: 'auto',
  });

  if (!response.ok) {
    const errorBody = await response.text();
    throw new Error(`Agent request failed (${response.status}): ${errorBody.slice(0, 300)}`);
  }

  const responseJson = await response.json();
  const assistantMessage = responseJson?.choices?.[0]?.message;
  if (!assistantMessage) {
    throw new Error('Agent response had no message.');
  }
  return assistantMessage as AgentMessage;
}

interface AgentToolOutcome {
  resultText: string;
  screenshotJpegBase64?: string;
}

async function executeAgentTool(toolName: string, rawArguments: string): Promise<AgentToolOutcome> {
  const teachy = window.teachy!;

  let toolArguments: Record<string, unknown> = {};
  try {
    toolArguments = JSON.parse(rawArguments || '{}');
  } catch {
    return { resultText: 'Could not parse the arguments for that action.' };
  }

  try {
    switch (toolName) {
      case 'click_element': {
        await teachy.invoke('click-element', { elementId: Number(toolArguments.element_id) });
        return observeAfterAction(`Clicked element ${toolArguments.element_id}.`);
      }
      case 'type_text': {
        await teachy.invoke('type-text', {
          elementId: Number(toolArguments.element_id),
          text: String(toolArguments.text ?? ''),
        });
        return observeAfterAction(`Typed into element ${toolArguments.element_id}.`);
      }
      case 'press_key': {
        await teachy.invoke('press-key', { key: String(toolArguments.key ?? '') });
        return observeAfterAction(`Pressed ${toolArguments.key}.`);
      }
      case 'scroll': {
        const notches = Number(toolArguments.notches ?? -3);
        await teachy.invoke('scroll', { notches });
        return observeAfterAction(`Scrolled ${notches} notches.`);
      }
      case 'open_url': {
        // The sidecar independently rejects anything that is not http/https.
        await teachy.invoke('open-url', { url: String(toolArguments.url ?? '') });
        await delay(2200); // let the page start rendering before observing
        return observeAfterAction(`Opened ${toolArguments.url}.`);
      }
      case 'observe_screen':
        return observeAfterAction('Re-read the screen.');
      default:
        return { resultText: `Unknown tool "${toolName}".` };
    }
  } catch (toolError) {
    const message = toolError instanceof Error ? toolError.message : String(toolError);
    return { resultText: `That action failed: ${message}` };
  }
}

/** Re-reads screen and elements so the model's next decision reflects reality. */
async function observeAfterAction(resultText: string): Promise<AgentToolOutcome> {
  await delay(450); // let the UI settle
  const capturedScreen = await window.teachy!.invoke<CapturedScreen>('capture-screen', {
    includeElements: true,
  });
  return {
    resultText: `${resultText}\n\nInteractive elements now:\n${formatElementList(capturedScreen.elements)}`,
    screenshotJpegBase64: capturedScreen.jpegBase64,
  };
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
