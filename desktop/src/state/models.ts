// One source of truth for the default chat model.
//
// The null-config fallback used by the coaching loops MUST equal what the
// Settings dropdown shows as selected. Previously they disagreed: the loops fell
// back to a paid `anthropic/claude-sonnet-4.6` while Settings showed free Gemini,
// so a fresh user's coach silently ran (and billed) Claude while the UI claimed
// Gemini. Keep this equal to the first entry of `MODEL_OPTIONS` in SettingsTab.
export const DEFAULT_CHAT_MODEL = 'google/gemini-2.5-flash';
