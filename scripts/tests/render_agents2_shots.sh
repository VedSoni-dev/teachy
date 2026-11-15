#!/bin/bash
# Renders the job cards, the Home tab's agents cards and the connectors "Popular"
# strip to PNGs in $TMPDIR/agents2-shots/, without launching Teachy, showing
# anything on screen or reading ~/.teachy. Exits non-zero on failure.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$REPO_ROOT/leanring-buddy"
OUT="${TMPDIR:-/tmp}/teachy-agents2-shots"

# Connectors: everything (the card file holds the Popular strip).
CONNECTOR_SOURCES=("$APP"/Connectors/*.swift)

swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/TeachyDataPaths.swift" \
  "$APP/Agent/AgentJobModel.swift" \
  "$APP/Agent/AgentJobCardView.swift" \
  "$APP/Agent/AgentsSectionContent.swift" \
  "$APP/Agent/AgentRoster.swift" \
  "$APP/Agent/AgentCompaction.swift" \
  "$APP/Agent/AgentHistory.swift" \
  "$APP/Agent/Routines/RoutineSchedule.swift" \
  "$APP/Agent/Routines/RoutineStore.swift" \
  "$APP/Brain/BrainMarkdown.swift" \
  "${CONNECTOR_SOURCES[@]}" \
  "$REPO_ROOT/scripts/tests/connectors/BackgroundAgentToolStub.swift" \
  "$REPO_ROOT/scripts/tests/agents2_shots/main.swift" 2>&1 | grep -E 'error' || true
"$OUT"
