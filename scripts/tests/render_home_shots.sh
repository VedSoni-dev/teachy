#!/bin/sh
# Renders the notch panel's Home tab (the real NotchHomeTabView and the real
# agents section with sample data; stand-ins for the app's managers and
# placeholders for the sections that read live data)
# to PNGs in $TMPDIR/teachy-home-shots/, without launching Teachy, showing
# anything on screen or reading ~/.teachy. Exits non-zero if a render fails.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-home-shots-bin"
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
  "$APP/NotchHomeTabView.swift" \
  "$APP/NotchPanelTab.swift" \
  "$APP/Settings/TeachySettingsPage.swift" \
  "$APP/ClickyNotchRootView.swift" \
  "$APP/ClickyAudioSpectrumView.swift" \
  "$APP/ClickyNotchShape.swift" \
  "$APP/ClickyNotchSizing.swift" \
  "$APP/NotchScreenGeometry.swift" \
  "$APP/TeachyDataPaths.swift" \
  "$APP/Agent/AgentJobModel.swift" \
  "$APP/Agent/AgentsSectionContent.swift" \
  "$APP/Agent/AgentRoster.swift" \
  "$APP/Agent/AgentCompaction.swift" \
  "$APP/Agent/AgentHistory.swift" \
  "$APP/Agent/Routines/RoutineSchedule.swift" \
  "$APP/Agent/Routines/RoutineStore.swift" \
  "$APP/Brain/BrainMarkdown.swift" \
  scripts/tests/home_shots/Stubs.swift \
  scripts/tests/home_shots/main.swift
"$OUT"
