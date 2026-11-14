#!/bin/sh
# Unit tests for the pure logic behind settings, captions, the text box shortcut
# and the paint trail. No app or Xcode project needed. Exits non-zero on failure.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-uiextras-tests"
swiftc -o "$OUT" \
  leanring-buddy/Settings/TeachySettings.swift \
  leanring-buddy/Captions/CaptionLineFitter.swift \
  leanring-buddy/TextBox/DoubleTapControlStateMachine.swift \
  leanring-buddy/Trail/PaintTrailMath.swift \
  scripts/tests/uiextras/main.swift
"$OUT"
