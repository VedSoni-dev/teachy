#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/teachy-announcement-render.XXXXXX")
trap 'rm -rf "$BUILD_DIRECTORY"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
  leanring-buddy/DesignSystem.swift \
  leanring-buddy/PushToTalkShortcutKeys.swift \
  leanring-buddy/Announcements/*.swift \
  scripts/tests/announcements/Stubs.swift scripts/tests/announcements/LifecycleChecks.swift scripts/tests/announcements/main.swift \
  -o "$BUILD_DIRECTORY/render"
"$BUILD_DIRECTORY/render" "${1:-${TMPDIR:-/tmp}/teachy-announcement-shots}"
"$BUILD_DIRECTORY/render" --check-lifecycle
