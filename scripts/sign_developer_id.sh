#!/bin/bash
set -euo pipefail

# =============================================================================
# sign_developer_id.sh — Re-sign a built Teachy.app with a Developer ID
# certificate so Apple will notarize it.
#
# Notarization needs every piece of code signed with the Developer ID, the
# hardened runtime turned on, and a secure timestamp. Code is signed from the
# inside out (Sparkle's helpers, then Sparkle, then the app), never with
# --deep, because --deep signs nested code with the app's entitlements.
#
# The app is signed with the real entitlements file rather than whatever the
# build left behind: an ad-hoc Xcode build carries get-task-allow, which Apple
# rejects, and under the hardened runtime a missing entitlement silently turns
# off the microphone, camera or Apple Events.
#
# Usage:
#   scripts/sign_developer_id.sh path/to/Teachy.app
#   DEVELOPER_ID_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/sign_developer_id.sh path/to/Teachy.app
# =============================================================================

APP_BUNDLE_PATH="${1:?Usage: sign_developer_id.sh path/to/Teachy.app}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ENTITLEMENTS_PATH="${PROJECT_DIR}/leanring-buddy/leanring-buddy.entitlements"

if [ ! -d "${APP_BUNDLE_PATH}" ]; then
    echo "❌ No app at ${APP_BUNDLE_PATH}"
    exit 1
fi

# Use the SHA-1 hash of the identity so a second certificate with a similar
# name can never be picked by mistake.
if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
    SIGNING_IDENTITY_NAME="${DEVELOPER_ID_IDENTITY}"
else
    SIGNING_IDENTITY_NAME=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -z "${SIGNING_IDENTITY_NAME}" ]; then
    echo "❌ No Developer ID Application certificate found in the keychain."
    exit 1
fi
SIGNING_IDENTITY_HASH=$(security find-identity -v -p codesigning | grep -F "\"${SIGNING_IDENTITY_NAME}\"" | head -1 | awk '{print $2}')
if [ -z "${SIGNING_IDENTITY_HASH}" ]; then
    echo "❌ Certificate \"${SIGNING_IDENTITY_NAME}\" is not in the keychain."
    exit 1
fi

echo "🔏 Signing with ${SIGNING_IDENTITY_NAME}"

sign_code_with_hardened_runtime() {
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY_HASH}" "$@"
}

# Sparkle's own helpers, in the order Sparkle's documentation gives.
# Downloader.xpc keeps its own entitlements (it is sandboxed by Sparkle).
SPARKLE_FRAMEWORK_PATH="${APP_BUNDLE_PATH}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_FRAMEWORK_PATH}" ]; then
    SPARKLE_VERSION_PATH="${SPARKLE_FRAMEWORK_PATH}/Versions/B"
    sign_code_with_hardened_runtime "${SPARKLE_VERSION_PATH}/XPCServices/Installer.xpc"
    sign_code_with_hardened_runtime --preserve-metadata=entitlements "${SPARKLE_VERSION_PATH}/XPCServices/Downloader.xpc"
    sign_code_with_hardened_runtime "${SPARKLE_VERSION_PATH}/Autoupdate"
    sign_code_with_hardened_runtime "${SPARKLE_VERSION_PATH}/Updater.app"
    sign_code_with_hardened_runtime "${SPARKLE_FRAMEWORK_PATH}"
fi

# Any other embedded frameworks or dylibs (none today; PostHog and
# PLCrashReporter are linked statically). Kept so a new one is not missed.
find "${APP_BUNDLE_PATH}/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) ! -name "Sparkle.framework" 2>/dev/null | while read -r embedded_code_path; do
    sign_code_with_hardened_runtime "${embedded_code_path}"
done

# The app last, so its seal covers everything signed above.
sign_code_with_hardened_runtime --entitlements "${APP_ENTITLEMENTS_PATH}" "${APP_BUNDLE_PATH}"

echo "🔎 Verifying signature…"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE_PATH}"

if codesign -d --entitlements - "${APP_BUNDLE_PATH}" 2>/dev/null | grep -q "get-task-allow"; then
    echo "❌ The app still carries get-task-allow; Apple will reject it."
    exit 1
fi

echo "✅ Signed with Developer ID and the hardened runtime"
