//
//  NotchPanelSharedComponents.swift
//  leanring-buddy
//
//  Small, dependency-free views/helpers shared across the notch panel tab
//  files (Home, Setup/Onboarding).
//

import SwiftUI

// MARK: - Keyboard Key Label

struct KeyboardKeyLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

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
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(selectedOption.subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .pointerCursor()
    }
}

// MARK: - FlowLayout (wrapping horizontal stack)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return LayoutResult(
            size: CGSize(width: maxWidth, height: currentY + lineHeight),
            positions: positions
        )
    }
}

private struct LayoutResult {
    let size: CGSize
    let positions: [CGPoint]
}
