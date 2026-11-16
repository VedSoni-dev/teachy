#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/teachy-notch-hover.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
  leanring-buddy/NotchPanelTab.swift \
  leanring-buddy/ClickyNotchSizing.swift \
  leanring-buddy/NotchScreenGeometry.swift \
  leanring-buddy/NotchWindowManager.swift \
  scripts/tests/notch_hover/main.swift -o "$OUT/tests"
"$OUT/tests"
