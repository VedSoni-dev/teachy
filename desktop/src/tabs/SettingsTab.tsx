import { useState } from 'react';
import { useTeachyConfig } from '../state/useTeachyConfig';
import './tabs.css';

const PLACEMENT_OPTIONS = [
  { id: 'TopLeft', label: 'Top left' },
  { id: 'TopCenter', label: 'Top center' },
  { id: 'TopRight', label: 'Top right' },
] as const;

const MODEL_OPTIONS = [
  { id: 'google/gemini-2.5-flash', label: 'Gemini 2.5 Flash', subtitle: 'Vision + tools · free default' },
  { id: 'anthropic/claude-sonnet-4.6', label: 'Claude Sonnet 4.6', subtitle: 'Smartest tutor · needs your own key' },
  { id: 'anthropic/claude-haiku-4.5', label: 'Claude Haiku 4.5', subtitle: 'Fast + sharp · needs your own key' },
  { id: 'google/gemma-4-26b-a4b-it', label: 'Gemma 4 26B', subtitle: 'Vision + tools · cheaper' },
  { id: 'google/gemini-2.5-flash-lite', label: 'Gemini 2.5 Flash Lite', subtitle: 'Vision + tools · fast' },
  { id: 'qwen/qwen3-vl-30b-a3b-instruct', label: 'Qwen3 VL 30B', subtitle: 'Vision + tools' },
] as const;

interface SettingsTabProps {
  onAskQuestion?: (question: string) => void;
}

export function SettingsTab({ onAskQuestion }: SettingsTabProps) {
  const { config, isSaving, saveApiKey, updateConfig } = useTeachyConfig();
  const [apiKeyDraft, setApiKeyDraft] = useState('');
  const [questionDraft, setQuestionDraft] = useState('');

  async function handleSaveApiKey() {
    const trimmedKey = apiKeyDraft.trim();
    if (trimmedKey.length === 0) {
      return;
    }
    await saveApiKey(trimmedKey);
    setApiKeyDraft('');
  }

  function handleAskQuestion() {
    const trimmedQuestion = questionDraft.trim();
    if (trimmedQuestion.length === 0 || !onAskQuestion) {
      return;
    }
    setQuestionDraft('');
    onAskQuestion(trimmedQuestion);
  }

  const currentModelLabel = MODEL_OPTIONS.find(
    (modelOption) => modelOption.id === config?.chatModel,
  )?.label ?? MODEL_OPTIONS[0].label;

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
        <div className="section-label">Ask Teachy</div>
        <div className="field-row">
          <input
            className="text-field"
            type="text"
            placeholder="Type a question about your screen…"
            value={questionDraft}
            onChange={(changeEvent) => setQuestionDraft(changeEvent.target.value)}
            onKeyDown={(keyEvent) => {
              if (keyEvent.key === 'Enter') {
                handleAskQuestion();
              }
            }}
          />
          <button
            type="button"
            className="primary-button"
            onClick={handleAskQuestion}
            disabled={questionDraft.trim().length === 0}
          >
            Ask
          </button>
        </div>
      </section>

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

        <div className="section-label" style={{ marginTop: 12 }}>Model</div>
        <div className="model-picker-wrapper">
          <select
            className="model-picker"
            value={config?.chatModel ?? MODEL_OPTIONS[0].id}
            onChange={(changeEvent) => void updateConfig({ chatModel: changeEvent.target.value })}
          >
            {MODEL_OPTIONS.map((modelOption) => (
              <option key={modelOption.id} value={modelOption.id}>
                {modelOption.label} — {modelOption.subtitle}
              </option>
            ))}
          </select>
        </div>
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
        <span>{config?.hasApiKey ? `● ready · ${currentModelLabel}` : '● needs API key'}</span>
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
