import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  extractOpenRouterKey,
  looksLikeOpenRouterKey,
  validateOpenRouterKey,
} from './openRouterKey';

const workingKey = 'sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('looksLikeOpenRouterKey', () => {
  it('accepts a real-shaped key', () => {
    expect(looksLikeOpenRouterKey(workingKey)).toBe(true);
  });

  it.each([
    ['empty', ''],
    ['an OpenAI key', 'sk-proj-abcdefghijklmnopqrstuvwxyz012345'],
    ['the placeholder text', 'your-api-key-here'],
    ['a truncated key', 'sk-or-v1-0123'],
  ])('rejects %s', (_label, candidate) => {
    expect(looksLikeOpenRouterKey(candidate)).toBe(false);
  });
});

describe('extractOpenRouterKey', () => {
  it('survives the ways people actually paste', () => {
    // Every one of these is a real paste, and every one used to read as invalid.
    expect(extractOpenRouterKey(`  ${workingKey}\n`)).toBe(workingKey);
    expect(extractOpenRouterKey(`"${workingKey}"`)).toBe(workingKey);
    expect(extractOpenRouterKey(`OPENROUTER_API_KEY=${workingKey}`)).toBe(workingKey);
    expect(extractOpenRouterKey(`Your key: ${workingKey} (keep it secret)`)).toBe(workingKey);
  });

  it('returns null when there is no key in the text', () => {
    expect(extractOpenRouterKey('I clicked create but nothing happened')).toBeNull();
  });
});

describe('validateOpenRouterKey', () => {
  function mockKeyEndpoint(status: number, body: unknown = {}) {
    return vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: status >= 200 && status < 300,
      status,
      json: async () => body,
    } as Response);
  }

  it('confirms a working key and reports what OpenRouter knows about it', async () => {
    mockKeyEndpoint(200, { data: { label: 'Teachy', limit: 5, usage: 0.12, is_free_tier: true } });

    const result = await validateOpenRouterKey(workingKey);

    expect(result.outcome).toBe('valid');
    if (result.outcome !== 'valid') return;
    expect(result.keyLabel).toBe('Teachy');
    expect(result.limitUsd).toBe(5);
    expect(result.usageUsd).toBe(0.12);
    expect(result.isFreeTier).toBe(true);
  });

  it('accepts a working key even when the metadata is missing', async () => {
    // A valid key with a sparse body must not fail the flow over a nicety.
    mockKeyEndpoint(200, {});
    const result = await validateOpenRouterKey(workingKey);
    expect(result.outcome).toBe('valid');
  });

  it('accepts a working key even when the body is unreadable', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => {
        throw new SyntaxError('Unexpected end of JSON input');
      },
    } as unknown as Response);

    expect((await validateOpenRouterKey(workingKey)).outcome).toBe('valid');
  });

  it('never spends a round trip on text that cannot be a key', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const result = await validateOpenRouterKey('not-a-key');

    expect(result.outcome).toBe('malformed');
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('says the key was rejected on a 401', async () => {
    mockKeyEndpoint(401);
    const result = await validateOpenRouterKey(workingKey);
    expect(result.outcome).toBe('rejected');
  });

  it('separates "your key is wrong" from "OpenRouter is down"', async () => {
    mockKeyEndpoint(503);
    const result = await validateOpenRouterKey(workingKey);

    // Telling someone their brand-new key is invalid during an outage sends them
    // round the whole signup loop again for nothing.
    expect(result.outcome).toBe('unreachable');
    expect(result.outcome).not.toBe('rejected');
  });

  it('separates a dropped connection from a bad key', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));
    const result = await validateOpenRouterKey(workingKey);
    expect(result.outcome).toBe('unreachable');
  });

  it('explains every failure in plain words a learner can act on', async () => {
    const failures = [
      await validateOpenRouterKey('nonsense'),
      await (mockKeyEndpoint(401), validateOpenRouterKey(workingKey)),
      await (mockKeyEndpoint(500), validateOpenRouterKey(workingKey)),
    ];

    for (const failure of failures) {
      expect(failure.outcome).not.toBe('valid');
      if (failure.outcome === 'valid') continue;
      expect(failure.explanation.length).toBeGreaterThan(10);
      expect(failure.explanation).not.toMatch(/\b(401|403|500|503|fetch|undefined|Error)\b/);
      expect(failure.explanation.endsWith('.')).toBe(true);
    }
  });

  it('validates the key it was given, ignoring surrounding whitespace', async () => {
    const fetchSpy = mockKeyEndpoint(200, { data: {} });
    await validateOpenRouterKey(`  ${workingKey}  `);

    const [, requestInit] = fetchSpy.mock.calls[0];
    const headers = (requestInit as RequestInit).headers as Record<string, string>;
    expect(headers.Authorization).toBe(`Bearer ${workingKey}`);
  });
});
