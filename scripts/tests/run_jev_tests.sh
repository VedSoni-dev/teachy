#!/bin/bash
# Jev client + 3D drawing router. Offline by default; JEV_LIVE=1 with AI_GATEWAY_API_KEY
# set in the environment makes three real Jev calls through Vercel AI Gateway.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/teachy-jev.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
S=leanring-buddy/Scene
swiftc -O "$S/SceneCommand.swift" "$S/SceneScriptParser.swift" "$S/SceneGeometry.swift" \
  "$S/SceneParts.swift" "$S/SceneMacros.swift" "$S/SceneReplayLog.swift" \
  "$S/SceneScriptPrompt.swift" "$S/SceneCamera.swift" "$S/SceneRefine.swift" "$S/SceneCanvasRouting.swift" \
  leanring-buddy/TeachyGatewayKeyStore.swift leanring-buddy/TeachyJev.swift leanring-buddy/Core/SceneJevRouter.swift \
  scripts/tests/jev/main.swift -o "$OUT/checks"
DO_NOT_TRACK=1 "$OUT/checks"
