// Single OpenRouter access point.
//
// Previously the endpoint, auth headers, and the HTTP-Referer were copy-pasted
// into companion.ts, agentLoop.ts, and courseVerifier.ts — three places to edit
// for any header/referer/endpoint change, and three chances to drift. Callers
// still own their response handling (SSE stream vs. single JSON), which
// legitimately differs; only the request plumbing is shared here.

export const OPENROUTER_CHAT_ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';

const OPENROUTER_REFERER = 'https://vedsoni-dev.github.io/teachy/';

export function buildOpenRouterHeaders(apiKey: string): Record<string, string> {
  return {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
    'HTTP-Referer': OPENROUTER_REFERER,
    'X-Title': 'Teachy',
  };
}

/**
 * POST a chat-completions request. Returns the raw Response so the caller can
 * stream it (companion/coach) or read it as JSON (verifier/agent).
 */
export function postOpenRouterChat(apiKey: string, body: Record<string, unknown>): Promise<Response> {
  return fetch(OPENROUTER_CHAT_ENDPOINT, {
    method: 'POST',
    headers: buildOpenRouterHeaders(apiKey),
    body: JSON.stringify(body),
  });
}
