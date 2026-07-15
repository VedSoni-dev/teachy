# Teachy

**Teachy** is free & open-source macOS software — the ultimate free teaching companion. A 1:1 tutor in your menu bar that sees your screen, points at real UI, and coaches you until something actually runs.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Download](https://img.shields.io/badge/download-macOS%20DMG-black.svg)](https://github.com/VedSoni-dev/teachy/releases/latest)
[![Website](https://img.shields.io/badge/website-live-brightgreen.svg)](https://vedsoni-dev.github.io/teachy/)

> **North star:** free 1:1 teaching for everyone — practice on the real screen, not another video player.

Born from Farza’s [Clicky](https://www.heyclicky.com/) experiments. This line is Teachy: courses-first, teach-by-doing, open curriculum.

**Website:** [vedsoni-dev.github.io/teachy](https://vedsoni-dev.github.io/teachy/) · **Launch posts:** [`docs/LAUNCH_POSTS.md`](docs/LAUNCH_POSTS.md)

![Teachy on macOS](clicky-demo.gif)

## Free download

**→ [Download Teachy.dmg](https://github.com/VedSoni-dev/teachy/releases/latest/download/Teachy.dmg)** · [All releases](https://github.com/VedSoni-dev/teachy/releases/latest)

### First open (Gatekeeper)

Community builds ship **without** Apple’s paid Developer ID / notarization (keeps Teachy free for maintainers too). macOS may say it “can’t verify” the developer:

1. Drag **Teachy** to Applications  
2. **Right-click** → **Open** → **Open**  
   (or System Settings → Privacy & Security → **Open Anyway**)  
3. Grant Microphone, Screen Recording, Accessibility  
4. Run the local Teachy proxy (below) with an OpenRouter key

Installed apps can **Check for Updates…** under Home → Updates (Sparkle).

## What it does

- **Learn paths** — goal-based courses (First Win with AI, Use AI to Code, GitHub, and more)
- **Teacher clips** — optional videos beside the cursor, then hands-on coaching
- **Live coaching** — `[POINT:…]` on your real screen, hints, “do it for me,” teach-backs
- **Open curriculum** — course JSON + Mux/HLS videos via `courses/` and Teachy Academy

MIT licensed. Hack on it, ship courses, build companies — go wild.

## Quick start (from source)

### Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| macOS | 14.2+ | ScreenCaptureKit required |
| Xcode | 15+ | App Store or developer.apple.com |
| Node.js | 18+ | For the local API proxy |
| OpenRouter key | — | Free at [openrouter.ai](https://openrouter.ai) |

### Step 1 — Start the proxy

The app routes all AI traffic through a local proxy. It supports OpenRouter (recommended), Anthropic, and OpenAI keys.

```bash
cd worker
cp .env.template .env      # paste your API key
npm install
npm run local              # runs on http://localhost:8787
```

Verify it's working: open `http://localhost:8787/health` in your browser — you should see `"ok": true`.

### Step 2 — Build the app

```bash
open leanring-buddy.xcodeproj
```

1. Select the **leanring-buddy** scheme in the toolbar (the app displays as **Teachy** — the project name is a legacy spelling)
2. Go to **Signing & Capabilities** and set your Apple Development Team — this lets Accessibility and Screen Recording permissions persist across rebuilds
3. **Cmd+R** to build and run

> **Do not** use `xcodebuild` from the terminal for day-to-day runs — it invalidates TCC permissions and the app will re-request screen recording, accessibility, etc.

### Step 3 — Grant permissions

When prompted, grant:
- **Microphone** — voice input
- **Screen Recording** — Teachy sees your screen
- **Accessibility** — cursor pointing

### Step 4 — Use it

Click the Teachy icon in your menu bar. The notch panel opens. Pick a learning path (try "First Win with AI" — 10 minutes) and hold **ctrl+option** to talk.

## AI-assisted setup

If you're using Claude or Cursor, paste this into your AI assistant:

```
Clone this repo. Read AGENTS.md (or CLAUDE.md — same file).

I want Teachy running locally on my Mac.

Help me set up the worker proxy with my API keys, then get the Teachy target
building in Xcode (leanring-buddy scheme / PRODUCT_NAME Teachy).
```

| Path | Purpose |
|------|---------|
| `~/.teachy/courses/` | Installed course JSON (falls back to `~/.clicky/courses/`) |
| `~/.teachy/connectors/` | OpenAPI / HTTP connections |

## Releasing updates (maintainers)

See [`scripts/README.md`](scripts/README.md). No Apple paid cert required by default:

```bash
./scripts/release.sh 1.0
```

That ships a free GitHub Release DMG and updates `appcast.xml` so existing installs can update. If you later join the Apple Developer Program: `NOTARIZE=1 ./scripts/release.sh 1.0`.

## Open curriculum

- Authoring: [`courses/README.md`](courses/README.md)
- Academy site: [`academy/`](academy/)

## Architecture (short)

Menu-bar Teachy → notch panel → LessonPlayer / companion voice → Teachy proxy (`worker/`) → OpenRouter + optional AssemblyAI. Mac tools run locally. Full map: **AGENTS.md**.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Security: [SECURITY.md](SECURITY.md).

## License

MIT — [LICENSE](LICENSE). Third-party notices: [NOTICE](NOTICE).

## Credits

Originally created by [Farza](https://x.com/farzatv) as Clicky. Teachy continues that spirit as an open teaching platform for everyone.
