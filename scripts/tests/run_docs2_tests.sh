#!/bin/sh
# Unit tests for documents, attachments and the chat thread: chunking and
# retrieval ranking, budget assembly, PDF reading (incl. a scanned page), CSV
# preview, other file kinds, size limits, the "is this about the current
# document" classifier, the attachment cap, and timeline persistence.
# Uses temp directories only. No app, no network.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/teachy-docs2-tests"
APP=leanring-buddy
swiftc -swift-version 5 -default-isolation MainActor -o "$OUT" \
  "$APP/DesignSystem.swift" \
  "$APP/Documents/DocumentModel.swift" \
  "$APP/Documents/DocumentTextTools.swift" \
  "$APP/Documents/DocumentRetrieval.swift" \
  "$APP/Documents/DocumentContext.swift" \
  "$APP/Documents/DocumentQuestionClassifier.swift" \
  "$APP/Documents/DocumentReader.swift" \
  "$APP/Documents/AttachmentShelf.swift" \
  "$APP/ChatWindow/ChatTimelineModel.swift" \
  scripts/tests/docs2/Fixtures.swift \
  scripts/tests/docs2/main.swift
"$OUT"
