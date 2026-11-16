#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/teachy-announcement-tests.XXXXXX")
trap 'rm -rf "$BUILD_DIRECTORY"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
  leanring-buddy/Announcements/TeachyAnnouncement.swift \
  scripts/tests/announcement_history/main.swift -o "$BUILD_DIRECTORY/tests"
"$BUILD_DIRECTORY/tests"
