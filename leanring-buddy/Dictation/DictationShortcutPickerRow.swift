//
//  DictationShortcutPickerRow.swift
//  leanring-buddy
//
//  "Hold [key] [key] to dictate" with a Change button that records new keys.
//  Recording runs through the dictation event tap, so it works even though the
//  notch panel never becomes the key window.
//

import SwiftUI

struct DictationShortcutPickerRow: View {
    @State private var keyCodes: [UInt16] = DictationShortcut.current()
    @State private var isRecording = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isRecording {
                    // Teachy is listening for keys right now: the live mark.
                    TeachyStatusMark(kind: .live)
                    Text("Hold the keys you want, then let go…")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                } else {
                    Text("Hold")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    HStack(spacing: 4) {
                        ForEach(Array(keyCodes.enumerated()), id: \.offset) { _, keyCode in
                            KeyboardKeyLabel(text: PushToTalkShortcutKeys.displayName(forKeyCode: keyCode))
                        }
                    }
                    Text("to dictate")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                }

                Spacer(minLength: 8)

                Button(isRecording ? "Cancel" : "Change keys") {
                    if isRecording { DictationController.shared.cancelShortcutRecording() } else { startRecording() }
                }
                .teachyButton(.secondary, size: .compact)

                if !isRecording, keyCodes != DictationShortcut.defaultKeyCodes {
                    Button("Reset") {
                        DictationShortcut.reset()
                        keyCodes = DictationShortcut.current()
                        problem = nil
                    }
                    .teachyButton(.quiet, size: .compact)
                }
            }

            Text(problem ?? "Tap the same keys twice quickly for hands-free; twice again to stop. Escape cancels. If your keyboard has no fn key, pick your own keys here.")
                .font(DS.Fonts.caption)
                .foregroundColor(problem == nil ? DS.Colors.textSecondary : DS.Colors.warningText)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear {
            if isRecording { DictationController.shared.cancelShortcutRecording() }
        }
    }

    private func startRecording() {
        problem = nil
        isRecording = true
        DictationController.shared.recordShortcut { result in
            isRecording = false
            switch result {
            case .saved(let newKeyCodes):
                keyCodes = newKeyCodes
            case .cancelled:
                break
            case .rejected(let message):
                problem = message
            }
        }
    }
}
