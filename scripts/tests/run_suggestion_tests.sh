#!/bin/bash
# Suggestion rules (pure, no network, no user data).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O leanring-buddy/Suggestions/TeachySuggestion.swift scripts/tests/suggestions/main.swift -o "$OUT/checks"
"$OUT/checks"
