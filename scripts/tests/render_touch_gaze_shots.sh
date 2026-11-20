#!/bin/sh
# Renders Settings → Touch & Eyes (the real TeachyTouchAndGazeSettingsPage) and the
# eye-tracking calibration screen to PNGs in $TMPDIR/teachy-touch-gaze-shots/,
# without launching Teachy, opening the camera or reading Teachy's settings.
# Reuses the Home shots' stand-ins for the app's managers.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-touch-gaze-shots-bin"
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
  "$APP/Skills/SkillLibrary.swift" \
  "$APP/Skills/SkillMarket.swift" \
  "$APP/Skills/SkillStore.swift" \
  "$APP/Skills/SkillsLibraryView.swift" \
  "$APP/Skills/SkillsLibraryWindowController.swift" \
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
  "$APP/Touch/ScreenTapSignalProcessing.swift" \
  "$APP/Touch/ScreenTapSensor.swift" \
  "$APP/Touch/ScreenTapController.swift" \
  "$APP/EyeTracking/GazeMath.swift" \
  "$APP/EyeTracking/GazeCameraReader.swift" \
  "$APP/EyeTracking/GazeTracker.swift" \
  "$APP/EyeTracking/GazeCalibrationWindowController.swift" \
  "$APP/Settings/TeachyTouchAndGazeSettingsPage.swift" \
  scripts/tests/home_shots/Stubs.swift \
  scripts/tests/touch_gaze_shots/main.swift
"$OUT"
