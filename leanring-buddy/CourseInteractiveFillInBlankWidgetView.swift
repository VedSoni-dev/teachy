//
//  CourseInteractiveFillInBlankWidgetView.swift
//  leanring-buddy
//
//  Inline fill-in-the-blank lesson step — sibling of
//  `CourseInteractiveChoiceWidgetView`. Local exact-match verification
//  (trimmed/lowercased) for instant UI feedback; the same normalization is
//  mirrored in `LessonPlayer.runInteractiveFillInBlankStep` for the authoritative
//  pass/fail signal fed into the learner model. Shared by both lesson-rendering
//  surfaces (the floating HUD and the in-panel Courses tab).
//

import SwiftUI

/// Renders a `CourseInteractiveFillInBlank` question with a text field, a "Check"
/// button, correct/incorrect feedback, and a "Continue" button. Tapping Continue
/// calls `onSubmit` — callers wire this to
/// `companionManager.submitCourseInteractiveFillInBlankAnswer(_:)`, which resumes
/// the `LessonPlayer` continuation. This view never resumes anything itself.
struct CourseInteractiveFillInBlankWidgetView: View {
    let fillInBlank: CourseInteractiveFillInBlank
    let onSubmit: (String) -> Void

    @State private var answerText: String = ""
    @State private var isRevealed: Bool = false
    @State private var wasCorrect: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fillInBlank.prompt)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Type your answer…", text: $answerText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(8)
                .disabled(isRevealed)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DS.Colors.learnAccent.opacity(0.3), lineWidth: 1)
                        )
                )

            if isRevealed {
                feedbackBlock

                Button {
                    onSubmit(answerText)
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
            } else {
                Button {
                    checkAnswer()
                } label: {
                    Text("Check")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.learnAccent))
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .glassCard(tint: DS.Colors.learnAccent, prominent: true)
    }

    // MARK: - Verification

    /// Same trim/lowercase exact-match normalization as
    /// `LessonPlayer.runInteractiveFillInBlankStep` — instant UI feedback here,
    /// authoritative pass/fail signal there.
    private func checkAnswer() {
        let normalizedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        wasCorrect = fillInBlank.acceptableAnswers.contains { acceptable in
            acceptable.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedAnswer
        }
        isRevealed = true
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: wasCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(wasCorrect ? DS.Colors.success : DS.Colors.destructiveText)

                Text(wasCorrect ? "Correct!" : "Not quite.")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(wasCorrect ? DS.Colors.success : DS.Colors.destructiveText)
            }

            if let explanation = fillInBlank.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
