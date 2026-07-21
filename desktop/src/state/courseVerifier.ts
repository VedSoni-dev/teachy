/**
 * Vision gate for course goal advancement — the same structured protocol as the
 * macOS CourseVerifier: send the screen plus the goal's natural-language
 * doneWhen, get back pass / partial / offTrack with specific feedback.
 */

export type CourseVerificationStatus = 'pass' | 'partial' | 'offTrack';

export interface CourseVerificationResult {
  status: CourseVerificationStatus;
  whatsGood: string;
  whatsMissing: string | null;
  suggestedNextAction: string | null;
  visibleErrorSummary: string | null;
}

/** Verbatim from CourseVerifier.verifyStructured on macOS. */
const VERIFIER_SYSTEM_PROMPT = `you verify whether a course goal is complete. look at the screenshot only.

reply with ONLY a JSON object:
{"status":"pass"|"partial"|"offTrack","whatsGood":"short description of what IS correct on screen","whatsMissing":"what's still missing or wrong — null if pass","suggestedNextAction":"one specific next move the learner should take — null if pass","visibleErrorSummary":"one plain-words sentence describing any error message, stack trace, or failure state visible on screen — null if none"}

rules:
- status "pass" = the goal is clearly complete on screen.
- status "partial" = the learner made real progress but something specific is missing or incomplete. name exactly what they got right first, then what's missing.
- status "offTrack" = the goal is not meaningfully progressed or the screen shows something unrelated. still name any partial progress if it exists.
- whatsGood should always name something concrete the learner did or that is visible — never leave it empty.
- suggestedNextAction should be one short, specific instruction — not a list.
- be honest but kind. "close" is partial, not offTrack.
- visibleErrorSummary: set this ONLY when an actual error message, exception, stack trace, or failure state is clearly visible on screen. null otherwise — do not set it for a missing feature or incomplete state.`;

export async function verifyCourseGoal(
  apiKey: string,
  modelIdentifier: string,
  doneWhenCriteria: string,
  screenshotJpegBase64: string,
): Promise<CourseVerificationResult> {
  const userPrompt = `completion criteria: ${doneWhenCriteria}

What is the current state on screen? Is this goal complete, partially complete, or off track?`;

  try {
    const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://vedsoni-dev.github.io/teachy/',
        'X-Title': 'Teachy',
      },
      body: JSON.stringify({
        model: modelIdentifier,
        messages: [
          { role: 'system', content: VERIFIER_SYSTEM_PROMPT },
          {
            role: 'user',
            content: [
              { type: 'text', text: userPrompt },
              {
                type: 'image_url',
                image_url: { url: `data:image/jpeg;base64,${screenshotJpegBase64}` },
              },
            ],
          },
        ],
      }),
    });

    if (!response.ok) {
      throw new Error(`verifier request failed (${response.status})`);
    }

    const responseJson = await response.json();
    const rawText: string = responseJson?.choices?.[0]?.message?.content ?? '';
    return parseVerificationResult(rawText);
  } catch (verificationError) {
    const message = verificationError instanceof Error ? verificationError.message : String(verificationError);
    return {
      status: 'offTrack',
      whatsGood: '',
      whatsMissing: `vision check failed — ${message}`,
      suggestedNextAction: 'try the step and press I did it again',
      visibleErrorSummary: null,
    };
  }
}

function parseVerificationResult(rawText: string): CourseVerificationResult {
  const trimmed = rawText.trim();
  const jsonStart = trimmed.indexOf('{');
  const jsonEnd = trimmed.lastIndexOf('}');
  const jsonCandidate = jsonStart >= 0 && jsonEnd > jsonStart ? trimmed.slice(jsonStart, jsonEnd + 1) : trimmed;

  try {
    const parsed = JSON.parse(jsonCandidate);
    const statusText = String(parsed.status ?? '').toLowerCase();
    const status: CourseVerificationStatus =
      statusText === 'pass' ? 'pass' : statusText === 'partial' ? 'partial' : 'offTrack';

    return {
      status,
      whatsGood: typeof parsed.whatsGood === 'string' ? parsed.whatsGood : '',
      whatsMissing: typeof parsed.whatsMissing === 'string' ? parsed.whatsMissing : null,
      suggestedNextAction:
        typeof parsed.suggestedNextAction === 'string' ? parsed.suggestedNextAction : null,
      visibleErrorSummary:
        typeof parsed.visibleErrorSummary === 'string' ? parsed.visibleErrorSummary : null,
    };
  } catch {
    // Fallback: a YES-ish plain-text reply still counts as a pass, as on macOS.
    if (trimmed.toLowerCase().startsWith('yes')) {
      return {
        status: 'pass',
        whatsGood: 'vision confirmed completion',
        whatsMissing: null,
        suggestedNextAction: null,
        visibleErrorSummary: null,
      };
    }
    return {
      status: 'offTrack',
      whatsGood: '',
      whatsMissing: 'could not parse verification response',
      suggestedNextAction: 'try the step and press I did it again',
      visibleErrorSummary: null,
    };
  }
}
