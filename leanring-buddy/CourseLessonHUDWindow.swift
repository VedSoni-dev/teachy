//
//  CourseLessonHUDWindow.swift
//  leanring-buddy
//
//  Teaching HUD docked right of the notch — coach line, goal, tools, Hint / Do it / I did it.
//  Visual language loosely inspired by boring.notch (glass, hover expand, soft glow).
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CourseLessonHUDManager: ObservableObject {
    private var panel: NSPanel?
    private var screenConfigurationObserver: NSObjectProtocol?

    private let hudWidth: CGFloat = 340
    private let collapsedHeight: CGFloat = 118
    private let expandedHeight: CGFloat = 340

    @Published private(set) var isHoverExpanded = false

    func show(companionManager: CompanionManager) {
        if panel == nil {
            createPanel(companionManager: companionManager)
        } else if let hostingView = panel?.contentView as? NSHostingView<CourseLessonHUDView> {
            hostingView.rootView = CourseLessonHUDView(
                companionManager: companionManager,
                hudManager: self
            )
        }

        positionRightOfNotch()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        installScreenConfigurationObserver()
    }

    func hide() {
        removeScreenConfigurationObserver()
        isHoverExpanded = false
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.contentView = nil
            self?.panel = nil
        })
    }

    func repositionIfNeeded() {
        guard panel != nil else { return }
        positionRightOfNotch()
    }

    func setHoverExpanded(_ expanded: Bool) {
        guard isHoverExpanded != expanded else { return }
        isHoverExpanded = expanded
        positionRightOfNotch(animated: true)
    }

    private func createPanel(companionManager: CompanionManager) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: hudWidth, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        let hostingView = NSHostingView(
            rootView: CourseLessonHUDView(
                companionManager: companionManager,
                hudManager: self
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: hudWidth, height: collapsedHeight)
        panel.contentView = hostingView
        self.panel = panel
    }

    private func positionRightOfNotch(animated: Bool = false) {
        guard let panel else { return }
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }

        let height = isHoverExpanded ? expandedHeight : collapsedHeight
        let notchGeometry = NotchScreenGeometry.from(screen: targetScreen)
        let hudFrame = notchGeometry.rightOfNotchFrame(width: hudWidth, height: height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(hudFrame, display: true)
            }
        } else {
            panel.setFrame(hudFrame, display: true)
        }

        if let hostingView = panel.contentView as? NSHostingView<CourseLessonHUDView> {
            hostingView.frame = NSRect(x: 0, y: 0, width: hudWidth, height: height)
        }
    }

    private func installScreenConfigurationObserver() {
        removeScreenConfigurationObserver()
        screenConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionRightOfNotch()
        }
    }

    private func removeScreenConfigurationObserver() {
        if let screenConfigurationObserver {
            NotificationCenter.default.removeObserver(screenConfigurationObserver)
            self.screenConfigurationObserver = nil
        }
    }
}

// MARK: - HUD View

