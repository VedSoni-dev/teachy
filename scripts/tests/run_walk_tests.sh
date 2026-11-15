#!/bin/sh
# Unit tests for walkthroughs and app skills (pure logic, no app, no network,
# no Accessibility): the walkthrough state machine, target matching against
# synthetic accessibility snapshots, plan JSON validation and the repair retry,
# saving and resuming, voice commands, skill front matter, bundle/site matching,
# the budgeted prompt section, and a check of every skill file in skills/.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-walk-tests"
swiftc -o "$OUT" \
  leanring-buddy/Agent/Drive/AXSnapshotModel.swift \
  leanring-buddy/Walkthrough/WalkthroughModel.swift \
  leanring-buddy/Walkthrough/WalkthroughTargetMatcher.swift \
  leanring-buddy/Walkthrough/WalkthroughPlan.swift \
  leanring-buddy/Walkthrough/WalkthroughEngine.swift \
  leanring-buddy/Walkthrough/WalkthroughAI.swift \
  leanring-buddy/Skills/SkillLibrary.swift \
  scripts/tests/walk/main.swift
"$OUT" "$(pwd)/skills"
