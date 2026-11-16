#!/bin/sh
# Unit tests for how much thought a voice turn gets (VoiceTurnDepth) and the
# [OPEN:] link tag. No app, no network.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-voice-depth-tests"
swiftc -o "$OUT" \
  leanring-buddy/Core/VoiceTags.swift \
  leanring-buddy/Core/VoiceTurnDepth.swift \
  scripts/tests/voice_depth/main.swift
"$OUT"
