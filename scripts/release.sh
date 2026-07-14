#!/bin/bash
set -euo pipefail

# Add Homebrew to PATH so create-dmg and gh are available in non-interactive shells
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh — Ship Teachy to GitHub Releases (free downloads + Sparkle)
#
# Default mode: community build (NO $99 Apple Developer ID / notarization).
# Downloads still work. First open needs a Gatekeeper “Open anyway” click.
# Sparkle EdDSA signatures still protect update integrity.
#
# Optional notarized mode (if you later get Developer ID):
#   NOTARIZE=1 ./scripts/release.sh 1.0
#
# Usage:
#   ./scripts/release.sh              Auto-bumps version
#   ./scripts/release.sh 1.2          Set marketing version
#   ./scripts/release.sh 1.2 5        Set version + build
# =============================================================================

SCHEME="leanring-buddy"
APP_NAME="Teachy"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
EXPORT_DIR="${BUILD_DIR}/export"
RELEASES_DIR="${PROJECT_DIR}/releases"
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
DERIVED_DATA_PATH="${BUILD_DIR}/DerivedData"

GITHUB_REPO="VedSoni-dev/teachy"
SPARKLE_KEYCHAIN_ACCOUNT="teachy"
NOTARIZE="${NOTARIZE:-0}"

HAS_DEVELOPER_ID=0
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    HAS_DEVELOPER_ID=1
fi

if [ "$NOTARIZE" = "1" ] && [ "$HAS_DEVELOPER_ID" != "1" ]; then
    echo "❌ NOTARIZE=1 needs a Developer ID Application certificate (Apple Developer Program)."
    echo "   Without it, run normally for a free community release:"
    echo "     ./scripts/release.sh 1.0"
    exit 1
fi

# Community is the default. Notarize only when explicitly requested AND cert exists.
USE_NOTARIZE=0
if [ "$NOTARIZE" = "1" ] && [ "$HAS_DEVELOPER_ID" = "1" ]; then
    USE_NOTARIZE=1
fi

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle tools not found. Build the project in Xcode first so SPM downloads Sparkle."
    exit 1
fi

echo "🔍 Checking latest release on GitHub..."

LATEST_TAG=$(gh release view --repo "${GITHUB_REPO}" --json tagName --jq '.tagName' 2>/dev/null || echo "")

if [ -n "$LATEST_TAG" ]; then
    LATEST_VERSION="${LATEST_TAG#v}"
    LATEST_BUILD=$(gh release list --repo "${GITHUB_REPO}" --json tagName --jq 'length' 2>/dev/null || echo "0")
    echo "   Latest release: ${LATEST_TAG} (approx build ${LATEST_BUILD})"
else
    LATEST_VERSION="0.0"
    LATEST_BUILD=0
    echo "   No previous releases found — starting from scratch"
fi

