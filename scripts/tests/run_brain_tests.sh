#!/bin/bash
# Compiles and runs the standalone tests for Teachy's memory (leanring-buddy/Brain).
# No Xcode project, no app launch, and nothing is written to the real ~/.teachy:
# the tests work in a temporary directory. Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-brain-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Every Brain source except the SwiftUI card, which needs the app's design system.
SOURCES=()
for source_file in "$REPO_ROOT"/leanring-buddy/Brain/*.swift; do
    case "$(basename "$source_file")" in
        BrainMemorySection.swift) ;;
        *) SOURCES+=("$source_file") ;;
    esac
done

swiftc -O \
    "${SOURCES[@]}" \
    "$REPO_ROOT/leanring-buddy/TeachyDataPaths.swift" \
    "$REPO_ROOT/scripts/tests/brain_tests.swift" \
    -o "$BUILD_DIR/brain_tests"

"$BUILD_DIR/brain_tests"
