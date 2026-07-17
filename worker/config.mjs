import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Load worker/.env into process.env (simple KEY=VALUE parser). */
export function loadEnvFile() {
  const envPath = join(__dirname, '.env');
  if (!existsSync(envPath)) return;

  for (const line of readFileSync(envPath, 'utf-8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    const value = trimmed.slice(eqIdx + 1).trim().replace(/^["']|["']$/g, '');
    process.env[key] = value;
  }
}

loadEnvFile();

// ─── API Keys ────────────────────────────────────────────────────────────────

export const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY || '';
export const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';
export const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
export const ASSEMBLYAI_API_KEY = process.env.ASSEMBLYAI_API_KEY || '';
export const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY || '';
export const ELEVENLABS_VOICE_ID =
  process.env.ELEVENLABS_VOICE_ID || 'kPzsL2i3teMYv0FxEYQ6';

// ─── Provider Detection ──────────────────────────────────────────────────────

/**
 * The active AI provider, detected from which API key is present.
 * Priority: openrouter > anthropic > openai
 *
 * @type {'openrouter' | 'anthropic' | 'openai' | null}
 */
export const ACTIVE_PROVIDER = (() => {
  if (OPENROUTER_API_KEY) return 'openrouter';
  if (ANTHROPIC_API_KEY) return 'anthropic';
  if (OPENAI_API_KEY) return 'openai';
  return null;
})();

// ─── Per-Provider Default Models ─────────────────────────────────────────────

const PROVIDER_DEFAULTS = {
  openrouter: {
    vision: 'google/gemini-2.5-flash',
    text: 'deepseek/deepseek-v4-flash',
    chat: 'google/gemini-2.5-flash',
    agent: 'google/gemini-2.5-flash',
  },
  anthropic: {
    vision: 'claude-sonnet-4-6',
    text: 'claude-sonnet-4-6',
    chat: 'claude-sonnet-4-6',
    agent: 'claude-sonnet-4-6',
  },
  openai: {
    vision: 'gpt-4o',
    text: 'gpt-4o-mini',
    chat: 'gpt-4o',
    agent: 'gpt-4o',
  },
};

const defaults = ACTIVE_PROVIDER ? PROVIDER_DEFAULTS[ACTIVE_PROVIDER] : PROVIDER_DEFAULTS.openrouter;

/** Resolved model IDs — env overrides take precedence over provider defaults. */
export const MODEL = process.env.MODEL || defaults.vision;
export const VISION_MODEL = process.env.VISION_MODEL || process.env.MODEL || defaults.vision;
export const TEXT_MODEL = process.env.TEXT_MODEL || process.env.MODEL || defaults.text;

export const PORT = parseInt(process.env.PORT || '8787', 10);

/** Legacy aliases — both routes use unified model routing now. */
export const CHAT_MODEL = process.env.CHAT_MODEL || defaults.chat;
export const AGENT_MODEL = process.env.AGENT_MODEL || defaults.agent;

/** Legacy Claude model IDs from the Swift UI map to OpenRouter models. */
const LEGACY_CLAUDE_MODEL_MAP = {
  'claude-sonnet-4-6': CHAT_MODEL,
  'claude-opus-4-6': CHAT_MODEL,
};

export function resolveChatModelRequest(requestedModel) {
  if (!requestedModel || requestedModel in LEGACY_CLAUDE_MODEL_MAP) {
    return CHAT_MODEL;
  }
  return requestedModel;
}

export function resolveAgentModel(requestedModel, messages) {
  if (!requestedModel) {
    return AGENT_MODEL;
  }
  return requestedModel;
}

// ─── Provider-Specific API URLs ──────────────────────────────────────────────

export const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';
export const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
export const OPENAI_URL = 'https://api.openai.com/v1/chat/completions';

// ─── Headers ─────────────────────────────────────────────────────────────────

export function openRouterHeaders(title = 'Teachy') {
  return {
    Authorization: `Bearer ${OPENROUTER_API_KEY}`,
    'Content-Type': 'application/json',
    'HTTP-Referer': `http://localhost:${PORT}`,
    'X-Title': title,
  };
}

export function anthropicHeaders() {
  return {
    'x-api-key': ANTHROPIC_API_KEY,
    'anthropic-version': '2023-06-01',
    'content-type': 'application/json',
  };
}

export function openAIHeaders() {
  return {
    Authorization: `Bearer ${OPENAI_API_KEY}`,
    'Content-Type': 'application/json',
  };
}
