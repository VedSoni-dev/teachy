export {};

export interface InspectedElement {
  id: number;
  name: string;
  controlType: string;
  centerX: number;
  centerY: number;
  enabled: boolean;
  line: string;
}

export interface CapturedScreen {
  jpegBase64: string;
  width: number;
  height: number;
  circledGridCells: string | null;
  elements: InspectedElement[] | null;
}

export interface TeachyConfigSnapshot {
  hasApiKey: boolean;
  chatModel: string | null;
  showTeachyCursor: boolean;
  notchPlacement: string;
}

export type TeachyEventName =
  | 'ready'
  | 'ptt-pressed'
  | 'ptt-released'
  | 'ptt-error'
  | 'transcript';

declare global {
  interface Window {
    teachy?: {
      /** Toggles whether the transparent Electron window accepts pointer events. */
      setInteractive(isInteractive: boolean): void;
      /** Calls a command on the C# sidecar. */
      invoke<TResult = unknown>(command: string, args?: Record<string, unknown>): Promise<TResult>;
      /** Subscribes to a sidecar event; returns an unsubscribe function. */
      on(eventName: TeachyEventName, listener: (payload: unknown) => void): () => void;
      /** Reads the clipboard as text — used by key setup, on an explicit step. */
      readClipboardText(): Promise<string>;
      /** Notch window placement — manual drag and preset positioning. */
      notch: {
        moveBy(dx: number, dy: number): void;
        getPosition(): Promise<{ x: number; y: number }>;
        applyPlacement(placement: string): void;
        onOpenRequested(listener: () => void): () => void;
      };
      /** Drives the click-through cursor overlay window. */
      overlay: {
        send(command: Record<string, unknown>): void;
        onCursor(listener: (point: { x: number; y: number }) => void): () => void;
        onState(listener: (state: never) => void): () => void;
        onPointAt(listener: (target: { x: number; y: number; label: string | null }) => void): () => void;
      };
    };
  }
}
