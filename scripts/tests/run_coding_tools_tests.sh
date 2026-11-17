#!/bin/sh
# Unit tests for the agent's coding tools: line-numbered reading, exact-string
# edits, the diff snippet, glob matching, search command building and output
# shaping, project detection from a request, the project prompt section, and
# the permission policy for read_file / edit_file / grep / glob /
# list_directory / bash working folders. No app, no network, no real ~/ files.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-coding-tools-tests"
swiftc -default-isolation MainActor -o "$OUT" \
  leanring-buddy/Agent/ToolPolicy.swift \
  leanring-buddy/Agent/Drive/AXSnapshotModel.swift \
  leanring-buddy/Browser/BrowserRisk.swift \
  leanring-buddy/Agent/Coding/CodingToolSupport.swift \
  scripts/tests/coding_tools/main.swift
"$OUT"
