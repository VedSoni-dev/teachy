//
//  NotchPanelSharedComponents.swift
//  leanring-buddy
//
//  Small views/helpers shared across the notch panel tab
//  files (Home, Setup/Onboarding).
//

import SwiftUI

// MARK: - OpenRouter Model Picker Row

/// Pure model-picker row — takes all state as parameters so it has no
/// captured state and can be shared across tab files.
func openRouterModelPickerRow(
    title: String,
    models: [OpenRouterModelOption],
    selectedModelID: String,
    onSelect: @escaping (String) -> Void
) -> some View {
    let selectedOption = models.first(where: { $0.id == selectedModelID }) ?? models[0]

    return HStack {
        Text(title)
            .font(DS.Fonts.bodyEmphasized)
            .foregroundColor(DS.Colors.textPrimary)
        Spacer()
        Menu {
            ForEach(models) { model in
                Button(action: { onSelect(model.id) }) {
                    HStack {
                        Text(model.displayName)
                        if model.id == selectedModelID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(selectedOption.displayName)
                        .font(DS.Fonts.controlCompact)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(selectedOption.subtitle)
                        .font(DS.Fonts.mono(10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(DS.Fonts.sans(9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .teachyOption(isSelected: false)
        }
        .menuStyle(.borderlessButton)
        .pointerCursor()
    }
}
