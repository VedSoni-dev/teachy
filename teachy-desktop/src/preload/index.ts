import { contextBridge, ipcRenderer } from 'electron'

// The ONLY bridge between the sandboxed renderer and the OS. Everything the UI is
// allowed to ask the main process to do is enumerated here — nothing else leaks
// through. Grows as capabilities land (screen capture, transcription, etc.).
const teachyApi = {
  platform: process.platform,

  togglePanel: (): void => ipcRenderer.send('panel:toggle'),
  collapse: (): void => ipcRenderer.send('panel:collapse'),

  /** Fires when the global push-to-talk chord (ctrl+alt+space) is pressed. */
  onPushToTalkToggle: (callback: () => void): (() => void) => {
    const listener = (): void => callback()
    ipcRenderer.on('push-to-talk:toggle', listener)
    return () => ipcRenderer.removeListener('push-to-talk:toggle', listener)
  }
}

contextBridge.exposeInMainWorld('teachy', teachyApi)

export type TeachyApi = typeof teachyApi
