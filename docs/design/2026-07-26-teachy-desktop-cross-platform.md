# Teachy Desktop — Cross-Platform (Electron) Migration for B2C / A&M

**Date:** 2026-07-26  ·  **Mode:** Startup  ·  **Stage:** Has users, none paying

## Problem

Teachy is a deeply macOS-native menu-bar app (SwiftUI + `NSPanel` + ScreenCaptureKit
+ CGEvent taps). The near-term growth wedge is a **Texas A&M partnership**: the
**Dean of AI** makes AI-literacy videos and spreads Teachy to students. But the
students are on **personal Windows laptops**, and the current Windows story is a
separate, drifting, "drastically different" build. Two hard constraints fell out
of the diagnosis:

1. **No surveillance on personal devices.** The block-bad-usage / internal-training
   B2B capability is *illegal* on students' own laptops — it belongs to a separate
   B2B motion on managed hardware and is **out of scope** for A&M.
2. **Maintainability is the real requirement.** "Windows is drastically different"
   is the pain. Two native codebases = permanent drift. The fix must be **one
   cross-platform codebase**.

Since SwiftUI is Apple-only, "both platforms + maintainable" forces leaving SwiftUI
for the shell. This doc is how.

## What I noticed (founder signals)

- **Named institutional champion** — not "a university," the *Dean of AI*, with a
  concrete activity (literacy videos + distribution).
- **Knew the legal wall cold** — flagged that surveillance on non-managed personal
  laptops is illegal before being pushed on it. Real domain judgment.
- **Sensed the platform/identity reckoning before it was proven** — brought up
  Windows drift and the Clicky-clone problem unprompted.
- **Pushed back on scope** ("the teaching thing is separate") and on fidelity
  ("I really need the Mac UI to be there") — protecting both focus and craft.

## Evidence & open questions

**Evidence:** a warm, named distribution channel (Dean + student body); an existing,
loved product; a real prior shipped-artifact user (nail-salon → website).

**Riskiest unproven assumptions:**
1. That the Dean's videos actually convert to installs + activations (the #1
   compounding-past-founder test — instrument it).
2. That a 4-week core-scope Electron build reaches "good enough to launch" quality
   on both OSes. The macOS-native fidelity gap (~5–10%) is the risk to watch.
3. That the ported TS learning engine preserves the coaching quality of the Swift
   engine.

## Premises (agreed)

1. **A&M is a free consumer AI-literacy wedge, not a governance sale.** Surveillance
   is out of scope.
2. **Windows is load-bearing** for the full rollout — no cross-platform Teachy, no
   A&M reach.
3. **Differentiation from Clicky is a partnership requirement**, not vanity. Public
   launch with a Dean's name attached; capabilities stay, identity/surface diverge.
4. **The B2B/governance product is real but a separate track**, deliberately parked
   until the A&M consumer wedge lands.
5. **"Maintainable + both platforms" = one Electron codebase as the END STATE.** The
   Swift Mac app is **not deleted** — it keeps running as flagship while the Electron
   app matures toward it. Migration, not demolition.
6. **4 weeks buys the B2C CORE loop on both OSes, not full parity.** The notch-perfect
   window behavior and accessibility "do it for me" are deferred past v1.

## Approaches considered

- **A — Web-first wedge (M–L, Low–Med risk):** web app + browser extension; runs
  everywhere day one; loses full-desktop superpowers. Fastest reach.
- **B — Cross-platform desktop shell / Electron (XL, Med–High):** one codebase for
  mac+win; keeps the desktop nature; new identity by construction. **Chosen.**
- **C — One brain, thin clients everywhere (L→grows, Low–Med):** engine-as-core with
  per-surface adapters (already in `TeachyAdapter`). Great long-term, more moving
  parts.

## Recommended approach

