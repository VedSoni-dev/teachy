//
//  CourseInteractiveChoiceWidgetView.swift
//  leanring-buddy
//
//  Inline multiple-choice lesson step — first proof of the "interactive widget"
//  architecture. Shared by both lesson-rendering surfaces (the floating HUD and
//  the in-panel Courses tab) so the interaction only has to be built once.
//

import SwiftUI

/// Renders a `CourseInteractiveMultipleChoice` question with tappable option rows.
/// Once an option is tapped, rows become non-interactive, the correct answer is
/// highlighted, the wrong pick (if any) is marked, and a "Continue" button appears.
/// Tapping Continue calls `onSubmit` — callers wire this to
/// `companionManager.submitCourseInteractiveChoiceAnswer(_:)`, which resumes the
/// `LessonPlayer` continuation. This view never resumes anything itself.
struct CourseInteractiveChoiceWidgetView: View {
    let multipleChoice: CourseInteractiveMultipleChoice
    let onSubmit: (Int) -> Void

    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(multipleChoice.question)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(multipleChoice.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option)
                }
            }

            if let selectedIndex {
                feedbackBlock(selectedIndex: selectedIndex)

                Button {
                    onSubmit(selectedIndex)
                } label: {
                    Text("Continue")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.learnAccent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(14)
        .glassCard(tint: DS.Colors.learnAccent, prominent: true)
    }

    // MARK: - Option row

    @ViewBuilder
    private func optionRow(index: Int, option: String) -> some View {
        let isAnswered = selectedIndex != nil
        let isCorrectOption = index == multipleChoice.correctAnswerIndex
        let isSelectedOption = index == selectedIndex
        let isWrongSelection = isAnswered && isSelectedOption && !isCorrectOption

        Button {
            guard selectedIndex == nil else { return }
            selectedIndex = index
        } label: {
            HStack(spacing: 8) {
                Text(option)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if isAnswered && isCorrectOption {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Colors.success)
                } else if isWrongSelection {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Colors.destructiveText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFillColor(isCorrectOption: isCorrectOption, isWrongSelection: isWrongSelection, isAnswered: isAnswered))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(rowStrokeColor(isCorrectOption: isCorrectOption, isWrongSelection: isWrongSelection, isAnswered: isAnswered), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: !isAnswered)
        .disabled(isAnswered)
    }

    private func rowFillColor(isCorrectOption: Bool, isWrongSelection: Bool, isAnswered: Bool) -> Color {
        guard isAnswered else { return Color.white.opacity(0.1) }
        if isCorrectOption { return DS.Colors.success.opacity(0.16) }
        if isWrongSelection { return DS.Colors.destructive.opacity(0.16) }
        return Color.white.opacity(0.05)
    }

    private func rowStrokeColor(isCorrectOption: Bool, isWrongSelection: Bool, isAnswered: Bool) -> Color {
        guard isAnswered else { return DS.Colors.learnAccent.opacity(0.4) }
        if isCorrectOption { return DS.Colors.success.opacity(0.5) }
        if isWrongSelection { return DS.Colors.destructive.opacity(0.5) }
        return Color.white.opacity(0.12)
    }

    // MARK: - Feedback

    @ViewBuilder
    private func feedbackBlock(selectedIndex: Int) -> some View {
        let isCorrect = selectedIndex == multipleChoice.correctAnswerIndex
        VStack(alignment: .leading, spacing: 4) {
            Text(isCorrect ? "Correct!" : "Not quite.")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isCorrect ? DS.Colors.success : DS.Colors.destructiveText)

            if let explanation = multipleChoice.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
