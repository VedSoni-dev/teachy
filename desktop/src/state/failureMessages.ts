/**
 * Turns an internal failure into something a learner can act on.
 *
 * Every catch in the coaching loop used to interpolate the raw Error message
 * straight into the coach line — which is both displayed and SPOKEN ALOUD. A
 * learner mid-course got read this out:
 *
 *   "I couldn't finish that automatically: Error invoking remote method
 *    'sidecar:send': Error: Teachy background service is not running."
 *
 * That is Electron's IPC wrapper, a C# process name, and a stack-shaped string
 * read to someone who just wanted to build a website. The failure is real; the
 * words are not theirs. Everything here maps a cause to a plain sentence that
 * says what happened and what to do next.
 */

/** Electron wraps every ipcRenderer.invoke rejection; the wrapper is pure noise. */
const IPC_WRAPPER_PATTERN = /^Error invoking remote method '[^']*':\s*/;

export function unwrapErrorMessage(failure: unknown): string {
  const rawMessage = failure instanceof Error ? failure.message : String(failure);
  return rawMessage
    .replace(IPC_WRAPPER_PATTERN, '')
    .replace(/^Error:\s*/, '')
    .trim();
}

/**
 * A short, spoken-friendly sentence for the learner.
 *
 * @param whatFailed what the app was trying to do, phrased to slot into the
 *   sentence — e.g. "finish that for you". Keep it a verb phrase.
 */
export function describeFailureForLearner(failure: unknown, whatFailed: string): string {
  const message = unwrapErrorMessage(failure);

  // The background service died or is restarting. It comes back on its own, so
  // the honest instruction is "wait a second", not "restart the app".
  if (/background service|sidecar (exited|stopped|is not running)/i.test(message)) {
    return `My background helper just restarted, so I couldn't ${whatFailed}. Give it a second and try again.`;
  }

  if (/\b401\b|invalid.*api key|unauthorized|no auth credentials/i.test(message)) {
    return `OpenRouter didn't accept that API key, so I couldn't ${whatFailed}. Check the key in Settings.`;
  }

  if (/\b402\b|insufficient|credits?|quota|billing/i.test(message)) {
    return `Your OpenRouter account is out of credit, so I couldn't ${whatFailed}. Top it up, or pick a free model in Settings.`;
  }

  if (/\b429\b|rate.?limit|too many requests/i.test(message)) {
    return `That model is rate-limiting us, so I couldn't ${whatFailed}. Wait a moment and try again, or pick another model in Settings.`;
  }

  if (/\b5\d{2}\b|internal server error|service unavailable|bad gateway/i.test(message)) {
    return `The model provider is having trouble right now, so I couldn't ${whatFailed}. Try again in a minute.`;
  }

  if (/failed to fetch|network|enotfound|econnrefused|etimedout|dns|offline/i.test(message)) {
    return `I couldn't reach the internet, so I couldn't ${whatFailed}. Check your connection and try again.`;
  }

  if (/timed? ?out|timeout/i.test(message)) {
    return `That took too long, so I couldn't ${whatFailed}. Try again.`;
  }

  if (/api key/i.test(message)) {
    return `I need your OpenRouter API key before I can ${whatFailed}. Add it in Settings.`;
  }

  // Unknown cause: still say what we were doing and stay calm. The raw text goes
  // to the console for whoever is debugging, not into the learner's ears.
  console.error(`[teachy] could not ${whatFailed}:`, failure);
  return `Something went wrong on my end, so I couldn't ${whatFailed}. Try that again.`;
}
