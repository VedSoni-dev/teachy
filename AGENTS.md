# Teachy - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar **assistant** in the HeyClicky mould. Hold the push-to-talk key, ask anything about your screen, and Teachy answers out loud, points and draws on screen, remembers you (the Brain), and can do the thing for you (one-shot [DO:] commands, background agent jobs via [JOB:], Drive). When you'd rather click through it yourself, it walks you through step by step ([GUIDE:]). Tagline direction: "finally do the thing — jump into any tool, ask questions, and Teachy draws on your screen and helps you / does it for you."

There are no courses, lessons, teach-backs or learner models any more: the course stack (`ClickyCourse`, `CoursesManager`, `LessonPlayer`, the course HUD/dock, the Courses/Portfolio/Skills tabs) and the `TeachyEngine/` learning engine were removed in Nov 2026. All voice goes through one general voice turn (`CompanionManager.sendCompanionChatResponse`). The `courses/` folder still exists but the macOS app no longer reads it. The `academy/` site is now the assistant landing page (`index.html`) plus `changelog.html`.

**Distribution:** Free (closed-source, BYOK) macOS DMGs via GitHub Releases on the PUBLIC `VedSoni-dev/teachy-releases` repo — DMGs, `appcast.xml` (Sparkle feed), `registry.json`, and the free course library live there so this code repo can be private without breaking downloads/updates/installs. `scripts/release.sh` builds locally and publishes to that repo (appcast via the GitHub contents API). Default shipping is a **community build** (ad-hoc signed, no Apple notarization). Users right-click → Open once for Gatekeeper. Sparkle (`TeachySoftwareUpdater`) verifies EdDSA signatures before updating. The app still registers the `teachy://` URL scheme, but any `teachy://` link now just opens the notch (the old `teachy://install?url=` course installer is gone).

All API keys live on the Teachy proxy (local dev server or Cloudflare Worker) — nothing sensitive ships in the app.

## Windows port (`windows/`)

