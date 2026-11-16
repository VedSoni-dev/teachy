#!/bin/bash
# Exercise the real composer in a briefly shown nonactivating NSPanel. Events
# go only to that fixture; no Teachy app, backend, saved data, or permissions.
# Pass --hittable-outline to compare native routing with outline hit testing enabled.
set -euo pipefail
cd "$(dirname "$0")/../.."
COMPOSER_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-composer-focus.XXXXXX")"
trap 'rm -rf "$COMPOSER_TEST_DIR"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
  leanring-buddy/DesignSystem.swift \
  leanring-buddy/ChatWindow/ChatTimelineModel.swift \
  leanring-buddy/ChatWindow/ChatComposerTextView.swift \
  scripts/tests/chat_composer_focus/main.swift \
  -o "$COMPOSER_TEST_DIR/TeachyComposerFocusFixture"
"$COMPOSER_TEST_DIR/TeachyComposerFocusFixture" "$@"
