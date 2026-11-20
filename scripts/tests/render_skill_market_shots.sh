#!/bin/sh
# Renders the Skills Library and Settings → Skills (the real views) to PNGs in
# $TMPDIR/teachy-skill-market-shots/, from a temp skills folder and the repo's local
# Skill Market index. No network, no Teachy launch, ~/.teachy untouched.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-skill-market-shots-bin"
APP=leanring-buddy
# The settings containers are pulled out of their real files (those files need half the app to compile).
SHARED="${TMPDIR:-/tmp}/teachy-skill-market-shared.swift"
{
  echo "import SwiftUI"
  for name in SettingsPageGroup SettingsPageHeading SettingsPageLabel; do
    awk "/^struct $name[<:]/,/^}/" "$APP/Settings/SettingsSections.swift"
  done
  awk '/^struct FlowLayout:/,/^}/' "$APP/NotchPanelSharedComponents.swift"
  awk '/^private struct LayoutResult/,/^}/' "$APP/NotchPanelSharedComponents.swift"
} > "$SHARED"
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/Settings/TeachySettingsPage.swift" \
  "$APP/Skills/SkillLibrary.swift" \
  "$APP/Skills/SkillMarket.swift" \
  "$APP/Skills/SkillStore.swift" \
  "$APP/Skills/SkillsLibraryView.swift" \
  "$APP/Skills/SkillsLibraryWindowController.swift" \
  "$APP/Settings/TeachySkillsSettingsPage.swift" \
  "$SHARED" \
  scripts/tests/skill_market_shots/main.swift
"$OUT" "$(pwd)"
