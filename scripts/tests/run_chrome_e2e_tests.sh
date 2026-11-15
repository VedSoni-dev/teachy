#!/bin/sh
# End to end from the app's side: the real agent browser tools and BrowserBridge, the real
# helper binary, and the real extension in a headless Chromium with a brand-new temp profile,
# against HTML fixtures on a local web server. Only the agent job types are stand-ins.
#
# Needs node and a Chromium that can load an unpacked extension (Playwright's cache, or
# TEACHY_TEST_CHROME=/path/to/chromium). Without one it says SKIPPED and exits 0.
# Nothing touches the real ~/Library/Application Support or a real browser profile.
set -e
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
WORK="${TMPDIR:-/tmp}/teachy-chrome"
mkdir -p "$WORK"

TEACHY_HOST_BINARY="$(sh native-host/build.sh "$WORK/host" 2>"$WORK/host-build.log" | tail -n 1)" || {
  cat "$WORK/host-build.log" >&2
  echo "Could not build the helper." >&2
  exit 1
}
export TEACHY_HOST_BINARY
export TEACHY_REPO_ROOT="$REPO"
export TEACHY_TEST_SCRATCH="$WORK"

APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$WORK/chrome-e2e" \
  "$APP/BackgroundAgentTool.swift" \
  "$APP/AgentToolResult.swift" \
  "$APP/Agent/ShellRunner.swift" \
  "$APP/Browser/BrowserWire.swift" \
  "$APP/Browser/BrowserHostManifest.swift" \
  "$APP/Browser/BrowserRisk.swift" \
  "$APP/Browser/BrowserSocketServer.swift" \
  "$APP/Browser/BrowserLink.swift" \
  "$APP/Browser/BrowserBridge.swift" \
  "$APP/Browser/BrowserAgentTools.swift" \
  scripts/tests/chrome_e2e/stubs.swift \
  scripts/tests/chrome_e2e/main.swift
"$WORK/chrome-e2e"
