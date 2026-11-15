#!/bin/sh
# Renders Teachy's design kit (type, colour, buttons, key caps, switches,
# status marks, a grouped list, glass tiles) to PNGs in $TMPDIR/teachy-design-shots/ without
# launching Teachy or showing anything on screen. Look at these after any change
# to DesignSystem.swift.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-design-shots-bin"
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  leanring-buddy/DesignSystem.swift \
  scripts/tests/design_shots/main.swift
"$OUT"
