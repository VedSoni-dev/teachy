# Teachy Desktop — React Component Inventory (Electron Port)

Build-ready mapping of the SwiftUI menu-bar app to a React renderer. Source of truth: `leanring-buddy/*.swift`.

## Ground rules for the port

- **Renderer = the notch panel + the full-screen cursor overlay.** Two separate Electron `BrowserWindow`s: (1) the notch panel (frameless, top-center, animates open/closed), (2) a click-through transparent always-on-top overlay per display for the cursor buddy.
- **State stores (Zustand or Redux) replace the two `@ObservedObject`s** every view reads: `CompanionManager` → `useCompanionStore`, `TeachyEngine` → `useEngineStore`. Swift `@Published` props become store fields; Swift methods become store actions that call `worker` HTTP, the ported TS engine, or main-process IPC.
- **Data source legend:** `worker` = HTTP call to Teachy proxy (`/chat`, `/v1/chat/completions`, `/tts`, `/transcribe-token`, `/health`). `engine` = ported TypeScript `TeachyEngine` (local, in-renderer or main). `persist` = local persisted state (`~/.teachy/*.json`, mirror of Swift `UserDefaults`/JSON via `electron-store`/main IPC). `ipc` = Electron main-process bridge for OS capabilities (screen capture, global hotkey, cursor position, keychain, file install, `open external`).
- **No `NotchProgressTabView` exists** in the Swift source. "Progress" surfaces are split across the **Portfolio** and **Skills** tabs. Router tabs today: `home` (labeled "Settings"), `courses` (labeled "Learn"), `portfolio`, `skills`, `agents` (hidden, aliases to courses).

---

## 1. Shell / router

`NotchPanelView.swift` = tab router with a setup-gate. `ClickyNotchRootView.swift` = the window shell (notch shape, header tab bar, open/close spring).

| Aspect | Detail |
|---|---|
| (a) Purpose | Frameless notch window that expands on hover/click to host the active tab; gates behind onboarding/permissions until setup complete. |
| (b) Data read → source | `notchManager.selectedTab`, `isExpanded`, `isHoveringNotch` → local UI store (`useNotchStore`). `allPermissionsGranted`, `hasCompletedOnboarding` → `ipc` (permission polling) + `persist`. `TeachyAPIKeyStore.isConfigured` → `persist` (keychain via `ipc`). `voiceState`, `backgroundAgentManager.status`, `coursesManager.isCourseActive` → `useCompanionStore` for live-activity wing. `selectedCursorColor` → `persist`. |
| (c) Component + route | `<AppShell>` (window chrome) wrapping `<NotchRouter>`. Routes: `/setup`, `/learn`, `/settings`, `/portfolio`, `/skills`. Default `/learn`. |
| (d) Interactions | Hover notch → `expand()`; tap when closed → `expand()`; drag-down >36px → `expand()`; click-outside / chevron-up / context-menu "Collapse" → `collapse()`; header tab buttons → `setSelectedTab`; gear icon → `ipc` open system privacy settings; auto-switch to Learn when `isCourseActive` flips true. Setup-gate: if `needsSetup` render `<SetupOnboarding>` regardless of tab. |

Note: `<SetupOnboarding>` (from `NotchSetupOnboardingView`/`PermissionChoreographyView`) is a real screen but out of the requested inventory scope — stub as `/setup` route, permission polling via `ipc`.

---

## 2. Learn tab (Courses)

`NotchCoursesTabView.swift` — the flagship screen. Largest, most stateful.

