#!/bin/bash
# Deterministic annotation lifecycle regression; no model calls or screen capture.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/teachy-annotation-lifecycle.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -default-isolation MainActor \
  leanring-buddy/DesignSystem.swift leanring-buddy/Scene/*.swift \
  leanring-buddy/Core/SceneDirector.swift leanring-buddy/Core/StreamIdleGuard.swift \
  leanring-buddy/TeachyAIRouter.swift leanring-buddy/TeachyPublikSession.swift \
  leanring-buddy/Publik.swift leanring-buddy/TeachyAPIKeyStore.swift \
  scripts/tests/scene2/annotation-lifecycle/main.swift \
  -o "$OUT/test" > "$OUT/compile.log" 2>&1 || { cat "$OUT/compile.log"; exit 1; }
DO_NOT_TRACK=1 "$OUT/test"
