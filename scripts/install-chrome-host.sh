#!/bin/sh
# Installs the Teachy browser helper: the small program Chrome starts so the
# Teachy extension can talk to the Teachy app (Chrome "native messaging").
#
#   scripts/install-chrome-host.sh              build the helper, install it, write the manifests
#   scripts/install-chrome-host.sh --uninstall  remove the helper and the manifests
#   scripts/install-chrome-host.sh --print      print the manifest JSON and where it would go; change nothing
#
# What it writes, all under ~/Library/Application Support:
#   Teachy/browser-host/teachy-browser-host                      the helper
#   <browser>/NativeMessagingHosts/com.teachy.browser.json       one per browser:
#     Google/Chrome, Google/Chrome Beta, Microsoft Edge,
#     BraveSoftware/Brave-Browser, Arc/User Data, Vivaldi
#
# Environment (all optional):
#   TEACHY_HOST_BINARY    use this already-built helper instead of building one
#                         (the app passes the copy inside its bundle)
#   TEACHY_EXTENSION_IDS  space-separated extension ids allowed to start the helper.
#                         Default: the id of the unpacked extension in chrome-extension/.
#                         Add the Chrome Web Store id here once the extension is published.
#   TEACHY_INSTALL_ROOT   install under this folder instead of
#                         ~/Library/Application Support (used by the tests)
set -eu

HOST_NAME="com.teachy.browser"
# The id Chrome derives from the public "key" in chrome-extension/manifest.json.
DEFAULT_EXTENSION_ID="okfgkjagfedglgjgnfbcffnmopbgigem"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${TEACHY_INSTALL_ROOT:-$HOME/Library/Application Support}"
EXTENSION_IDS="${TEACHY_EXTENSION_IDS:-$DEFAULT_EXTENSION_ID}"
HOST_DIR="$ROOT/Teachy/browser-host"
HOST_PATH="$HOST_DIR/teachy-browser-host"
MODE="${1:-install}"

# One line per browser: the folder under Application Support that holds NativeMessagingHosts.
browser_dirs() {
  cat <<'LIST'
Google/Chrome
Google/Chrome Beta
Microsoft Edge
BraveSoftware/Brave-Browser
Arc/User Data
Vivaldi
LIST
}

json_escape() {
  # Backslash and double quote are the only characters a macOS path can carry that JSON minds.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Extension ids are 32 letters a-p. Anything else would let a stranger's id in through a typo.
check_extension_ids() {
  for id in $EXTENSION_IDS; do
    case "$id" in
      *[!a-p]*) echo "Not an extension id: $id" >&2; exit 2 ;;
    esac
    if [ "${#id}" -ne 32 ]; then
      echo "Not an extension id (needs 32 letters): $id" >&2
      exit 2
    fi
  done
}

manifest_json() {
  origins=""
  for id in $EXTENSION_IDS; do
    if [ -n "$origins" ]; then origins="$origins, "; fi
    origins="$origins\"chrome-extension://$id/\""
  done
  printf '{\n'
  printf '  "name": "%s",\n' "$HOST_NAME"
  printf '  "description": "Lets the Teachy extension talk to the Teachy app on this Mac.",\n'
  printf '  "path": "%s",\n' "$(json_escape "$HOST_PATH")"
  printf '  "type": "stdio",\n'
  printf '  "allowed_origins": [%s]\n' "$origins"
  printf '}\n'
}

check_extension_ids

case "$MODE" in
  --print)
    manifest_json
    browser_dirs | while IFS= read -r dir; do
      echo "would write: $ROOT/$dir/NativeMessagingHosts/$HOST_NAME.json"
    done
    exit 0
    ;;

  --uninstall)
    browser_dirs | while IFS= read -r dir; do
      target="$ROOT/$dir/NativeMessagingHosts/$HOST_NAME.json"
      if [ -f "$target" ]; then
        rm -f "$target"
        echo "removed: $target"
      fi
    done
    if [ -f "$HOST_PATH" ]; then
      rm -f "$HOST_PATH"
      rmdir "$HOST_DIR" 2>/dev/null || true
      echo "removed: $HOST_PATH"
    fi
    exit 0
    ;;

  install)
    ;;

  *)
    echo "usage: $0 [--uninstall | --print]" >&2
    exit 2
    ;;
esac

# 1. The helper itself.
if [ -n "${TEACHY_HOST_BINARY:-}" ]; then
  BUILT="$TEACHY_HOST_BINARY"
elif [ -x "$SCRIPT_DIR/teachy-browser-host" ]; then
  # Inside the app bundle the helper sits next to this script.
  BUILT="$SCRIPT_DIR/teachy-browser-host"
elif [ -f "$SCRIPT_DIR/../native-host/build.sh" ]; then
  BUILT="$(sh "$SCRIPT_DIR/../native-host/build.sh" | tail -n 1)"
else
  echo "No helper to install: set TEACHY_HOST_BINARY or run this from the Teachy repository." >&2
  exit 1
fi
if [ ! -f "$BUILT" ]; then
  echo "Helper not found at: $BUILT" >&2
  exit 1
fi

mkdir -p "$HOST_DIR"
chmod 700 "$ROOT/Teachy" 2>/dev/null || true
# Copy to a temporary name and rename, so a helper Chrome is running right now is never half-written.
cp "$BUILT" "$HOST_PATH.new"
chmod 755 "$HOST_PATH.new"
mv -f "$HOST_PATH.new" "$HOST_PATH"
echo "installed: $HOST_PATH"

# 2. One manifest per browser.
browser_dirs | while IFS= read -r dir; do
  target_dir="$ROOT/$dir/NativeMessagingHosts"
  mkdir -p "$target_dir"
  manifest_json > "$target_dir/$HOST_NAME.json.new"
  chmod 644 "$target_dir/$HOST_NAME.json.new"
  mv -f "$target_dir/$HOST_NAME.json.new" "$target_dir/$HOST_NAME.json"
  echo "wrote: $target_dir/$HOST_NAME.json"
done

echo "Done. Restart the browser, or click the Teachy icon in its toolbar, so it finds the helper."
