#!/bin/sh
# Renders the notch panel's first-run screens (the real NotchSetupOnboardingView,
# PermissionChoreographyView and PublikGateView, with stand-ins for the app's
# managers and for publik) to PNGs in $TMPDIR/teachy-onboarding-shots/, without
# launching Teachy, showing anything on screen, asking macOS for a permission,
# signing in to publik or reaching the network. Exits non-zero if a render fails.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-onboarding-shots-bin"
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
  "$APP/NotchSetupOnboardingView.swift" \
  "$APP/PermissionChoreographyView.swift" \
  "$APP/PublikGateView.swift" \
  scripts/tests/onboarding_shots/main.swift
"$OUT"
