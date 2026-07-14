# Security Policy

## Supported versions

Security fixes land on the `main` branch and ship via Sparkle / GitHub Releases when maintainers cut a build.

## Reporting a vulnerability

Please **do not** open a public issue for security problems that could let others:

- Steal screen contents, mic audio, cookies, or local files beyond intended teaching tools
- Escalate privileges on a Teachy user’s Mac
- Impersonate Teachy update signatures

Email or privately message a maintainer (GitHub security advisory preferred when available):

1. Describe the issue and impact
2. Include steps to reproduce if safe
3. Give us a few days before public disclosure

We will acknowledge reports and ship fixes when possible.

## Secrets

- Never put API keys in the Mac app or this repository
- Proxy secrets stay in Cloudflare Worker secrets / local `worker/.env` (gitignored)
- Sparkle **private** EdDSA keys stay in the releaser’s Keychain — never commit them
- The app only embeds the **public** `SUPublicEDKey`

## Updates

Teachy checks `https://raw.githubusercontent.com/VedSoni-dev/teachy/main/appcast.xml` and verifies EdDSA signatures before installing updates from GitHub Releases.

Default releases are community builds (not Apple-notarized). Sparkle’s EdDSA check is independent of Gatekeeper; users may need a one-time “Open anyway” on first install.
