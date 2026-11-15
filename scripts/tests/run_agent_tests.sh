#!/bin/sh
# Unit tests for the agent's pure logic: the permission policy (incl. shell
# command reading), consent bookkeeping, Drive coordinate maths, accessibility
# snapshot text + diff, job budget, speech formatting, and the shell runner.
# No app, no network, no Accessibility needed.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-agent-tests"
swiftc -o "$OUT" \
  leanring-buddy/Agent/ToolPolicy.swift \
  leanring-buddy/Browser/BrowserRisk.swift \
  leanring-buddy/Agent/ConsentLedger.swift \
  leanring-buddy/Agent/AgentJobModel.swift \
  leanring-buddy/Agent/ShellRunner.swift \
  leanring-buddy/Agent/Drive/DriveCoordinates.swift \
  leanring-buddy/Agent/Drive/AXSnapshotModel.swift \
  scripts/tests/agent/main.swift
"$OUT"
