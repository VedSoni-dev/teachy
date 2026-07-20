//
//  NotchCoursesTabView.swift
//  leanring-buddy
//
//  Courses tab content for the notch panel — catalog, active course session,
//  Teachy Academy install/featured sections, and the custom course builder
//  entry point.
//

import SwiftUI

struct NotchCoursesTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @State private var courseInstallURLText: String = ""
    @State private var courseQuestionText: String = ""
    /// ID of the catalog row currently expanded to show its preview content.
    /// Only one row can be expanded at a time; tapping the same row again collapses it.
    @State private var expandedCourseID: String? = nil

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !companionManager.isBackendReachable {
                backendOfflineBanner
            }

            if let activeSession = companionManager.coursesManager.activeSession {
                activeCourseSessionCard(session: activeSession)
            } else {
                if let celebration = companionManager.coursesManager.completionCelebration {
                    courseCompletionCard(celebration)
                }
                projectsSection
                coursesCatalogIntroduction
                if let continueCourse = companionManager.coursesManager.continueCourse {
                    continueLearningCard(course: continueCourse)
                }
                coursesCatalogList

                academyFeaturedSection

                academyInstallSection

                if companionManager.coursesManager.preferSimplifiedCatalog {
                    Button {
                        companionManager.coursesManager.setPreferSimplifiedCatalog(false)
                    } label: {
                        Text("Show all paths")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .onAppear {
            companionManager.refreshBackendReachability()
        }
    }

    /// Durable build arcs (v2) — the things they're actually making, above the
    /// catalog because a build in progress beats browsing for a new one. Shipped
    /// projects render with their live URL as a small trophy row.
    @ViewBuilder
    private var projectsSection: some View {
        let engineProjects = companionManager.teachyEngine.state.projects
        let inProgressProjects = engineProjects.filter { $0.status == .active || $0.status == .paused }
        let shippedProjects = engineProjects.filter { $0.status == .shipped }

        if !inProgressProjects.isEmpty || !shippedProjects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR PROJECTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .kerning(0.8)

                ForEach(inProgressProjects) { project in
                    projectCard(project: project)
                }
                ForEach(shippedProjects.prefix(3)) { project in
                    shippedProjectRow(project: project)
                }
            }
        }
    }

    private func projectCard(project: TeachyProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.learnAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(project.steps.isEmpty
                        ? "Planning · last worked \(LearnerTemporalContext.relativeTimeLabel(for: project.lastWorkedAt))"
                        : "Step \(min(project.currentStepIndex + 1, project.steps.count)) of \(project.steps.count) · last worked \(LearnerTemporalContext.relativeTimeLabel(for: project.lastWorkedAt))")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer(minLength: 0)

                Button {
                    companionManager.submitSyntheticCompanionRequest(
                        "Let's keep going on my project \"\(project.title)\" — pick up where we left off."
                    )
                    notchManager.collapse()
                } label: {
                    Text("Resume")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.learnAccent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: DS.Colors.learnAccent, prominent: true)
    }

    private func shippedProjectRow(project: TeachyProject) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.success)

            Text(project.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let deployedURL = project.deployedURL, let url = URL(string: deployedURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 3) {
                        Text("Live")
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(DS.Colors.success)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 10, tint: DS.Colors.success)
    }

    private func courseCompletionCard(_ celebration: CourseCompletionCelebration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(DS.Colors.learnAccent)
                Text("You finished")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.learnAccent)
                Spacer()
                Button {
                    companionManager.coursesManager.dismissCompletionCelebration()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Text(celebration.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(celebration.message)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Recap
            Text(celebration.recap)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Next steps
            if !celebration.nextSteps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("what's next:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    ForEach(celebration.nextSteps, id: \.self) { step in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(DS.Colors.learnAccent)
                            Text(step)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(tint: DS.Colors.learnAccent, prominent: true)
    }

    private func continueLearningCard(course: ClickyCourse) -> some View {
        let resumeIndex = companionManager.coursesManager.resumeStepIndex(for: course)
        let label = resumeIndex > 0 ? "Continue" : "Start"

        return Button {
            companionManager.startClickyCourse(courseID: course.id)
            notchManager.collapse()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: course.iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.learnAccent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DS.Colors.learnAccent.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue learning")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                    Text(course.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(
                        resumeIndex > 0
                            ? "Goal \(resumeIndex + 1) of \(course.stepCount)"
                            : "~\(course.estimatedMinutes) min · \(course.stepCount) goals"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(DS.Colors.learnAccent))
            }
            .padding(12)
            .glassCard(tint: DS.Colors.learnAccent, prominent: true)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var academyInstallSection: some View {
        let coursesManager = companionManager.coursesManager

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Teachy Academy")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("Open site") {
                    companionManager.openTeachyAcademyWebsite()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .pointerCursor()
            }

            Text("Paste a course JSON URL (GitHub or raw). Free packs install into \(TeachyDataPaths.coursesDirectoryDisplayPath)/")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://github.com/…/course.json", text: $courseInstallURLText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                Button {
                    let urlString = courseInstallURLText
                    companionManager.installCourseFromURL(urlString)
                } label: {
                    if coursesManager.isInstallingCourse {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 52, height: 28)
                    } else {
                        Text("Add")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(
                    coursesManager.isInstallingCourse
                        || courseInstallURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let status = coursesManager.courseInstallStatusMessage, !status.isEmpty {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var academyFeaturedSection: some View {
        let coursesManager = companionManager.coursesManager
        if let registry = coursesManager.academyRegistry, !registry.courses.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("From the wall")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.3)
                    if coursesManager.isLoadingAcademyRegistry {
                        ProgressView().scaleEffect(0.5)
                    }
                }

                ForEach(registry.courses.prefix(4)) { featured in
                    academyFeaturedRow(featured)
                }
            }
        } else if coursesManager.isLoadingAcademyRegistry {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.55)
                Text("Loading academy…")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func academyFeaturedRow(_ featured: ClickyAcademyRegistryCourse) -> some View {
        let alreadyHave = companionManager.coursesManager.course(withID: featured.id) != nil
            || featured.isBundledWithApp

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(featured.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("\(featured.authorName) · \(featured.estimatedMinutes) min · \(featured.goalCount) goals")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(featured.blurb)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if alreadyHave {
                if featured.isBundledWithApp || companionManager.coursesManager.course(withID: featured.id) != nil {
                    Button("Start") {
                        companionManager.startClickyCourse(courseID: featured.id)
                        notchManager.collapse()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.accent))
                    .pointerCursor()
                    .disabled(
                        companionManager.coursesManager.isCourseActive
                            || !companionManager.isBackendReachable
                    )
                    .opacity(
                        companionManager.coursesManager.isCourseActive
                            || !companionManager.isBackendReachable ? 0.4 : 1
                    )
                }
            } else {
                Button("Add") {
                    courseInstallURLText = featured.installURL
                    companionManager.installCourseFromURL(featured.installURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.accent))
                .pointerCursor()
                .disabled(companionManager.coursesManager.isInstallingCourse)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private var backendOfflineBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                Text(TeachyAPIKeyStore.isConfigured ? "can't reach OpenRouter" : "Teachy needs an AI backend")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.warning)
            }

            if TeachyAPIKeyStore.isConfigured {
                // Direct-key users only land here on a genuine network problem —
                // their calls go straight to OpenRouter, no proxy involved.
                Text("Your key talks to OpenRouter directly — check your internet connection and try again.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Easiest: paste your free OpenRouter API key in the Home tab. Developers can run the local proxy instead:")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(companionManager.backendConnectionHint ?? "cd worker && npm run local")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: {
                companionManager.refreshBackendReachability()
            }) {
                Text("Check again")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private var coursesCatalogIntroduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learn with Teachy")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("A free 1:1 tutor on your Mac — warm, playful, beside your cursor. Paths can include teacher clips (your face next to Teachy), then hands-on coaching.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private func activeCourseSessionCard(session: ClickyCourseSession) -> some View {
        let coursesManager = companionManager.coursesManager
        let lessonPlayer = companionManager.lessonPlayer
        let stepNumber = session.currentStepIndex + 1
        let stepCount = session.course.stepCount
        let phase = lessonPlayer.phase

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: phase.systemImageName)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Colors.learnAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.currentStep.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)

                    Text("Step \(stepNumber) of \(stepCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                }

                Spacer(minLength: 0)

                if coursesManager.isCourseInteractionRunning || lessonPlayer.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                }

                Button {
                    companionManager.exitClickyCourse(voiceInitiated: false)
                } label: {
                    Text("Exit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            courseProgressBar(session: session)
                .padding(.top, 8)

            Text(session.currentStep.goal)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            courseConversationArea(session: session)
                .padding(.top, 10)

            if phase.isPlacement {
                coursePhasePromptRow(
                    icon: "questionmark.circle",
                    title: "Quick check",
                    subtitle: "Tell Teachy what you already know — it'll skip ahead if you're ready."
                )
            } else if phase.isWatchingVideo {
                coursePhasePromptRow(
                    icon: "play.rectangle",
                    title: "Teacher clip",
                    subtitle: "Watch the clip, then Teachy will check in."
                )
            } else if phase.isYourTurn {
                coursePhasePromptRow(
                    icon: "hand.raised",
                    title: "Your turn",
                    subtitle: "Try it out. Say \"next step\" when you're done, or ask a question."
                )
            } else if phase.isUnderstanding {
                coursePhasePromptRow(
                    icon: "lightbulb",
                    title: "Quick check",
                    subtitle: "Explain it in your own words."
                )
            } else if phase.isInteractiveChoice {
                coursePhasePromptRow(
                    icon: "list.bullet.circle",
                    title: "Quick check",
                    subtitle: "Pick the best answer below."
                )
            } else if phase.isInteractiveChecklist {
                coursePhasePromptRow(
                    icon: "checklist",
                    title: "Checklist",
                    subtitle: "Check off what you did, then tap Done."
                )
            } else if phase.isInteractiveFillInBlank {
                coursePhasePromptRow(
                    icon: "text.cursor",
                    title: "Fill in the blank",
                    subtitle: "Type the missing word below."
                )
            } else if phase == .checking {
                coursePhasePromptRow(
                    icon: "checkmark.circle",
                    title: "Checking…",
                    subtitle: "Teachy is verifying your work."
                )
            }

            if phase.isWatchingVideo {
                HStack(spacing: 8) {
                    courseActionChip(title: "Skip video", isPrimary: true) {
                        companionManager.skipCourseVideo()
                    }
                    Text("or say \"skip\"")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.top, 8)
            } else if phase.isYourTurn || phase.isPlacement || phase.isUnderstanding {
                HStack(spacing: 8) {
                    courseActionChip(title: "Hint", isPrimary: false) {
                        companionManager.requestCourseHint()
                    }
                    courseActionChip(title: "I did it", isPrimary: true) {
                        companionManager.confirmCourseBeat()
                    }
                }
                .padding(.top, 8)
            } else if phase.isInteractiveChoice, let multipleChoice = session.currentGoal.interactiveMultipleChoice {
                CourseInteractiveChoiceWidgetView(
                    multipleChoice: multipleChoice,
                    onSubmit: { index in
                        companionManager.submitCourseInteractiveChoiceAnswer(index)
                    }
                )
                .padding(.top, 8)
            } else if phase.isInteractiveChecklist, let checklist = session.currentGoal.interactiveChecklist {
                CourseInteractiveChecklistWidgetView(
                    checklist: checklist,
                    onSubmit: { completed in
                        companionManager.submitCourseInteractiveChecklistCompletion(completed)
                    }
                )
                .padding(.top, 8)
            } else if phase.isInteractiveFillInBlank, let fillInBlank = session.currentGoal.interactiveFillInBlank {
                CourseInteractiveFillInBlankWidgetView(
                    fillInBlank: fillInBlank,
                    onSubmit: { text in
                        companionManager.submitCourseInteractiveFillInBlankAnswer(text)
                    }
                )
                .padding(.top, 8)
            }

            courseQuestionInput()
                .padding(.top, 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func courseConversationArea(session: ClickyCourseSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(session.stepConversationHistory.enumerated()), id: \.offset) { _, exchange in
                        courseConversationExchange(exchange)
                    }

                    if let coachMessage = companionManager.coursesManager.lastCoachMessage {
                        courseCoachMessageBlock(message: coachMessage)
                    } else if !companionManager.coursesManager.lastCoachSpokenText.isEmpty {
                        courseCoachMessageBlock(
                            message: CourseCoachMessageParts(
                                infoText: nil,
                                todoText: companionManager.coursesManager.lastCoachSpokenText,
                                spokenText: companionManager.coursesManager.lastCoachSpokenText,
                                rememberedFacts: []
                            )
                        )
                    }
                }
                .id("conversation")
            }
            .frame(maxHeight: 200)
            .onChange(of: companionManager.coursesManager.lastCoachMessage) { _ in
                withAnimation { proxy.scrollTo("conversation", anchor: .bottom) }
            }
        }
    }

    private func courseConversationExchange(_ exchange: ClickyCourseStepExchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 8))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14)

                Text(exchange.userTranscript)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 8))
                    .foregroundColor(DS.Colors.learnAccent)
                    .frame(width: 14)

                Text(exchange.assistantResponse)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func courseCoachMessageBlock(message: CourseCoachMessageParts) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let infoText = message.infoText, !infoText.isEmpty {
                courseCoachBlock(kindLabel: "FYI", text: infoText, accent: Color(red: 0.35, green: 0.55, blue: 0.95))
            }
            if let todoText = message.todoText, !todoText.isEmpty {
                courseCoachBlock(kindLabel: "Teachy", text: todoText, accent: DS.Colors.learnAccent)
            }
            if !message.hasStructuredParts, !message.spokenText.isEmpty {
                courseCoachBlock(kindLabel: "Teachy", text: message.spokenText, accent: DS.Colors.learnAccent)
            }
        }
    }

    private func courseCoachBlock(kindLabel: String, text: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kindLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(accent)
                .tracking(0.4)

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func coursePhasePromptRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.learnAccent)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    private func courseQuestionInput() -> some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $courseQuestionText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit {
                    let question = courseQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return }
                    courseQuestionText = ""
                    companionManager.submitCourseTextQuestion(question)
                }

            if !courseQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    let question = courseQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return }
                    courseQuestionText = ""
                    companionManager.submitCourseTextQuestion(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DS.Colors.learnAccent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func courseActionChip(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isPrimary ? DS.Colors.surface1 : DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isPrimary ? DS.Colors.learnAccent : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func courseProgressBar(session: ClickyCourseSession) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 4)
                Capsule()
                    .fill(DS.Colors.learnAccent)
                    .frame(
                        width: max(4, geometry.size.width * session.progressFraction),
                        height: 4
                    )
            }
        }
        .frame(height: 4)
    }

    /// Thin inline progress bar shown on catalog rows for a course with partial progress.
    /// `completedMainGoalCount` is the count of completed non-remediation goals;
    /// `totalMainGoalCount` is the total non-remediation goal count for the course.
    private func catalogRowProgressBar(
        completedMainGoalCount: Int,
        totalMainGoalCount: Int
    ) -> some View {
        let progressFraction = totalMainGoalCount > 0
            ? Double(completedMainGoalCount) / Double(totalMainGoalCount)
            : 0.0
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)
                    Capsule()
                        .fill(DS.Colors.learnAccent)
                        .frame(
                            width: max(3, geometry.size.width * progressFraction),
                            height: 3
                        )
                }
            }
            .frame(height: 3)

            Text("\(completedMainGoalCount) of \(totalMainGoalCount) steps")
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var coursesCatalogList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(companionManager.coursesManager.catalogSections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if let sectionTitle = section.title {
                        Text(sectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }

                    ForEach(section.courses) { course in
                        courseCatalogRow(course: course)
                    }
                }
            }

            // Build Your Own Course button
            Button {
                companionManager.showCustomCourseBuilder = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DS.Colors.learnAccent.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Build Your Own")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("describe what you want to learn — teachy builds a course")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func courseCatalogRow(course: ClickyCourse) -> some View {
        let progress = companionManager.coursesManager.progress(forCourseID: course.id)
        let isActive = companionManager.coursesManager.activeSession?.course.id == course.id
        let anotherCourseIsActive = companionManager.coursesManager.isCourseActive && !isActive
        let prerequisitesMet = companionManager.coursesManager.isPrerequisiteLikelyMet(for: course)
        let isCompleted = progress?.isFullyCompleted == true
        let isExpanded = expandedCourseID == course.id

        // Non-remediation goals are the learner-visible "main" steps. Remediation goals
        // are supplemental re-teach goals that are not counted in the stated step count.
        let mainGoals = course.goals.filter { $0.remediationGoalID == nil }
        let totalMainGoalCount = mainGoals.count

        // Partial progress: at least one main step completed and course not yet finished.
        let completedMainGoalCount = progress.map { p in
            mainGoals.filter { p.completedStepIDs.contains($0.id) }.count
        } ?? 0
        let hasPartialProgress = completedMainGoalCount > 0 && !isCompleted

        // Resume step number shown in the action button (1-based for human display).
        let resumeStepIndex = companionManager.coursesManager.resumeStepIndex(for: course)

        // Whether any main goal has an interactive widget — used to label the row hint.
        let hasAnyInteractiveGoal = mainGoals.contains {
            $0.interactiveMultipleChoice != nil
                || $0.interactiveChecklist != nil
                || $0.interactiveFillInBlank != nil
        }

        return VStack(alignment: .leading, spacing: 0) {

            // MARK: Row header — always visible; tapping it toggles the expanded preview.
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    if expandedCourseID == course.id {
                        expandedCourseID = nil
                    } else {
                        expandedCourseID = course.id
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: course.iconSystemName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DS.Colors.learnAccent.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        if let trackPartLabel = course.trackPartLabel {
                            Text(trackPartLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.learnAccent)
                        }

                        HStack(spacing: 6) {
                            Text(course.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)

                            if course.hasTeacherVideos {
                                Text("video")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(DS.Colors.learnAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(DS.Colors.learnAccent.opacity(0.16))
                                    )
                            }

                            if isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.success)
                            }
                        }

                        Text(course.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    // Chevron signals the row is expandable; rotates 180° when open.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.smooth(duration: 0.22), value: isExpanded)
                        .padding(.top, 2)
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // MARK: Prerequisite notice (always visible when relevant).
            if !prerequisitesMet, let prerequisiteIDs = course.prerequisiteCourseIDs {
                let prerequisiteTitles = prerequisiteIDs.compactMap { id in
                    companionManager.coursesManager.course(withID: id)?.title
                }
                if !prerequisiteTitles.isEmpty {
                    Text("Best after: \(prerequisiteTitles.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 6)
                }
            }

            // MARK: Inline progress bar — shown only when the learner has started but not finished.
            if hasPartialProgress {
                catalogRowProgressBar(
                    completedMainGoalCount: completedMainGoalCount,
                    totalMainGoalCount: totalMainGoalCount
                )
                .padding(.top, 8)
            }

            // MARK: Expandable preview — meta chips, learning outcomes, step list.
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {

                    // Meta chip row: duration, step count, interaction hint.
                    HStack(spacing: 8) {
                        Label("~\(course.estimatedMinutes) min", systemImage: "clock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)

                        Label("\(totalMainGoalCount) steps", systemImage: "list.bullet")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)

                        if hasAnyInteractiveGoal {
                            Text("quiz + hands-on")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                        } else {
                            Text("hands-on")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .padding(.top, 2)

                    // What you'll learn — capped at 5 outcomes with a "+N more" overflow line.
                    if !course.learningOutcomes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What you'll learn")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)

                            let visibleOutcomes = Array(course.learningOutcomes.prefix(5))
                            let hiddenOutcomeCount = course.learningOutcomes.count - visibleOutcomes.count

                            ForEach(visibleOutcomes, id: \.self) { outcome in
                                HStack(alignment: .top, spacing: 6) {
                                    // Bullet dot — matches the style used in other list rows
                                    // in this panel (small filled circle).
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .padding(.top, 4)

                                    Text(outcome)
                                        .font(.system(size: 11))
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            if hiddenOutcomeCount > 0 {
                                Text("+\(hiddenOutcomeCount) more")
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .padding(.leading, 10)
                            }
                        }
                    }

                    // Step list — one compact row per non-remediation goal.
                    // Completed steps show a filled checkmark; upcoming steps show the step number.
                    if !mainGoals.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Steps")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.bottom, 4)

                            ForEach(Array(mainGoals.enumerated()), id: \.element.id) { index, goal in
                                let isGoalCompleted = progress?.completedStepIDs.contains(goal.id) == true

                                HStack(alignment: .top, spacing: 8) {
                                    // Step number or completed checkmark.
                                    if isGoalCompleted {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(DS.Colors.success)
                                            .frame(width: 16)
                                    } else {
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(DS.Colors.textTertiary)
                                            .frame(width: 16)
                                    }

                                    Text(goal.title)
                                        .font(.system(size: 11))
                                        .foregroundColor(
                                            isGoalCompleted
                                                ? DS.Colors.textTertiary
                                                : DS.Colors.textSecondary
                                        )
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                // Clip so the expanding content doesn't bleed outside the card during animation.
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // MARK: Row footer — action buttons, always visible in both states.
            HStack {
                Text("\(course.stepCount) goals · ~\(course.estimatedMinutes) min")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                if isActive {
                    Text("In progress")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.learnAccent.opacity(0.15)))
                } else {
                    if companionManager.coursesManager.installedCourseSourcesByID[course.id] != nil {
                        Button("Remove") {
                            companionManager.uninstallInstalledCourse(courseID: course.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .pointerCursor()
                    }

                    Button(action: {
                        notchManager.selectedTab = .courses
                        companionManager.startClickyCourse(courseID: course.id)
                        notchManager.collapse()
                    }) {
                        // Label is "Retake" for fully completed courses, "Resume · step N"
                        // when there is partial progress, and "Start" for untouched courses.
                        Text(
                            isCompleted
                                ? "Retake"
                                : (hasPartialProgress
                                    ? "Resume · step \(resumeStepIndex + 1)"
                                    : "Start")
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.learnAccent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(anotherCourseIsActive || !companionManager.isBackendReachable)
                    .opacity(anotherCourseIsActive || !companionManager.isBackendReachable ? 0.4 : 1)
                }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .glassCard(tint: DS.Colors.learnAccent, prominent: isActive)
    }
}
