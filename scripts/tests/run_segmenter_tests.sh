#!/bin/sh
# Unit tests for the streaming speech segmenter (pure logic, no app needed).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-segmenter-tests"
swiftc -o "$OUT" leanring-buddy/Core/StreamingSpeechSegmenter.swift scripts/tests/segmenter/main.swift
"$OUT"
