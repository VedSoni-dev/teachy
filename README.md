# Teachy

**HeyClicky, but open source.** Teachy is an AI that lives next to your cursor on the Mac. Hold **control + option**, ask about anything on your screen, and it answers out loud, points at the button you need, draws to explain, or does the job for you.

[![Download](https://img.shields.io/badge/download-macOS%20DMG-black.svg)](https://github.com/VedSoni-dev/teachy-releases/releases/latest/download/Teachy.dmg)
[![Website](https://img.shields.io/badge/website-tryteachy.com-3380ff.svg)](https://www.tryteachy.com)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Teachy grew from Farza's open-source [Clicky](https://github.com/farzaa/clicky). When Clicky's new work went private, Teachy kept building in the open: the app, the prompts and every fix are here to read, fork and change. Not affiliated with HeyClicky.

![Teachy on macOS](clicky-demo.gif)

## Download

**→ [Download Teachy.dmg](https://github.com/VedSoni-dev/teachy-releases/releases/latest/download/Teachy.dmg)** · [All releases](https://github.com/VedSoni-dev/teachy-releases/releases) · [Changelog](https://www.tryteachy.com/changelog.html)

Free, for Macs with Apple silicon on macOS 14.2 or later.

### First open

The free build is not notarised by Apple yet, so macOS asks once:

1. Drag **Teachy** to Applications
2. **Right-click** Teachy → **Open** → **Open** (or System Settings → Privacy & Security → **Open Anyway**)
3. Grant the permissions it walks you through, one at a time
4. Sign in on first launch, or choose **Use my own key** and paste an [OpenRouter](https://openrouter.ai) key

Updates arrive through Sparkle: Home → Updates → **Check for Updates…**

## What it does

- **Answers about your screen, out loud.** Hold control + option and ask; it starts speaking within about half a second.
- **Points the way.** The blue triangle flies to the button or menu you asked about.
- **Draws to explain.** Diagrams, arrows and 3D scenes on top of your screen, narrated as they appear.
- **Does the job.** Hand off a task and keep working. Jobs plan, run in the background, and ask before they click, type or run anything.
- **Types what you say.** Hold fn + control in any text field and talk.
- **Remembers you.** Its memory is two Markdown files in `~/.teachy/brain/` that you can open and edit.
- **Connects to your tools.** MCP connectors over stdio or HTTP, and a Chrome extension for jobs that need your browser.

Teachy only sees your screen while you hold the shortcut, or when you turn on hands-free voice.

## Build from source

| Requirement | Version |
|-------------|---------|
| macOS | 14.2+ (ScreenCaptureKit) |
| Xcode | 15+ |

```bash
git clone https://github.com/VedSoni-dev/teachy.git
cd teachy
open leanring-buddy.xcodeproj
```

1. Select the **leanring-buddy** scheme (the app is named **Teachy**; the project name is a legacy spelling)
2. In **Signing & Capabilities**, set your Apple Development team, so Accessibility and Screen Recording permissions survive rebuilds
3. **Cmd+R**

Run day-to-day builds from Xcode rather than `xcodebuild` in a terminal: a terminal build resets the macOS permissions and the app asks for them again.

The engineering map, conventions and test scripts are in [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`). Tests run without an Xcode test target, for example `./scripts/tests/run_brain_tests.sh`.

## Releasing (maintainers)

```bash
./scripts/release.sh 2.1
```

Builds a community DMG, signs it for Sparkle, publishes it to [teachy-releases](https://github.com/VedSoni-dev/teachy-releases) and updates the appcast. See [`scripts/README.md`](scripts/README.md).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security problems privately: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Third-party notices: [NOTICE](NOTICE).

## Credits

Built on [Clicky](https://github.com/farzaa/clicky) by [Farza](https://x.com/farzatv). Thank you, Farza.
