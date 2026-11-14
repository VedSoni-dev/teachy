//
//  BrainMemorySection.swift
//  leanring-buddy
//
//  Home tab card for Teachy's memory: how much is remembered, a way to open
//  the two plain-text files in the person's own editor, and "forget everything".
//  Self-contained — it only talks to `BrainStore.shared`.
//

import AppKit
import SwiftUI

struct BrainMemorySection: View {
    @State private var rememberedCount: Int = 0
    @State private var isConfirmingForgetEverything: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(summaryLine)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("It lives in two plain text files on this Mac. Open them to read, fix or delete anything — Teachy uses whatever they say.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                openFileButton(title: "Open PROFILE.md", file: .profile)
                openFileButton(title: "Open VOLATILE.md", file: .volatile)
            }

            if isConfirmingForgetEverything {
                forgetEverythingConfirmation
            } else {
                Button {
                    isConfirmingForgetEverything = true
                } label: {
                    Text("Forget everything…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .onAppear { refreshRememberedCount() }
        .onReceive(NotificationCenter.default.publisher(for: BrainStore.didChangeNotification)) { _ in
            refreshRememberedCount()
        }
    }

    private var summaryLine: String {
        switch rememberedCount {
        case 0: return "Nothing remembered yet. Tell Teachy how you like answers and it will stick."
        case 1: return "1 thing remembered."
        default: return "\(rememberedCount) things remembered."
        }
    }

    private func openFileButton(title: String, file: BrainFile) -> some View {
        Button {
            // Make sure the file exists first so the editor never opens to an error.
            BrainStore.shared.ensureFilesExist()
            NSWorkspace.shared.open(BrainStore.shared.fileURL(for: file))
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var forgetEverythingConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Erase both memory files and the saved conversation? This can't be undone.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    BrainStore.shared.forgetEverything()
                    isConfirmingForgetEverything = false
                    refreshRememberedCount()
                } label: {
                    Text("Forget everything")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.destructive))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button {
                    isConfirmingForgetEverything = false
                } label: {
                    Text("Keep it")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func refreshRememberedCount() {
        rememberedCount = BrainStore.shared.rememberedCount
    }
}
