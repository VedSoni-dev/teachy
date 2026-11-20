#!/bin/sh
# Renders the settings cards, caption bar, text box and paint trail to PNGs in
# $TMPDIR/uiextras-shots/ and checks the text box's key handling, without
# launching Teachy or showing anything on screen. Exits non-zero on failure.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-uiextras-shots"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/Dictation/DictationDictionary.swift" \
  "$APP/Dictation/DictationShortcut.swift" \
  "$APP/Dictation/DictationHotkeyStateMachine.swift" \
  "$APP/Dictation/DictationShortcutPickerRow.swift" \
  "$APP/PushToTalkShortcutKeys.swift" \
  "$APP/Settings/TeachySettings.swift" \
  "$APP/Touch/ScreenTapSignalProcessing.swift" \
  "$APP/Settings/TeachySettings+CursorColor.swift" \
  "$APP/Settings/VoicePreviewPlayer.swift" \
  "$APP/Settings/SettingsSections.swift" \
  "$APP/Captions/CaptionLineFitter.swift" \
  "$APP/Captions/CaptionPresenter.swift" \
  "$APP/TextBox/DoubleTapControlStateMachine.swift" \
  "$APP/TextBox/TextBoxController.swift" \
  "$APP/Trail/PaintTrailMath.swift" \
  "$APP/Trail/PaintTrailPresenter.swift" \
  scripts/tests/uiextras_shots/main.swift
"$OUT"
