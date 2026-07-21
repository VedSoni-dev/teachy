# Teachy for Windows

Native Windows port of the macOS Teachy app. Same product, same worker proxy, same course JSON format, same `[POINT:...]` grid-pointing contract — different shell.

## Status: Phase 2 complete (notch + courses)

Working now:

- **The notch** — boring.notch-style black silhouette at top-center (exact `ClickyNotchShape` path port, animatable corner radii). Closed: 185×36 bar with the glowing pulsing Teachy triangle on the right wing; live-activity wings (triangle badge + animated audio spectrum) while listening. Hover springs it open to 640×320.
- **Header tabs** — Learn / Portfolio / Skills / Settings with the mac accent colors (teal `#0F8A6A`, orange `#FF9F0A`, purple `#BF5AF2`)
- **Courses, fully playable** — all four bundled courses with every goal ported verbatim (31 goals): coach turns grounded in the live screen, natural-language `doneWhen` gates via the mac verifier protocol (pass / partial / offTrack JSON), soft teach-backs (protégé effect), concept goals that advance on confirmation
- **Lesson HUD** — glass panel under the notch: course title, goal *n* of *N*, last coach line, Hint / I did it / Exit
- **Progress that survives** — `%USERPROFILE%\.teachy\windows-learner.json`; catalog cards show progress bars and Continue; courses resume where you left off; Skills tab shows per-domain proficiency; Portfolio shows shipped courses
- **Global push-to-talk**: hold **Ctrl + Alt** anywhere (mirrors ctrl+option) — course-aware: coaching stays on-goal mid-course
- **Screen capture** with the invisible 24×16 grid (A–X × 1–16) — identical contract to `ScreenGridAnnotationUtility`
- **Vision chat** direct to OpenRouter (BYOK, streaming SSE), key-aware model default (Sonnet 4.6 with your key), mac's curated model picker
- **Cursor companion overlay**: click-through, non-activating; glowing triangle cursor, response bubble, glide-and-pulse pointing
- **Apple-grade chrome**: overlay scrollbars (hidden until hover), rounded controls everywhere, real mac app icon in the tray
- **Voice**: local System.Speech transcription + SAPI TTS · **Keys**: DPAPI-encrypted at rest

## Automation — "Do it for me"

Teachy can perform the step itself, narrating each action aloud before it happens (the macOS announce-before-act contract).

Windows does this **better than the Mac original**: instead of inferring positions from pixels, `UiElementInspector` reads the real UI Automation tree of the active window and hands the model a numbered element list with exact bounds. The model then acts by element id, so a click lands on the actual control.

- `UiElementInspector` — enumerates interactive controls (name, type, exact bounds), capped at 60
- `InputSynthesizer` — prefers UIA `Invoke`/`Value`/`Toggle`/`SelectionItem` patterns; falls back to `SendInput` only when a control exposes no pattern
- `AgentToolLoop` — OpenRouter tool-calling loop; **re-observes the screen after every action**, so the model sees what its action actually did rather than what it intended. Capped at 12 steps.
- Same element list also sharpens pointing: `[POINT:ax:7:the Sign in button]` resolves to exact bounds, outranking grid cells

**Deliberate limits.** The tool vocabulary is `click_element`, `type_text`, `press_key`, `scroll`, `open_url`, `observe_screen` — screen-level actions a learner could do by hand. There is no shell tool and no filesystem tool. `open_url` accepts http/https only. The agent prompt forbids entering credentials or payment details, accepting terms, purchasing, or sending messages on the learner's behalf.

Verified end-to-end against a live window: UIA discovery → `ValuePattern` typing → `InvokePattern` click → target app's own state confirmed the change.

## Roadmap (remaining parity)

| Phase | Scope |
|-------|-------|
| 3 | Full TeachyEngine port (SkillGraph, SM-2 reviews), course JSON install from `~/.teachy/courses/` + Academy, onboarding permission choreography + product tour |
| 4 | AssemblyAI streaming transcription via the worker proxy, multi-monitor capture (Windows.Graphics.Capture), teacher video clips, Velopack auto-updates, installer |

## Build & run

Requires .NET 8 SDK.

```powershell
cd windows
dotnet build Teachy.sln
dotnet run --project Teachy.App
```

First run opens the panel — paste your free [OpenRouter](https://openrouter.ai) key. Then hold **Ctrl+Alt** and ask about anything on screen.

## Projects

| Project | Purpose |
|---------|---------|
| `Teachy.Engine` | Platform-free logic: OpenRouter streaming client, companion prompt, `[POINT:...]` tag parsing, grid geometry. Mirrors the mac `TeachyEngine` boundary (adapter-agnostic core). |
| `Teachy.Platform` | Windows capabilities: keyboard hook (PTT), GDI screen capture + grid burn, NAudio mic recording, System.Speech STT, SAPI TTS, DPAPI config, `%USERPROFILE%\.teachy` paths. |
| `Teachy.App` | WPF shell: tray icon, panel window, click-through cursor overlay, `CompanionManager` orchestrator. |

## Notes

- On some international keyboard layouts AltGr registers as Ctrl+Alt; push-to-talk requires a *hold*, so brief AltGr taps don't trigger recording.
- Primary display only in v0; multi-monitor lands with Windows.Graphics.Capture in Phase 4.
