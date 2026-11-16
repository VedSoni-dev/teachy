#!/bin/bash
# Tests for the 3D camera that directs itself (focus, refine, direct manipulation, replay).
#
#   scripts/tests/run_scene3_tests.sh           pure tests, then the in-process app tests
#   scripts/tests/run_scene3_tests.sh --pure    only the pure tests (fast, no AppKit)
#   scripts/tests/run_scene3_tests.sh --perf    frame times of the three heaviest eval scenes (needs saved eval answers)
#
# Nothing is shown on screen: the one real window the app tests need is placed off every
# display and gets its events in-process. Pictures go to $TMPDIR/teachy-scene3/.
# Exits non-zero on any failure. No model calls.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-scene3/bin"
mkdir -p "$OUT"
S=leanring-buddy/Scene
APP_SOURCES="leanring-buddy/DesignSystem.swift $S/*.swift leanring-buddy/Core/StreamIdleGuard.swift leanring-buddy/TeachyAIRouter.swift leanring-buddy/TeachyPublikSession.swift leanring-buddy/Publik.swift leanring-buddy/TeachyAPIKeyStore.swift"

if [ "${1:-}" = "--perf" ]; then
  swiftc -O -swift-version 5 -default-isolation MainActor $APP_SOURCES scripts/tests/scene3/perf/main.swift -o "$OUT/scene3_perf"
  shift
  "$OUT/scene3_perf" "$@"
  exit $?
fi

swiftc -O \
  $S/SceneCommand.swift $S/SceneScriptParser.swift $S/SceneGeometry.swift $S/SceneParts.swift $S/SceneMacros.swift \
  $S/SceneReplayLog.swift $S/SceneScriptPrompt.swift $S/SceneCamera.swift $S/SceneRefine.swift \
  scripts/tests/scene3/pure/main.swift \
  -o "$OUT/scene3_tests"
"$OUT/scene3_tests"
if [ "${1:-}" = "--pure" ]; then exit 0; fi

swiftc -O -swift-version 5 -default-isolation MainActor $APP_SOURCES scripts/tests/scene3/app/main.swift -o "$OUT/scene3_app_tests"
DO_NOT_TRACK=1 "$OUT/scene3_app_tests" "$@"
