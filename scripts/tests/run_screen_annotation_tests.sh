#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-screen-annotation.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -swift-version 5 leanring-buddy/Core/ScreenAnnotationPolicy.swift scripts/tests/screen_annotation/main.swift -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
