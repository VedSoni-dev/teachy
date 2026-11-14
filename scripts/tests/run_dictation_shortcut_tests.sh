#!/bin/sh
# Rules for the customisable dictation shortcut (pure logic, no app needed).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-dictation-shortcut-tests"
swiftc -o "$OUT" leanring-buddy/Dictation/DictationShortcut.swift leanring-buddy/Dictation/DictationHotkeyStateMachine.swift scripts/tests/dictation_shortcut/main.swift
"$OUT"
