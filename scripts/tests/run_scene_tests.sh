#!/bin/bash
# Builds and runs the standalone tests for the pure half of the drawing engine.
# Exits non-zero if any check fails.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-scene-tests"
mkdir -p "$OUT"
swiftc -O -parse-as-library \
  leanring-buddy/Scene/SceneCommand.swift \
  leanring-buddy/Scene/SceneScriptParser.swift \
  leanring-buddy/Scene/SceneGeometry.swift \
  leanring-buddy/Scene/SceneParts.swift \
  leanring-buddy/Scene/SceneReplayLog.swift \
  leanring-buddy/Scene/SceneScriptPrompt.swift \
  scripts/tests/scene_tests.swift \
  -o "$OUT/scene_tests"
"$OUT/scene_tests"
