#!/bin/bash
# Compiles the pure dictation logic together with its tests and runs them.
# Exits non-zero if compilation or any test fails. No Xcode project needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCES="$REPO_ROOT/leanring-buddy/Dictation"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dictation-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc -O -parse-as-library \
  "$SOURCES/DictationHotkeyStateMachine.swift" \
  "$SOURCES/DictationTextRules.swift" \
  "$SOURCES/DictationDictionary.swift" \
  "$REPO_ROOT/scripts/tests/dictation_tests.swift" \
  -o "$BUILD_DIR/dictation_tests"

"$BUILD_DIR/dictation_tests"
