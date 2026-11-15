#!/bin/bash
# Renders scene script files to PNG without launching Teachy and without showing
# anything on screen (windows are placed off every display).
#
#   scripts/tests/render_scene2_shots.sh OUT_DIR SECONDS file.txt [file.txt …]
#
# SECONDS is how long each script is left to build before its picture is taken
# (lines appear about 0.1 s apart, so 6 is enough for a long script).
# Example: the answers saved by scripts/eval/run_scene_eval.sh --out DIR.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${TMPDIR:-/tmp}/teachy-scene2/bin"
mkdir -p "$BIN"
swiftc -O -swift-version 5 -default-isolation MainActor \
  leanring-buddy/DesignSystem.swift \
  leanring-buddy/Scene/*.swift \
  scripts/tests/scene2/render/main.swift \
  -o "$BIN/scene2_render" 2>&1 | grep -E ' error:' || true
"$BIN/scene2_render" "$@"
