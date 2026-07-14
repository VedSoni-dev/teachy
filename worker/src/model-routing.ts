/**
 * Routes OpenRouter model IDs based on request content (images, tools, etc.).
 */

export const VISION_MODEL =
  process.env.VISION_MODEL || process.env.MODEL || 'google/gemini-2.5-flash';

export const TEXT_MODEL =
  process.env.TEXT_MODEL || process.env.MODEL || 'google/gemini-2.5-flash';

const TEXT_ONLY_MODEL_PREFIXES = ['deepseek/'];

/** Models known to accept image_url blocks on OpenRouter. */
const VISION_MODEL_PREFIXES = ['google/gemini', 'google/gemma', 'qwen/qwen3-vl'];

export function supportsVisionOnOpenRouter(modelID?: string): boolean {
  if (!modelID) return false;
  return VISION_MODEL_PREFIXES.some((prefix) => modelID.startsWith(prefix));
}

export function requestMessagesContainImages(messages: unknown): boolean {
  if (!Array.isArray(messages)) return false;

  for (const message of messages) {
    if (!message || typeof message !== 'object') continue;
    const content = (message as { content?: unknown }).content;
    if (!Array.isArray(content)) continue;

    for (const block of content) {
      if (block && typeof block === 'object' && (block as { type?: string }).type === 'image_url') {
        return true;
      }
    }
  }

  return false;
}

export function isTextOnlyModel(modelID?: string): boolean {
  if (!modelID) return false;
  return TEXT_ONLY_MODEL_PREFIXES.some((prefix) => modelID.startsWith(prefix));
}

/** Upgrades to a vision model when the request includes screenshots. */
export function resolveCompletionsModel(requestedModel: string | undefined, messages: unknown): string {
  const hasImages = requestMessagesContainImages(messages);

  if (!requestedModel) {
    return hasImages ? VISION_MODEL : TEXT_MODEL;
  }

  if (hasImages && (!supportsVisionOnOpenRouter(requestedModel) || isTextOnlyModel(requestedModel))) {
    return VISION_MODEL;
  }

  return requestedModel;
}

export function resolveChatModel(requestedModel: string | undefined): string {
  if (!requestedModel) return VISION_MODEL;
  return requestedModel;
}
