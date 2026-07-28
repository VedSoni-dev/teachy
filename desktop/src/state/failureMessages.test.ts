import { describe, expect, it, vi } from 'vitest';
import { describeFailureForLearner, unwrapErrorMessage } from './failureMessages';

describe('unwrapErrorMessage', () => {
  it('strips the Electron IPC wrapper the learner should never see', () => {
    const raw = new Error(
      "Error invoking remote method 'sidecar:send': Error: Teachy background service is not running.",
    );
    expect(unwrapErrorMessage(raw)).toBe('Teachy background service is not running.');
  });

  it('handles a thrown non-Error', () => {
    expect(unwrapErrorMessage('plain string failure')).toBe('plain string failure');
  });
});

describe('describeFailureForLearner', () => {
  const spokenNoise = [
    'Error invoking remote method',
    'sidecar:send',
    'ipcRenderer',
    'undefined',
    'null',
    'stack',
    'at Object.',
    '{',
    '}',
  ];

  function expectSpeakable(sentence: string) {
    for (const noise of spokenNoise) {
      expect(sentence, `leaked "${noise}"`).not.toContain(noise);
    }
    // It is read aloud, so it has to be a sentence, not a fragment or a dump.
    expect(sentence.length).toBeLessThan(220);
    expect(sentence.endsWith('.')).toBe(true);
  }

  it('explains a dead background service as temporary, not as a broken app', () => {
    const sentence = describeFailureForLearner(
      new Error("Error invoking remote method 'sidecar:send': Error: Teachy background service is not running."),
      'finish that for you',
    );
    expect(sentence).toMatch(/restarted/i);
    expect(sentence).toMatch(/try again/i);
    expectSpeakable(sentence);
  });

  it('points a rejected key at Settings', () => {
    const sentence = describeFailureForLearner(
      new Error('OpenRouter request failed (401): {"error":{"message":"No auth credentials found"}}'),
      'answer that',
    );
    expect(sentence).toMatch(/Settings/);
    expectSpeakable(sentence);
  });

  it('tells an out-of-credit learner they can switch to a free model', () => {
    const sentence = describeFailureForLearner(
      new Error('OpenRouter request failed (402): insufficient credits'),
      'answer that',
    );
    expect(sentence).toMatch(/free model|top it up/i);
    expectSpeakable(sentence);
  });

  it('treats rate limiting as wait-and-retry', () => {
    const sentence = describeFailureForLearner(
      new Error('OpenRouter request failed (429): rate limit exceeded'),
      'answer that',
    );
    expect(sentence).toMatch(/wait|another model/i);
    expectSpeakable(sentence);
  });

  it('blames the provider, not the learner, on a 5xx', () => {
    const sentence = describeFailureForLearner(
      new Error('OpenRouter request failed (503): service unavailable'),
      'answer that',
    );
    expect(sentence).toMatch(/provider/i);
    expectSpeakable(sentence);
  });

  it('names the connection when the network is down', () => {
    const sentence = describeFailureForLearner(new TypeError('Failed to fetch'), 'answer that');
    expect(sentence).toMatch(/connection|internet/i);
    expectSpeakable(sentence);
  });

  it('stays calm and speakable on a cause it has never seen', () => {
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const sentence = describeFailureForLearner(
      new Error('ERR_ELECTRON_WEIRDNESS: 0x8007000E at Object.<anonymous>'),
      'finish that for you',
    );
    expectSpeakable(sentence);
    // The raw cause still has to reach a developer.
    expect(consoleErrorSpy).toHaveBeenCalled();
    consoleErrorSpy.mockRestore();
  });

  it('always names what it was trying to do', () => {
    const failures = [
      new Error('background service is not running'),
      new Error('OpenRouter request failed (401)'),
      new Error('Failed to fetch'),
      'something odd',
    ];
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    for (const failure of failures) {
      expect(describeFailureForLearner(failure, 'deploy your site')).toContain('deploy your site');
    }
    consoleErrorSpy.mockRestore();
  });
});
