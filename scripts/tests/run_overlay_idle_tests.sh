#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
TEST_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/teachy-overlay-idle.XXXXXX")
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
swiftc -O -swift-version 5 -default-isolation MainActor \
  leanring-buddy/Scene/SceneCommand.swift \
  leanring-buddy/Scene/SceneGeometry.swift \
  leanring-buddy/Scene/SceneOverlayView.swift \
  scripts/tests/overlay_idle/main.swift -o "$TEST_DIRECTORY/tests"
"$TEST_DIRECTORY/tests"
