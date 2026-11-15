#!/bin/sh
# Renders the chat window (three sizes, plus search, streaming, thinking, empty
# and job states) and the attachment chips / drop highlight to PNGs in
# $TMPDIR/teachy-docs2/shots/, and checks the composer's Return handling, the
# window style, live updates and hotkey registration. Never launches Teachy and
# never shows a window. Exits non-zero on failure.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-docs2-shots"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/PushToTalkShortcutKeys.swift" \
  "$APP/Documents/DocumentModel.swift" \
  "$APP/Documents/DocumentTextTools.swift" \
  "$APP/Documents/DocumentRetrieval.swift" \
  "$APP/Documents/DocumentContext.swift" \
  "$APP/Documents/DocumentQuestionClassifier.swift" \
  "$APP/Documents/DocumentReader.swift" \
  "$APP/Documents/AttachmentShelf.swift" \
  "$APP/ChatWindow/ChatTimelineModel.swift" \
  "$APP/ChatWindow/ChatTimeline.swift" \
  "$APP/ChatWindow/ChatComposerTextView.swift" \
  "$APP/ChatWindow/ChatWindowView.swift" \
  "$APP/ChatWindow/ChatWindowController.swift" \
  scripts/tests/docs2_shots/main.swift \
  scripts/tests/docs2_shots/Stubs.swift
"$OUT"
