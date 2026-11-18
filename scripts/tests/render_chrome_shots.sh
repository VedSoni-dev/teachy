#!/bin/sh
# Renders the Browser settings card (leanring-buddy/Browser/BrowserExtensionCard.swift)
# in each of its states to PNGs in $TMPDIR/teachy-chrome/shots/, without launching
# Teachy or showing anything on screen. Exits non-zero if a render fails.
set -e
cd "$(dirname "$0")/../.."
WORK="${TMPDIR:-/tmp}/teachy-chrome"
mkdir -p "$WORK"
export TEACHY_TEST_SCRATCH="$WORK"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$WORK/chrome-shots" \
  "$APP/DesignSystem.swift" \
  "$APP/Dictation/DictationDictionary.swift" \
  "$APP/Settings/TeachySettings.swift" \
  "$APP/Touch/ScreenTapSignalProcessing.swift" \
  "$APP/Settings/TeachySettings+CursorColor.swift" \
  "$APP/Settings/VoicePreviewPlayer.swift" \
  "$APP/Settings/SettingsSections.swift" \
  "$APP/PushToTalkShortcutKeys.swift" \
  "$APP/Dictation/DictationShortcut.swift" \
  "$APP/Dictation/DictationHotkeyStateMachine.swift" \
  "$APP/Browser/BrowserWire.swift" \
  "$APP/Browser/BrowserHostManifest.swift" \
  "$APP/Browser/BrowserSocketServer.swift" \
  "$APP/Browser/BrowserLink.swift" \
  "$APP/Browser/BrowserExtensionCard.swift" \
  scripts/tests/chrome_shots/main.swift
"$WORK/chrome-shots"
