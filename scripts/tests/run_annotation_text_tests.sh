#!/bin/bash
# Synthetic glyph images only: no screen capture, user files, credentials or API calls.
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-annotation-text.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -O -swift-version 5 -default-isolation MainActor -parse-as-library \
  leanring-buddy/Scene/SceneAnnotationText.swift \
  scripts/tests/annotation_text/main.swift \
  -o "$BUILD_DIR/annotation_text_tests"
"$BUILD_DIR/annotation_text_tests"
