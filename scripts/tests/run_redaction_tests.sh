#!/bin/bash
# redact_image rules and one synthetic Vision + Core Image run. Never reads user files.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O leanring-buddy/Agent/ImageRedactionTool.swift scripts/tests/redaction/stubs.swift scripts/tests/redaction/main.swift -o "$OUT/checks"
"$OUT/checks" "$OUT"
