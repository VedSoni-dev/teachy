#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/teachy-camera-input.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 leanring-buddy/CameraInput/CameraInputMath.swift scripts/tests/camera_input/main.swift -o "$OUT/tests"
"$OUT/tests"
