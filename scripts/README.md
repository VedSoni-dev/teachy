# Release Scripts

## `release.sh` — Ship Teachy (free DMG + Sparkle updates)

**Default = community release.** No Apple Developer Program / $99 cert required.

```bash
./scripts/release.sh 1.0
```

That builds Teachy, packs a DMG, Sparkle-signs it (EdDSA), publishes a free GitHub Release, and updates `appcast.xml`.

Always-latest download:

```
https://github.com/VedSoni-dev/teachy/releases/latest/download/Teachy.dmg
```

### Gatekeeper (expected without notarization)

Community DMGs are **not** Apple-notarized. First-time users:

1. Drag Teachy to Applications  
2. **Right-click → Open → Open** (or Privacy & Security → Open Anyway)

After that, Sparkle updates install normally. Integrity still comes from our Sparkle EdDSA key — not from Apple.

### Prerequisites (community mode)

1. Xcode (free) with a team set for local signing if you want — release uses ad-hoc sign when notarizing is off
2. `brew install create-dmg gh`
3. `gh auth login` (push access to `VedSoni-dev/teachy`)
4. Sparkle EdDSA key in Keychain under account `teachy` (see below)
5. Build Teachy once in Xcode so Sparkle CLI tools download

### Optional: notarized releases (later, if you get Developer ID)

```bash
NOTARIZE=1 ./scripts/release.sh 1.0
```

Needs Apple Developer Program + Developer ID Application + `notarytool` credentials. Not required for OSS.

### Sparkle key

```bash
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 | head -1)
"$SPARKLE_BIN/generate_keys" --account teachy -p   # must match Info.plist SUPublicEDKey
```

Private key stays in Keychain — never commit it. Backup offline only if you are the releaser:

```bash
"$SPARKLE_BIN/generate_keys" --account teachy -x ~/Desktop/teachy-sparkle-private.key
```

### Note on `xcodebuild`

Day-to-day: run from Xcode (TCC). This script uses `xcodebuild` for release archives only.
