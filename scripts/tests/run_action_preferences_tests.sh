#!/bin/bash
# Standalone tests for TeachyActionPreferences (where jobs do web work, whether they may take
# the mouse) and the two settings behind it. No app launch; uses a throwaway defaults suite.
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-action-preferences.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP=leanring-buddy
swiftc -swift-version 5 -o "$BUILD_DIR/tests" \
  "$APP/Settings/TeachySettings.swift" \
  "$APP/Dictation/DictationDictionary.swift" \
  "$APP/Dictation/DictationShortcut.swift" \
  "$APP/Dictation/DictationHotkeyStateMachine.swift" \
  "$APP/PushToTalkShortcutKeys.swift" \
  "$APP/Touch/ScreenTapSignalProcessing.swift" \
  "$APP/Agent/TeachyActionPreferences.swift" \
  scripts/tests/action_preferences/tests.swift
"$BUILD_DIR/tests"
