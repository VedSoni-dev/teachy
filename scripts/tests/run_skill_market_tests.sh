#!/bin/sh
# Unit tests for the Skill Market (pure logic, temp folder, no network): listing IDs,
# index decoding, file validation, install / update state / remove, teachy://skill links,
# and a check that every listing in academy/skillmarket/index.json installs cleanly.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-skill-market-tests"
swiftc -o "$OUT" \
  leanring-buddy/Skills/SkillLibrary.swift \
  leanring-buddy/Skills/SkillMarket.swift \
  scripts/tests/skill_market/main.swift
"$OUT" "$(pwd)/academy/skillmarket"
if command -v node >/dev/null 2>&1; then node scripts/build-skillmarket.mjs --check; fi
