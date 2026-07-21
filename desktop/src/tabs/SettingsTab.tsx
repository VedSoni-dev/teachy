import { useState } from 'react';
import { useTeachyConfig } from '../state/useTeachyConfig';
import './tabs.css';

const PLACEMENT_OPTIONS = [
  { id: 'TopLeft', label: 'Top left' },
  { id: 'TopCenter', label: 'Top center' },
  { id: 'TopRight', label: 'Top right' },
] as const;

export function SettingsTab() {
  const { config, isSaving, saveApiKey, updateConfig } = useTeachyConfig();
  const [apiKeyDraft, setApiKeyDraft] = useState('');

  async function handleSaveApiKey() {
    const trimmedKey = apiKeyDraft.trim();
    if (trimmedKey.length === 0) {
      return;
    }
    await saveApiKey(trimmedKey);
    setApiKeyDraft('');
  }

  return (
    <div className="settings-stack">
      <div className="glass-card settings-card">
        <div className="hotkey-row">
          <span>Hold</span>
          <span className="keycap">Ctrl</span>
          <span>+</span>
          <span className="keycap">Alt</span>
          <span>and talk about your screen</span>
        </div>
      </div>

      <section>
        <div className="section-label">AI Brain</div>
        <div className="field-row">
          <input
            className="text-field"
            type="password"
            placeholder="OpenRouter API key"
            value={apiKeyDraft}
            onChange={(changeEvent) => setApiKeyDraft(changeEvent.target.value)}
            onKeyDown={(keyEvent) => {
              if (keyEvent.key === 'Enter') {
                void handleSaveApiKey();
              }
            }}
          />
          <button
            type="button"
            className="primary-button"
            onClick={() => void handleSaveApiKey()}
            disabled={isSaving}
          >
            {isSaving ? 'Saving…' : 'Save key'}
          </button>
        </div>
        <p className="field-hint">
          {config?.hasApiKey
            ? 'Key saved (encrypted with Windows DPAPI). Paste a new one to rotate it.'
            : 'Paste your free OpenRouter API key (openrouter.ai) — stored encrypted on this machine.'}
        </p>
      </section>

      <section>
        <div className="section-label">Position</div>
        <div className="glass-card settings-card">
          <div className="chip-row">
            {PLACEMENT_OPTIONS.map((option) => (
              <button
                key={option.id}
                type="button"
                className={`chip ${config?.notchPlacement === option.id ? 'is-selected' : ''}`}
                onClick={() => {
                  // Move the window now, and remember the choice.
                  window.teachy?.notch.applyPlacement(option.id);
                  void updateConfig({ notchPlacement: option.id });
                }}
              >
                {option.label}
              </button>
            ))}
          </div>
          <p className="field-hint">
            Or just drag the notch anywhere on screen — Teachy remembers where you put it.
          </p>
        </div>
      </section>

      <section>
        <div className="section-label">Companion</div>
        <div className="glass-card settings-card">
          <div className="toggle-row">
            <div>
              <div className="toggle-copy-title">Show Teachy</div>
              <div className="toggle-copy-body">
                Keep the cursor companion on screen, trailing your pointer.
              </div>
            </div>
            <button
              type="button"
              className={`switch ${config?.showTeachyCursor ? 'is-on' : ''}`}
              onClick={() => void updateConfig({ showTeachyCursor: !config?.showTeachyCursor })}
              aria-pressed={config?.showTeachyCursor ?? false}
              aria-label="Show Teachy cursor"
            >
              <span className="switch-thumb" />
            </button>
          </div>
        </div>
      </section>

      <div className="settings-footer">
        <span>{config?.hasApiKey ? '● ready' : '● needs API key'}</span>
        <button
          type="button"
          className="quiet-button"
          onClick={() => void window.teachy?.invoke('quit')}
        >
          Quit Teachy
        </button>
      </div>
    </div>
  );
}
