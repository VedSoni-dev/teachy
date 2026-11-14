#!/bin/sh
# Tests for microphone choice and the level meter maths (lists this Mac's real inputs too).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-microphone-tests"
swiftc -o "$OUT" leanring-buddy/Core/MicrophoneCenter.swift scripts/tests/microphone/main.swift
"$OUT"
