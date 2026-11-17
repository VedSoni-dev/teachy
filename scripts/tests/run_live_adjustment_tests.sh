#!/bin/bash
# Deterministic local controls. No model calls or application launch.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/teachy-live-adjustment.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
S=leanring-buddy/Scene
if [ "${1:-}" = "--engine" ]; then
    swiftc -O -swift-version 5 -default-isolation MainActor -D LIVE_ENGINE \
      leanring-buddy/DesignSystem.swift "$S"/*.swift \
      leanring-buddy/Core/StreamIdleGuard.swift leanring-buddy/TeachyAIRouter.swift \
      leanring-buddy/TeachyPublikSession.swift leanring-buddy/Publik.swift leanring-buddy/TeachyAPIKeyStore.swift \
      scripts/tests/live-adjustment/main.swift -o "$OUT/checks"
else
    swiftc -O "$S/SceneCommand.swift" "$S/SceneScriptParser.swift" "$S/SceneGeometry.swift" \
      "$S/SceneParts.swift" "$S/SceneMacros.swift" "$S/SceneReplayLog.swift" \
      "$S/SceneScriptPrompt.swift" "$S/SceneCamera.swift" "$S/SceneRefine.swift" \
      scripts/tests/live-adjustment/main.swift -o "$OUT/checks"
fi
DO_NOT_TRACK=1 "$OUT/checks"
