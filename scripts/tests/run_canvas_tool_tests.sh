#!/bin/bash
# Direct canvas tool adapter; no app, network, screen capture or permissions.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/teachy-canvas-tools.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
  leanring-buddy/Agent/SceneCanvasTools.swift scripts/tests/canvas_tools/Harness.swift \
  -o "$OUT/test"
"$OUT/test"
