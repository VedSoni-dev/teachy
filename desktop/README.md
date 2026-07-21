# Teachy for Windows — Electron shell

Rebuild of the Windows client as Electron + React, replacing the WPF version.

## Why the rewrite

The WPF app's problem was never really WPF — it was that the UI had been designed to a "distinctive aesthetic" brief when the actual requirement is **pixel fidelity with the macOS app**. That mistake would have reproduced itself in any stack.

That said, Electron is the correct target for this specific goal:

- The Mac app is SwiftUI. Its `GlassCardModifier` uses `.regularMaterial` / `.ultraThinMaterial` — real vibrancy. CSS `backdrop-filter` reproduces this directly; WPF has no equivalent short of hand-rolled Win32 acrylic.
- Spring animations, continuous corner curves, and type rendering all map far more closely from SwiftUI to CSS than to WPF.
- Fonts can be bundled (Inter, the closest shippable SF Pro analogue) instead of depending on what Windows happens to have installed.

## The fidelity rule

**Every visual value in this app is transcribed from the Swift source. Nothing is invented.**

- `src/styles/tokens.css` ← `DesignSystem.swift` (`DS.Colors`, `DS.CornerRadius`, `DS.Spacing`)
- `src/notch/notchShape.ts` ← `ClickyNotchShape.swift` (`path(in:)`, verbatim) and `ClickyNotchSizing.swift`
- `src/data/courseCatalog.ts` ← `ClickyCourseCatalog.bundledCourses`
- Type scale / padding / radii in `tabs.css` ← `NotchCoursesTabView.swift`

If something looks wrong, fix it in the Swift source first, then mirror it here.

Two corrections already caught by re-reading the Swift rather than eyeballing:
- The notch body is **solid black** (`.background(Color.black)`), not a material — only the cards are glass.
- On a display without a physical notch, the header's centre "camera bay" is `Color.clear`, so Windows correctly omits it.

## Architecture

| Piece | Role |
|-------|------|
| `electron/main.cjs` | Frameless, transparent, always-on-top notch window. Click-through except over real chrome, via the `notch:set-interactive` IPC channel. |
| `electron/preload.cjs` | Minimal `contextBridge` surface. No Node in the renderer. |
| `src/notch/` | Notch shell — exact silhouette, spring-matched open/close, header tabs. |
| `src/tabs/` | Learn / Portfolio / Skills / Settings. |
| `../windows/Teachy.Platform` | **Kept.** The verified C# OS layer (UI Automation, SendInput, screen capture + grid, PTT hook, DPAPI, SAPI) becomes a sidecar — Electron cannot do UIA natively, so discarding proven code would be pure waste. |

## Run

```bash
npm install
npm run build
npm start          # Electron
npm run dev        # Vite only, for fast UI iteration in a browser
```

## The sidecar bridge

`Teachy.Sidecar` is a `WinExe` (no console window) that speaks newline-delimited JSON over stdio:

```
in : {"id":"7","command":"capture-screen","args":{"includeElements":true}}
out: {"id":"7","ok":true,"result":{...}}
out: {"event":"ptt-pressed","payload":{}}      // unsolicited
```

It runs a hidden WinForms message loop because the global push-to-talk hook requires one, and pumps stdin on a background thread.

Commands: `capture-screen`, `inspect-elements`, `click-element`, `click-point`, `type-text`, `press-key`, `scroll`, `open-url` (http/https only), `speak`, `stop-speaking`, `get-config`, `set-config`, `get-api-key`, `set-api-key`, `get-screen-info`, `quit`.
Events: `ready`, `ptt-pressed`, `ptt-released`, `ptt-error`, `transcript`.

The renderer reaches it only through an enumerated `contextBridge` surface — no Node access, and only whitelisted events can be subscribed to.

**Both processes carry the Per-Monitor-V2 DPI manifest.** Without it Windows virtualizes every coordinate API to a compatibility resolution that disagrees with what the app renders — the bug that silently broke cursor pointing in the WPF build.

## Status

Working and verified live:
- Notch silhouette + spring motion, header tabs, course catalog, exact token system
- Sidecar bridge round-tripping real data (Settings reads the true DPAPI-encrypted key state and persisted notch placement out of C#)
- Sidecar verified standalone: correct 1920×1080 metrics, real UI Automation element list, JPEG capture
- **Cursor overlay** — a second click-through window trailing the pointer at 60fps, verified tracking across two positions
- **Voice loop** — push-to-talk → transcript → screen capture → OpenRouter (streaming) → speak + point

### How the two windows split

| Window | Role |
|--------|------|
| notch | The panel. Owns the companion loop (one instance) and drives the overlay over IPC. |
| overlay | Full-screen, permanently click-through decoration: trailing companion, response bubble, pointing ring. |

Only the main process can read the global cursor, so it polls `getCursorScreenPoint()` at ~60fps and pushes to the overlay. Positions are written straight to `style.transform` via refs — animating 60fps through React state would re-render the tree every frame.

**Coordinate spaces are the sharp edge here.** The sidecar reports PHYSICAL pixels (that is what screen capture and UI Automation deal in); Electron windows live in DIP. `overlay:command` converts by `scaleFactor` at the boundary. Getting this wrong is exactly the class of bug that silently broke pointing in the WPF build.

- **Course runtime** — all 31 goals across 4 courses, coaching turns grounded in the live screen, vision `doneWhen` gating (pass/partial/offTrack), soft teach-backs, progress persisted through the sidecar and resumed on restart

### Course goal data is generated, not retyped

`src/data/courseGoals.ts` is produced by a script that parses `Teachy.Engine/CourseDefinitions.cs` and emits TypeScript. Retyping 31 goals by hand would have silently drifted the Windows courses away from the Mac's wording — this way the coachAsk and doneWhen strings are byte-identical.

Verified after generation: 31 goals (9 / 8 / 7 / 7), zero null ids, exactly 8 concept goals with a null `doneWhen` (the Mac's `requireUserAdvance` cases).

- **"Do it for me" agent loop** — tool-calling against the sidecar's verified UIA primitives, re-observing the screen after every action
- **Tray icon**, **drag-to-place**, and working placement presets

### Two Electron gotchas worth remembering

**`nativeImage` does not decode SVG on Windows.** `createFromDataURL` with an SVG silently returns an empty image and the tray shows nothing — no error. The Teachy mark is rasterized into a BGRA buffer via `createFromBitmap` instead. (New tray icons also land in the Windows 11 overflow flyout by default, which is normal, not a failure.)

**`-webkit-app-region: drag` is not usable for the notch.** It swallows mouse events on the dragged element, which would break hover-to-open. Dragging is done manually: pointer capture, deltas reported over IPC, `setPosition` in main.

## Safety boundaries in the agent loop

Unchanged from the WPF build, and deliberate:

- Tool vocabulary is `click_element`, `type_text`, `press_key`, `scroll`, `open_url`, `observe_screen` — screen-level actions a learner could perform by hand. **No shell tool, no filesystem tool.**
- `open_url` is http/https only, enforced *in the sidecar* rather than only in the prompt.
- The system prompt forbids entering credentials or payment details, accepting terms, purchasing, or sending messages on the learner's behalf.
- Capped at 12 steps so a confused model cannot flail indefinitely.
