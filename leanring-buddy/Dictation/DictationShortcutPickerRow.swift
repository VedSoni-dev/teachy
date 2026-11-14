//
//  DictationShortcutPickerRow.swift
//  leanring-buddy
//
//  "Hold [key] + [key] to dictate" with a Change button that records new keys.
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
                    Text("Hold the keys you want, then let go…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                } else {
                    Text("Hold")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    ForEach(Array(keyCodes.enumerated()), id: \.offset) { index, keyCode in
                        if index > 0 {
                            Text("+").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                        }
                        KeyboardKeyLabel(text: PushToTalkShortcutKeys.displayName(forKeyCode: keyCode))
                    }
                    Text("to dictate")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                Spacer(minLength: 8)

                Button(isRecording ? "Cancel" : "Change keys") {
                    if isRecording { DictationController.shared.cancelShortcutRecording() } else { startRecording() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .pointerCursor()

                if !isRecording, keyCodes != DictationShortcut.defaultKeyCodes {
                    Button("Reset") {
                        DictationShortcut.reset()
                        keyCodes = DictationShortcut.current()
                        problem = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .pointerCursor()
                }
            }

            Text(problem ?? "Tap the same keys twice quickly for hands-free; twice again to stop. Escape cancels. If your keyboard has no fn key, pick your own keys here.")
                .font(.system(size: 11))
                .foregroundColor(problem == nil ? DS.Colors.textTertiary : DS.Colors.warning)
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
