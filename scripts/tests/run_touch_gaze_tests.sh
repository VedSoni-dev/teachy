#!/bin/sh
# Unit tests for "tap the screen to talk" (ScreenTapRecognizer) and webcam eye
# tracking math (features, calibration regression, smoothing, fixations).
# Synthetic sensor streams and gaze samples only: no hardware, camera, or app.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-touch-gaze-tests"
swiftc -O -o "$OUT" \
  leanring-buddy/Touch/ScreenTapSignalProcessing.swift \
  leanring-buddy/EyeTracking/GazeMath.swift \
  scripts/tests/touch_gaze/main.swift
"$OUT"

# Gaze → grid cells, against the real grid helper.
OUT2="${TMPDIR:-/tmp}/teachy-gaze-context-tests"
swiftc -o "$OUT2" \
  leanring-buddy/EyeTracking/GazeMath.swift \
  leanring-buddy/EyeTracking/CompanionGazeContext.swift \
  leanring-buddy/ScreenGridAnnotationUtility.swift \
  scripts/tests/gaze_context/Stubs.swift \
  scripts/tests/gaze_context/main.swift
"$OUT2"
