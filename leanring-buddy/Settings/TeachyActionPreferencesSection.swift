//
//  TeachyActionPreferencesSection.swift
//  leanring-buddy
//
//  Settings → Agents, top: how Teachy does things for you. Where web work
//  happens (your Chrome, Teachy's own background browser, your screen, or
//  let Teachy choose) and whether jobs may take your mouse. Read by every
//  agent job through `TeachyActionPreferences`.
//

import SwiftUI

struct TeachyActionPreferencesSection: View {
    @ObservedObject private var settings = TeachySettings.shared

    var body: some View {
        SettingsPageGroup(title: "How Teachy does things") {
            SettingsPageLabel(title: "Websites", caption: "Where jobs open pages, click and fill things in.")
            VStack(spacing: 6) {
                ForEach(TeachyWebControlPreference.allCases) { preference in
                    optionRow(
                        title: preference.title,
                        detail: preference.detail,
                        isSelected: settings.webControlPreference == preference
                    ) {
                        settings.webControlPreference = preference
                    }
                }
            }

            TeachyRule()

            HStack(alignment: .top, spacing: 12) {
                SettingsPageLabel(title: "Your mouse and keyboard", caption: settings.pointerControlPreference.detail)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    ForEach(TeachyPointerControlPreference.allCases) { preference in
                        let isSelected = settings.pointerControlPreference == preference
                        Button {
                            settings.pointerControlPreference = preference
                        } label: {
                            Text(preference.title)
                                .font(DS.Fonts.controlCompact)
                                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .teachyOption(isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }

            TeachyRule()

            Text("When you correct Teachy (\"use my Chrome for YouTube\"), it remembers that habit under How I like things done in Memory, and the habit wins over these settings for that site.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(title: String, detail: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Fonts.body)
                    .foregroundColor(isSelected ? DS.Colors.pointer : DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(detail)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .teachyOption(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
