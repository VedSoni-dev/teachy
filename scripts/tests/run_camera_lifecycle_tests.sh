#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/teachy-camera-lifecycle.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -default-isolation MainActor leanring-buddy/DesignSystem.swift leanring-buddy/CameraInput/CameraInputModels.swift leanring-buddy/CameraInput/CameraInputMath.swift leanring-buddy/CameraInput/CameraInputController.swift scripts/tests/camera_lifecycle/Stubs.swift scripts/tests/camera_lifecycle/main.swift -o "$OUT/tests"
"$OUT/tests"
