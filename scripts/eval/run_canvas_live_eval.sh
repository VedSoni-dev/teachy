#!/bin/bash
# Exactly one synthetic text-only AI call; no user screen/camera/history access.
# Result artifacts default to this project's work directory, never outputs.
set -euo pipefail
cd "$(dirname "$0")/../.."
RESULT_DIR="${1:-../work/canvas-live-eval}"
mkdir -p "$RESULT_DIR"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-canvas-live-eval.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -Onone -swift-version 5 -default-isolation MainActor -parse-as-library \
  leanring-buddy/DesignSystem.swift leanring-buddy/Scene/*.swift \
  leanring-buddy/Core/StreamIdleGuard.swift leanring-buddy/TeachyAIRouter.swift \
  leanring-buddy/TeachyPublikSession.swift leanring-buddy/Publik.swift \
  scripts/eval/canvas_live_eval.swift -o "$BUILD_DIR/eval" \
  > "$RESULT_DIR/compile.log" 2>&1 || { cat "$RESULT_DIR/compile.log" >&2; exit 1; }
DO_NOT_TRACK=1 "$BUILD_DIR/eval" --out "$RESULT_DIR" | tee "$RESULT_DIR/run.log"
