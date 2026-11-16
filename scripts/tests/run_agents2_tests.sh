#!/bin/bash
# Unit tests for concurrent jobs, job history, compaction, named agents, routines,
# the unattended consent rule, the connector catalog and the agent loop itself
# (driven by a scripted model and stub tools). No app, no network, no Keychain,
# and nothing touches the real ~/.teachy: every file lives in a temp directory.
# Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teachy-agents2-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$REPO_ROOT/leanring-buddy"

# Connectors: everything except the SwiftUI card and the Keychain store.
CONNECTOR_SOURCES=()
for source_file in "$APP"/Connectors/*.swift; do
    case "$(basename "$source_file")" in
        ConnectorsSection.swift|McpKeychainSecretStore.swift) ;;
        *) CONNECTOR_SOURCES+=("$source_file") ;;
    esac
done

SOURCES=(
    "$APP/Agent/ToolPolicy.swift"
    "$APP/Browser/BrowserRisk.swift"
    "$APP/Agent/Drive/AXSnapshotModel.swift"
    "$APP/Agent/ConsentLedger.swift"
    "$APP/Agent/AgentJobModel.swift"
    "$APP/Agent/AgentConcurrency.swift"
    "$APP/Agent/AgentHistory.swift"
    "$APP/Agent/AgentCompaction.swift"
    "$APP/Agent/AgentRoster.swift"
    "$APP/Agent/AgentLoop.swift"
    "$APP/Agent/Routines/RoutineSchedule.swift"
    "$APP/Agent/Routines/RoutineStore.swift"
    "$APP/Brain/BrainMarkdown.swift"
    "$APP/Core/StreamingSpeechSegmenter.swift"
    "${CONNECTOR_SOURCES[@]}"
    "$REPO_ROOT/scripts/tests/connectors/BackgroundAgentToolStub.swift"
    "$REPO_ROOT/scripts/tests/agents2/main.swift"
)

echo "== plain build =="
swiftc "${SOURCES[@]}" -o "$BUILD_DIR/agents2_tests"
"$BUILD_DIR/agents2_tests"

# The app compiles with "everything is on the main actor unless it says otherwise".
# Build and run the same tests that way too, so a type that forgot `nonisolated`
# shows up here and not in the app.
echo ""
echo "== built like the app (main-actor default isolation) =="
swiftc \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    "${SOURCES[@]}" -o "$BUILD_DIR/agents2_tests_main_actor"
"$BUILD_DIR/agents2_tests_main_actor"
