//
//  CourseInteractiveChecklistWidgetView.swift
//  leanring-buddy
//
//  Inline self-attested checklist lesson step — sibling of
//  `CourseInteractiveChoiceWidgetView`. No right/wrong concept: checking items is
//  a memory aid, not a gate, so "Done" always advances regardless of what (if
//  anything) got checked. Shared by both lesson-rendering surfaces (the floating
//  HUD and the in-panel Courses tab).
//

import SwiftUI

/// Renders a `CourseInteractiveChecklist` as tappable self-check rows plus a
/// "Done" button. Tapping Done calls `onSubmit` — callers wire this to
/// `companionManager.submitCourseInteractiveChecklistCompletion(_:)`, which resumes
/// the `LessonPlayer` continuation. This view never resumes anything itself.
struct CourseInteractiveChecklistWidgetView: View {
    let checklist: CourseInteractiveChecklist
    let onSubmit: (Bool) -> Void

    @State private var checkedItemIndexes: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(checklist.prompt)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(checklist.items.enumerated()), id: \.offset) { index, item in
                    checklistRow(index: index, item: item)
                }
            }

            Button {
                onSubmit(true)
            } label: {
                Text("Done")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.black.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.learnAccent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(14)
        .glassCard(tint: DS.Colors.learnAccent, prominent: true)
    }

    // MARK: - Checklist row

    private func checklistRow(index: Int, item: String) -> some View {
        let isChecked = checkedItemIndexes.contains(index)

        return Button {
            if isChecked {
                checkedItemIndexes.remove(index)
            } else {
                checkedItemIndexes.insert(index)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isChecked ? DS.Colors.learnAccent : DS.Colors.textTertiary)

                Text(item)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .strikethrough(isChecked, color: DS.Colors.textTertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isChecked ? DS.Colors.learnAccent.opacity(0.12) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isChecked ? DS.Colors.learnAccent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
