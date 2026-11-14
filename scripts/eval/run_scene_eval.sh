#!/bin/bash
# Builds and runs the TeachyScene model eval (10 prompts, one model call each).
# Calls go through TeachyAIRouter with this Mac's publik sign-in.
#
#   scripts/eval/run_scene_eval.sh                 all prompts
#   scripts/eval/run_scene_eval.sh --only gears    one prompt
#   scripts/eval/run_scene_eval.sh --out DIR       where to save the answers
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-scene-eval-build"
mkdir -p "$OUT"
swiftc -O -parse-as-library \
  leanring-buddy/Scene/SceneCommand.swift \
  leanring-buddy/Scene/SceneScriptParser.swift \
  leanring-buddy/Scene/SceneGeometry.swift \
  leanring-buddy/Scene/SceneParts.swift \
  leanring-buddy/Scene/SceneReplayLog.swift \
  leanring-buddy/Scene/SceneScriptPrompt.swift \
  leanring-buddy/TeachyAIRouter.swift \
  leanring-buddy/Publik.swift \
  leanring-buddy/TeachyAPIKeyStore.swift \
  scripts/eval/scene_eval.swift \
  -o "$OUT/scene_eval" 2>&1 | grep -E 'error' || true
# The eval is not a person using Teachy: keep it out of the usage counts.
DO_NOT_TRACK=1 "$OUT/scene_eval" "$@"
