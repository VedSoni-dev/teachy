/**
 * Routes model IDs based on request content (images, tools) and active provider.
 *
 * Each provider has different model naming conventions:
 *   - OpenRouter: "google/gemini-2.5-flash", "deepseek/deepseek-v4-flash"
 *   - Anthropic:  "claude-sonnet-4-6", "claude-opus-4-6"
 *   - OpenAI:     "gpt-4o", "gpt-4o-mini", "o3"
 */

// ─── Provider-Specific Defaults ──────────────────────────────────────────────

const PROVIDER_VISION_MODELS: Record<string, string> = {
  openrouter: 'google/gemini-2.5-flash',
  anthropic: 'claude-sonnet-4-6',
  openai: 'gpt-4o',
};

const PROVIDER_TEXT_MODELS: Record<string, string> = {
  openrouter: 'deepseek/deepseek-v4-flash',
  anthropic: 'claude-sonnet-4-6',
  openai: 'gpt-4o-mini',
};

/**
 * Detect the active provider from environment variables.
 */
export function detectProvider(env?: Record<string, string | undefined>): string {
  const e = env || process.env;
  if (e.OPENROUTER_API_KEY) return 'openrouter';
  if (e.ANTHROPIC_API_KEY) return 'anthropic';
  if (e.OPENAI_API_KEY) return 'openai';
  return 'openrouter';
}

/**
 * Resolve the vision-capable model for the given provider.
 */
export function providerVisionModel(provider?: string): string {
  const resolved = provider || detectProvider();
  return process.env.VISION_MODEL || process.env.MODEL || PROVIDER_VISION_MODELS[resolved] || PROVIDER_VISION_MODELS.openrouter;
}

/**
 * Resolve the text-only model for the given provider.
 */
export function providerTextModel(provider?: string): string {
  const resolved = provider || detectProvider();
  return process.env.TEXT_MODEL || process.env.MODEL || PROVIDER_TEXT_MODELS[resolved] || PROVIDER_TEXT_MODELS.openrouter;
}

// ─── OpenRouter-Specific Vision Detection ────────────────────────────────────

const TEXT_ONLY_MODEL_PREFIXES = ['deepseek/'];

/** Models known to accept image_url blocks on OpenRouter. */
const VISION_MODEL_PREFIXES = ['google/gemini', 'google/gemma', 'qwen/qwen3-vl', 'anthropic/', 'openai/'];

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

// ─── Model Resolution ────────────────────────────────────────────────────────

/** Legacy defaults — kept for backward compat with openrouter.ts */
export const VISION_MODEL =
  process.env.VISION_MODEL || process.env.MODEL || 'google/gemini-2.5-flash';

export const TEXT_MODEL =
  process.env.TEXT_MODEL || process.env.MODEL || 'google/gemini-2.5-flash';

/** Upgrades to a vision model when the request includes screenshots. */
export function resolveCompletionsModel(
  requestedModel: string | undefined,
  messages: unknown,
  provider?: string
): string {
  const resolvedProvider = provider || detectProvider();
  const hasImages = requestMessagesContainImages(messages);

  if (!requestedModel) {
    return hasImages ? providerVisionModel(resolvedProvider) : providerTextModel(resolvedProvider);
  }

  // For OpenRouter, do vision upgrade logic for text-only models
  if (resolvedProvider === 'openrouter' && hasImages &&
      (!supportsVisionOnOpenRouter(requestedModel) || isTextOnlyModel(requestedModel))) {
    return providerVisionModel(resolvedProvider);
  }

  return requestedModel;
}

export function resolveChatModel(requestedModel: string | undefined, provider?: string): string {
  if (!requestedModel) return providerVisionModel(provider || detectProvider());
  return requestedModel;
}
