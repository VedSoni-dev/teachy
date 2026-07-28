import { useCallback, useEffect, useRef, useState } from 'react';
import {
  extractOpenRouterKey,
  looksLikeOpenRouterKey,
  validateOpenRouterKey,
  type KeyValidationResult,
} from '../state/openRouterKey';
import './keySetup.css';

/**
 * Bring-your-own-key, walked through.
 *
 * BYOK is the right call — the learner's usage stays on their own account and
 * nobody's spend depends on ours. But "paste your OpenRouter API key" in a
 * settings field asks someone who came here to build a website to already know
 * what an API key is, where OpenRouter lives, and which of its pages issues one.
 * That is where a first run ends.
 *
 * So this walks it: open the right page for them, say exactly what to click,
 * take the key off their clipboard, and check it against OpenRouter before
 * saving — so "you're in" is a fact, not a hope. They still create their own
 * account and their own key; Teachy never touches their credentials.
 */

const SIGN_UP_URL = 'https://openrouter.ai/sign-up';
const KEYS_URL = 'https://openrouter.ai/settings/keys';

type SetupStep = 'why' | 'account' | 'createKey' | 'pasteKey' | 'done';

const STEP_ORDER: SetupStep[] = ['why', 'account', 'createKey', 'pasteKey', 'done'];

interface KeySetupProps {
  /** Saves the validated key (DPAPI-encrypted by the sidecar). */
  onSaveKey: (apiKey: string) => Promise<void>;
  /** Leaves the flow — "I'll do this later", or done. */
  onClose: () => void;
  /** True when a key is already stored, so the copy reads as "replace" not "add". */
  hasExistingKey: boolean;
}

