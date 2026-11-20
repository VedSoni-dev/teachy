#!/bin/bash
# Standalone tests for memory recall and learning (leanring-buddy/Brain/MemoryRecall.swift,
# MemoryLearning.swift, BrainStore+Recall.swift). Works in a temporary directory; the real
# ~/.teachy is never touched and no model is called. Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-recall-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

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
    "$REPO_ROOT/scripts/tests/memory_recall_tests.swift" \
    -o "$BUILD_DIR/memory_recall_tests"

"$BUILD_DIR/memory_recall_tests"
