#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
TEST_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/teachy-publik-session.XXXXXX")
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
  leanring-buddy/TeachyPublikSession.swift scripts/tests/publik_session/main.swift \
  -o "$TEST_DIRECTORY/tests"
"$TEST_DIRECTORY/tests"
