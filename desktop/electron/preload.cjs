const { contextBridge, ipcRenderer } = require('electron');

/** Sidecar events the renderer is allowed to subscribe to. */
const FORWARDED_SIDECAR_EVENTS = ['ready', 'ptt-pressed', 'ptt-released', 'ptt-error', 'transcript'];

/**
 * Minimal, explicitly-enumerated bridge. The renderer never gets Node access —
 * only the specific functions listed here.
 */
contextBridge.exposeInMainWorld('teachy', {
  /** Tells the main process whether the pointer is over interactive notch chrome. */
  setInteractive(isInteractive) {
    ipcRenderer.send('notch:set-interactive', Boolean(isInteractive));
  },

  /** Invokes a command on the C# sidecar and resolves with its result. */
  invoke(command, args) {
    return ipcRenderer.invoke('sidecar:send', command, args);
  },

  /** Subscribes to a sidecar event. Returns an unsubscribe function. */
  on(eventName, listener) {
    if (!FORWARDED_SIDECAR_EVENTS.includes(eventName)) {
      throw new Error(`Unknown Teachy event "${eventName}".`);
    }
    const ipcListener = (_event, payload) => listener(payload);
    ipcRenderer.on(`sidecar:${eventName}`, ipcListener);
    return () => ipcRenderer.removeListener(`sidecar:${eventName}`, ipcListener);
  },

  /**
   * Reads the clipboard as text. Used by key setup to offer the key the learner
   * was just told to copy, so they never have to hunt for the paste shortcut in
   * a frameless always-on-top window. Pull-only and on an explicit step — the
   * renderer cannot watch the clipboard.
   */
  readClipboardText() {
    return ipcRenderer.invoke('clipboard:read-text');
  },

  /** Notch window placement — manual drag and preset positioning. */
  notch: {
    moveBy(dx, dy) {
      ipcRenderer.send('notch:move-by', { dx, dy });
    },
    getPosition() {
      return ipcRenderer.invoke('notch:get-position');
    },
    applyPlacement(placement) {
      ipcRenderer.send('notch:apply-placement', placement);
    },
    onOpenRequested(listener) {
      const ipcListener = () => listener();
      ipcRenderer.on('notch:open', ipcListener);
      return () => ipcRenderer.removeListener('notch:open', ipcListener);
    },
  },

  /** Drives the cursor overlay (status text, streaming reply, pointing). */
  overlay: {
    send(command) {
      ipcRenderer.send('overlay:command', command);
    },
    onCursor(listener) {
      const ipcListener = (_event, point) => listener(point);
      ipcRenderer.on('overlay:cursor', ipcListener);
      return () => ipcRenderer.removeListener('overlay:cursor', ipcListener);
    },
    onState(listener) {
      const ipcListener = (_event, state) => listener(state);
      ipcRenderer.on('overlay:state', ipcListener);
      return () => ipcRenderer.removeListener('overlay:state', ipcListener);
    },
    onPointAt(listener) {
      const ipcListener = (_event, target) => listener(target);
      ipcRenderer.on('overlay:point-at', ipcListener);
      return () => ipcRenderer.removeListener('overlay:point-at', ipcListener);
    },
  },
});