**B — Electron cross-platform shell, executed as a migration.** It's the only shape
that satisfies "both platforms + finished + maintainable." Electron (not Tauri) for
the 4-week finish: it has first-class cross-platform APIs for exactly Teachy's needs
(`desktopCapturer` screen capture, `globalShortcut` push-to-talk, `type: 'panel'` +
`alwaysOnTop: 'screen-saver'` non-activating float, `Tray`, native `vibrancy` =
real `NSVisualEffectView` on Mac / acrylic-mica on Win), and the largest hiring pool
— which *is* maintainability. Bundle size/RAM is irrelevant for B2C.

### Architecture

```
teachy-desktop/                     ← new one-codebase Electron app (mac + win)
├── src/main/                       ← Electron main process (Node)
│   ├── windows/                    notch panel + transparent overlay + tray
│   ├── capture/                    desktopCapturer screen frames (both OS)
│   ├── shortcuts/                  globalShortcut push-to-talk (ctrl+alt)
│   ├── platform/                   per-OS window level / vibrancy / permissions
│   └── updater/                    electron-updater (GitHub releases feed)
├── src/preload/                    contextIsolation IPC bridge
├── src/renderer/                   React + TS + Vite
│   ├── theme/                      ported DesignSystem tokens (light/dark)
│   ├── shell/                      notch shape, hover-open, tabs
│   ├── tabs/                       Learn · Progress · Portfolio · Skills · Settings
│   └── overlay/                    cursor + [POINT] pointing (web-motion)
├── src/shared/                     ← the reused/ported brain
│   ├── engine/                     TeachyEngine ported to TS (LearnerModel,
│   │                                 SkillGraph, Verification, SpacedRepetition)
│   ├── worker-client/              same proxy API (health/chat/completions/transcribe)
│   └── courses/                    loads existing courses/*.json unchanged
└── electron-builder config        dmg (mac, notarized) + nsis (win) installers
```

### Reuse map (what does NOT get rewritten)

| Reused as-is | Ported (Swift → TS) | Rebuilt (new UI) |
| --- | --- | --- |
| `worker/` proxy (all routes) | `TeachyEngine/*` core logic | The shell + tabs (React) |
| `courses/*.json` + academy registry | `DesignSystem.swift` tokens → theme | The Teachy visual identity |
| Sparkle → electron-updater feed shape | `[POINT]`/grid annotation logic | Onboarding |
| The coaching prompts / proxy contract | LearnerModel persistence (JSON) | — |

### Capability cut for v1 (deferred, on-strategy)

- Accessibility-driven **"do it for me"** (`ui_action`) — worst cross-platform;
  Agents tab already hidden.
- The last 5–10% of **notch-perfect** window behavior — polished post-launch.
- **App connectors / background agent**, and the **gbrain Learner Brain** (stays on
  the Mac flagship / next track).

### 4-week plan

- **Week 1 — Foundation.** Electron+React+TS+Vite scaffold; cross-platform notch
  panel + transparent overlay + tray; ported design tokens (light/dark); wired to
  the existing worker (`/health`, `/chat`). Runs on Mac **and** Windows.
- **Week 2 — Core teaching loop.** `desktopCapturer` screen frames → vision coaching
  with `[POINT]` overlay; push-to-talk (globalShortcut + Web Audio + `/transcribe`);
  courses list + course session UI; port `TeachyEngine` core to TS.
- **Week 3 — Learner surfaces + identity.** Progress, Skills, Portfolio, onboarding;
  the **new Teachy visual identity** (the differentiation deliverable); local learner
  persistence.
- **Week 4 — Harden + package.** electron-updater; mac notarization + win signing;
  `dmg` + `nsis` installers; QA on both OSes; activation telemetry; launch polish.

## The assignment

**This week, before the code goes deep: get the Dean to commit to one concrete
distribution act with a date.** Not "we'll spread it" — a specific line in a specific
video, or a link in a specific course/syllabus, on a specific date. Everything in
this doc is bet on that funnel existing; one concrete commitment from the Dean turns
the 4-week build from a hope into a deadline with a launch behind it.
