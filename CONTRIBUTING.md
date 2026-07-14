# Contributing to Teachy

Thanks for helping make free, on-screen teaching better for everyone.

## Ways to help

- **Courses** — JSON + optional teacher videos under `courses/` (see [`courses/README.md`](courses/README.md))
- **Teaching UX** — LessonPlayer, HUD, notch Learn tab
- **Connectors / tools** — OpenAPI connections, Mac agent tools used in-lesson
- **Docs** — README, Academy, setup clarity
- **Bugs** — clear repros with macOS version + Teachy version (Home → Updates)

## Development setup

1. Clone this repo
2. `cd worker && cp .env.template .env` → add `OPENROUTER_API_KEY` → `npm install` → `npm run local`
3. `open leanring-buddy.xcodeproj` → scheme **leanring-buddy** → set Signing Team → Cmd+R
4. Read **AGENTS.md** (same as CLAUDE.md) for architecture

Do **not** day-to-day run `xcodebuild` for launches — it tends to invalidate TCC permissions. Use Xcode. Releases use `./scripts/release.sh`.

## Pull requests

- Keep changes focused and named clearly
- No secrets in the app binary or git history (keys live only on the proxy / your `.env`)
- Prefer small PRs over mega-diffs
- Update AGENTS.md when you add significant new source files

## Code style

- Clear names over clever short names
- `@MainActor` for UI / app state
- Buttons should show a pointer cursor on hover
- Do not “fix” known non-blocking Swift 6 / deprecated onChange warnings

## License

By contributing, you agree your contributions are licensed under the MIT License ([LICENSE](LICENSE)).
