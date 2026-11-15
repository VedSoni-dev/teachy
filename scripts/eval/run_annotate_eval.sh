#!/bin/bash
# Builds and runs the "draw on the real screen" eval: ten made-up screenshots with a
# known target each, one model call per screenshot, scored by whether the model's
# mark lands on the target. Calls go through TeachyAIRouter with this Mac's publik sign-in.
#
#   scripts/eval/run_annotate_eval.sh                 all screenshots
#   scripts/eval/run_annotate_eval.sh --only code     one screenshot
#   scripts/eval/run_annotate_eval.sh --out DIR       where to save pictures and answers
#   scripts/eval/run_annotate_eval.sh --draw-only     just draw the screenshots, no model calls
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-annotate-eval-build"
mkdir -p "$OUT"
swiftc -O -swift-version 5 -parse-as-library \
  leanring-buddy/Scene/SceneCommand.swift \
  leanring-buddy/Scene/SceneScriptParser.swift \
  leanring-buddy/Scene/SceneGeometry.swift \
  leanring-buddy/Scene/SceneParts.swift \
  leanring-buddy/Scene/SceneMacros.swift \
  leanring-buddy/Scene/SceneReplayLog.swift \
  leanring-buddy/Scene/SceneScriptPrompt.swift \
  leanring-buddy/Scene/SceneNarration.swift \
  leanring-buddy/Scene/SceneOverlayView.swift \
  leanring-buddy/Core/StreamIdleGuard.swift \
  leanring-buddy/TeachyAIRouter.swift \
  leanring-buddy/Publik.swift \
  leanring-buddy/TeachyAPIKeyStore.swift \
  scripts/eval/annotate_eval.swift \
  -o "$OUT/annotate_eval" 2>&1 | grep -E 'error:' || true
# The eval is not a person using Teachy: keep it out of the usage counts.
DO_NOT_TRACK=1 "$OUT/annotate_eval" "$@"
