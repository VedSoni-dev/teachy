#!/bin/sh
# Unit tests for dictation speed (live typing, checked insertion, release policy,
# pause detection) and the "write it for me" prompt. Pure logic, no app needed.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-dictspeed-tests"
xcrun swiftc -o "$OUT" \
  leanring-buddy/Dictation/DictationTextRules.swift \
  leanring-buddy/Dictation/DictationSpeedPolicy.swift \
  leanring-buddy/Writing/WritingPrompt.swift \
  leanring-buddy/Core/VoiceTags.swift \
  scripts/tests/dictspeed/main.swift
"$OUT"