Native Windows companion app (C# / .NET 8 / WPF) sharing the worker proxy, course JSON format, `~/.teachy` layout, and the `[POINT:...]` 24×16 grid-pointing contract. Three projects: `Teachy.Engine` (platform-free logic), `Teachy.Platform` (keyboard hook PTT, GDI capture + grid burn, NAudio mic, System.Speech STT, SAPI TTS, DPAPI key storage), `Teachy.App` (WPF tray shell, panel, click-through cursor overlay). Push-to-talk is **Ctrl+Alt**. Build: `cd windows && dotnet build Teachy.sln`. Phase roadmap in `windows/README.md`. Changes to the grid contract, course JSON, or worker routes must stay compatible with both apps.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat (Companion)**: OpenRouter free-tier models (default `google/gemma-4-31b-it:free` for vision) via proxy with SSE streaming. Anthropic Claude supported as legacy fallback when `OPENROUTER_API_KEY` is not set.
- **AI Agent**: Single OpenRouter loop (default `google/gemini-2.5-flash`) via `POST /v1/chat/completions`. Screenshots attach directly to the first message; the proxy upgrades text-only models (e.g. DeepSeek) to a vision model when images are present. Web search/fetch via OpenRouter server tools; Mac tools execute locally. **Connections**: Composio (planned) for SaaS; **OpenAPI connections** register dynamic tools from `~/.teachy/connectors/*.json` (legacy `~/.clicky/connectors/` still works) by parsing an OpenAPI 3 spec (`transport.type: openapi`). Legacy **Teachy HTTP** connectors (`transport.type: http`) use `/tools` + `POST /tools/{name}`.
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: Local `NSSpeechSynthesizer` (ElevenLabs optional via worker when configured)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap. Every transcript (and the text box) goes through the one general voice turn: answer about the screen, point/draw, and do the task when asked ([DO:], [JOB:], [GUIDE:]).
- **Element Pointing**: Weaker vision models embed `[POINT:M6:label]` grid-cell tags (20×12 grid, columns A–T, rows 1–12). Screenshots include an invisible coordinate grid burned into the JPEG. The overlay parses tags and animates the cursor to the target.
- **Spatial mouse outline**: While push-to-talk is held, the user's mouse path is tracked. If they circle something on screen, a chalk stroke is burned into the model-facing screenshot and the touched grid cells are listed in the image label so the model knows what "this" refers to.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker + Local Dev)

The app never calls external APIs directly. All requests go through the Teachy proxy (`worker/src/index.ts` in production, `worker/local-proxy.mjs` for local dev). Base URL is read from `WorkerBaseURL` in Info.plist (default `http://localhost:8787`).

| Route | Upstream | Purpose |
|-------|----------|---------|
| `GET /health` | — | Proxy status + configured chat/agent models |
| `POST /chat` | OpenRouter (or Anthropic fallback) | Companion vision + streaming chat |
| `POST /v1/chat/completions` | OpenRouter | Background agent tool-calling loop |
| `POST /tts` | ElevenLabs (optional) | Cloud TTS audio (app uses local TTS by default) |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Short-lived AssemblyAI websocket token |

Worker secrets: `OPENROUTER_API_KEY` (primary), `ASSEMBLYAI_API_KEY`, `ANTHROPIC_API_KEY` (legacy fallback), `ELEVENLABS_API_KEY` (optional)
Worker vars: `CHAT_MODEL`, `AGENT_MODEL`, `ELEVENLABS_VOICE_ID`, `WORKER_REFERER`

Local dev:
```bash
cd worker && cp .env.template .env   # add OPENROUTER_API_KEY
npm run local                        # start proxy on :8787
npm run harness                      # validate all routes
```

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Teachy" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Notch Panel (boring.notch-inspired)**: Fixed-size floating `NSPanel` at top-center (`ClickyNotchSizing.windowSize`). SwiftUI animates a glass `ClickyNotchShape` open/closed inside it — the window frame does not resize. Closed: physical-notch width with a compact still pointer wing, or live-activity wings (cursor + spectrum) while listening / thinking / speaking / an agent job runs. Pinned navigation switches between **Home**, **Agents**, **Drawings** and **Settings**. First launch: permissions → scored Teachy product tour (music + soft SFX) with a live “I can see your screen” pointing beat → Home; optional full Farza intro video. Hover opens; click-outside / Collapse closes. Reference clone: `reference/boring.notch` (gitignored).

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~100 | Menu bar app entry point. Starts companion + Sparkle via `TeachySoftwareUpdater`. |
| `TeachySoftwareUpdater.swift` | ~70 | Sparkle auto-update controller — GitHub Releases feed + Check for Updates in Home settings. |
| `CompanionManager.swift` | ~2820 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the general voice turn and its system prompt (`buildCompanionVoiceResponseSystemPrompt`), [GUIDE:] walkthroughs, local TTS, and overlay management. Tracks voice state, conversation history, chat/agent model selection, and cursor visibility. Layer 2 `executeActStep` runs `.act` guided-task steps via the agent tool loop with announce-before-act ordering; Layer 3 `reflectAndReplaceRemainingSteps` calls the reasoning model on divergence to revise the living plan. |
| `CompanionGuidedTask.swift` | ~160 | Ephemeral [GUIDE:] walkthrough model (`GuidedStepGoal`, `GuidedStepExecutionMode` `.coach`/`.act`, `AgenticStep`, `CompanionGuidedTask` with a replan cap) plus the [GUIDE:] / [DO:] / [CLIPBOARD:] / [REMEMBER:] tag parsers. |
| `GuidedTaskPlanner.swift` | ~335 | Model calls behind [GUIDE:]: `GuidedTaskPlanner` (screen-grounded plan, text-only fallback, replan on divergence) and `GuidedStepScreenChecker` (pass / partial / off track + visible error). |
| `TeachyDataPaths.swift` | ~35 | Resolves `~/.teachy/{connectors,brain}` with legacy `~/.clicky/` fallback for connectors. |
| `academy/` | — | Marketing site: assistant landing page (`index.html`, `site.css`, `app.js`) and `changelog.html`. Course store removed; `registry.json` kept for old installs. |
| `AgentToolResult.swift` | ~35 | Tool results with optional vision images fed back into the agent loop. |
| `BackgroundAgentSideDockWindow.swift` | ~470 | Side-docked Teachy mascot shown during a live Composio sync prompt (background-agent progress card removed as dead UI — the mascot dock, sync card, and their animations are still live). |
| `BackgroundAgentManager.swift` | ~470 | OpenRouter tool-calling agent loop. OpenRouter server tools for web search/fetch; Mac-native tools + browser cookie sessions + App Connectors run locally. |
| `AppConnectorManager.swift` | ~320 | Discovers `~/.teachy/connectors/*.json`, loads OpenAPI or Teachy HTTP connections, registers dynamic agent tools. |
| `AppConnectorManifest.swift` | ~175 | Connection manifest types, tool naming (`connector_id__tool_name`), seed manifest for Plant Maint demo. |
| `OpenAPIConnectorParser.swift` | ~150 | Parses OpenAPI 3 JSON specs into agent tool operations. |
| `OpenAPIConnectorTool.swift` | ~170 | Executes OpenAPI operations as HTTP requests. |
| `RemoteAppConnectorTool.swift` | ~80 | Legacy Teachy HTTP connector — `POST /tools/{name}`. |
| `connectors/plant-maint/server.mjs` | ~200 | Reference Plant Maintenance ERP — REST API + `GET /openapi.json`. |
| `ComposioConnectionManager.swift` | ~220 | Monitors frontmost app, detects Composio-supported apps, shows sync prompt dock with haptic. |
| `ComposioFrontmostAppMapping.swift` | ~75 | Maps macOS bundle IDs / app names to Composio toolkit slugs. |
| `worker/src/composio.ts` | ~120 | Composio proxy routes: `/composio/connections`, `/composio/connect`. |
| `BackgroundAgentTool.swift` | ~150 | Tool protocol and registry: bash, files, AppleScript, UI, screen capture, browser cookies. |
| `ChromiumBrowserCookieReader.swift` | ~370 | Decrypts cookies from Chrome, Brave, Arc, and Edge. |
| `SafariBinaryCookiesReader.swift` | ~150 | Reads Safari Cookies.binarycookies. |
| `BrowserSessionStore.swift` | ~200 | Unified browser cookie access for authenticated_fetch. |
| `AgentMacNativeTools.swift` | ~400 | run_applescript, open_browser_tab, ui_action, capture_screen tools. |
| `Agent/Drive/ComputerUseTool.swift` | ~330 | `computer` tool: real computer use (screenshot, click, drag, type, key, scroll with the real pointer, HID-level CGEvents), judged by `ToolPolicy.classifyComputer` per app under the point; shares Drive's capture ids and takeover watch. |
| `AgentBrowserTools.swift` | ~120 | authenticated_fetch and list_browser_sessions tools. |
| `OpenRouterModelOptions.swift` | ~75 | Curated OpenRouter model list + `ClickyWorkerConfiguration` (proxy URL from Info.plist). |
| `LocalSpeechSynthesizer.swift` | ~45 | macOS `NSSpeechSynthesizer` TTS playback. |
| `NotchScreenGeometry.swift` | ~135 | Reads `NSScreen.auxiliaryTopLeftArea`; closed notch width/height. |
| `ClickyNotchSizing.swift` | ~40 | Open/closed sizes, corner radii, spring animations (boring.notch `matters.swift`). |
| `ClickyNotchShape.swift` | ~75 | Animatable notch silhouette (DynamicNotchKit / boring.notch). |
| `ClickyAudioSpectrumView.swift` | ~180 | Closed-notch spectrum bars + idle blinking face. |
| `ClickyNotchRootView.swift` | ~370 | Root notch UI — one `TeachyGlassSurface` in the notch shape: clear glass when closed, solid black when open; live activity, compact header navigation, spring open height. |
| `NotchWindowManager.swift` | ~220 | Fixed-size floating `NSPanel`, hover-to-open, click-outside collapse. |
| `NotchPanelView.swift` | ~70 | Thin notch panel shell — setup/onboarding until done, then the selected scroll page; navigation lives in the root header. |
| `NotchPanelSharedComponents.swift` | ~110 | Shared helpers for the notch panel: `FlowLayout` and the free-function `openRouterModelPickerRow`. (`KeyboardKeyLabel` moved to `DesignSystem.swift`.) |
| `NotchHomeTabView.swift` | ~415 | Home tab, top to bottom: the "Hold [keys] and ask." headline with the shortcut recorder, a three-column group of what you can do, quick actions (chat window, always-on, typing, files), agents / connectors / drawings / memory sections, then settings as one grouped list of rows that open in place (account, voice, microphone, dictation, shortcuts, pointer colour, browser, privacy, updates, advanced) and the feedback links. |
| `NotchSetupOnboardingView.swift` | ~575 | Setup stage router — permission choreography, one-time Automation explainer, API key setup, and the in-panel Teachy product tour (`TeachyOnboardingPage`). |
| `PermissionChoreographyView.swift` | ~430 | One-permission-at-a-time setup wizard: auto-fires system prompts, animated System Settings toggle mock, 1s poll auto-advances on grant. |
| `MenuBarPanelManager.swift` | ~103 | NSStatusItem lifecycle. Menu bar icon toggles the notch panel. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `ScreenGridAnnotationUtility.swift` | ~220 | Burns an invisible A-J / 1-8 coordinate grid onto screenshots before they are sent to vision models. Chalk-outlines user mouse circles and converts grid-cell POINT/DRAW tags to screen coordinates. |
| `MouseOutlineTracker.swift` | ~75 | Records the user's mouse path during push-to-talk for spatial "circle this" context. |
| `CompanionMouseOutlineContext.swift` | ~45 | Maps a mouse outline to touched grid cells and a spatial label for the model. |
| `ScreenGridDrawInstruction.swift` | ~55 | Parses `[DRAW:...]` model tags for visible chalk region highlights on the overlay. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Anthropic-format vision API client with SSE streaming. Used for companion chat through the proxy (OpenRouter or Anthropic backend). |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | — | Removed — app uses `LocalSpeechSynthesizer` instead. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~1020 | The design language in code ("Teachy looks like part of macOS", see `docs/DESIGN.md`): `DS.Colors` (Dark Mode system greys, label colours, the pointer colour as the tint), `DS.Fonts` (SF Pro at macOS sizes), `DS.Motion`, `DS.Haptics`, and the components every screen uses: `.teachyButton` (capsules), `.teachyIconButton`, `.teachyLinkButton`, `.teachyOption`, `.teachyTile` (system glass: Liquid Glass on macOS 26, a material before it, solid with Reduce Transparency, a frosted stand-in in off-screen renders), `.teachyGroup` (grouped-list container), `.teachyWell`, `TeachyRule`, `TeachySectionTitle`, `TeachyStatusMark` (SF Symbols), `TeachySwitch`, `KeyboardKeyLabel`, `TeachyPointerShape`. Controls are drawn here rather than borrowed from AppKit because Teachy's panels never become the key window. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `TeachyPublikSession.swift` | ~140 | Publik sign-in state, account logout, stale-response protection, and account beacons. |
| `worker/src/index.ts` | ~220 | Cloudflare Worker proxy. OpenRouter primary; Anthropic/ElevenLabs/AssemblyAI optional. |
| `worker/src/openrouter.ts` | ~200 | OpenRouter format conversion (Anthropic SSE ↔ OpenAI) shared by worker and local proxy. |
| `worker/local-proxy.mjs` | ~305 | Local dev proxy — same routes as production worker. |
| `worker/harness.mjs` | ~350 | Backend test harness (`npm run harness`). |
| `worker/config.mjs` | ~70 | Shared env + model resolution for local proxy. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team (required for Accessibility to persist across rebuilds), Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Signing team required for dev:** Set your Apple Development Team in Xcode → Signing & Capabilities. Without it, macOS treats each rebuild as a new unsigned app and Accessibility permission won't stick.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Notch UI (15 Nov 2026)

Home shows recent drawings, connection status, Open chat and the voice shortcut. `NotchPanelTab.swift` defines Home, Agents, Drawings, Connections and Settings. Home/Agents share the compact root header with Drawings/Settings icon buttons; `NotchPanelView` holds the selected scrolling page. Settings includes account/logout, always-on voice and other preferences, followed by Connectors and Memory. File drag-over selects Home. Shortcut recording cancels when leaving Home.

The expanded black shell is 520×240pt. Closed idle uses the real camera width plus symmetric 24pt wings and 8pt outer padding (249pt with a 185pt camera). A notchless display uses a 48pt idle indicator. Keep the real camera reservation intact in both idle and active states. Leaving the visible panel collapses after 180ms; re-entry, attachment drag and native menu tracking cancel pending closure. The full transparent hosting window is not a hover target. `scripts/tests/run_notch_hover_tests.sh` exercises the real manager with temporary stubs. Render `scripts/tests/render_home_shots.sh` for pages and notched/notchless states; its stubs read no live app data. Use Xcode GUI for the full Release build and validate live navigation after installing.

## Drawing performance (15 Nov 2026)

- Daily installs should use Xcode **Product → Build For → Profiling** (Release), then copy the completed signed `Build/Products/Release/Teachy.app` to `~/Applications/Teachy.app`. The dev-install phase only handles Debug and runs before final signing; do not treat its copy as the finished signed build.
- App startup initializes `SceneDirector.shared` before Home is shown, so saved-drawing Replay works even before the first new AI request. Keep this eager registration when changing startup.
- 2D overlays use a finite timeline for reveal/fade intervals. Settled drawings and hold gaps do not request frames. New items restart the schedule; frozen replay snapshots remain deterministic. Check `scripts/tests/run_overlay_idle_tests.sh`.
- 3D controllers sleep both their timer and SceneKit after the settling interval. Commands, gestures, viewport changes, narration and reopening wake them; real motion stays active. No default decorative sway. Preserve the three-angle opening framing envelope used by narration.
- Cache immutable geometry bounds with weak keys; invalidate world bounds and label anchors on scene changes. Batch SceneKit flushes at actual geometry/transform boundaries. New mutation paths must invalidate and wake as appropriate.
- Run `scripts/tests/run_scene3_tests.sh` for idle/wake, geometry replacement, motion stopping, camera, labels and replay coverage. Its compiler failures must stop the script rather than run a stale executable.
- Swift 6.3.3 Release WMO crashes in `EarlyPerfInliner` on the generic `BackgroundAgentToolRegistry.Race` destructor. Its explicit `@_optimize(none)` destructor is a narrow workaround; the rest of the app remains optimized. Recheck before removing it after a compiler upgrade.

## Cloudflare Worker

```bash
cd worker
npm install

# Primary backend (recommended)
npx wrangler secret put OPENROUTER_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY

# Optional
npx wrangler secret put ANTHROPIC_API_KEY   # legacy /chat fallback
npx wrangler secret put ELEVENLABS_API_KEY  # cloud TTS

# Deploy
npx wrangler deploy

# Local dev (create worker/.env from .env.template)
npm run local
npm run harness
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All UI follows `docs/DESIGN.md` and is built from the tokens and components in `DesignSystem.swift`. No `Color(hex:)`, `Color.white.opacity(…)` fills or raw `.font(.system(size:))` in views; if a token is missing, add it to the design system. After a visual change, render the view to PNG (`scripts/tests/render_*_shots.sh`) and look at it.
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the Xcode project directory or scheme (`leanring-buddy` — intentional/legacy). The shipping app display name is **Teachy**.
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

## publik API
- Base URL: https://publikhq.com/api/v1 (OpenAI Chat Completions, Responses, Anthropic Messages)
- Models: publik-fast, publik-balanced, publik-smart only; never a vendor model name
- Sign in with publik: the publik module's gate runs at start-up, before the first screen; it also sends usage telemetry
- Key: per-install `pk_` from POST /installs, stored at the publik credential path; env PUBLIK_API_KEY / PUBLIK_API_BASE_URL override
- App token: publik-app-token.txt (public by design, committed) or PUBLIK_APP_TOKEN
- 402: show error.message plus error.top_up_url only
- Never print or log a key
- Docs: https://publikhq.com/llms.txt, https://publikhq.com/developers, https://publikhq.com/skills/api.md

### How Teachy uses it
- Listing: Teachy signs in through the vedanttalksai **builds hub** listing (slug `deckhand`, token copied from `~/Projects/vedanttalksai/kit/publik-app-token.txt`). `TeachyHubBeacon` reports `build: "teachy"` to https://builds.vedantsoni.com/api/beacon so the hub's /stats splits Teachy out.
- `leanring-buddy/Publik.swift` is publik's Swift module, copied verbatim (only `appSlug`/`appVersion` set). Re-copy it from https://publikhq.com/sdk/publik.swift.md rather than hand-editing.
- `leanring-buddy/TeachyAIRouter.swift` is the only path to a model. Users never pick a model: the router maps each job to a tier (quickCheck → fast, coach/agent/write → balanced, plan → smart), falls back to the next tier on errors, remembers tiers that reject images, and never falls back on 402.
- `ClaudeAPI` and `BackgroundAgentManager.sendChatRequest` call the router; the agent's web tools are local (`web_search` → publik `/search`, `web_fetch` → local fetch).
- The "Use my own key" button on publik's gate is kept (publik requires it); that path uses the person's OpenRouter key with fixed open-weight models, still chosen per job.
- `worker/` and the Windows port still speak OpenRouter; the macOS app no longer uses the worker for AI.
- Self-test: `PUBLIK_SELF_TEST=1 ~/Applications/Teachy.app/Contents/MacOS/Teachy` → `publik self-test: ok deckhand 1.0`.

### Account switching
- `TeachyPublikSession.swift` owns the sign-in gate and account state. Account → Log out removes this listing’s local Publik credential, clears account state, stops active AI work, and restarts sign-in. The browser’s Publik session is separate; users can sign out there to choose another account. A launch-time `PUBLIK_API_KEY` must be removed before switching.
- Logout preserves Teachy history, settings, and own-provider keys. The copied `Publik.swift` SDK is unchanged.
- `scripts/tests/run_publik_session_tests.sh` tests logout with temporary credentials and a fake Publik service; it never accesses the real login or network.

## Memory (the Brain)
- Source of truth: two plain Markdown files the person can edit, `~/.teachy/brain/PROFILE.md` (durable) and `~/.teachy/brain/VOLATILE.md` (current), plus `conversation.jsonl` (last 40 messages). Code: `leanring-buddy/Brain/`.
- `BrainStore.shared` is the only way in. It re-reads the files on every call (hand edits are picked up), writes atomically, and is safe from any thread.
- Every model call should include `BrainStore.shared.promptContext()`; the system prompt should include `BrainStore.shared.actionSchemaDescription`, and the model's memory actions go to `apply(actions:)`.
- Rules live in `BrainMemory.swift` (pure): de-dupe, "(xN)" counts for repeated mistakes, "Subject: value" replaces the older bullet, Recently/Screen memory are trimmed, prompt context never cuts a section.
- The older stores (engine-state.json facts and projects, UserDefaults learner profiles) are imported once by `BrainMigration` (it decodes the old JSON itself) and left in place. [REMEMBER:] facts go straight to `BrainStore.shared.remember(_, kind: .aboutMe)`.
- Never log memory contents. Screen memory is text only.
- Tests: `./scripts/tests/run_brain_tests.sh` (standalone, temp directory, never touches the real `~/.teachy`).

## Rebuild status (14 Nov 2026) — read this before the older sections above
Direction: Teachy is a full HeyClicky competitor; the course/teaching system was removed entirely. Plan: `docs/PARITY-PLAN.md`. Competitor inventory: `docs/research/`.
- **Voice turn** (`CompanionManager.sendCompanionChatResponse`): one streamed call on job `.voice`; `Core/StreamingSpeechFeeder` + `Core/StreamingSpeechSegmenter` speak each sentence as it completes through `LocalSpeechSynthesizer`'s stream queue (publik speech, local voice fallback). `Core/StreamIdleGuard` ends streams that never close. Actions are still bracket tags ([POINT:], [DO:], [GUIDE:], [CLIPBOARD:], [REMEMBER:], [SHOW:]); structured actions are not built yet.
- **Routing** (`TeachyAIRouter`): jobs voice/coach/agent/scene/plan → smart first; quickCheck/cleanup → fast; write → balanced. `reasoningEffort(for:)` sets minimal/low per job (this is what makes voice fast). `PublikAudio` does transcription and speech.
- **Drawing engine** (`Scene/`, spec `docs/SCENE-SCRIPT.md`): the model streams a line-based scene script; `SceneSession` renders overlay shapes, cards and SceneKit 3D with simulations. `Core/SceneDirector` starts one when a reply carries [SHOW: …]. Demo without AI: `TEACHY_SCENE_DEMO=<sample>`.
- **Dictation** (`Dictation/`): hold Fn+Control, double-tap for hands-free. `DictationController.shared.startWhenReady()` from the app delegate.
- **Memory** (`Brain/`): see "Memory (the Brain)". Injected into the voice prompt; conversation persisted.
- **Connectors** (`Connectors/`): MCP client with no dependencies — stdio (local command) and HTTP (streamable, with HTTP+SSE fallback), API key or browser sign-in (OAuth + PKCE). `ConnectorCenter.shared` owns the list (`~/.teachy/connectors/mcp.json`, secrets only in the Keychain) and gives the agent tools named `mcp__<connector>__<tool>`, each with an `mcpRisk`. Settings section: `ConnectorsSection()`. Tests: `scripts/tests/run_connectors_tests.sh`. The Composio poller is switched off, pending deletion.
- **Agent jobs, permission gate, Drive** (`Agent/`): every tool call goes through `BackgroundAgentToolRegistry.invoke` (`Agent/AgentToolRegistry.swift`), which classifies it with `ToolPolicy` (safe / needsConsent / alwaysAsk / blocked, incl. a conservative shell reader), checks `ConsentLedger` (allow once / for the job / always per tool+app / not now for 30 min) and asks through `ConsentPrompter` (card under the notch). Tools are private to the registry: there is no other way to run one. `AgentJobRunner` (`Agent/AgentJob.swift`) is the loop: plan via the `update_plan` pseudo-tool, 25 steps / 10 min budget, per-call timeouts, same failure twice = change approach; jobs are published on `AgentJobCenter.shared.jobs` and shown by `AgentJobCardView`. Drive (`Agent/Drive/`) is accessibility-first control of one app: `drive_snapshot` then `drive_press` / `drive_set_text` / `drive_menu` / `drive_key` / `drive_scroll`, `drive_click_point` last (screenshot pixels + `capture_id`, converted by `DriveCoordinates`); every action re-reads the window and returns a diff; Escape, a click or a 40 pt mouse move stops the job (`DriveTakeoverMonitor`); password / code / card fields hand back. `ui_action` is gone. Guided-step `.act` turns get `ToolPolicy.guidedStepToolNames` only (read-only tools + Drive) via `BackgroundAgentManager.runScopedToolTurn`; `BackgroundAgentManager.runTask` is the full-toolset job entry (nothing calls it yet). Browser-cookie tools are blocked unless `teachy.agent.allowBrowserCookies` is set in UserDefaults.
- **Tests** (no Xcode test target needed): `scripts/tests/run_segmenter_tests.sh`, `run_brain_tests.sh`, `run_dictation_tests.sh`, `run_scene_tests.sh`, `run_agent_tests.sh`, `run_connectors_tests.sh`, `run_uiextras_tests.sh`. Model eval: `scripts/eval/run_scene_eval.sh`.
- **Builds**: use `SKIP_DEV_INSTALL=1` with xcodebuild unless you mean to replace `~/Applications/Teachy.app`.
- **Not built yet**: a voice entry point that starts a full agent job (`runTask` has no caller), named agents, streaming in the agent loop, Drive verified on real apps, MCP connectors, routines, walkthrough rewrite + skill files, Chrome extension, realtime voice, settings UI, new onboarding.

- **Second batch (14 Nov 2026, evening)**: dictation types while you speak and corrects on release (`Dictation/DictationSession.swift`, `DictationSpeedPolicy.swift`); `[WRITE:]` drafts into the focused field (`Writing/`); chat window + attachments + whole-document reading (`ChatWindow/`, `Documents/`); hands-free voice, reply language, screen memory, mic failover (`Voice/`); concurrent jobs, history, named agents, routines (`Agent/`, `Agent/Routines/`), connector catalog (`Connectors/ConnectorCatalog.swift`); Chrome extension + native host + bridge (`chrome-extension/`, `native-host/`, `Browser/`); walkthroughs via `[WALK:]` (`Walkthrough/`) and app skill files (`Skills/Library/*.skill.md`); drawings narrate themselves, `[MARK:]` draws on the live screen, photos, replay and video export (`Scene/`, `Core/SceneDirector.swift`).
- **Dead code to delete**: the old guided task in `CompanionManager.swift` (`activeGuidedTask`, `[GUIDE:]`, `presentGuidedTaskPlan`, `executeActStep`, `reflectAndReplaceRemainingSteps`), `GuidedTaskPlanner.swift`, most of `CompanionGuidedTask.swift`. `[WALK:]` replaces it.
- **Design language (14 Nov 2026, night)**: every screen was redrawn to `docs/DESIGN.md`: Teachy looks like part of macOS (SF Pro, system glass for the notch (clear when closed, frosted when open) and everything that floats, only the camera housing black, grouped lists as in System Settings, system-style capsule buttons and switches, SF Symbols, the pointer colour as the one tint, springs). Kit shots: `scripts/tests/render_design_shots.sh`; Home tab shots: `scripts/tests/render_home_shots.sh`; onboarding, permissions and publik gate shots: `scripts/tests/render_onboarding_shots.sh`. Off-screen renders show glass as a dark frosted stand-in. Real Liquid Glass is checked with `scripts/tests/run_notch_demo.sh` (the real `ClickyNotchRootView` in an on-screen window over a stand-in desktop, opening and closing; `--record DIR` writes mp4 and gif); it has not been looked at in the installed app yet. Known: `run_chrome_e2e_tests.sh` fails to compile (its file list lacks `Agent/ToolPolicy.swift`); that predates the redesign.
- **More tests**: `run_dictspeed_tests.sh`, `run_dictation_shortcut_tests.sh`, `run_microphone_tests.sh`, `run_docs2_tests.sh`, `run_voice2_tests.sh`, `run_agents2_tests.sh`, `run_chrome_tests.sh`, `run_chrome_e2e_tests.sh`, `run_walk_tests.sh`, `run_scene2_tests.sh`; evals `scripts/eval/run_annotate_eval.sh`. Parallel-builder rules: `docs/BUILDER-RULES.md`.
- **Auto permissions, computer use, built-in browser (15 Nov 2026)**: `ConsentLedger` auto mode is on by default (`TeachySettingsKey.agentAutoPermissions`, Settings > Privacy): needsConsent runs unasked, alwaysAsk still asks, blocked stays blocked. The `computer` tool gives jobs real pointer/keyboard control. `ConnectorCenter` seeds Microsoft's open-source Playwright MCP once as connector `browser` (`npx -y @playwright/mcp@latest`); `ToolPolicy.classifyBuiltInBrowser` makes clicks on send/buy/delete controls, password/card fields, uploads and page code always ask. Teachy's own `browser_*` tools are hidden from jobs unless its extension is connected.
- **Proactive voice turn (15 Nov 2026)**: the voice prompt now tells Teachy to own the outcome, bias to action, go one step beyond and mark the screen unasked (Codex/opencode-style agent instincts, consumer tone). `Core/VoiceTurnDepth.swift` sends teach/explain/debug questions with reasoning `low` and 2048 tokens plus a "deep" prompt section; commands stay minimal. New `[OPEN: url]` tag opens up to two http(s) links while Teachy talks (`VoiceOpenLinks`). Tests: `scripts/tests/run_voice_depth_tests.sh`.
- **Still not built**: Windows/iOS, notarized release, new onboarding, bundling the Chrome helper into the app, structured actions (tags are still free text).
