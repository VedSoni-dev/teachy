#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/teachy-annotation-tracking.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -default-isolation MainActor \
 leanring-buddy/Scene/SceneCommand.swift leanring-buddy/Scene/SceneGeometry.swift \
 leanring-buddy/Scene/SceneOverlayView.swift leanring-buddy/Scene/SceneAnnotationTracking.swift \
 scripts/tests/annotation_tracking/Harness.swift -o "$OUT/test"
"$OUT/test"
