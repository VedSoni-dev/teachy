/**
 * Routes model IDs based on request content (images, tools) and active provider.
 *
 * Each provider has different model naming conventions:
 *   - OpenRouter: "google/gemini-2.5-flash", "deepseek/deepseek-v4-flash"
 *   - Anthropic:  "claude-sonnet-4-6", "claude-opus-4-6"
 *   - OpenAI:     "gpt-4o", "gpt-4o-mini", "o3"
 */

// ─── Provider-Specific Defaults ──────────────────────────────────────────────

const PROVIDER_VISION_MODELS = {
  openrouter: 'google/gemini-2.5-flash',
  anthropic: 'claude-sonnet-4-6',
  openai: 'gpt-4o',
};

const PROVIDER_TEXT_MODELS = {
  openrouter: 'deepseek/deepseek-v4-flash',
  anthropic: 'claude-sonnet-4-6',
  openai: 'gpt-4o-mini',
};

/**
 * Detect the active provider from an explicit key or environment.
 * @param {'openrouter' | 'anthropic' | 'openai'} [providerOverride]
 */
function detectProvider(providerOverride) {
  if (providerOverride) return providerOverride;
  if (process.env.OPENROUTER_API_KEY) return 'openrouter';
  if (process.env.ANTHROPIC_API_KEY) return 'anthropic';
  if (process.env.OPENAI_API_KEY) return 'openai';
  return 'openrouter';
}

/**
 * Resolve the vision-capable model for the given provider.
 */
export function providerVisionModel(provider) {
  const resolved = detectProvider(provider);
  return process.env.VISION_MODEL || process.env.MODEL || PROVIDER_VISION_MODELS[resolved];
}

/**
 * Resolve the text-only model for the given provider.
 */
export function providerTextModel(provider) {
  const resolved = detectProvider(provider);
  return process.env.TEXT_MODEL || process.env.MODEL || PROVIDER_TEXT_MODELS[resolved];
}

// ─── OpenRouter-Specific Vision Detection ────────────────────────────────────

const TEXT_ONLY_MODEL_PREFIXES = ['deepseek/'];

/** Models known to accept image_url blocks on OpenRouter. */
const VISION_MODEL_PREFIXES = ['google/gemini', 'google/gemma', 'qwen/qwen3-vl'];

export function supportsVisionOnOpenRouter(modelID) {
  if (!modelID) return false;
  return VISION_MODEL_PREFIXES.some((prefix) => modelID.startsWith(prefix));
}

export function requestMessagesContainImages(messages) {
  if (!Array.isArray(messages)) return false;

  for (const message of messages) {
    if (!message || typeof message !== 'object') continue;
    const { content } = message;
    if (!Array.isArray(content)) continue;

    for (const block of content) {
      if (block?.type === 'image_url') return true;
    }
  }

  return false;
}

export function isTextOnlyModel(modelID) {
  if (!modelID) return false;
  return TEXT_ONLY_MODEL_PREFIXES.some((prefix) => modelID.startsWith(prefix));
}

// ─── Model Resolution ────────────────────────────────────────────────────────

/**
 * Resolve the model for /v1/chat/completions (agent loop).
 * Handles vision upgrade for OpenRouter text-only models.
 */
export function resolveCompletionsModel(requestedModel, messages, provider) {
  const resolvedProvider = detectProvider(provider);
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

/**
 * Resolve the model for /chat (companion vision).
 */
export function resolveChatModel(requestedModel, provider) {
  if (!requestedModel) return providerVisionModel(detectProvider(provider));
  return requestedModel;
}
