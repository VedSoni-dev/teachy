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
                Text("backend offline")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.warning)
            }

            Text("Courses need the local proxy. In Terminal:")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)

            Text(companionManager.backendConnectionHint ?? "cd worker && npm run local")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

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
                                spokenText: companionManager.coursesManager.lastCoachSpokenText
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

        return VStack(alignment: .leading, spacing: 10) {
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
            }

            if !prerequisitesMet, let prerequisiteIDs = course.prerequisiteCourseIDs {
                let prerequisiteTitles = prerequisiteIDs.compactMap { id in
                    companionManager.coursesManager.course(withID: id)?.title
                }
                if !prerequisiteTitles.isEmpty {
                    Text("Best after: \(prerequisiteTitles.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

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
                        Text(
                            isCompleted
                                ? "Retake"
                                : (companionManager.coursesManager.resumeStepIndex(for: course) > 0 ? "Continue" : "Start")
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
        }
        .padding(14)
        .glassCard(tint: DS.Colors.learnAccent, prominent: isActive)
    }
}
