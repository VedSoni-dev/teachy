#!/bin/sh
# Shows Teachy's real notch view (ClickyNotchRootView, in real Liquid Glass) in a
# small window on your screen, over a stand-in desktop, and opens and closes it
# on a loop so you can watch the glass. Hover or click the notch to drive it
# yourself. It never launches or touches the installed app, and reads nothing
# from ~/.teachy.
#
#   scripts/tests/run_notch_demo.sh [--seconds 30] [--notched] [--pages] [--record DIR]
#
#   --seconds N     how long the window stays up (default 30)
#   --notched       draw a camera housing, as on a MacBook Pro
#   --pages         switch Home -> Chat -> Settings and back while open
#   --record DIR    also write DIR/notch.mp4 and DIR/notch.gif (needs ffmpeg)
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-notch-demo-bin"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/Dictation/DictationDictionary.swift" \
  "$APP/Dictation/DictationShortcut.swift" \
  "$APP/Dictation/DictationHotkeyStateMachine.swift" \
  "$APP/PushToTalkShortcutKeys.swift" \
  "$APP/Settings/TeachySettings.swift" \
  "$APP/Touch/ScreenTapSignalProcessing.swift" \
  "$APP/Settings/TeachySettings+CursorColor.swift" \
  "$APP/Settings/VoicePreviewPlayer.swift" \
  "$APP/Settings/SettingsSections.swift" \
  "$APP/Settings/MicrophoneSettingsSection.swift" \
  "$APP/Core/MicrophoneCenter.swift" \
  "$APP/Voice/VoicePolicy.swift" \
  "$APP/Voice/AlwaysOnPillView.swift" \
  "$APP/NotchHomeTabView.swift" \
  "$APP/Skills/SkillLibrary.swift" \
  "$APP/Skills/SkillMarket.swift" \
  "$APP/Skills/SkillStore.swift" \
  "$APP/Skills/SkillsLibraryView.swift" \
  "$APP/Skills/SkillsLibraryWindowController.swift" \
  "$APP/NotchPanelTab.swift" \
  "$APP/Settings/TeachySettingsPage.swift" \
  "$APP/ClickyNotchRootView.swift" \
  "$APP/ClickyNotchShape.swift" \
  "$APP/ClickyNotchSizing.swift" \
  "$APP/NotchScreenGeometry.swift" \
  "$APP/ClickyAudioSpectrumView.swift" \
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
  scripts/tests/notch_demo/main.swift
"$OUT" "$@"
