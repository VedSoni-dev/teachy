#!/bin/bash
# Compiles and runs the standalone tests for MCP connectors (leanring-buddy/Connectors).
# No Xcode project, no app launch. Nothing touches the real ~/.teachy or the real
# Keychain: the tests use a temporary folder and an in-memory secret store, and the
# only servers they talk to are fakes they start themselves on this machine
# (a stdio one and an HTTP one, both small Python scripts written to a temp dir).
# Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-connectors-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is needed for the fake MCP servers." >&2
    exit 1
fi

# Every Connectors source except the SwiftUI card (needs the app's design system)
# and the Keychain store (the tests must never touch the real Keychain).
SOURCES=()
for source_file in "$REPO_ROOT"/leanring-buddy/Connectors/*.swift; do
    case "$(basename "$source_file")" in
        ConnectorsSection.swift|McpKeychainSecretStore.swift) ;;
        *) SOURCES+=("$source_file") ;;
    esac
done

TEST_SOURCES=("$REPO_ROOT"/scripts/tests/connectors/*.swift)

echo "== plain build =="
swiftc "${SOURCES[@]}" "${TEST_SOURCES[@]}" -o "$BUILD_DIR/connectors_tests"
"$BUILD_DIR/connectors_tests"

# The app target compiles with "everything is on the main actor unless it says otherwise"
# (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, SWIFT_APPROACHABLE_CONCURRENCY = YES). Build and
# run the same tests that way too, so a type that forgot `nonisolated` shows up here and not
# as a hang or a crash in the app.
echo ""
echo "== built like the app (main-actor default isolation) =="
swiftc \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    "${SOURCES[@]}" "${TEST_SOURCES[@]}" -o "$BUILD_DIR/connectors_tests_main_actor"
"$BUILD_DIR/connectors_tests_main_actor"