| Aspect | Detail |
|---|---|
| (a) Purpose | Browse/install/start courses; render the live in-course tutor session (video → your-turn → verify → teach-back) with conversation + interactive widgets. |
| (b) Data read → source | `isBackendReachable`, `backendConnectionHint` → `worker` (`GET /health`) via `useCompanionStore`. `coursesManager.activeSession`, `.completionCelebration`, `.continueCourse`, `.catalogSections`, `.academyRegistry`, `.isInstallingCourse`, `.courseInstallStatusMessage`, `.installedCourseSourcesByID`, `.recentlyAutoUpdatedCourseIDs`, `.progress(forCourseID:)`, `.resumeStepIndex`, `.preferSimplifiedCatalog` → `engine`/`persist` (course catalog is bundled JSON + `~/.teachy/courses/` installs). `teachyEngine.state.projects` / `activeProjects` → `engine`. `lessonPlayer.phase`, `.isRunning`, `coursesManager.lastCoachMessage`, `.lastCoachSpokenText`, `session.stepConversationHistory` → `worker` (coach turns via `/chat` + `/v1/chat/completions`) held in `engine`/session store. Academy `registry.json` → `worker`/HTTP fetch. |
| (c) Component + route | `<LearnTab>` at `/learn`. Children: `<ActiveCourseSession>` (when `activeSession`), else `<CourseCatalog>` composed of `<ProjectsSection>`, `<CourseCompletionCard>`, `<ContinueLearningCard>`, `<CourseCatalogList>` → `<CourseCatalogRow>` (expandable), `<AcademyFeaturedSection>`, `<AcademyInstallSection>`, `<BackendOfflineBanner>`. |
| (d) Interactions | **Catalog row:** header tap → toggle `expandedCourseID` (accordion, one open); chevron rotates 180°; Start/Resume/Retake → `startClickyCourse(id)` + `collapse()`; Remove → `uninstallInstalledCourse`; disabled when another course active or backend offline. **Install:** text field + Add → `installCourseFromURL` (`ipc` writes file); Featured Add → same; "Open site" → `ipc` open external. **Projects:** Resume → `submitSyntheticCompanionRequest`; shipped "Live" → `ipc` open URL. **Active session:** Exit → `exitClickyCourse`; Hint → `requestCourseHint`; "I did it" → `confirmCourseBeat`; Skip video → `skipCourseVideo`; question field submit → `submitCourseTextQuestion`; "Build Your Own" → open `<CustomCourseBuilderSheet>` modal. Auto-scroll conversation on new `lastCoachMessage`. |

### 2a. In-course interactive widgets (sub-components of `<ActiveCourseSession>`)

| Swift view | React component | Data | Handler |
|---|---|---|---|
| `CourseInteractiveChoiceWidgetView` | `<InteractiveChoice>` | `session.currentGoal.interactiveMultipleChoice` (engine) | `submitCourseInteractiveChoiceAnswer(index)` |
| `CourseInteractiveChecklistWidgetView` | `<InteractiveChecklist>` | `.interactiveChecklist` (engine) | `submitCourseInteractiveChecklistCompletion(bool)` |
| `CourseInteractiveFillInBlankWidgetView` | `<InteractiveFillInBlank>` | `.interactiveFillInBlank` (engine) | `submitCourseInteractiveFillInBlankAnswer(text)` |
| phase prompt rows + coach message blocks | `<CoursePhasePrompt>`, `<CoachMessageBlock>` | `lessonPlayer.phase`, `lastCoachMessage` (worker→engine) | render-only |
| progress bars | `<CourseProgressBar>` / `<CatalogRowProgressBar>` | `session.progressFraction`, goal completion (engine) | render-only |

---

## 3. Settings tab (Home)

`NotchHomeTabView.swift`

| Aspect | Detail |
|---|---|
| (a) Purpose | Push-to-talk help, trust/privacy copy, relationship check-in nudges, API-key management (OpenRouter + ElevenLabs), updates, cursor color, tutor-model picker, feedback. |
| (b) Data read → source | `pendingProactiveMoments` → `engine`. `teachyEngine.getLearnerModel()` (`.datedPersonalFacts`, `.personalFacts`, `.humorReceptivity`, `.lastRelationshipCheckInAt`, `.createdAt`), `teachyEngine.activeProjects` → `engine`. `TeachyAPIKeyStore` / `TeachyElevenLabsKeyStore.isConfigured` → `persist` (keychain via `ipc`). `TeachySoftwareUpdater.shortVersionString/.canCheckForUpdates` → Electron autoUpdater via `ipc` (Sparkle has no web analog). `selectedCursorColor`, `selectedModel` → `persist`. `OpenRouterModelOption.models` → static constant. |
| (c) Component + route | `<SettingsTab>` at `/settings`. Children: `<ProactiveMomentsCard>`, `<RelationshipCheckInCard>`, `<PushToTalkHelp>`, `<TrustPrivacyCard>`, `<TeachyRemembersCard>`, `<UpdatesCard>`, `<ApiKeyCard kind="openrouter">`, `<ApiKeyCard kind="elevenlabs">`, `<CursorColorPicker>`, `<ModelPickerRow>`, `<WatchDemoButton>`, `<FeedbackButton>`. |
| (d) Interactions | Check-in thumbs up/down → `recordRelationshipCheckInReaction(bool)` + local dismiss; Resume stale project → `submitSyntheticCompanionRequest`. API key Save → validate via direct HTTPS `fetch` to `openrouter.ai/api/v1/models` / ElevenLabs TTS endpoint, then persist (`ipc` keychain) + `refreshBackendReachability`; Remove → clear key. Check for Updates → `ipc` autoUpdater. Cursor color select → `setSelectedCursorColor` (also drives overlay + notch icon color). Model select → `setSelectedModel`. Watch demo → `replayOnboarding` + `collapse`. Feedback → `ipc` open GitHub issues. |