private struct CourseLessonHUDView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var hudManager: CourseLessonHUDManager
    @ObservedObject private var coursesManager: CoursesManager
    @ObservedObject private var lessonPlayer: LessonPlayer
    @State private var yourTurnPulseOpacity: Double = 1
    @State private var isHovering = false

    init(companionManager: CompanionManager, hudManager: CourseLessonHUDManager) {
        self.companionManager = companionManager
        self.hudManager = hudManager
        self._coursesManager = ObservedObject(wrappedValue: companionManager.coursesManager)
        self._lessonPlayer = ObservedObject(wrappedValue: companionManager.lessonPlayer)
    }

    var body: some View {
        if let session = coursesManager.activeSession {
            let phase = lessonPlayer.phase
            let isYourTurn = phase.isYourTurn
            let isPlacement = phase.isPlacement
            let isUnderstanding = phase.isUnderstanding
            let isInteractiveChoice = phase.isInteractiveChoice
            let isInteractiveChecklist = phase.isInteractiveChecklist
            let isInteractiveFillInBlank = phase.isInteractiveFillInBlank
            let isLearnerWaiting = isYourTurn || isPlacement || isUnderstanding
                || isInteractiveChoice || isInteractiveChecklist || isInteractiveFillInBlank
            let isWatchingVideo = phase.isWatchingVideo
            let showDetails = isHovering || isLearnerWaiting || isWatchingVideo
                || coursesManager.lastCoachMessage != nil
                || !coursesManager.lastCoachSpokenText.isEmpty

            VStack(alignment: .leading, spacing: 8) {
                headerRow(session: session, phase: phase, isYourTurn: isLearnerWaiting)

                if isPlacement {
                    Text("Before we start")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    Text("What do you already know?")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent.opacity(0.95))
                } else if isUnderstanding {
                    Text("Quick check")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    Text("Say it in your words")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent.opacity(0.95))
                } else if isInteractiveChoice {
                    Text("Quick check")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    Text("Pick an answer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent.opacity(0.95))
                } else if isInteractiveChecklist {
                    Text("Checklist")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    Text("Check off what you did")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent.opacity(0.95))
                } else if isInteractiveFillInBlank {
                    Text("Fill in the blank")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    Text("Type the missing word")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent.opacity(0.95))
                } else {
                    Text(session.currentStep.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Show the relevant learning outcome next to the goal.
                    if let outcome = relevantLearningOutcome(for: session) {
                        Text(outcome)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Show artifact state if available.
                    if let artifact = session.course.artifact, !session.artifactHistory.isEmpty {
                        artifactPreview(session: session, artifact: artifact)
                    }

                    Text("Step \(session.currentStepIndex + 1) of \(session.course.stepCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent.opacity(0.95))
                        .lineLimit(1)

                    progressBar(fraction: session.progressFraction)
                }

                if showDetails {
                    coachMessageBlocks(expanded: isHovering || isLearnerWaiting)
                }

                Text(subtitleText(session: session, phase: phase))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if isHovering, let latestTool = coursesManager.courseToolStepLog.last {
                    Text("did: \(latestTool.toolName)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                if isWatchingVideo {
                    HStack(spacing: 6) {
                        if let credit = companionManager.besideCursorVideoCredit, !credit.isEmpty {
                            Text(credit)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.learnAccent)
                                .lineLimit(1)
                        }
                        hudActionButton(title: "Skip video", emphasized: true) {
                            companionManager.skipCourseVideo()
                        }
                        Text("or say \"skip\"")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer(minLength: 0)
                    }
                } else if isPlacement {
                    promptChipRow(
                        chips: TeachyPromptChips.placementChips,
                        header: "pick one",
                        onSelect: { chip in
                            companionManager.submitCoursePlacementAnswer(chip)
                        }
                    )
                } else if isUnderstanding {
                    // Contextual teach-back chips based on the current goal's tool policy
                    let goalToolPolicy = session.currentGoal.toolPolicy
                    let teachBackChips = teachBackChips(for: goalToolPolicy)
                    if !teachBackChips.isEmpty {
                        promptChipRow(chips: teachBackChips, header: "try one") { chip in
                            copyPromptChip(chip)
                        }
                    }

                    HStack(spacing: 6) {
                        hudActionButton(title: "I get it", emphasized: true) {
                            companionManager.submitCourseUnderstandingAnswer("i get it — we did the goal")
                        }
                        Text("or hold ctrl+option")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer(minLength: 0)
                    }
                } else if isYourTurn {
                    if let promptChips = promptChips(for: session), !promptChips.isEmpty {
                        promptChipRow(chips: promptChips, header: "try one") { chip in
                            copyPromptChip(chip)
                        }
                    }

                    HStack(spacing: 6) {
                        hudActionButton(title: "Hint", emphasized: false) {
                            companionManager.requestCourseHint()
                        }
                        hudActionButton(title: "Next step", emphasized: true) {
                            companionManager.confirmCourseBeat()
                        }
                        Spacer(minLength: 0)
                    }
                } else if isInteractiveChoice, let multipleChoice = session.currentGoal.interactiveMultipleChoice {
                    CourseInteractiveChoiceWidgetView(
                        multipleChoice: multipleChoice,
                        onSubmit: { index in
                            companionManager.submitCourseInteractiveChoiceAnswer(index)
                        }
                    )
                } else if isInteractiveChecklist, let checklist = session.currentGoal.interactiveChecklist {
                    CourseInteractiveChecklistWidgetView(
                        checklist: checklist,
                        onSubmit: { completed in
                            companionManager.submitCourseInteractiveChecklistCompletion(completed)
                        }
                    )
                } else if isInteractiveFillInBlank, let fillInBlank = session.currentGoal.interactiveFillInBlank {
                    CourseInteractiveFillInBlankWidgetView(
                        fillInBlank: fillInBlank,
                        onSubmit: { text in
                            companionManager.submitCourseInteractiveFillInBlankAnswer(text)
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(hudBackground(isYourTurn: isLearnerWaiting))
            .animation(.easeInOut(duration: 0.25), value: phase.displayLabel)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                hudManager.setHoverExpanded(hovering || isLearnerWaiting)
            }
            .onChange(of: isLearnerWaiting) { isActive in
                hudManager.setHoverExpanded(isActive || isHovering)
                if isActive {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        yourTurnPulseOpacity = 0.45
                    }
                } else {
                    yourTurnPulseOpacity = 1
                }
            }
        }
    }

    private func headerRow(
        session: ClickyCourseSession,
        phase: CourseLessonPhase,
        isYourTurn: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: phase.systemImageName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.learnAccent)
                .opacity(isYourTurn ? yourTurnPulseOpacity : 1)

            Text(session.course.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if lessonPlayer.isRunning || coursesManager.isCourseInteractionRunning {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }

            Button(action: {
                companionManager.exitClickyCourse(voiceInitiated: false)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                DS.Colors.learnAccent,
                                DS.Colors.learnAccent.opacity(0.7),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
    }

    private func hudBackground(isYourTurn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        DS.Colors.learnAccent.opacity(isYourTurn ? 0.75 : 0.35),
                        lineWidth: isYourTurn ? 1.5 : 1
                    )
            )
            .shadow(
                color: DS.Colors.learnAccent.opacity(isYourTurn ? 0.22 : 0.08),
                radius: isYourTurn ? 16 : 10,
                x: 0,
                y: 4
            )
    }

    private func subtitleText(session: ClickyCourseSession, phase: CourseLessonPhase) -> String {
        if case .watchingVideo = phase {
            return "clip beside Teachy — say “skip” anytime"
        }
        if case .placement = phase {
            return "tap a chip · or hold ctrl+option and say it"
        }
        if case .understanding = phase {
            return "hold ctrl+option and explain · or tap “I get it”"
        }
        if case .interactiveChoice = phase {
            return "tap an answer to see how you did"
        }
        if case .interactiveChecklist = phase {
            return "check off what applies · tap Done when ready"
        }
        if case .interactiveFillInBlank = phase {
            return "type your answer · tap Check to see how you did"
        }
        if case .yourTurn = phase {
            if !TeachyPromptChips.chips(forGoalID: session.currentStep.id).isEmpty {
                return "tap a prompt · paste · then say “next step”"
            }
            return "ctrl+option to ask · say “next step” when done"
        }
        if case .coaching = phase {
            return "coaching…"
        }
        if case .checking = phase {
            return "checking…"
        }
        return session.currentStep.goal
    }

    @ViewBuilder
    private func coachMessageBlocks(expanded: Bool) -> some View {
        if let message = coursesManager.lastCoachMessage {
            VStack(alignment: .leading, spacing: 6) {
                if let infoText = message.infoText, !infoText.isEmpty {
                    coachKindBlock(
                        kindLabel: "FYI",
                        text: infoText,
                        accent: Color(red: 0.35, green: 0.55, blue: 0.95),
                        lineLimit: expanded ? 4 : 2
                    )
                }
                if let todoText = message.todoText, !todoText.isEmpty {
                    coachKindBlock(
                        kindLabel: "Your move",
                        text: todoText,
                        accent: DS.Colors.learnAccent,
                        lineLimit: expanded ? 4 : 2
                    )
                }
                if !message.hasStructuredParts,
                   !message.spokenText.isEmpty {
                    coachKindBlock(
                        kindLabel: "Your move",
                        text: message.spokenText,
                        accent: DS.Colors.learnAccent,
                        lineLimit: expanded ? 4 : 2
                    )
                }
            }
        } else if !coursesManager.lastCoachSpokenText.isEmpty {
            coachKindBlock(
                kindLabel: "Your move",
                text: coursesManager.lastCoachSpokenText,
                accent: DS.Colors.learnAccent,
                lineLimit: expanded ? 4 : 2
            )
        }
    }

    private func coachKindBlock(
        kindLabel: String,
        text: String,
        accent: Color,
        lineLimit: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kindLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(accent)
                .tracking(0.4)

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary.opacity(0.94))
                .lineLimit(lineLimit)
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

    private func promptChips(for session: ClickyCourseSession) -> [String]? {
        let chips = TeachyPromptChips.chips(forGoalID: session.currentStep.id)
        return chips.isEmpty ? nil : chips
    }

    private func teachBackChips(for toolPolicy: CourseToolPolicy?) -> [String] {
        switch toolPolicy {
        case .canDoForThem:
            return ["You do it, then teach me", "Show me step by step"]
        case .helpWhenStuck:
            return ["I'm stuck, show me", "What's the next move?"]
        case .pointOnly, .preferPointing, .none:
            return ["I think I get it", "Can you explain that differently?"]
        }
    }

    private func relevantLearningOutcome(for session: ClickyCourseSession) -> String? {
        let goal = session.currentGoal
        let outcome = goal.outcome ?? goal.goal
        return outcome
    }

    private func artifactPreview(
        session: ClickyCourseSession,
        artifact: CourseArtifactSpec
    ) -> some View {
        let latestSnapshot = session.artifactHistory.last
        let description = latestSnapshot?.stateDescription ?? artifact.previewIfNoProgress
        return HStack(spacing: 6) {
            Image(systemName: artifact.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.learnAccent)
            Text(description)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.learnAccent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.learnAccent.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func promptChipRow(
        chips: [String],
        header: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(header)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            FlowChipLayout(spacing: 5) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        onSelect(chip)
                    } label: {
                        Text(chip)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(DS.Colors.learnAccent.opacity(0.4), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private func copyPromptChip(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        companionManager.showCoursePresenceBubble("copied — paste it in the chat")
    }

    private func hudActionButton(
        title: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(emphasized ? Color.black.opacity(0.85) : DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        emphasized
                            ? DS.Colors.learnAccent
                            : Color.white.opacity(0.1)
                    )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Simple wrapping chip layout for HUD prompt suggestions.
private struct FlowChipLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, currentX + size.width)
            currentX += size.width + spacing
            totalHeight = currentY + rowHeight
        }

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
