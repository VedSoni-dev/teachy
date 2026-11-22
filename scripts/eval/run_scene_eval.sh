#!/bin/bash
# Builds and runs the TeachyScene model eval: seventeen prompts (one model call each) and six refine
# cases on a drawing that is already up (one call each). It measures how well the model writes
# the script, and what the self-directing 3D camera does with it. Nothing is shown on screen.
# Calls go through TeachyAIRouter with this Mac's publik sign-in.
#
#   scripts/eval/run_scene_eval.sh                       everything (23 model calls)
#   scripts/eval/run_scene_eval.sh --only oslayers,agentloop,network   selected prompts
#   scripts/eval/run_scene_eval.sh --strict              fail on parse errors, failures or the wrong presentation
#   scripts/eval/run_scene_eval.sh --no-refine           skip the refine cases
#   scripts/eval/run_scene_eval.sh --refine-only [DIR]   only the refine cases (6 calls)
#   scripts/eval/run_scene_eval.sh --out DIR             where to save the answers
#   scripts/eval/run_scene_eval.sh --score DIR           measure saved answers again, no model calls
#   scripts/eval/run_scene_eval.sh --score DIR --no-direct   the same, with the camera as it was before
#   scripts/eval/run_scene_eval.sh --shots a,b,c,d       also write a PNG per sentence ($TMPDIR/teachy-scene3/shots/<scene>/NN.png)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-scene3/bin"
mkdir -p "$OUT" "${TMPDIR:-/tmp}/teachy-scene3/eval-logs"
S=leanring-buddy/Scene
BUILD_DIR="$(mktemp -d "$OUT/.scene-eval-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
if ! swiftc -O -swift-version 5 -default-isolation MainActor -parse-as-library \
  leanring-buddy/DesignSystem.swift \
  $S/*.swift \
  leanring-buddy/Core/SceneDirector.swift leanring-buddy/Core/StreamIdleGuard.swift \
  leanring-buddy/TeachyAIRouter.swift leanring-buddy/TeachyGatewayKeyStore.swift leanring-buddy/TeachyPublikSession.swift leanring-buddy/Publik.swift \
  scripts/eval/scene_eval.swift \
  -o "$BUILD_DIR/scene_eval" > "$BUILD_DIR/compile.log" 2>&1; then
  cat "$BUILD_DIR/compile.log" >&2
  exit 1
fi
# Replace the runnable binary only after a successful compile, on the same filesystem.
mv -f "$BUILD_DIR/scene_eval" "$OUT/scene_eval"
# The eval is not a person using Teachy: keep it out of the usage counts.
DO_NOT_TRACK=1 "$OUT/scene_eval" "$@"