Note: key-validation `fetch` goes **direct to provider**, not through `worker` — replicate exactly (CORS: do the request from main via `ipc` to avoid renderer CORS).

---

## 4. Portfolio tab

`NotchPortfolioTabView.swift`

| Aspect | Detail |
|---|---|
| (a) Purpose | Show shareable artifacts captured from completed course goals + "In your own words" teaching demos. |
| (b) Data read → source | `teachyEngine.portfolioManager` (`.items`, `.recentItems`, `.summary`, `.generateShareCard`) → `engine` (persisted at `~/.teachy/portfolio/`). `learnerModel.teachingDemos`, `.skillNode(byID:)` → `engine`. |
| (c) Component + route | `<PortfolioTab>` at `/portfolio`. Children: `<PortfolioHeader>`, `<EmptyPortfolioCard>`, `<PortfolioSummaryCard>`, `<PortfolioItemCard>` (list), `<TeachingDemosSection>` → `<TeachingDemoRow>`. |
| (d) Interactions | Item "Live" link → `ipc` open URL; "Share" → build share text + write to clipboard (`navigator.clipboard` or `ipc`); relative-time labels (use `date-fns`). Mostly read-only. |

---

## 5. Skills tab

`NotchSkillsTabView.swift`

| Aspect | Detail |
|---|---|
| (a) Purpose | Learner-model proficiency dashboard: summary, retention reviews due, forgetting-curve strength, at-risk skills, per-domain breakdown, suggested next, streak. |
| (b) Data read → source | `teachyEngine.getLearnerModel()` (`.skillNodes`, `.totalSkillsLearned`, `.currentStreakDays`, `.longestStreakDays`, `.skills(inDomain:)`), `state.skillGraph` (`.nodes(inDomain:)`, `.suggestedNextSkills`), `getDueRetentionChecks()`, `getAtRiskSkills()`, `SpacedRepetitionEngine.retentionProbability`, `CoachAutonomy.level`, `BundledSkillGraph.domains` → all `engine` (pure computations over persisted learner state; must port SM-2 math). |
| (c) Component + route | `<SkillsTab>` at `/skills`. Children: `<SkillsHeader>`, `<EmptySkillsCard>`, `<SkillsSummaryCard>` (+`<AutonomyRow>`), `<RetentionReviewCard>`, `<RetentionStrengthSection>` → `<RetentionStrengthRow>`, `<AtRiskSkillsCard>`, `<SkillsByDomainSection>`, `<SuggestedNextSection>`, `<StreakCard>`. |
| (d) Interactions | Read-only dashboard; all bars are computed widths. Only interaction is scroll. Retention/at-risk lists cap with "+N more". |

---

## 6. Cursor overlay + response bubble

`OverlayWindow.swift` (full-screen click-through) + `CompanionResponseOverlay.swift` (cursor-following streaming text panel).

| Aspect | Detail |
|---|---|
| (a) Purpose | The blue triangle "buddy" that follows the cursor across all displays; morphs to waveform (listening) / spinner (processing) / streaming text bubble (responding); flies a bezier arc to `[POINT]` targets; draws chalk outlines and success rings; plays beside-cursor video. |
| (b) Data read → source | `voiceState`, `currentAudioPowerLevel`, `overlayCursorColor` → `useCompanionStore` (driven by `ipc` audio + `worker` streaming). `detectedElementScreenLocation`/`DisplayFrame`/`BubbleText` → `worker` response parsing (`[POINT:cell:label]`) + `ipc` grid→coord mapping. `activeScreenDrawInstruction`, `courseSuccessCelebration`, `coursePresenceBubbleText`, onboarding video fields → store. Live cursor position + per-screen frames → `ipc` (main polls `screen.getCursorScreenPoint()` and streams to overlay window). Streaming response text → `worker` SSE. |
| (c) Component + route | Separate overlay renderer window(s): `<CursorOverlay>` (one canvas per display) with `<BuddyTriangle>`, `<BuddyWaveform>`, `<BuddySpinner>`, `<ResponseBubble>`, `<NavigationBubble>`, `<ChalkStroke>`, `<ChalkDrawOverlay>`, `<SuccessRing>`, `<BesideCursorVideo>`. Not part of the notch router. |
| (d) Interactions | No user input (click-through window). All motion is timer-driven: 60fps cursor tracking, bezier flight arc with tangent-facing rotation + scale pulse, char-streamed bubbles, auto-hide after ~6s. Port timers to `requestAnimationFrame`. |

