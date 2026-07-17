//
//  NotchCustomCourseBuilderSheet.swift
//  leanring-buddy
//
//  Sheet for describing a custom course and generating a plan via the Teachy
//  proxy. Presented from NotchPanelView's .sheet(isPresented:).
//

import SwiftUI

struct NotchCustomCourseBuilderSheet: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.learnAccent)
                Text("Build Your Own Course")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button {
                    companionManager.showCustomCourseBuilder = false
                    companionManager.customCourseDescription = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Text("describe what you want to learn or build — teachy will create a course plan for you.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("e.g. build a portfolio website with React", text: $companionManager.customCourseDescription)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            Button {
                generateCustomCourse()
            } label: {
                HStack {
                    if companionManager.isGeneratingCustomCourse {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(companionManager.isGeneratingCustomCourse ? "Creating course..." : "Create Course")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.learnAccent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.customCourseDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || companionManager.isGeneratingCustomCourse)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func generateCustomCourse() {
        let description = companionManager.customCourseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }

        companionManager.isGeneratingCustomCourse = true

        Task {
            do {
                let apiClient = ClaudeAPI(
                    proxyURL: ClickyWorkerConfiguration.workerBaseURL,
                    model: "google/gemini-2.5-flash"
                )
                let course = try await companionManager.coursesManager.generateCustomCoursePlan(
                    description: description,
                    apiClient: apiClient
                )
                await MainActor.run {
                    companionManager.isGeneratingCustomCourse = false
                    companionManager.showCustomCourseBuilder = false
                    companionManager.customCourseDescription = ""
                    companionManager.coursesManager.addCustomCourse(course)
                    companionManager.startClickyCourse(courseID: course.id)
                }
            } catch {
                await MainActor.run {
                    companionManager.isGeneratingCustomCourse = false
                }
                print("⚠️ Custom course generation failed: \(error)")
            }
        }
    }
}
