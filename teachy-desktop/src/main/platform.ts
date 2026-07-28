import { BrowserWindow, type BrowserWindowConstructorOptions } from 'electron'

// Per-OS window treatment. This is the ONE place platform differences live — the
// rest of the app is identical across macOS and Windows. On macOS we get the same
// real vibrancy the SwiftUI app used (NSVisualEffectView under the hood); on
// Windows we use the closest system material (acrylic).
export function panelMaterialOptions(): Partial<BrowserWindowConstructorOptions> {
  if (process.platform === 'darwin') {
    return { vibrancy: 'under-window', visualEffectState: 'active' }
  }
  if (process.platform === 'win32') {
    // Mica/acrylic on Windows 11; harmless (ignored) on Windows 10.
    return { backgroundMaterial: 'acrylic' }
  }
  return {}
}

// Reproduce the NSPanel behaviors the Mac app relied on: float above fullscreen
// apps and join every Space, without stealing focus from the app the learner is
// working in. Deferred-to-later polish (premise 6) is the last-mile notch geometry.
export function configurePanelBehavior(win: BrowserWindow): void {
  win.setAlwaysOnTop(true, 'screen-saver')
  if (process.platform === 'darwin') {
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  }
}
