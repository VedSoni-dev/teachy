#!/bin/sh
# Unit tests for the pure logic behind always-on mode (voice detector on synthetic
# sound, Control tap counting), quiet-on-calls, the muted Mac, microphone failover,
# reply languages, the realtime voice's pace and screen memory.
# No app, microphone or network needed. Exits non-zero on failure.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-voice2-tests"
swiftc -O -o "$OUT" \
  leanring-buddy/Voice/VoiceActivityDetector.swift \
  leanring-buddy/Voice/ControlTapCountStateMachine.swift \
  leanring-buddy/Voice/VoicePolicy.swift \
  leanring-buddy/Voice/ScreenMemorySummary.swift \
  leanring-buddy/Core/MicrophoneCenter.swift \
  leanring-buddy/Settings/TeachySettings.swift \
  leanring-buddy/TextBox/DoubleTapControlStateMachine.swift \
  scripts/tests/voice2/main.swift
"$OUT"
