#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
binary="$(mktemp -d "${TMPDIR:-/tmp}/teachy-agent-rail.XXXXXX")"
trap 'rm -rf "$binary"' EXIT
app="$root/leanring-buddy"
swiftc -swift-version 5 -default-isolation MainActor -o "$binary/test" \
    "$app/DesignSystem.swift" "$app/Agent/AgentJobModel.swift" \
    "$app/Agent/AgentJobCardView.swift" "$app/Agent/AgentSideRail.swift" \
    "$root/scripts/tests/agent_side_rail/main.swift"
"$binary/test" "${1:-${TMPDIR:-/tmp}/teachy-agent-rail.png}"
