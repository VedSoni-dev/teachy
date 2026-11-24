#!/bin/sh
# Renders the real suggestion panel to PNGs in $TMPDIR/teachy-suggestion-shots/.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-suggestion-shots-bin"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/Suggestions/TeachySuggestion.swift" \
  "$APP/Suggestions/SuggestionPanel.swift" \
  scripts/tests/suggestion_shots/Stubs.swift \
  scripts/tests/suggestion_shots/main.swift
"$OUT"
