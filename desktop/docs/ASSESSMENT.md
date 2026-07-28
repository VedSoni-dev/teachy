# Teachy for Windows (Electron) — Architecture Assessment & Parity Plan

Assessment only. No code was changed. Paths are absolute where they leave this repo; `file:line` citations are relative to `/Users/ved.soni/clicky-win/desktop/` unless noted.

Reference macOS app: `/Users/ved.soni/clicky/leanring-buddy/`. Note that `clicky-win/` is a full mirror of the `clicky` repo **plus** two extra trees: `windows/` (C# — old WPF `Teachy.App`, `Teachy.Engine`, `Teachy.Platform`, `Teachy.Sidecar`) and `desktop/` (this Electron app).

---

## 1. Architecture as-built

Three processes, one of them borrowed from the dead WPF build.

| Layer | Where | Responsibility |
|-------|-------|----------------|
| **Electron main** | `electron/main.cjs` | Two frameless/transparent/always-on-top `BrowserWindow`s (notch + full-screen overlay), tray icon (hand-rasterized triangle, `main.cjs:29`), 60fps cursor polling → overlay (`main.cjs:154`), click-through toggling (`notch:set-interactive`), manual drag, placement presets, physical→DIP scale conversion at the overlay boundary (`main.cjs:272`). |
| **Preload** | `electron/preload.cjs` | Enumerated `contextBridge` surface `window.teachy` — `invoke`, `on` (whitelisted events only), `notch.*`, `overlay.*`. No Node in renderer. |
| **Sidecar bridge** | `electron/sidecar.cjs` | Spawns the C# `Teachy.Sidecar.exe`, newline-delimited JSON over stdio, id-keyed request/reply + unsolicited events. |
| **C# sidecar** | `../windows/Teachy.Sidecar/Program.cs` | OS primitives only: `capture-screen` (+grid+elements), `click-element`/`click-point`/`type-text`/`press-key`/`scroll`, `open-url`, SAPI `speak`, DPAPI config + API key, `get-progress`/`record-goal-completed` (durable `LearnerProgressStore`), PTT hook, transcription. |
| **Renderer** | `src/**` | React. One bundle serves both windows; `main.tsx:18` branches on `?window=overlay`. **All AI logic lives here.** |

**Renderer internal map**
- **Windows:** `notch/Notch.tsx` (the panel; owns the single companion loop and course session) and `overlay/Overlay.tsx` (pure decoration — trailing cursor, bubble, pointing arc; refs + rAF, never React state at 60fps).
- **State (hooks + plain modules):** `state/useCompanionLoop.ts` (voice/typed Q&A turn), `state/useCourseSession.ts` (course runtime), `state/companion.ts` (prompt build + `[POINT:...]` parse + OpenRouter stream), `state/agentLoop.ts` ("Do it for me" tool loop), `state/courseVerifier.ts` (vision pass/partial/offTrack gate), `state/useTeachyConfig.ts` (config mirror).
- **Tabs:** `tabs/{Learn,Portfolio,Skills,Settings}Tab.tsx`. **Course HUD:** `course/LessonHUD.tsx`.
- **Data:** `data/courseCatalog.ts` (4 courses), `data/courseGoals.ts` (31 goals, "generated" from `CourseDefinitions.cs`).
- **Design:** `styles/tokens.css` (transcribed from `DesignSystem.swift`), `styles/global.css`, per-area CSS.

**Data flow (one turn):** PTT held → C# transcribes → `transcript` event → `useCompanionLoop` → `capture-screen` (C#) → **renderer calls `https://openrouter.ai` directly with the raw key** → stream parsed for `[POINT]` → `speak` (C#) + overlay pointing over IPC.

---

## 2. What's wild / messy

### Triple-implemented AI logic (the headline mess)
The companion prompt, point-tag parser, grid geometry, course verifier, agent tool loop, and course data now exist in **three** languages: Swift (`leanring-buddy/`), C# (`windows/Teachy.Engine/`: `CompanionPromptBuilder.cs`, `PointTagParser.cs`, `GridGeometry.cs`, `CourseVerifier.cs`, `AgentToolLoop.cs`, `AgentToolDefinitions.cs`, `CourseDefinitions.cs`, `CourseCatalog.cs`), and TypeScript (`src/state/`, `src/data/`).
- The **entire `Teachy.Engine` C# project is now dead code** for this app — the Electron renderer re-implements all of it in TS and the sidecar only uses `Teachy.Platform` + the progress store. It sits in the tree as a maintenance trap.
- `data/courseGoals.ts:1-7` documents a **3-hop transcription chain** (Swift → `CourseDefinitions.cs` → `courseGoals.ts`). Any wording change must be made in three places or the courses silently diverge.

### Duplication inside the renderer
- **OpenRouter fetch boilerplate copied 3×** — identical headers, `HTTP-Referer`, endpoint, SSE handling in `companion.ts:197`, `agentLoop.ts:199`, `courseVerifier.ts:43`. No shared client.
- **Hardcoded referer** `'https://vedsoni-dev.github.io/teachy/'` in all three of the above.
- **`BRING_YOUR_OWN_KEY_MODEL = 'anthropic/claude-sonnet-4.6'`** hardcoded twice (`useCompanionLoop.ts:11`, `useCourseSession.ts:14`).

### Inconsistent default model (real bug)
- Fallback when `config.chatModel` is null is `claude-sonnet-4.6` (`useCompanionLoop.ts:83`, `useCourseSession.ts:94`) — a **paid BYOK** model.
- But the Settings dropdown shows `google/gemini-2.5-flash` as selected in the same null case (`SettingsTab.tsx:12,49,123`).
- So a fresh user's coach silently runs Claude while the UI claims Gemini. The `MODEL_OPTIONS` list itself (`SettingsTab.tsx:11-18`, e.g. `gemma-4-26b-a4b-it`, `claude-haiku-4.5`) looks hand-invented and does not trace to `OpenRouterModelOptions.swift`/`.cs`.

### Key handling
- The raw OpenRouter key is pulled out of DPAPI **into the Chromium renderer** (`get-api-key` → `useCompanionLoop.ts:67`, `useCourseSession.ts:80`, `agentLoop`) and the network call is made from the renderer. The sidecar comment even flags it (`Program.cs:247` "Stays inside the local process boundary") — but IPC to the renderer crosses that boundary. Larger secret-exposure surface than necessary.

### Fragile / dead patterns
- **Sidecar path is dev-only:** `resolveExecutablePath()` hardcodes `bin/Debug/net8.0-windows` (`sidecar.cjs:27-38`); a packaged build works **only** if `TEACHY_SIDECAR_PATH` is set. No Release path, no packaging config in `package.json` (no electron-builder, no `test`/`lint` scripts).
- **`ptt-released` is forwarded and whitelisted** (`main.cjs:292`, `preload.cjs:4`) but **no renderer consumer** exists — dead channel.
- **`onState` typed `(state: never)`** in `types/global.d.ts:56`, then cast to `OverlayState` at the call site (`Overlay.tsx:93`) — a type hole papered over by a cast.
- **Overlay/notch are primary-display only** (`main.cjs:107`, `createOverlayWindow` uses `getPrimaryDisplay()`); cursor polling and pointing break across monitors. macOS `OverlayWindow` is explicitly multi-monitor and joins all Spaces.
- **`React.StrictMode`** (`main.tsx:20`) double-mounts the companion loop effect in dev; it cleans up listeners so it survives, but the pattern is fragile for an "always-on" singleton loop.
- **Teach-back double-handling** (see §3) — a structural smell, not just style.

---

## 3. Drift from the macOS app

### Tabs — visible set actually matches; everything behind them is thinner
Mac header (`ClickyNotchRootView.swift:353-356`) shows **Learn / Portfolio / Skills / Settings** (enum `NotchPanelTab` has `home, courses, portfolio, skills, agents`; agents hidden; `home`=Settings). Electron `NotchTab` = `learn | portfolio | skills | settings` (`Notch.tsx:12`). **Tab set is at parity.** The divergence is in depth (§4), plus the **new Progress tab the Mac gained** which desktop lacks entirely (§6).

### Coaching loop
| Aspect | macOS | Electron |
|--------|-------|----------|
| Course engine | `LessonPlayer.swift` (~730) + `CoursesManager` + `TeachyEngine` | `useCourseSession.ts` (~410), self-contained |
| Teacher videos | video parts (`teacherVideoURL`, notes, `teachingContext`, `toolPolicy`) | none — goals only |
| Teach-back | `TeachBackEngine` (quick / full / teach-someone-else, quality scoring, produces `TeachingDemo`) | one boolean `isAwaitingTeachBack`; any next voice line advances |
| Verification | `VerificationEngine` (vision + explain + near-transfer + code analysis) | vision-only `courseVerifier.ts` |
| Learner model updates | writes `LearnerModel`, skills, spaced-repetition schedule | writes only `completedGoals` count via `record-goal-completed` |
| Autonomy transfer | coach does less as proficiency rises (`CoachAutonomy`) | not modeled |

**Teach-back double-handling (behavioral bug):** while a teach-back is pending, the voice transcript is routed *both* to the full screen-grounded companion turn *and* to the advance callback (`Notch.tsx:32`, `useCompanionLoop.ts:125-127`). So the general companion answers the teach-back question about the screen, then the course advances — instead of the answer being scored as teaching. On Mac these are distinct paths.

### API path
Mac routes coaching through a proxy abstraction (`WorkerBaseURL`, `worker/`), though its BYOK path also hits OpenRouter directly (`ClaudeAPI.swift:23`). Electron has **no proxy option at all** and no `/health` fail-fast (`ClickyProxyHealthChecker.swift` has no counterpart). Consequence: no server-side model upgrade for text-only models, no place to move the key off the client.

### What the sidecar does that Mac does natively
The C# sidecar is the correct call — Electron cannot do UI Automation, global low-level hooks, DPAPI, or SAPI. Mac does all of these in-process (ScreenCaptureKit, `CGEvent` tap, Keychain-ish, `NSSpeechSynthesizer`). This split is sound. The problem is only that the sidecar's **`Teachy.Engine` half was left in the tree and bypassed.**

### Design tokens — actually a strength
`styles/tokens.css` matches `DesignSystem.swift` value-for-value (surfaces `#12151A…`, blues, tab accents `#0F8A6A`/`#FF9F0A`/`#BF5AF2`, radii, spacing, spring `linear()` curves). The notch silhouette (`notchShape.ts`) and 24×16 grid (`companion.ts:33`, matching `ScreenGridAnnotationUtility.swift:16`) are faithful. **No meaningful token drift** — the earlier "distinctive aesthetic" mistake has been corrected. One nit: `tabs.css` re-hardcodes glass fill `#1b1e25` and various `rgba(245,245,247,…)` inline instead of going through token vars.

---

## 4. Parity gaps (Mac has, desktop lacks or does worse)

| Feature | Mac | Desktop | Severity |
|---------|-----|---------|----------|
| **TeachyEngine** (LearnerModel, SkillGraph, VerificationEngine, TeachBackEngine, SpacedRepetitionEngine, PortfolioManager) | full (`leanring-buddy/TeachyEngine/`) | **absent** — Skills/Portfolio faked from raw progress | P0 |
| Skills tab | proficiency, retention forgetting-curve %, at-risk, by-domain, suggested-next, streak, autonomy (`NotchSkillsTabView.swift`) | course rows with `completedGoals/total` relabeled "learning/developing/proficient" (`SkillsTab.tsx`) | P1 |
| Portfolio tab | real artifacts, quality scores, skills-used, share cards, live URLs, teaching demos (`NotchPortfolioTabView.swift`) | list of completed course titles (`PortfolioTab.tsx`) | P1 |
| Onboarding / permissions | `NotchSetupOnboardingView` + `PermissionChoreographyView` (one-at-a-time animated wizard, product tour) | **none** | P1 |
| Settings/Home depth | ElevenLabs voice key, Sparkle software updates, cursor color, check-in card, feedback link, live model fetch (`NotchHomeTabView.swift`) | key + model + placement + show-cursor toggle (`SettingsTab.tsx`) | P2 |
| Course catalog | Academy install (URL/GitHub), featured, custom-course builder sheet (`NotchCoursesTabView.swift`) | 4 hardcoded bundled courses only (`LearnTab.tsx`) | P2 |
| Teacher videos in lessons | yes | no | P2 |
| Multi-monitor overlay/pointing | yes | primary display only | P1 |
| Temporal continuity ("last time you…") | `LearnerTemporalContext.swift` injected into prompts | none | P2 |
| Progress tab | **new on Mac** | absent | P1 (see §6) |
| Auto-update | Sparkle (`TeachySoftwareUpdater`) | none | P2 |

---

## 5. Prioritized cleanup + parity plan

### P0 — correctness & the structural trap
1. **Fix the default-model split-brain.** One source of truth for the default; make the null-config fallback and the Settings dropdown agree. Pick a free vision model (align with `OpenRouterModelOptions`), not `claude-sonnet-4.6`. Files: `useCompanionLoop.ts:11,83`, `useCourseSession.ts:14,94`, `SettingsTab.tsx:11-18,49,123`.
2. **Collapse the OpenRouter client to one module.** Extract the shared `fetch` + headers + SSE parse used by `companion.ts:197`, `agentLoop.ts:199`, `courseVerifier.ts:43`. Kills the referer/model/endpoint copies.
3. **Decide the fate of C# `Teachy.Engine`.** Either (a) delete it and make TS the Windows source of truth, or (b) route the renderer through the sidecar so the C# engine is authoritative and TS is thin.
   > **CORRECTION (verified 2026-07-27):** `Teachy.Engine` is NOT fully dead. `Teachy.Platform` project-references it (`Teachy.Platform.csproj`) and uses it (`ScreenGridAnnotationUtility.cs: using Teachy.Engine;` — GridGeometry), and the sidecar uses `Teachy.Platform`. So the sidecar transitively depends on `Teachy.Engine`; a blind delete breaks the build. Option (a) requires first extracting the still-used bits (grid geometry) out of Engine (or into Platform), removing the *dangling* `ProjectReference` in `Teachy.Sidecar.csproj:23` (the sidecar's own code doesn't use Engine directly), then rebuilding on Windows. This is a Windows-toolchain task, not a text delete.
4. **Fix teach-back double-handling** so a pending teach-back answer is scored/advances *instead of* running a generic screen-Q&A turn (`Notch.tsx:32`, `useCompanionLoop.ts:125-127`).
5. **Give the sidecar a real resolved path + packaging.** Release path in `resolveExecutablePath()` (`sidecar.cjs:27`), add electron-builder config and a `test`/`typecheck` script to `package.json`.

### P1 — parity that users see
6. **Port a minimal TeachyEngine to the Windows data plane.** Move the `LearnerProgressStore` in the sidecar toward a `LearnerModel`-shaped store (skills, streak, timestamps, teaching demos) and expose `get-learner-model` / `get-progress-summary`. This unblocks Skills, Portfolio, and Progress at once.
7. **Rebuild Skills & Portfolio tabs on that model** instead of faking from `completedGoals`.
8. **Add onboarding + permission priming** (Windows needs mic/accessibility-equivalent consent) — port the choreography intent from `PermissionChoreographyView`.
9. **Multi-monitor overlay** — create/position the overlay per display and pick the display under the cursor when pointing (`main.cjs:107,272`).

### P2 — depth & polish
10. Settings depth: software updates, cursor color, feedback, live model list fetch.
11. Academy install + custom-course builder in Learn.
12. Teacher-video lesson parts; temporal continuity phrases in prompts.
13. Route tokens through vars in `tabs.css` (remove inline `#1b1e25`).

---

## 6. Progress tab slot-in

The Mac just gained `NotchProgressTabView` (streak, things-built, skills-learned, current-course bar, recent moments, next-up). Desktop should mirror it. Given the current tab + state structure, it slots in cleanly:

**Wiring (all in `src/notch/Notch.tsx`):**
1. Extend the union — `Notch.tsx:12`: `export type NotchTab = 'learn' | 'progress' | 'portfolio' | 'skills' | 'settings';`
2. Add to `TAB_DEFINITIONS` (`Notch.tsx:15-20`) with a new `accentVariable`, ordered right after `learn` (matches a "your journey" position). Add a `--progress-accent` token to `styles/tokens.css` (Mac will define one; if none yet, a distinct hue e.g. the existing `--info` `#70B8FF`, kept in sync with Swift later).
3. Add a `TabGlyph` case (`Notch.tsx:250-278`) — a flame or upward-trend SVG.
4. Add the render branch in the tab body (`Notch.tsx:196-199`): `{selectedTab === 'progress' && <ProgressTab />}`.

**New file `src/tabs/ProgressTab.tsx`** — mirror the `SkillsTab.tsx`/`PortfolioTab.tsx` pattern (useEffect → `window.teachy.invoke('get-progress')`, `glass-card` styling from `tabs.css`).

**Data source per field — and the gap that forces one sidecar change:**

| Progress field | Available now from `get-progress`? | Source |
|----------------|-----------------------------------|--------|
| things-built | yes | count of `progress.completed` courses (same as `PortfolioTab.tsx`) |
| skills-learned | partial | count of courses with `completedGoals > 0` (as `SkillsTab.tsx`); real skill count needs the learner model (P1 #6) |
| current-course bar | yes | the in-progress course + `completedGoals/totalGoals` |
| next-up | yes (client-side) | next incomplete goal from `GOALS_BY_COURSE_ID` for the in-progress course |
| **streak** | **no** | `LearnerProgressStore` stores only `lastActivityUtc` per course — no streak. **Add a `currentStreakDays`/`longestStreakDays` field (or a `get-progress-summary` command) to `Program.cs`.** |
| **recent moments** | **no** | needs per-goal completion timestamps; today only a `completedGoals` count is stored. **Add a timestamped goal-completion log to the sidecar.** |

**Recommendation:** ship a v1 Progress tab now using only the four client-derivable fields (things-built, current-course, next-up, skills-learned-approx) so it lands without sidecar work; add `streak` + `recent moments` when P1 #6 extends the sidecar store. This keeps the tab honest rather than showing zeros for fields the Windows data plane cannot yet supply.

---

*End of assessment.*
