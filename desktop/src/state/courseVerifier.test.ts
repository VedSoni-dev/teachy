import { afterEach, describe, expect, it, vi } from 'vitest';
import { verifyCourseGoal } from './courseVerifier';

/**
 * The verifier is the gate between "learner keeps going" and "learner is told
 * they got it wrong". Its failure handling matters as much as its parsing: a
 * transport error must never read as a wrong answer.
 */

function mockOpenRouterJson(body: unknown, ok = true, status = 200) {
  return vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  } as Response);
}

function verifierReply(content: string) {
  return { choices: [{ message: { content } }] };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('verifyCourseGoal parsing', () => {
  it('reads a clean pass', async () => {
    mockOpenRouterJson(
      verifierReply('{"status":"pass","whatsGood":"the site is live","whatsMissing":null,"suggestedNextAction":null,"visibleErrorSummary":null}'),
    );
    const result = await verifyCourseGoal('key', 'model', 'site is live', 'base64');
    expect(result.status).toBe('pass');
    expect(result.whatsGood).toBe('the site is live');
  });

  it('reads a partial with the gap named', async () => {
    mockOpenRouterJson(
      verifierReply('{"status":"partial","whatsGood":"repo exists","whatsMissing":"no deploy yet","suggestedNextAction":"open Vercel","visibleErrorSummary":null}'),
    );
    const result = await verifyCourseGoal('key', 'model', 'deployed', 'base64');
    expect(result.status).toBe('partial');
    expect(result.whatsMissing).toBe('no deploy yet');
  });

  it('digs the JSON out of a model that wrapped it in prose or fences', async () => {
    mockOpenRouterJson(
      verifierReply('Sure! ```json\n{"status":"pass","whatsGood":"done","whatsMissing":null,"suggestedNextAction":null,"visibleErrorSummary":null}\n``` hope that helps'),
    );
    const result = await verifyCourseGoal('key', 'model', 'anything', 'base64');
    expect(result.status).toBe('pass');
  });
});

describe('verifyCourseGoal failure handling', () => {
  it('reports checkFailed — not offTrack — when the request errors', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));
    const result = await verifyCourseGoal('key', 'model', 'site is live', 'base64');

    // The distinction is the whole point: offTrack would count against the
    // learner's failure streak and tell them they did the step wrong.
    expect(result.status).toBe('checkFailed');
    expect(result.status).not.toBe('offTrack');
  });

  it('reports checkFailed on a non-ok HTTP status', async () => {
    mockOpenRouterJson({ error: 'nope' }, false, 503);
    const result = await verifyCourseGoal('key', 'model', 'site is live', 'base64');
    expect(result.status).toBe('checkFailed');
  });

  it('explains a check failure in learner words, with no raw error text', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(
      new Error("Error invoking remote method 'sidecar:send': Error: ECONNREFUSED 127.0.0.1:443"),
    );
    const result = await verifyCourseGoal('key', 'model', 'site is live', 'base64');

    const spokenLine = result.suggestedNextAction ?? '';
    expect(spokenLine).not.toContain('ECONNREFUSED');
    expect(spokenLine).not.toContain('remote method');
    expect(spokenLine.length).toBeGreaterThan(0);
  });

  it('never claims to know what is on screen when the check failed', async () => {
    // An unrecognised cause is logged for developers; keep it out of test output.
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('boom'));
    const result = await verifyCourseGoal('key', 'model', 'site is live', 'base64');
    expect(result.whatsGood).toBe('');
    expect(result.whatsMissing).toBeNull();
  });
});
