#!/bin/sh
# Renders the always-on pill (every state), the Voice card and the Microphone card
# to PNGs in $TMPDIR/voice2-shots/ without launching Teachy, showing anything on
# screen or opening the microphone. It lists this Mac's real input devices.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-voice2-shots"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/Dictation/DictationDictionary.swift" \
  "$APP/Dictation/DictationShortcut.swift" \
  "$APP/Dictation/DictationHotkeyStateMachine.swift" \
  "$APP/PushToTalkShortcutKeys.swift" \
  "$APP/Settings/TeachySettings.swift" \
  "$APP/Settings/TeachySettings+CursorColor.swift" \
  "$APP/Settings/VoicePreviewPlayer.swift" \
  "$APP/Settings/SettingsSections.swift" \
  "$APP/Settings/MicrophoneSettingsSection.swift" \
  "$APP/Core/MicrophoneCenter.swift" \
  "$APP/Voice/VoicePolicy.swift" \
  "$APP/Voice/AlwaysOnPillView.swift" \
  scripts/tests/voice2_shots/main.swift
"$OUT"
