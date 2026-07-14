# Teachy - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar **teaching companion**. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a notch-style panel focused on **Teachy Courses** — goal-based learning sessions with durable outcomes only (no hardcoded buttons, grid cells, or layout). Courses can form **learning tracks** (e.g. Git & GitHub Parts 1–4) that build on each other like a Khan Academy unit. A Swift `LessonPlayer` runs a **buddy tutor** loop: session memory + live screen → coach with `[POINT:…]` → optional Mac tools (`ui_action`, browser, Terminal) when stuck or when the user says “do it for me.” `CourseVerifier` gates advance with natural-language `doneWhen`. Live phase + last coach line show in the course lesson HUD (glass hover expand, boring.notch–inspired).

Push-to-talk (ctrl+option) captures voice, transcribed via AssemblyAI (or Apple Speech locally), with screenshots sent through the Teachy proxy. Outside a course, the same PTT path answers quick on-screen questions with spoken replies and cursor pointing. Free-form background automation is demoted from the primary product surface (Agents tab hidden); Mac tools still power in-lesson “Do it for me” exactly as before.

**Curriculum videos:** Every course part can attach an optional Farza-style teacher clip (`teacherVideoURL` preferred; legacy `introVideoURL` still works) — HLS/mp4 beside Teachy with optional `teacherName` credit. Authors can also ship `teacherVideoNotes`, `teachingContext` (concepts / pitfalls / teach-back), and `toolPolicy`. After vision `doneWhen`, Teachy runs a soft teach-back and updates a durable per-course learner model. See `courses/README.md`.

**Teachy Academy:** Free open platform — static site in `academy/` (retro Facebook-style wall) + `registry.json`. App Learn tab installs course JSON from URL/GitHub into `~/.teachy/courses/` (legacy `~/.clicky/courses/` still works).

**Distribution:** Free macOS DMGs via GitHub Releases. Default shipping is a **community build** (ad-hoc signed, no Apple notarization — no paid Developer Program required). Users right-click → Open once for Gatekeeper. Sparkle (`TeachySoftwareUpdater`) checks `appcast.xml` on `main` and verifies EdDSA signatures before updating. Optional `NOTARIZE=1` path exists if a maintainer later has Developer ID.

All API keys live on the Teachy proxy (local dev server or Cloudflare Worker) — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat (Companion)**: OpenRouter free-tier models (default `google/gemma-4-31b-it:free` for vision) via proxy with SSE streaming. Anthropic Claude supported as legacy fallback when `OPENROUTER_API_KEY` is not set.
- **AI Agent**: Single OpenRouter loop (default `google/gemini-2.5-flash`) via `POST /v1/chat/completions`. Screenshots attach directly to the first message; the proxy upgrades text-only models (e.g. DeepSeek) to a vision model when images are present. Web search/fetch via OpenRouter server tools; Mac tools execute locally. **Connections**: Composio (planned) for SaaS; **OpenAPI connections** register dynamic tools from `~/.teachy/connectors/*.json` (legacy `~/.clicky/connectors/` still works) by parsing an OpenAPI 3 spec (`transport.type: openapi`). Legacy **Teachy HTTP** connectors (`transport.type: http`) use `/tools` + `POST /tools/{name}`.
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: Local `NSSpeechSynthesizer` (ElevenLabs optional via worker when configured)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap. **While a course is active**, all voice goes to `LessonPlayer` (exit phrases carve out). Outside a course, voice is quick companion Q&A about the screen. Free-form `"agent,"` / automation triggers are not primary UX (Agents tab hidden); course “Do it for me” still uses the shared Mac tool loop.
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

