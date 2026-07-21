import { useCallback, useEffect, useState } from 'react';
import type { TeachyConfigSnapshot } from '../types/global';

/**
 * Live view of the config the C# sidecar owns (DPAPI-encrypted key, model
 * choice, cursor toggle, notch placement). The sidecar is the single source of
 * truth — the renderer never persists anything itself.
 */
export function useTeachyConfig() {
  const [config, setConfig] = useState<TeachyConfigSnapshot | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const reloadConfig = useCallback(async () => {
    if (!window.teachy) {
      return;
    }
    const snapshot = await window.teachy.invoke<TeachyConfigSnapshot>('get-config');
    setConfig(snapshot);
  }, []);

  useEffect(() => {
    void reloadConfig();
  }, [reloadConfig]);

  const saveApiKey = useCallback(
    async (apiKey: string) => {
      if (!window.teachy) {
        return;
      }
      setIsSaving(true);
      try {
        await window.teachy.invoke('set-api-key', { key: apiKey });
        await reloadConfig();
      } finally {
        setIsSaving(false);
      }
    },
    [reloadConfig],
  );

  const updateConfig = useCallback(
    async (changes: Partial<Pick<TeachyConfigSnapshot, 'chatModel' | 'showTeachyCursor' | 'notchPlacement'>>) => {
      if (!window.teachy) {
        return;
      }
      await window.teachy.invoke('set-config', changes);
      await reloadConfig();
    },
    [reloadConfig],
  );

  return { config, isSaving, saveApiKey, updateConfig };
}