---

## Shared shell components

| Swift source | React component | Notes |
|---|---|---|
| `ClickyNotchShape` + `NotchWindowManager` + `ClickyNotchSizing` | `<NotchWindow>` / `AppShell` | Frameless top-center Electron window; animate an SVG/CSS notch silhouette open/closed (window frame stays fixed size, inner shape animates). Spring via Framer Motion. |
| `clickyNotchHeader` (in `ClickyNotchRootView`) | `<HeaderTabBar>` | Icon tab buttons (Learn/Portfolio/Skills/Settings) with per-tab accent, selected capsule, tooltip, pointer cursor; camera-bay spacer; gear + collapse-chevron buttons. |
| `.glassCard()` modifier (DesignSystem) | `<GlassCard tint prominent cornerRadius>` | Ubiquitous — every tab wraps rows in it. Translucent fill + subtle border; port `DS.Colors.*` tokens to CSS variables. Highest-reuse component. |
| `Triangle` shape + `BlueCursorView` | `<BuddyCursor>` | The triangle mark, reused in notch idle icon, live-activity wing, cursor-color picker, and overlay. |
| `[POINT:cell:label]` parse + `ScreenGridAnnotationUtility` + bezier flight | `<PointingController>` (overlay) + `parsePointTags()` util | Grid-cell → screen-coord mapping must be reimplemented; screenshot grid burn-in happens in `ipc`/main before send. |
| `liveActivityRow` / `ClickyAudioSpectrumView` / `closedCursorBadge` | `<LiveActivityWing>` | Closed-notch listening/course indicator (spectrum bars + cursor badge). |
| Push-to-talk indicator (`voiceState` waveform/spinner in overlay + closed notch) | `<PushToTalkIndicator>` | Shared visual driven by `voiceState`; appears in overlay and notch wing. |
| `KeyboardKeyLabel`, `FlowLayout`, `openRouterModelPickerRow` (`NotchPanelSharedComponents`) | `<KeyCap>`, `<FlowLayout>`, `<ModelPickerRow>` | Dependency-free shared primitives; port directly. |
| `CompanionResponseOverlay` panel | `<ResponseBubble>` | Cursor-glued streaming text panel; reused for companion Q&A replies. |

---

## Port risk

- **Cursor overlay is the single hardest piece.** A macOS `NSPanel` that is transparent, click-through (`ignoresMouseEvents`), non-activating, joins all Spaces, and floats above fullscreen apps — Electron can approximate with `transparent + frameless + alwaysOnTop("screen-saver") + setIgnoreMouseEvents(true) + setVisibleOnAllWorkspaces`, but always-on-top **over other apps' fullscreen** and true per-display click-through is unreliable and OS-permission-sensitive. Multi-display (one window per screen) + global cursor position must come from main via `screen` APIs, adding IPC latency to the 60fps tracking loop.
- **Screen capture + global push-to-talk + `[POINT]` grid mapping** all need native `ipc`: ScreenCaptureKit → `desktopCapturer`, the listen-only CGEvent tap for ctrl+option → `globalShortcut` (which can't do press-and-hold cleanly — needs a native module or `uiohook-napi`), and burning the invisible coordinate grid into JPEGs before upload. None of this lives in the renderer.
- **Porting `TeachyEngine` to TypeScript is a large, correctness-sensitive lift.** SM-2 spaced repetition, forgetting-curve `retentionProbability`, skill-graph prerequisites/transfers, `CoachAutonomy` levels, portfolio share-card generation, and the `Codable` legacy-migration of `personalFacts` all drive on-screen numbers in Skills/Portfolio. Any drift produces visibly wrong dashboards. Must be ported with parity tests against the Swift outputs.
- **The notch open/close choreography is genuinely custom.** Fixed window frame with an animating inner black silhouette (not a resizing window), matched-geometry cursor/spectrum transitions between closed/open, drag-to-open gesture, and hover-chin. Framer Motion can do the shape morph, but `matchedGeometryEffect` (shared-element transition of the cursor badge between wing and header) has no clean web equivalent and will need `layoutId` + careful layout.
- **Live coach loop couples `worker` streaming, TTS, and overlay state.** A single course turn fans out to `/chat` + `/v1/chat/completions` (SSE), `/tts` (or local speech — no web equivalent to `NSSpeechSynthesizer`, so ElevenLabs/`worker` becomes mandatory or use Web Speech API), plus overlay pointing/celebration side effects, all gated by `lessonPlayer.phase`. The phase state machine and its many `phase.isX` branches must be ported faithfully or the Active Course card renders the wrong prompt/widget.
