#!/bin/bash
# Builds and runs the "draw on the real screen" eval: twelve made-up screenshots with a
# known target each, one model call per screenshot, scored by whether the model's
# mark lands on the target. Calls go through TeachyAIRouter with this Mac's publik sign-in.
#
#   scripts/eval/run_annotate_eval.sh                 all screenshots
#   scripts/eval/run_annotate_eval.sh --only name,teachy   selected screenshots
#   scripts/eval/run_annotate_eval.sh --out DIR       where to save pictures and answers
#   scripts/eval/run_annotate_eval.sh --strict        fail on misses, wrong shapes, parse errors, or API errors
#   scripts/eval/run_annotate_eval.sh --score DIR     score saved scripts without API calls
#   scripts/eval/run_annotate_eval.sh --draw-only     just draw the screenshots, no model calls
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-annotate-eval-build"
mkdir -p "$OUT"
BUILD_DIR="$(mktemp -d "$OUT/.compile.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
if ! swiftc -O -swift-version 5 -default-isolation MainActor -parse-as-library \
  leanring-buddy/Scene/SceneCommand.swift \
  leanring-buddy/Scene/SceneScriptParser.swift \
  leanring-buddy/Scene/SceneGeometry.swift \
  leanring-buddy/Scene/SceneParts.swift \
  leanring-buddy/Scene/SceneMacros.swift \
  leanring-buddy/Scene/SceneReplayLog.swift \
  leanring-buddy/Scene/SceneScriptPrompt.swift \
  leanring-buddy/Scene/SceneAnnotationText.swift \
  leanring-buddy/Scene/SceneNarration.swift \
  leanring-buddy/Scene/SceneOverlayView.swift \
  leanring-buddy/Core/StreamIdleGuard.swift \
  leanring-buddy/TeachyAIRouter.swift leanring-buddy/TeachyGatewayKeyStore.swift leanring-buddy/TeachyPublikSession.swift \
  leanring-buddy/Publik.swift \
  scripts/eval/annotate_eval.swift \
  -o "$BUILD_DIR/annotate_eval" > "$BUILD_DIR/compile.log" 2>&1; then
  cat "$BUILD_DIR/compile.log" >&2
  exit 1
fi
mv -f "$BUILD_DIR/annotate_eval" "$OUT/annotate_eval"
# The eval is not a person using Teachy: keep it out of the usage counts.
DO_NOT_TRACK=1 "$OUT/annotate_eval" "$@"
