# Teachy vs HeyClicky: parity plan

Written 14 Nov 2026. Source: HeyClicky's public site, changelog (45 entries, Apr 6 – Nov 6 2026), videos and posts, saved in [research/heyclicky-inventory-2026-11-14.md](research/heyclicky-inventory-2026-11-14.md). Public information only; nothing from their app binary. We copy what features *do*, with our own name, look and code.

Decisions already made (Vedant, 14 Nov): full competitor, not teaching-only. Publik is the only AI provider and people never pick a model. The current frontend stays; the backend and rules are rebuilt in the Swift app.

## Where we can be better, not just equal

| Their weak spot (their own words or users') | Our answer |
|---|---|
| Free tier is 25 messages a month; no own key | Publik balance + free credit, own-key option |
| "Not good at controlling your computer yet", "sometimes breaks" | Accessibility-tree-first control, scoped to one app, every action checked |
| Pointer landed on the wrong monitor | Per-display coordinate mapping with tests |
| Freezes (1,600+ users), mic failures, stuck "thinking…" | One small state machine with timeouts on every wait; replay tests |
| 3D is explanation only: no physics, no simulation | Real simulations you can change (see Drawing engine) |
| Skills library paused since Sep 12 | Open skill files in a public repo from day one |
| Activity tracking removed as "creepy"; no SOC 2 | Local-first memory in plain files the person can read and edit |
| Dictation "not as reliable or fast" as Wispr Flow (Reddit) | On-device text appears instantly; cloud pass only polishes |

## What we measured on Publik today

| Call | Result |
|---|---|
| Spoken answer + pointing, smart tier (GPT-6), streamed | first text 1.5 s, done 1.8 s |
| Same, fast tier (Claude Haiku today) | first text 1.3 s; stream sometimes never closes |
| Same, balanced tier (MiMo) | 21 s — unusable for voice |
| Transcription, 8 s clip | 1.5 s (`gpt-4o-transcribe`), 3.0 s (`whisper-1`), under $0.001 |
| Speech, one sentence (`tts-1`) | 1.9 s |
| Realtime voice WebSocket (Gemini Live) | exists, about $0.0225 a minute; not yet tested |

So: voice turns go to the smart tier, the balanced tier is for background work only, and the engine needs an idle guard for streams that don't close.

## Feature map

Size: S = a session, M = a few sessions, L = a week or more of sessions.

### 1. Voice loop (their "one brain") — M
**Theirs:** hold Control+Option, release, answer starts in about 2 s; barge-in; captions; voice speed; 130+ languages; text box on double-tap Control.
**Ours:**
- New turn engine: one streamed call on the smart tier, speech starts on the first sentence, actions arrive as a structured block (not free-text tags).
- Speech: Publik speech per sentence now; move to Publik realtime voice once tested with screenshots.
- Barge-in on key press (exists) plus voice interrupt later. Captions overlay. Text box on double-tap Control.
- Screenshot only on the hotkey, focused window at full resolution, plus the accessibility tree.

### 2. Pointing, circle-to-ask, screen memory — M
**Theirs:** cursor flies to things; hold the key and circle something; remembers what was on screen earlier.
**Ours:** accessibility element first, pixels second; a paint trail while the key is held (the tracker exists, the trail drawing doesn't); keep a short text summary of each screen seen in the conversation.

### 3. Dictation — M
**Theirs:** hold Fn+Control; double-tap for hands-free; text streams in at about 450 ms; a second model cleans up without rewriting; types into the field directly with a paste fallback; learns words from your edits within 20 s; 83 languages; local backup.
**Ours:**
- Hotkeys the same shape, rebindable.
- Text appears from Apple's on-device recognizer as you speak (no network wait). On release, Publik `gpt-4o-transcribe` replaces it with the accurate version, and the fast tier does a faithful cleanup (no added words, no em dashes).
- Insertion: accessibility "set text" where the app supports it, else a layout-aware paste that marks the clipboard as transient and restores it. Collapse newlines in terminals. Skip near-silent taps.
- Dictionary: watch the field for 20 s after insert, diff the edit, save the correction, and feed the dictionary to transcription as a prompt.
- Every transcript saved locally. Screen-aware "write a reply for me" uses the voice loop plus memory.

### 4. Drawing engine — L (the centerpiece)
**Theirs:** hand-drawn rings, arrows and polygons over the real screen; floating explainer cards (grid paper, handwriting, photos, charts); 3D models built on the fly that you rotate and click to ask about; everything builds in time with the speech; replay and MP4 export. In-house native renderer; the model sends a compact description, not code. No physics.
**Ours — one "scene script" the model writes, three renderers that play it:**
- **Script:** a small JSON timeline: items (shape, label, card, chart, 3D part, motion) with an id, where it anchors, and which spoken sentence it appears on. Validated against a schema; bad items are dropped, not fatal.
- **Overlay renderer (2D):** SwiftUI Canvas on the existing transparent overlay. Rough, hand-drawn strokes. Highlights fade after 2 s; shapes clear when speech ends.
- **Card renderer:** floating draggable windows for explainers, charts (Swift Charts) and photos (Publik search).
- **3D renderer:** SceneKit. The model composes parts from primitives (box, cylinder, sphere, tube, cone, lathe and extrude profiles, arrows) with names, colours, labels and simple motions. Drag to rotate; click a part to ask about it (hit test → part name → next question).
- **Better than theirs:** a simulation mode. The script can declare bodies, joints, forces and sliders, run on SceneKit physics: pendulums, gears, projectiles, orbits, circuits as flow. You change a number and watch it respond. They have explanation-only animation.
- **Replay and export:** the timeline is deterministic, so replay is free; MP4 via AVAssetWriter. Follow-up chips under each drawing.
- Order: overlay shapes → cards → 3D static → 3D motion and click-to-ask → simulation → replay/export.

### 5. Walkthroughs and per-app skills — M
**Theirs:** up to 15 steps, target ring, detects your click and moves on, re-checks the screen, skill files injected by app (89 apps); community skills paused.
**Ours:** step state machine with a progress log; click detection through the event tap; re-check before each step; skill files chosen by bundle ID or site, kept in the public `teachy-skills` repo so anyone can add one. The courses become walkthroughs with checks.

### 6. Memory — S/M
**Theirs:** PROFILE.md (habits) and VOLATILE.md (current project), 40 recent messages, style preferences that stick.
**Ours:** the same two plain files under `~/.teachy/brain/`, written by the model through a structured "remember" action, shown and editable in the app, never cut mid-section. Replaces today's three overlapping stores.

### 7. Agents, jobs and routines — L
**Theirs:** named agents with their own memory and files, jobs that show their plan under the notch, own lightweight harness, routines on a schedule, per-job budgets, Stop button.
**Ours:** rebuild the existing agent loop as a job runner: streamed, plan visible, budgeted, stoppable, with a permission gate in code (not in the prompt). Named agents are a folder each (`AGENTS.md`, memory, files). Routines run while the app is open, pause after 3 failures.

### 8. Drive (computer control) — L
**Theirs:** asks first ("Allow once / Always / Not now"), visible driving state, Escape or mouse takes control back, clicks scoped to the target window.
**Ours:** same consent and takeover rules. Actions go through the accessibility tree (press this button, set this field) and fall back to coordinates only when needed, with correct mapping. After every action, re-read the tree and confirm it worked before the next one.

### 9. Connectors — M
**Theirs:** Gmail, Google, Notion, Linear, Slack through Composio; custom MCP servers.
**Ours:** MCP first (URL or local command), which covers most of those without a middleman holding sign-ins. Drop the dormant Composio code.

### 10. Chrome extension — L, later
**Theirs:** agents work in your Chrome in their own tab group through the debugger API and native messaging; hands passwords back to you.
**Ours:** same design, after agents and Drive are solid.

### 11. Shell, onboarding, settings — M
Already have: notch, onboarding, auto-update, cursor colour. Add: settings for shortcuts, voice, dictation dictionary, captions; an onboarding that has you talk, circle, dictate and see a drawing in two minutes.

### Not cloning now
Windows (the port exists; revisit after Mac parity), teams, referrals, their billing plans (Publik does billing), iOS, the paused Suggestions feature.

## Build order

| Phase | What ships | Why here |
|---|---|---|
| 0 | New turn engine, state machine, replay test harness, dead code removed, course bugs gone | Everything else sits on it |
| 1 | Voice loop, accurate pointing, circle trail, captions, text box | The core loop people judge in 10 seconds |
| 2 | Dictation | Small, used all day, drives Publik usage daily |
| 3 | Drawing engine: overlay → cards → 3D → simulation → replay | The demo that goes viral |
| 4 | Walkthroughs + skills, memory files | Makes it sticky |
| 5 | Jobs, Drive, MCP connectors, routines | The big surface |
| 6 | Chrome extension, settings, new onboarding | Polish and reach |

## Open risks
- Publik's fast tier doesn't always close streams; the balanced tier is too slow for voice. Voice depends on the smart tier staying fast.
- Publik realtime voice is untested: unknown whether it accepts screenshots and structured actions.
- Fn-key hotkeys need a lower-level event tap than the current Control+Option one.
- 3D quality depends on how well the smart tier composes parts from primitives; needs an eval set of 30 objects before we promise it.
- The Publik listing still shows the app as "Deckhand".
