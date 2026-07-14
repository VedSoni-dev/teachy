#!/bin/bash
# Copies the latest Xcode build to ~/Applications/Teachy.app so macOS permissions
# survive rebuilds (TCC is tied to bundle path + signing identity).
set -euo pipefail

if [ "${CONFIGURATION:-}" = "Release" ] || [ "${SKIP_DEV_INSTALL:-}" = "1" ]; then
  echo "install-dev: skipping (Release / SKIP_DEV_INSTALL)"
  exit 0
fi

INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="${INSTALL_DIR}/Teachy.app"
PRODUCT_NAME="${FULL_PRODUCT_NAME:-Teachy.app}"
BUILT_APP="${BUILT_PRODUCTS_DIR:-}/${PRODUCT_NAME}"

if [ ! -d "$BUILT_APP" ]; then
  # Allow running outside Xcode by locating the most recent DerivedData build.
  BUILT_APP="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/Teachy.app' -type d 2>/dev/null | grep -v Index.noindex | head -1 || true)"
fi

if [ -z "$BUILT_APP" ] || [ ! -d "$BUILT_APP" ]; then
  echo "warning: install-dev: Teachy.app not found — skipping install to ~/Applications"
  if [ -n "${RUNNING_FROM_XCODE_BUILD:-}" ]; then
    exit 0
  fi
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP"
if ! ditto "$BUILT_APP" "$INSTALL_APP"; then
  echo "warning: install-dev: ditto failed — build succeeded but ~/Applications install was skipped"
  if [ -n "${RUNNING_FROM_XCODE_BUILD:-}" ]; then
    exit 0
  fi
  exit 1
fi

echo "Installed ${BUILT_APP} -> ${INSTALL_APP}"

if [ "${1:-}" = "--open" ] || [ "${INSTALL_CLICKY_AFTER_BUILD:-}" = "1" ]; then
  osascript -e 'quit app "Teachy"' 2>/dev/null || true
  sleep 0.4
  open "$INSTALL_APP"
  echo "Launched ${INSTALL_APP}"
fi
