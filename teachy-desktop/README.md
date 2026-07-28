# Teachy Desktop (cross-platform)

The **one-codebase** Electron + React + TypeScript rewrite of Teachy's shell, so
the same app runs on **macOS and Windows**. This is the migration described in
[`docs/design/2026-07-26-teachy-desktop-cross-platform.md`](../docs/design/2026-07-26-teachy-desktop-cross-platform.md).

The SwiftUI Mac app (`../leanring-buddy`) is **not** deleted — it stays the
flagship while this app matures toward it. Migration, not demolition.

## Status: foundation

- ✅ Electron main process — cross-platform notch panel window, tray, push-to-talk
  global shortcut, per-OS material (mac vibrancy / win acrylic)
- ✅ Design system ported from `DesignSystem.swift` → `src/renderer/src/theme/`
  (47 color tokens, both light/dark)
- ✅ Renderer shell — notch panel, header tabs (Learn · Progress · Portfolio ·
  Skills · Settings), Progress tab ported and live (sample data)
- ⏳ Next: worker client, `TeachyEngine` → TS port, course tutor loop, screen
  capture + `[POINT]` overlay, the remaining tabs, packaging

## Run

```bash
npm install                 # deps (downloads Electron binary)
npm run dev                 # electron-vite: main + preload + renderer, opens the app

# Preview just the UI in a browser (no native window):
npx vite serve src/renderer
```

## Layout

```
src/main/       Electron main process (windows, tray, shortcuts, platform)
src/preload/    contextIsolation IPC bridge (window.teachy)
src/renderer/   React + Vite UI (theme, shell, tabs)
src/shared/     ported engine + worker client + course loader  (coming)
docs/           component-inventory.md (SwiftUI → React map)
```

## Reuse (not rewritten)

The `../worker` proxy and `../courses/*.json` are consumed as-is. Only the UI
shell and the engine logic get ported; the backend contract is unchanged.
