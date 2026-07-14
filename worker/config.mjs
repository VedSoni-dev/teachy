import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import {
  MODEL,
  TEXT_MODEL,
  VISION_MODEL,
  resolveChatModel,
  resolveCompletionsModel,
} from './model-routing.mjs';

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

export const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY;
export const ASSEMBLYAI_API_KEY = process.env.ASSEMBLYAI_API_KEY;
export const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';
export const PORT = parseInt(process.env.PORT || '8787', 10);

export { MODEL, TEXT_MODEL, VISION_MODEL, resolveChatModel, resolveCompletionsModel };

/** Legacy aliases — both routes use unified model routing now. */
export const CHAT_MODEL = process.env.CHAT_MODEL || MODEL;
export const AGENT_MODEL = process.env.AGENT_MODEL || MODEL;

/** Legacy Claude model IDs from the Swift UI map to OpenRouter models. */
const LEGACY_CLAUDE_MODEL_MAP = {
  'claude-sonnet-4-6': CHAT_MODEL,
  'claude-opus-4-6': CHAT_MODEL,
};

export function resolveChatModelRequest(requestedModel) {
  if (!requestedModel || requestedModel in LEGACY_CLAUDE_MODEL_MAP) {
    return resolveChatModel(undefined);
  }
  return resolveChatModel(requestedModel);
}

export function resolveAgentModel(requestedModel, messages) {
  if (!requestedModel) {
    return resolveCompletionsModel(undefined, messages);
  }
  return resolveCompletionsModel(requestedModel, messages);
}

export function openRouterHeaders(title = 'Teachy') {
  return {
    Authorization: `Bearer ${OPENROUTER_API_KEY}`,
    'Content-Type': 'application/json',
    'HTTP-Referer': `http://localhost:${PORT}`,
    'X-Title': title,
  };
}
