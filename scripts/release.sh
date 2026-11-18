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
# Notarized mode (Developer ID certificate in the keychain, plus a notarytool
# login saved as AC_PASSWORD, or NOTARY_PROFILE=<name>):
#   NOTARIZE=1 ./scripts/release.sh 2.2
# Pick a certificate by name with DEVELOPER_ID_IDENTITY="Developer ID Application: …".
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

# Prefer full Xcode over bare Command Line Tools (no sudo xcode-select needed)
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Public distribution repo — DMG releases, Sparkle appcast, and the course
# registry live here so the (now private) code repo can stay private without
# breaking downloads or auto-updates.
GITHUB_REPO="VedSoni-dev/teachy-releases"
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

# notarytool credentials saved once with:
#   xcrun notarytool store-credentials AC_PASSWORD --apple-id <apple-id> --team-id <team-id>
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"

if [ "$USE_NOTARIZE" = "1" ]; then
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" > /dev/null 2>&1; then
        echo "❌ No notarization login saved as \"${NOTARY_PROFILE}\". Save it once with:"
        echo "     xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <apple-id> --team-id <team-id>"
        exit 1
    fi
fi

# Sends a file to Apple's notary service and fails the release unless Apple
# accepts it, printing Apple's log so the reason is visible.
submit_for_notarization() {
    local file_to_notarize_path="$1"
    local notary_result_json
    notary_result_json=$(xcrun notarytool submit "${file_to_notarize_path}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --output-format json)
    local notary_status
    notary_status=$(echo "${notary_result_json}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
    if [ "${notary_status}" != "Accepted" ]; then
        local notary_submission_id
        notary_submission_id=$(echo "${notary_result_json}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
        echo "❌ Apple did not accept $(basename "${file_to_notarize_path}") (status: ${notary_status:-unknown})"
        if [ -n "${notary_submission_id}" ]; then
            xcrun notarytool log "${notary_submission_id}" --keychain-profile "${NOTARY_PROFILE}" || true
        fi
        exit 1
    fi
    echo "✅ Apple accepted $(basename "${file_to_notarize_path}")"
}

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

if [ "${YES:-0}" = "1" ]; then
    echo "   Proceeding (YES=1)…"
else
    read -p "   Proceed? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "   Aborted."
        exit 0
    fi
fi
echo ""

echo "🧹 Cleaning build directory and stale DMGs..."
rm -rf "${BUILD_DIR}"
rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${RELEASES_DIR}"

echo "📦 Building Release (arm64)…"
# Day-to-day TCC tip still applies; this path is for shipping only.
# Built ad-hoc in both modes; notarized mode re-signs it with the Developer ID
# below, which avoids needing the project's team to match the certificate's.
xcodebuild build \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -destination 'platform=macOS,arch=arm64' \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS=arm64 \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    2>&1 | tee /tmp/teachy-xcodebuild.log | tail -20

if ! grep -q "BUILD SUCCEEDED" /tmp/teachy-xcodebuild.log; then
    echo "❌ xcodebuild failed — last errors:"
    rg -i "error:" /tmp/teachy-xcodebuild.log | head -40 || true
    exit 1
fi

BUILT_APP=$(find "${DERIVED_DATA_PATH}/Build/Products/Release" -maxdepth 1 -name "${APP_NAME}.app" | head -1)
if [ -z "$BUILT_APP" ]; then
    echo "❌ Could not find ${APP_NAME}.app under ${DERIVED_DATA_PATH}/Build/Products/Release"
    exit 1
fi

rm -rf "${EXPORT_DIR}/${APP_NAME}.app"
cp -R "${BUILT_APP}" "${EXPORT_DIR}/${APP_NAME}.app"

if [ "$USE_NOTARIZE" = "1" ]; then
    "${PROJECT_DIR}/scripts/sign_developer_id.sh" "${EXPORT_DIR}/${APP_NAME}.app"

    # Notarize and staple the app itself, so a copy dragged out of the DMG
    # still opens offline.
    echo "🔏 Notarizing the app with Apple (usually a few minutes)…"
    APP_NOTARIZATION_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "${EXPORT_DIR}/${APP_NAME}.app" "${APP_NOTARIZATION_ZIP}"
    submit_for_notarization "${APP_NOTARIZATION_ZIP}"
    rm -f "${APP_NOTARIZATION_ZIP}"
    xcrun stapler staple "${EXPORT_DIR}/${APP_NAME}.app"
else
    echo "🔏 Ad-hoc codesigning (Sparkle still signs the DMG separately)…"
    codesign --force --deep --sign - "${EXPORT_DIR}/${APP_NAME}.app"
fi

echo "✅ App ready at ${EXPORT_DIR}/${APP_NAME}.app"

DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"

echo "💿 Creating DMG…"
# Prefer create-dmg (pretty Finder layout). Fall back to hdiutil if Finder AppleScript flakes.
if create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | tee /tmp/teachy-createdmg.log | tail -8 \
  && [ -f "${DMG_PATH}" ]; then
    echo "✅ DMG created: ${DMG_PATH}"
else
    echo "⚠️  create-dmg failed (often Finder AppleScript) — falling back to hdiutil…"
    rm -f "${DMG_PATH}"
    STAGE="${BUILD_DIR}/dmg-stage"
    rm -rf "${STAGE}"
    mkdir -p "${STAGE}"
    cp -R "${EXPORT_DIR}/${APP_NAME}.app" "${STAGE}/"
    ln -s /Applications "${STAGE}/Applications"
    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "${STAGE}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}"
    echo "✅ DMG created (hdiutil): ${DMG_PATH}"
fi

if [ "$USE_NOTARIZE" = "1" ]; then
    DEVELOPER_ID_HASH=$(security find-identity -v -p codesigning | grep "${DEVELOPER_ID_IDENTITY:-Developer ID Application}" | head -1 | awk '{print $2}')
    codesign --force --timestamp --sign "${DEVELOPER_ID_HASH}" "${DMG_PATH}"
    echo "🔏 Notarizing DMG with Apple…"
    submit_for_notarization "${DMG_PATH}"
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

This community build is **not** Apple-notarized (keeps Teachy free).

1. Drag **Teachy.app** to Applications and open it. macOS says it cannot verify Teachy: click **Done**
2. Open System Settings → Privacy & Security, scroll down and click **Open Anyway** next to Teachy, then confirm with your password
3. Teachy walks you through permissions, then you sign in (or choose **Use my own key** and paste an OpenRouter key)

Later updates via Sparkle keep working after that first allow.
NOTES
)"
fi

# The unpacked Chrome extension, zipped for "Get the extension" in Settings → Browser.
# The app fetches it from releases/latest/download/Teachy-Chrome-Extension.zip.
echo "🧩 Zipping the Chrome extension…"
EXTENSION_ZIP_PATH="${RELEASES_DIR}/Teachy-Chrome-Extension.zip"
EXTENSION_STAGING_DIR="$(mktemp -d)"
ditto "${PROJECT_DIR}/chrome-extension" "${EXTENSION_STAGING_DIR}/Teachy Chrome Extension"
rm -rf "${EXTENSION_STAGING_DIR}/Teachy Chrome Extension/tests"
rm -f "${EXTENSION_ZIP_PATH}"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "${EXTENSION_STAGING_DIR}/Teachy Chrome Extension" "${EXTENSION_ZIP_PATH}"
rm -rf "${EXTENSION_STAGING_DIR}"

echo "🏷️  Creating GitHub Release ${TAG}…"
gh release create "${TAG}" "${DMG_PATH}" "${EXTENSION_ZIP_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "Teachy ${MARKETING_VERSION}" \
    --notes "$(cat <<EOF
## Teachy ${MARKETING_VERSION}

Free and open source (MIT). Hold control + option and ask about anything on your screen: Teachy answers out loud, points, draws, or does the job. Source: https://github.com/VedSoni-dev/teachy · What changed: https://www.tryteachy.com/changelog.html

**Direct download:** https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${DMG_FILENAME}

${GATEKEEPER_NOTES}

Sparkle will offer this build to existing installs automatically.
EOF
)" \
    --latest

echo "📝 Publishing appcast.xml to ${GITHUB_REPO}…"
# The Sparkle feed URL baked into the app points at the PUBLIC releases repo,
# so the generated appcast is published there via the GitHub contents API —
# the (private) code repo keeps a local copy purely as generator state.
APPCAST_CONTENT_B64=$(base64 -i "${PROJECT_DIR}/appcast.xml" | tr -d '\n')
APPCAST_EXISTING_SHA=$(gh api "repos/${GITHUB_REPO}/contents/appcast.xml" --jq .sha 2>/dev/null || echo "")
if [ -n "${APPCAST_EXISTING_SHA}" ]; then
    gh api -X PUT "repos/${GITHUB_REPO}/contents/appcast.xml" \
        -f message="Update Sparkle appcast for v${MARKETING_VERSION}" \
        -f content="${APPCAST_CONTENT_B64}" \
        -f sha="${APPCAST_EXISTING_SHA}" > /dev/null
else
    gh api -X PUT "repos/${GITHUB_REPO}/contents/appcast.xml" \
        -f message="Update Sparkle appcast for v${MARKETING_VERSION}" \
        -f content="${APPCAST_CONTENT_B64}" > /dev/null
fi
echo "✅ appcast published"

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
