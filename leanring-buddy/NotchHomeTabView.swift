//
//  NotchHomeTabView.swift
//  leanring-buddy
//
//  Home tab content for the notch panel — push-to-talk instructions, trust
//  copy, software updates, cursor color, model picker, and feedback link.
//

import SwiftUI

struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var softwareUpdater = TeachySoftwareUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pushToTalkInstructions

            trustAndPrivacySection

            softwareUpdatesSection

            cursorColorSection

            modeAndModelSection

            watchIntroAgainButton

            dmFeedbackButton
        }
    }

    private var pushToTalkInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Hold")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                KeyboardKeyLabel(text: "control")
                Text("+")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                KeyboardKeyLabel(text: "option")
                Text("to talk")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Text("Ask about your screen, or talk during a course for hints and help.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Double-tap Control for text mode.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var trustAndPrivacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trust & privacy")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Teachy is free by design. Screen captures and voice go to your configured Teachy proxy so the tutor can see what you’re doing — only for the turn you’re in. Course memory stays on this Mac. You can wipe progress anytime by Retaking a path.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("We don’t sell your screen. No subscription funnel.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.learnAccent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: DS.Colors.learnAccent)
    }

    private var softwareUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Teachy \(softwareUpdater.shortVersionString) (\(softwareUpdater.buildNumberString)) — free updates via GitHub Releases.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                softwareUpdater.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Check for Updates…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!softwareUpdater.canCheckForUpdates)
            .opacity(softwareUpdater.canCheckForUpdates ? 1 : 0.45)
            .pointerCursor(isEnabled: softwareUpdater.canCheckForUpdates)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var watchIntroAgainButton: some View {
        Button {
            companionManager.replayOnboarding()
            notchManager.collapse()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 11))
                Text("Watch demo again")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var cursorColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cursor color")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            HStack(spacing: 8) {
                ForEach(ClickyCursorColor.allCases) { cursorColor in
                    cursorColorOptionButton(cursorColor: cursorColor)
                }
            }
        }
    }

    private func cursorColorOptionButton(cursorColor: ClickyCursorColor) -> some View {
        let isSelected = companionManager.selectedCursorColor == cursorColor
        return Button(action: {
            companionManager.setSelectedCursorColor(cursorColor)
        }) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .overlay {
                    ZStack {
                        Triangle()
                            .fill(cursorColor.displayColor)
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-35))
                            .blur(radius: 12)
                            .opacity(isSelected ? 0.55 : 0.2)
                            .scaleEffect(1.8)

                        Triangle()
                            .fill(cursorColor.displayColor)
                            .frame(width: 14, height: 14)
                            .rotationEffect(.degrees(-35))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected ? cursorColor.displayColor : Color.white.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .shadow(
                    color: isSelected ? cursorColor.displayColor.opacity(0.35) : .clear,
                    radius: 8,
                    x: 0,
                    y: 2
                )
                .scaleEffect(isSelected ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var modeAndModelSection: some View {
        openRouterModelPickerRow(
            title: "Tutor model",
            models: OpenRouterModelOption.models,
            selectedModelID: companionManager.selectedModel
        ) { modelID in
            companionManager.setSelectedModel(modelID)
        }
    }

    private var dmFeedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/VedSoni-dev/teachy/issues") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                Text("Give feedback")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
