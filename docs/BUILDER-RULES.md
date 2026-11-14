# Rules for parallel builders

You are building one piece of Teachy, a macOS Swift menu-bar AI companion competing with HeyClicky. Several engineers work at the same time, each in their own git worktree. These rules keep the pieces mergeable.

## Start
1. Run `git merge --ff-only rebuild` (or `git reset --hard rebuild` if your worktree is clean) so you are on the latest `rebuild` branch.
2. Read root `AGENTS.md` — ONLY its last section, "Rebuild status", is current; older sections are stale. Read `docs/PARITY-PLAN.md` and the part of `docs/research/heyclicky-inventory-2026-11-14.md` your brief names (it describes the competitor behaviour we are matching, from public sources).
3. Source is in `leanring-buddy/`. Xcode uses synchronized folders: any new `.swift` file under it compiles automatically. Never edit the `.xcodeproj`.

## Files you must not edit (unless your brief says you own them)
`CompanionManager.swift`, `leanring_buddyApp.swift`, `NotchHomeTabView.swift`, `NotchPanelView.swift`, `TeachyAIRouter.swift`, `LocalSpeechSynthesizer.swift`, `ClaudeAPI.swift`, `Publik.swift`, `AGENTS.md`, and any folder another builder owns. When you need something to happen inside one of those, expose a clean API on your side and put the EXACT hook in your report: file, the line of existing code it goes after, and the code to add. The integrator wires it. Keep hooks tiny (1–5 lines each).

## AI and network
- Chat models only through `TeachyAIRouter.sendJSON` / `openStream` with a `TeachyAIJob` (OpenAI chat-completions body WITHOUT a "model" key; the router picks the tier and reasoning effort). Speech-to-text and text-to-speech only through `PublikAudio`; live voice only through `Core/RealtimeVoice.swift` or the publik realtime socket it documents. Never another provider, never a vendor model name for chat, never a key in code or logs.
- Model streams must be read through `StreamIdleGuard.lines(from:)` (some tiers never close their stream).
- You may make a small number of real publik calls from a temporary `swiftc` harness (not committed). The key is read by `Publik.readCredential()`; never print it. Keep spend tiny.

## Quality
- Put pure logic in types with no AppKit side effects and unit-test it: `scripts/tests/<name>/main.swift` (top-level code must be in a file named `main.swift`) plus `scripts/tests/run_<name>_tests.sh` that compiles the pure files with `swiftc` and exits non-zero on failure. Pattern: `scripts/tests/run_segmenter_tests.sh`.
- UI matches `DesignSystem.swift` (DS tokens) and the cards in `Settings/SettingsSections.swift`. Check visuals by rendering SwiftUI views to PNG in-process (see `scripts/tests/render_uiextras_shots.sh`), look at the PNGs, and fix what looks wrong.
- The project compiles with default MainActor isolation. Swift 6 concurrency warnings are known and non-blocking.

## Safety
- Build check, always with these flags: `SKIP_DEV_INSTALL=1 xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug -derivedDataPath "$TMPDIR/dd-<yourname>" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E ' error:|BUILD (SUCCEEDED|FAILED)' | sort -u`. NEVER omit `SKIP_DEV_INSTALL=1` (without it the build overwrites the user's installed app).
- Never launch or quit the installed app, never change system settings, never act on the user's real apps, files outside your worktree and temp dirs, accounts or browser. Tests use temp directories, never the real `~/.teachy`.
- Use a temp directory unique to you (e.g. `$TMPDIR/teachy-<yourname>`); other builders share the machine.

## Finish
Commit on your worktree branch (message ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`). Do not push.

Report: branch and commit; files added/changed; test output; build result; every hook line the integrator must add; what you verified versus what you could not (anything needing the running app); risks and decisions to review. Be blunt and factual. Never claim an untested thing works.
