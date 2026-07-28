import { buildOpenRouterHeaders } from './openRouterClient';

/**
 * Checking a key BEFORE we save it.
 *
 * The old flow accepted whatever was in the field, encrypted it, and said "Key
 * saved". A learner who pasted a truncated key, the wrong string, or a key from
 * the wrong account got a green tick and then a wall of failures at their first
 * question — with no way to tell that the key was the problem. Nobody recovers
 * from that; they close the app.
 *
 * So the setup flow asks OpenRouter first and only saves what actually works.
 */

const OPENROUTER_KEY_ENDPOINT = 'https://openrouter.ai/api/v1/key';

/** OpenRouter issues keys prefixed `sk-or-`; the rest is opaque. */
const OPENROUTER_KEY_PATTERN = /\bsk-or-[A-Za-z0-9._-]{16,}\b/;

/**
 * True when the text looks like an OpenRouter key. Shape only — it says nothing
 * about whether the key works, and is used to spot a key in the clipboard and to
 * catch an obvious paste mistake before spending a round trip.
 */
export function looksLikeOpenRouterKey(candidateText: string): boolean {
  return OPENROUTER_KEY_PATTERN.test(candidateText.trim());
}

/**
 * Pulls a key out of pasted text. People paste with quotes, a trailing newline,
 * or the whole `OPENROUTER_API_KEY=sk-or-…` line from somewhere else — none of
 * which should read as "invalid key".
 */
export function extractOpenRouterKey(pastedText: string): string | null {
  return pastedText.trim().match(OPENROUTER_KEY_PATTERN)?.[0] ?? null;
}

export interface KeyValidationSuccess {
  outcome: 'valid';
  /** The label the learner gave the key on OpenRouter, when it has one. */
  keyLabel: string | null;
  /** Spend limit in USD, or null for no limit set. */
  limitUsd: number | null;
  /** Spend so far in USD, when OpenRouter reports it. */
  usageUsd: number | null;
  isFreeTier: boolean;
}

export interface KeyValidationFailure {
  outcome: 'rejected' | 'unreachable' | 'malformed';
  /** A sentence for the learner. Never a raw error or status code. */
  explanation: string;
}

export type KeyValidationResult = KeyValidationSuccess | KeyValidationFailure;

export async function validateOpenRouterKey(candidateKey: string): Promise<KeyValidationResult> {
  const key = candidateKey.trim();

  if (key.length === 0) {
    return { outcome: 'malformed', explanation: 'Paste your key first — it starts with sk-or-.' };
  }

  if (!looksLikeOpenRouterKey(key)) {
    return {
      outcome: 'malformed',
      explanation: "That doesn't look like an OpenRouter key. They start with sk-or- — copy the whole thing.",
    };
  }

  let response: Response;
  try {
    response = await fetch(OPENROUTER_KEY_ENDPOINT, { headers: buildOpenRouterHeaders(key) });
  } catch {
    return {
      outcome: 'unreachable',
      explanation: "I couldn't reach OpenRouter to check that key. Check your connection and try again.",
    };
  }

  if (response.status === 401 || response.status === 403) {
    return {
      outcome: 'rejected',
      explanation: 'OpenRouter says that key is not valid. Create a fresh one and paste it again.',
    };
  }

  if (!response.ok) {
    return {
      outcome: 'unreachable',
      explanation: 'OpenRouter is having trouble right now. Give it a minute and try again.',
    };
  }

  // Shape: { data: { label, limit, usage, is_free_tier } }. Every field is
  // optional as far as we are concerned — a valid key with no metadata is still
  // a valid key, and the flow must not fail on a missing nicety.
  let keyInformation: Record<string, unknown> = {};
  try {
    const responseJson = (await response.json()) as { data?: Record<string, unknown> };
    keyInformation = responseJson?.data ?? {};
  } catch {
    // 200 with an unreadable body still means the key authenticated.
  }

  return {
    outcome: 'valid',
    keyLabel: typeof keyInformation.label === 'string' && keyInformation.label.length > 0
      ? keyInformation.label
      : null,
    limitUsd: typeof keyInformation.limit === 'number' ? keyInformation.limit : null,
    usageUsd: typeof keyInformation.usage === 'number' ? keyInformation.usage : null,
    isFreeTier: keyInformation.is_free_tier === true,
  };
}