export function KeySetup({ onSaveKey, onClose, hasExistingKey }: KeySetupProps) {
  const [step, setStep] = useState<SetupStep>(hasExistingKey ? 'pasteKey' : 'why');
  const [keyDraft, setKeyDraft] = useState('');
  const [validation, setValidation] = useState<KeyValidationResult | null>(null);
  const [isChecking, setIsChecking] = useState(false);
  const [clipboardNotice, setClipboardNotice] = useState<string | null>(null);
  const keyFieldRef = useRef<HTMLInputElement | null>(null);

  const stepIndex = STEP_ORDER.indexOf(step);

  function openInBrowser(url: string) {
    void window.teachy?.invoke('open-url', { url }).catch(() => {});
  }

  /**
   * Offers the key the learner was just told to copy. Ctrl+V into a frameless,
   * non-activating window is awkward enough on its own to lose people here.
   */
  const offerClipboardKey = useCallback(async () => {
    const teachy = window.teachy;
    if (!teachy?.readClipboardText) {
      return;
    }
    try {
      const clipboardText = await teachy.readClipboardText();
      const foundKey = extractOpenRouterKey(clipboardText ?? '');
      if (foundKey) {
        setKeyDraft(foundKey);
        setValidation(null);
        setClipboardNotice('Found your key on the clipboard.');
      } else {
        setClipboardNotice("Nothing that looks like a key on the clipboard yet — copy it from OpenRouter first.");
      }
    } catch {
      setClipboardNotice(null);
    }
  }, []);

  // Landing on the paste step is the one moment the key is expected to be on the
  // clipboard, so check once, right then. The notice says we looked.
  useEffect(() => {
    if (step === 'pasteKey' && keyDraft.length === 0) {
      void offerClipboardKey();
      keyFieldRef.current?.focus();
    }
  }, [step, keyDraft.length, offerClipboardKey]);

  async function checkAndSave() {
    const candidateKey = extractOpenRouterKey(keyDraft) ?? keyDraft.trim();
    setIsChecking(true);
    setClipboardNotice(null);
    try {
      const result = await validateOpenRouterKey(candidateKey);
      setValidation(result);
      if (result.outcome === 'valid') {
        await onSaveKey(candidateKey);
        setKeyDraft('');
        setStep('done');
      }
    } finally {
      setIsChecking(false);
    }
  }

  return (
    <div className="key-setup">
      <ol className="key-setup-rail" aria-label="Setup progress">
        {STEP_ORDER.slice(0, -1).map((railStep, railIndex) => (
          <li
            key={railStep}
            className={`rail-dot ${railIndex < stepIndex ? 'is-done' : ''} ${railIndex === stepIndex ? 'is-current' : ''}`}
          />
        ))}
      </ol>

      {step === 'why' && (
        <StepPanel
          eyebrow="One-time setup · about a minute"
          title="Teachy needs a brain"
          body={
            <>
              <p>
                Teachy watches your screen and coaches you through building real things. The thinking
                happens on an AI model, and you connect one with a free OpenRouter account.
              </p>
              <p className="muted">
                It stays yours — your account, your key, your usage. Teachy stores it encrypted on
                this PC and never sends it anywhere except the model you pick.
              </p>
            </>
          }
          primaryLabel="Walk me through it"
          onPrimary={() => setStep('account')}
          secondaryLabel="I already have a key"
          onSecondary={() => setStep('pasteKey')}
          onSkip={onClose}
        />
      )}

      {step === 'account' && (
        <StepPanel
          eyebrow="Step 1 of 3"
          title="Make a free OpenRouter account"
          body={
            <>
              <p>I'll open the sign-up page. Use Google or GitHub — it's the fastest way in.</p>
              <p className="muted">
                No card needed. OpenRouter has free models, and Teachy defaults to one.
              </p>
            </>
          }
          primaryLabel="Open the sign-up page"
          onPrimary={() => {
            openInBrowser(SIGN_UP_URL);
            setStep('createKey');
          }}
          secondaryLabel="I already have an account"
          onSecondary={() => setStep('createKey')}
          onSkip={onClose}
        />
      )}

      {step === 'createKey' && (
        <StepPanel
          eyebrow="Step 2 of 3"
          title="Create your key"
          body={
            <>
              <p>On the keys page:</p>
              <ol className="key-setup-instructions">
                <li>Click <strong>Create Key</strong></li>
                <li>Name it <strong>Teachy</strong></li>
                <li>Leave the credit limit blank</li>
                <li>Click <strong>Create</strong>, then <strong>Copy</strong></li>
              </ol>
              <p className="muted">
                OpenRouter shows a key once. Copy it before you close that box — if you lose it, just
                make another.
              </p>
            </>
          }
          primaryLabel="Open the keys page"
          onPrimary={() => {
            openInBrowser(KEYS_URL);
            setStep('pasteKey');
          }}
          secondaryLabel="It's copied — next"
          onSecondary={() => setStep('pasteKey')}
          onSkip={onClose}
        />
      )}

      {step === 'pasteKey' && (
        <div className="key-setup-panel">
          <div className="key-setup-eyebrow">Step 3 of 3</div>
          <h2 className="key-setup-title">Paste it here</h2>

          <div className="key-setup-field-row">
            <input
              ref={keyFieldRef}
              className="key-setup-field"
              type="password"
              autoComplete="off"
              spellCheck={false}
              placeholder="sk-or-…"
              value={keyDraft}
              onChange={(changeEvent) => {
                setKeyDraft(changeEvent.target.value);
                setValidation(null);
                setClipboardNotice(null);
              }}
              onKeyDown={(keyEvent) => {
                if (keyEvent.key === 'Enter' && !isChecking) {
                  void checkAndSave();
                }
              }}
            />
            <button type="button" className="key-setup-ghost-button" onClick={() => void offerClipboardKey()}>
              Paste
            </button>
          </div>

          {clipboardNotice && <p className="key-setup-notice">{clipboardNotice}</p>}

          {validation && validation.outcome !== 'valid' && (
            <p className="key-setup-error" role="alert">
              {validation.explanation}
            </p>
          )}

          {!validation && keyDraft.length > 0 && !looksLikeOpenRouterKey(keyDraft) && (
            <p className="key-setup-notice">OpenRouter keys start with sk-or- — make sure you copied all of it.</p>
          )}

          <div className="key-setup-actions">
            <button
              type="button"
              className="key-setup-primary"
              onClick={() => void checkAndSave()}
              disabled={isChecking || keyDraft.trim().length === 0}
            >
              {isChecking ? 'Checking with OpenRouter…' : 'Check and save'}
            </button>
            <button type="button" className="key-setup-quiet" onClick={() => setStep('createKey')}>
              Back
            </button>
          </div>

          <button type="button" className="key-setup-skip" onClick={onClose}>
            I'll do this later
          </button>
        </div>
      )}

      {step === 'done' && (
        <div className="key-setup-panel key-setup-done">
          <div className="key-setup-check" aria-hidden="true">
            <svg viewBox="0 0 32 32" width="32" height="32">
              <circle cx="16" cy="16" r="15" fill="none" stroke="currentColor" strokeWidth="1.5" opacity="0.35" />
              <path
                d="M10 16.5 L14.5 21 L22 12"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </div>
          <h2 className="key-setup-title">You're in</h2>
          <p>
            {validation?.outcome === 'valid' && validation.keyLabel
              ? `Your "${validation.keyLabel}" key works. `
              : 'Your key works. '}
            Teachy can see your screen and coach you now.
          </p>
          <p className="muted">
            Hold <span className="key-setup-keycap">Ctrl</span> +{' '}
            <span className="key-setup-keycap">Alt</span> any time and just talk.
          </p>
          <div className="key-setup-actions">
            <button type="button" className="key-setup-primary" onClick={onClose}>
              Start building
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

interface StepPanelProps {
  eyebrow: string;
  title: string;
  body: React.ReactNode;
  primaryLabel: string;
  onPrimary: () => void;
  secondaryLabel?: string;
  onSecondary?: () => void;
  onSkip: () => void;
}

function StepPanel({
  eyebrow,
  title,
  body,
  primaryLabel,
  onPrimary,
  secondaryLabel,
  onSecondary,
  onSkip,
}: StepPanelProps) {
  return (
    <div className="key-setup-panel">
      <div className="key-setup-eyebrow">{eyebrow}</div>
      <h2 className="key-setup-title">{title}</h2>
      <div className="key-setup-body">{body}</div>
      <div className="key-setup-actions">
        <button type="button" className="key-setup-primary" onClick={onPrimary}>
          {primaryLabel}
        </button>
        {secondaryLabel && onSecondary && (
          <button type="button" className="key-setup-quiet" onClick={onSecondary}>
            {secondaryLabel}
          </button>
        )}
      </div>
      <button type="button" className="key-setup-skip" onClick={onSkip}>
        I'll do this later
      </button>
    </div>
  );
}
