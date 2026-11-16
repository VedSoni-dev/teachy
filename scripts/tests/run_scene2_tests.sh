#!/bin/bash
# Tests for the second round of drawing-engine work.
#
#   scripts/tests/run_scene2_tests.sh              pure tests, then the in-process app tests
#   scripts/tests/run_scene2_tests.sh --pure       only the pure tests (fast, no AppKit)
#   scripts/tests/run_scene2_tests.sh --network    also fetch real photos (Wikipedia, and one publik search)
#   scripts/tests/run_scene2_tests.sh --live       pure tests, then SceneDirector with the real model (3 model calls)
#
# Nothing is shown on screen: windows the app tests need are placed off every display.
# Pictures and videos go to $TMPDIR/teachy-scene2/. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-scene2/bin"
mkdir -p "$OUT"
S=leanring-buddy/Scene
swiftc -O -parse-as-library \
  $S/SceneCommand.swift $S/SceneScriptParser.swift $S/SceneGeometry.swift $S/SceneParts.swift $S/SceneMacros.swift \
  $S/SceneReplayLog.swift $S/SceneScriptPrompt.swift $S/SceneLabelLayout.swift $S/SceneNarration.swift $S/SceneQuality.swift \
  $S/ScenePhotoPicker.swift $S/SceneHistoryStore.swift $S/SceneCamera.swift $S/SceneRefine.swift \
  scripts/tests/scene2/pure/scene2_tests.swift \
  -o "$OUT/scene2_tests"
"$OUT/scene2_tests"
if [ "${1:-}" = "--pure" ]; then exit 0; fi

if [ "${1:-}" = "--live" ]; then
  # SceneDirector end to end with the real scene model (three model calls) and a stand-in voice.
  swiftc -O -swift-version 5 -default-isolation MainActor \
    leanring-buddy/DesignSystem.swift \
    $S/*.swift \
    leanring-buddy/Core/SceneDirector.swift leanring-buddy/Core/StreamIdleGuard.swift \
    leanring-buddy/TeachyAIRouter.swift leanring-buddy/TeachyPublikSession.swift leanring-buddy/Publik.swift leanring-buddy/TeachyAPIKeyStore.swift \
    scripts/tests/scene2/director/main.swift \
    -o "$OUT/scene2_director_test"
  DO_NOT_TRACK=1 "$OUT/scene2_director_test"
  exit $?
fi

swiftc -O -swift-version 5 -default-isolation MainActor \
  leanring-buddy/DesignSystem.swift \
  $S/*.swift \
  leanring-buddy/Core/StreamIdleGuard.swift leanring-buddy/TeachyAIRouter.swift leanring-buddy/TeachyPublikSession.swift leanring-buddy/Publik.swift leanring-buddy/TeachyAPIKeyStore.swift \
  scripts/tests/scene2/app/main.swift \
  -o "$OUT/scene2_app_tests"
DO_NOT_TRACK=1 "$OUT/scene2_app_tests" "$@"
