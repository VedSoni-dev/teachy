#!/bin/sh
# Tests for the app side of the Chrome extension bridge (leanring-buddy/Browser):
# message framing, request/response pairing and timeouts, the risk classes the
# permission gate uses, the native-messaging manifest (the app's copy against
# scripts/install-chrome-host.sh), and the socket link driven for real against
# the built helper binary with the test playing Chrome.
#
# No app launch, no browser, nothing outside temp folders: the install script
# is only ever run with TEACHY_INSTALL_ROOT pointing into $TMPDIR.
#
# The extension's own tests (JavaScript, incl. a real headless Chromium run)
# are in chrome-extension/tests/run.sh.
set -e
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
WORK="${TMPDIR:-/tmp}/teachy-chrome"
mkdir -p "$WORK"

sh -n scripts/install-chrome-host.sh
sh -n native-host/build.sh
sh -n chrome-extension/tests/run.sh

TEACHY_HOST_BINARY="$(sh native-host/build.sh "$WORK/host" 2>"$WORK/host-build.log" | tail -n 1)" || {
  cat "$WORK/host-build.log" >&2
  echo "Could not build the helper." >&2
  exit 1
}
export TEACHY_HOST_BINARY
export TEACHY_REPO_ROOT="$REPO"
export TEACHY_TEST_SCRATCH="$WORK"

APP=leanring-buddy/Browser
SOURCES="$APP/BrowserWire.swift $APP/BrowserHostManifest.swift $APP/BrowserRisk.swift $APP/BrowserSocketServer.swift $APP/BrowserLink.swift scripts/tests/chrome/main.swift"

# shellcheck disable=SC2086
swiftc -o "$WORK/chrome-swift-tests" $SOURCES
"$WORK/chrome-swift-tests"

# The app compiles with "everything is on the main actor unless it says otherwise". Build and
# run the same tests that way too, so a type that forgot `nonisolated` shows up here.
echo ""
echo "== built like the app (main-actor default isolation) =="
# shellcheck disable=SC2086
swiftc -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -o "$WORK/chrome-swift-tests-main-actor" $SOURCES
"$WORK/chrome-swift-tests-main-actor"
