#!/bin/sh
# Builds the Chrome native-messaging host and prints the path of the binary.
#   native-host/build.sh [output-directory]
# Default output: native-host/.build/out/teachy-browser-host
# Uses SwiftPM; if that fails (odd toolchain, locked cache) it compiles the
# single source file with swiftc directly.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$HERE/.build/out}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/teachy-browser-host"

if (cd "$HERE" && swift build -c release >&2); then
  BIN_DIR="$(cd "$HERE" && swift build -c release --show-bin-path)"
  cp "$BIN_DIR/teachy-browser-host" "$OUT"
else
  echo "swift build failed; compiling with swiftc" >&2
  swiftc -O -o "$OUT" "$HERE/Sources/teachy-browser-host/main.swift" >&2
fi
chmod 755 "$OUT"
echo "$OUT"