**Notch Panel (boring.notch-inspired)**: Fixed-size floating `NSPanel` at top-center (`ClickyNotchSizing.windowSize`). SwiftUI animates a black `ClickyNotchShape` open/closed inside it — the window frame does not resize. Closed: physical-notch width with idle blinking face wing, or live-activity wings (cursor + spectrum) while listening/course. Teaching-first tabs: **Courses** (default) then **Home**; Agents UI retained in code but hidden. First launch: permissions → scored Teachy product tour (music + soft SFX) with a live “I can see your screen” pointing beat → Learn; optional full Farza intro video. Hover opens; click-outside / Collapse closes. Reference clone: `reference/boring.notch` (gitignored).

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~100 | Menu bar app entry point. Starts companion + Sparkle via `TeachySoftwareUpdater`. |
| `TeachySoftwareUpdater.swift` | ~70 | Sparkle auto-update controller — GitHub Releases feed + Check for Updates in Home settings. |
| `CompanionManager.swift` | ~1400 | Central state machine. Owns dictation, shortcut monitoring, screen capture, companion chat, background agent dispatch (voice trigger: "agent,"), Teachy Courses sessions, local TTS, and overlay management. Tracks voice state, conversation history, chat/agent model selection, and cursor visibility. |
| `ClickyCourse.swift` | ~1380 | Goal-based courses; **First Win** + **Use AI to Code** flagship; Teachy catalog + lesson briefs. |
| `CoursesManager.swift` | ~710 | Catalog, sessions, learner profile memory, tool step log. |
| `TeachyDataPaths.swift` | ~40 | Resolves `~/.teachy/{courses,connectors}` with legacy `~/.clicky/` fallback. |
| `LessonPlayer.swift` | ~730 | Goal auto-prompter — video parts → tutor turns → verify → teach-back. |
| `ClickyAcademyCatalog.swift` | ~100 | Academy registry models + GitHub→raw install URL resolver. |
| `courses/README.md` | — | Open curriculum authoring (JSON + Mux/HLS part videos). |
| `academy/` | — | Teachy Academy site — Apple×Khan UI, cinematic intro, Teachy cursor tour, `registry.json`. |
| `CourseUIGrounder.swift` | ~50 | Soft start URL open + cursor-screen capture (no UI hardcoding). |
| `CourseVerifier.swift` | ~90 | Vision YES/NO verify for natural-language `doneWhen`. |
| `CourseLessonHUDWindow.swift` | ~340 | Teaching HUD — coach line, glass hover expand, Hint / Do it / I did it. |
| `CourseModeNotchDockWindow.swift` | ~200 | Legacy compact dock (HUD is primary in v2). |
| `AgentToolResult.swift` | ~35 | Tool results with optional vision images fed back into the agent loop. |
| `ClickyProxyHealthChecker.swift` | ~55 | GET /health probe — courses fail fast when the proxy is offline. |
| `VoiceBackgroundAgentTrigger.swift` | ~50 | Parses voice trigger phrases ("agent,", "background agent", etc.) and returns the stripped task prompt for background agent dispatch. |
| `BackgroundAgentSideDockWindow.swift` | ~280 | Side-docked Teachy mascot shown during background agent runs. Hover expands a progress card with status, task prompt, and tool step log. |
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
| `VoiceBackgroundAgentTrigger.swift` | ~55 | Parses explicit "agent," voice prefixes for background agent dispatch. |
| `VoiceAutomationTrigger.swift` | ~95 | Parses natural-language build/automate/open requests (no "agent," prefix required). |
| `AgentMacNativeTools.swift` | ~400 | run_applescript, open_browser_tab, ui_action, capture_screen tools. |
| `AgentBrowserTools.swift` | ~120 | authenticated_fetch and list_browser_sessions tools. |
| `OpenRouterModelOptions.swift` | ~75 | Curated OpenRouter model list + `ClickyWorkerConfiguration` (proxy URL from Info.plist). |
| `LocalSpeechSynthesizer.swift` | ~45 | macOS `NSSpeechSynthesizer` TTS playback. |
| `NotchScreenGeometry.swift` | ~135 | Reads `NSScreen.auxiliaryTopLeftArea`; closed notch width/height and course HUD docking. |
| `ClickyNotchSizing.swift` | ~40 | Open/closed sizes, corner radii, spring animations (boring.notch `matters.swift`). |
| `ClickyNotchShape.swift` | ~75 | Animatable notch silhouette (DynamicNotchKit / boring.notch). |
| `ClickyAudioSpectrumView.swift` | ~180 | Closed-notch spectrum bars + idle blinking face. |
| `ClickyNotchRootView.swift` | ~400 | Root notch UI — black shape, live activity, header, spring open height. |
| `NotchWindowManager.swift` | ~220 | Fixed-size floating `NSPanel`, hover-to-open, click-outside collapse. |
| `NotchPanelView.swift` | ~1970 | Expanded body — Learn / Settings; permissions + multi-step Teachy product tour before tabs. |
| `MenuBarPanelManager.swift` | ~103 | NSStatusItem lifecycle. Menu bar icon toggles the notch panel. |
| `CompanionPanelView.swift` | ~933 | Legacy menu bar dropdown panel content (retained; notch UI uses NotchPanelView instead). |
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
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
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
