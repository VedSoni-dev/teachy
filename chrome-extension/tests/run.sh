#!/bin/sh
# Tests for the Teachy browser extension and its native-messaging helper.
#
#   chrome-extension/tests/run.sh            everything
#   chrome-extension/tests/run.sh unit       pure modules only (no browser, no helper)
#   chrome-extension/tests/run.sh host       the built helper against a fake app and a fake Chrome
#   chrome-extension/tests/run.sh smoke      the real extension in a headless Chromium (skipped if none is found)
#
# Nothing here touches a real browser profile or the real NativeMessagingHosts
# folders: the helper is built into a temp folder, the socket lives in a temp
# folder, and Chromium runs with a brand-new --user-data-dir there too.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WHAT="${1:-all}"
WORK="${TMPDIR:-/tmp}/teachy-chrome"
mkdir -p "$WORK"

if [ "$WHAT" != "unit" ]; then
  TEACHY_HOST_BINARY="$(sh "$REPO/native-host/build.sh" "$WORK/host" 2>"$WORK/host-build.log" | tail -n 1)" || {
    cat "$WORK/host-build.log" >&2
    echo "Could not build the helper." >&2
    exit 1
  }
  export TEACHY_HOST_BINARY
fi

case "$WHAT" in
  unit)  node --test "$HERE/unit.test.js" ;;
  host)  node --test "$HERE/host.test.js" ;;
  smoke) node --test "$HERE/smoke.test.js" ;;
  all)   node --test "$HERE/unit.test.js" "$HERE/host.test.js" "$HERE/smoke.test.js" ;;
  *)     echo "usage: $0 [unit|host|smoke|all]" >&2; exit 2 ;;
esac
