//
//  BrainMemorySection.swift
//  leanring-buddy
//
//  Home tab section for Teachy's memory: how much is remembered, a way to open
//  the two plain-text files in the person's own editor, and "forget everything".
//  Self-contained — it only talks to `BrainStore.shared`.
//

import AppKit
import SwiftUI

struct BrainMemorySection: View {
    @State private var rememberedCount: Int = 0
    @State private var isConfirmingForgetEverything: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TeachySectionTitle(title: "Memory", detail: rememberedCountDetail)

            // The section's one group, as in System Settings: a heading, then
            // its rows in one rounded container with a divider between them.
            VStack(alignment: .leading, spacing: 0) {
                whereMemoryLivesRow
                    .padding(.vertical, 12)

                TeachyRule()

                forgetEverythingRow
                    .padding(.vertical, 11)
            }
            .teachyGroup()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshRememberedCount() }
        .onReceive(NotificationCenter.default.publisher(for: BrainStore.didChangeNotification)) { _ in
            refreshRememberedCount()
        }
    }

    /// Shown first in the group while memory is empty.
    private let nothingRememberedLine = "Nothing remembered yet. Tell Teachy how you like answers and it will stick."

    /// The count beside the section title. Nothing when memory is empty: the
    /// first line of the group says so instead.
    private var rememberedCountDetail: String? {
        switch rememberedCount {
        case 0: return nil
        case 1: return "1 thing remembered"
        default: return "\(rememberedCount) things remembered"
        }
    }

    /// What memory is made of, and the two files to open.
    private var whereMemoryLivesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if rememberedCount == 0 {
                    Text(nothingRememberedLine)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("It lives in two plain text files on this Mac. Open them to read, fix or delete anything — Teachy uses whatever they say.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                openFileButton(title: "Open PROFILE.md", file: .profile)
                openFileButton(title: "Open VOLATILE.md", file: .volatile)
            }
        }
    }

    /// The red action, the way a list ends with "Erase…" in System Settings;
    /// once pressed, the question that confirms it takes its place.
    @ViewBuilder
    private var forgetEverythingRow: some View {
        if isConfirmingForgetEverything {
            forgetEverythingConfirmation
        } else {
            Button("Forget everything…") {
                isConfirmingForgetEverything = true
            }
            .teachyLinkButton(color: DS.Colors.destructiveText, font: DS.Fonts.body)
        }
    }

    private func openFileButton(title: String, file: BrainFile) -> some View {
        Button(title) {
            // Make sure the file exists first so the editor never opens to an error.
            BrainStore.shared.ensureFilesExist()
            NSWorkspace.shared.open(BrainStore.shared.fileURL(for: file))
        }
        .teachyButton(.secondary, size: .compact)
    }

    private var forgetEverythingConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Erase both memory files and the saved conversation? This can't be undone.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Forget everything") {
                    BrainStore.shared.forgetEverything()
                    isConfirmingForgetEverything = false
                    refreshRememberedCount()
                }
                .teachyButton(.danger, size: .compact)

                Button("Keep it") {
                    isConfirmingForgetEverything = false
                }
                .teachyButton(.secondary, size: .compact)
            }
        }
    }

    private func refreshRememberedCount() {
        rememberedCount = BrainStore.shared.rememberedCount
    }
}
