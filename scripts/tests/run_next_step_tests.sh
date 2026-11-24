#!/bin/bash
# Next-step chip rules (pure).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O leanring-buddy/Core/NextSteps.swift scripts/tests/next_steps/main.swift -o "$OUT/checks"
"$OUT/checks"