if [ $# -ge 1 ]; then
    MARKETING_VERSION="$1"
else
    MAJOR=$(echo "$LATEST_VERSION" | cut -d. -f1)
    MINOR=$(echo "$LATEST_VERSION" | cut -d. -f2)
    NEXT_MINOR=$((MINOR + 1))
    if [ "$NEXT_MINOR" -ge 10 ]; then
        MAJOR=$((MAJOR + 1))
        NEXT_MINOR=0
    fi
    MARKETING_VERSION="${MAJOR}.${NEXT_MINOR}"
fi

if [ $# -ge 2 ]; then
    BUILD_NUMBER="$2"
else
    BUILD_NUMBER=$((LATEST_BUILD + 1))
fi

DMG_FILENAME="${APP_NAME}.dmg"
TAG="v${MARKETING_VERSION}"

if gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
    echo ""
    echo "❌ Release ${TAG} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
    exit 1
fi

if [ "$USE_NOTARIZE" = "1" ]; then
    RELEASE_MODE="notarized (Developer ID)"
else
    RELEASE_MODE="community (no Apple notarization — free / broke-friendly)"
fi

echo ""
echo "🚀 Releasing ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "   Mode:     ${RELEASE_MODE}"
echo "   Previous: ${LATEST_TAG:-none}"
echo "   Download: https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo ""

read -p "   Proceed? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   Aborted."
    exit 0
fi
echo ""

echo "🧹 Cleaning build directory and stale DMGs..."
rm -rf "${BUILD_DIR}"
rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${RELEASES_DIR}"

if [ "$USE_NOTARIZE" = "1" ]; then
    ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
    echo "📦 Archiving (Developer ID)…"
    xcodebuild archive \
        -scheme "${SCHEME}" \
        -archivePath "${ARCHIVE_PATH}" \
        MARKETING_VERSION="${MARKETING_VERSION}" \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
        2>&1 | tail -8

    EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
    cat > "${EXPORT_OPTIONS}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

    echo "📤 Exporting notarized app…"
    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_DIR}" \
        -exportOptionsPlist "${EXPORT_OPTIONS}" \
        2>&1 | tail -8
else
    echo "📦 Building community Release (Apple Development / ad-hoc — no \$99 cert)…"
    # Day-to-day TCC tip still applies; this path is for shipping only.
    xcodebuild build \
        -scheme "${SCHEME}" \
        -configuration Release \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        MARKETING_VERSION="${MARKETING_VERSION}" \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | tail -12

    BUILT_APP=$(find "${DERIVED_DATA_PATH}/Build/Products/Release" -maxdepth 1 -name "${APP_NAME}.app" | head -1)
    if [ -z "$BUILT_APP" ]; then
        echo "❌ Could not find ${APP_NAME}.app under ${DERIVED_DATA_PATH}/Build/Products/Release"
        exit 1
    fi

    rm -rf "${EXPORT_DIR}/${APP_NAME}.app"
    cp -R "${BUILT_APP}" "${EXPORT_DIR}/${APP_NAME}.app"

    echo "🔏 Ad-hoc codesigning (Sparkle still signs the DMG separately)…"
    codesign --force --deep --sign - "${EXPORT_DIR}/${APP_NAME}.app"
fi

echo "✅ App ready at ${EXPORT_DIR}/${APP_NAME}.app"

DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"

echo "💿 Creating DMG…"
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | tail -5

echo "✅ DMG created: ${DMG_PATH}"

if [ "$USE_NOTARIZE" = "1" ]; then
    echo "🔏 Notarizing DMG with Apple…"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "AC_PASSWORD" \
        --wait
    echo "📎 Stapling…"
    xcrun stapler staple "${DMG_PATH}"
    echo "✅ DMG notarized and stapled"
else
    echo "⏭️  Skipping Apple notarization (community release — no Developer ID needed)"
fi

echo "🔐 Signing DMG with Sparkle EdDSA key (account: ${SPARKLE_KEYCHAIN_ACCOUNT})…"
"${SPARKLE_BIN}/sign_update" --account "${SPARKLE_KEYCHAIN_ACCOUNT}" "${DMG_PATH}"

echo "📡 Generating appcast.xml…"
"${SPARKLE_BIN}/generate_appcast" \
    --account "${SPARKLE_KEYCHAIN_ACCOUNT}" \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
    -o "${PROJECT_DIR}/appcast.xml" \
    "${RELEASES_DIR}"

echo "✅ appcast.xml updated"

if [ "$USE_NOTARIZE" = "1" ]; then
    GATEKEEPER_NOTES="This build is notarized — drag to Applications and open normally."
else
    GATEKEEPER_NOTES="$(cat <<'NOTES'
### First open (Gatekeeper)

This community build is **not** Apple-notarized (Teachy is free OSS without the paid Developer Program).

1. Drag **Teachy.app** to Applications
2. **Right-click** Teachy → **Open** → click **Open**
   - Or: open once, then System Settings → Privacy & Security → **Open Anyway**
3. Grant Microphone, Screen Recording, and Accessibility

Later updates via Sparkle keep working after that first allow.
NOTES
)"
fi

echo "🏷️  Creating GitHub Release ${TAG}…"
gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "Teachy ${MARKETING_VERSION}" \
    --notes "$(cat <<EOF
## Teachy ${MARKETING_VERSION}

Free macOS download. Run a Teachy proxy (see README), then coach yourself through real work on screen.

**Direct download:** https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${DMG_FILENAME}

${GATEKEEPER_NOTES}

Sparkle will offer this build to existing installs automatically.
EOF
)" \
    --latest

echo "📝 Committing appcast.xml…"
cd "${PROJECT_DIR}"
git add appcast.xml
if git diff --cached --quiet; then
    echo "   (appcast already up to date)"
else
    git commit -m "Update Sparkle appcast for v${MARKETING_VERSION}"
    git push origin HEAD || echo "   (push failed — push appcast.xml manually)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Teachy v${MARKETING_VERSION} (build ${BUILD_NUMBER}) shipped!"
echo "   Mode: ${RELEASE_MODE}"
echo ""
echo "   DMG:      ${DMG_PATH}"
echo "   Appcast:  ${PROJECT_DIR}/appcast.xml"
echo "   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "   Always-latest free download:"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo "═══════════════════════════════════════════════════════════════"
