//
//  CoursesManager.swift
//  leanring-buddy
//
//  Manages Teachy Courses — catalog, active sessions, and progress persistence.
//  While a course is active, voice input routes through course-specific prompts
//  until the course finishes or the user opts out.
//

import Combine
import Foundation

@MainActor
final class CoursesManager: ObservableObject {
    @Published private(set) var availableCourses: [ClickyCourse] = []
    @Published private(set) var progressByCourseID: [String: ClickyCourseProgress] = [:]
    @Published private(set) var activeSession: ClickyCourseSession?
    @Published private(set) var courseToolStepLog: [AgentStep] = []
    @Published private(set) var isCourseInteractionRunning = false
    @Published private(set) var courseTeachingPhase: CourseTeachingPhase = .idle
    /// Last thing Teachy said aloud — shown in the teaching HUD for continuity.
    @Published private(set) var lastCoachSpokenText: String = ""
    /// Structured coach line — INFO (explain) vs TODO (do this) for HUD styling.
    @Published private(set) var lastCoachMessage: CourseCoachMessageParts?
    /// Short notes that survive goal advances so the tutor remembers the session.
    @Published private(set) var courseRollingMemory: [String] = []
    /// Richer durable learner model for the active course (knows / confused / prefs).
    @Published private(set) var learnerProfile: CourseLearnerProfile = CourseLearnerProfile()
    /// Persistent global learner profile — carries knowledge across all courses.
    @Published private(set) var globalLearnerProfile: CourseLearnerProfile = CourseLearnerProfile()
    /// Notes from the teacher clip that just played — injected into the next coach turns.
    @Published private(set) var activeTeacherVideoNotes: String?
    /// Courses installed from the academy / a URL (not bundled).
    @Published private(set) var installedCourseSourcesByID: [String: String] = [:]
    /// Featured packs from the public academy registry.
    @Published private(set) var academyRegistry: ClickyAcademyRegistry?
    @Published private(set) var isInstallingCourse = false
    @Published private(set) var isLoadingAcademyRegistry = false
    @Published var courseInstallStatusMessage: String?
    /// Shown after a path finishes — outcome proof, not vibes.
    @Published var completionCelebration: CourseCompletionCelebration?
    /// When true, Learn emphasizes First Win + flagship first.
    @Published private(set) var preferSimplifiedCatalog: Bool = true

    private static let progressUserDefaultsKey = "clickyCourseProgressByCourseID"
    private static let coursesDirectoryPath = TeachyDataPaths.coursesDirectoryURL.path
    private static let courseSourcesFileName = "sources.json"
    private static let learnerMemoryUserDefaultsKey = "clickyCourseLearnerMemoryByCourseID"
    private static let learnerProfileUserDefaultsKey = "teachyCourseLearnerProfileByCourseID"
    private static let globalLearnerProfileUserDefaultsKey = "teachyGlobalLearnerProfile"
    private static let simplifiedCatalogUserDefaultsKey = "teachyPreferSimplifiedCatalog"
    private static let bundledCourseIDs: Set<String> = Set(ClickyCourseCatalog.bundledCourses.map(\.id))

    var isCourseActive: Bool { activeSession != nil }

    init() {
        loadProgressFromDisk()
        loadInstalledCourseSourcesFromDisk()
        preferSimplifiedCatalog = UserDefaults.standard.object(forKey: Self.simplifiedCatalogUserDefaultsKey) as? Bool ?? true
        globalLearnerProfile = Self.loadGlobalLearnerProfile()
        reloadCourseCatalog()
    }

    // MARK: - Catalog

    func setPreferSimplifiedCatalog(_ prefer: Bool) {
        preferSimplifiedCatalog = prefer
        UserDefaults.standard.set(prefer, forKey: Self.simplifiedCatalogUserDefaultsKey)
    }

    func reloadCourseCatalog() {
        var courses = ClickyCourseCatalog.bundledCourses
        courses.append(contentsOf: loadCustomCoursesFromDisk())
        var seenIDs = Set<String>()
        availableCourses = courses.filter { course in
            guard !seenIDs.contains(course.id) else { return false }
            seenIDs.insert(course.id)
            return true
        }
    }

    /// Adds a dynamically generated course to the catalog (in-memory only).
    func addCustomCourse(_ course: ClickyCourse) {
        if !availableCourses.contains(where: { $0.id == course.id }) {
            availableCourses.append(course)
        }
    }

    /// Continue target — most recently accessed incomplete course, else First Win / flagship.
    var continueCourse: ClickyCourse? {
        let candidates = availableCourses.compactMap { course -> (ClickyCourse, Date)? in
            guard let progress = progressByCourseID[course.id],
                  !progress.isFullyCompleted,
                  let lastAccessedAt = progress.lastAccessedAt
            else { return nil }
            return (course, lastAccessedAt)
        }
        if let best = candidates.max(by: { $0.1 < $1.1 }) {
            return best.0
        }
        if progress(forCourseID: "build-a-website")?.isFullyCompleted != true {
            return course(withID: "build-a-website")
        }
        return nil
    }

    func resumeStepIndex(for course: ClickyCourse) -> Int {
        guard let progress = progressByCourseID[course.id], !progress.isFullyCompleted else {
            return 0
        }
        for (index, goal) in course.goals.enumerated() {
            if !progress.completedStepIDs.contains(goal.id) {
                return index
            }
        }
        return 0
    }

    /// Standalone courses first, then each learning track in part order.
    /// Simplified mode: First Win + Use AI to Code (+ in-progress), rest under More.
    var catalogSections: [CourseCatalogSection] {
        learnerCatalogSections(simplified: preferSimplifiedCatalog)
    }

    func learnerCatalogSections(simplified: Bool) -> [CourseCatalogSection] {
        if simplified {
            let featuredIDs = ClickyCourseCatalog.featuredLearnerCourseIDs
            let featured = featuredIDs.compactMap { course(withID: $0) }
            let inProgressExtras = availableCourses.filter { course in
                guard !featuredIDs.contains(course.id) else { return false }
                guard let progress = progressByCourseID[course.id] else { return false }
                return !progress.isFullyCompleted && progress.completedStepCount > 0
            }
            var primary = featured + inProgressExtras
            var seen = Set<String>()
            primary = primary.filter { seen.insert($0.id).inserted }

            var sections: [CourseCatalogSection] = [
                CourseCatalogSection(id: "start-here", title: "Start here", courses: primary)
            ]
            let more = availableCourses.filter { !seen.contains($0.id) }
            if !more.isEmpty {
                sections.append(CourseCatalogSection(id: "more", title: "More paths", courses: more))
            }
            return sections
        }

        var standalone: [ClickyCourse] = []
        var tracks: [String: (title: String, courses: [ClickyCourse])] = [:]

        for course in availableCourses {
            if let trackID = course.trackID, let trackTitle = course.trackTitle {
                var entry = tracks[trackID] ?? (title: trackTitle, courses: [])
                entry.courses.append(course)
                tracks[trackID] = entry
            } else {
                standalone.append(course)
            }
        }

        var sections: [CourseCatalogSection] = []
        if !standalone.isEmpty {
            sections.append(CourseCatalogSection(id: "standalone", title: nil, courses: standalone))
        }

        let sortedTrackIDs = tracks.keys.sorted { left, right in
            (tracks[left]?.title ?? left) < (tracks[right]?.title ?? right)
        }
        for trackID in sortedTrackIDs {
            guard let entry = tracks[trackID] else { continue }
            let ordered = entry.courses.sorted { ($0.trackOrder ?? 0) < ($1.trackOrder ?? 0) }
            sections.append(CourseCatalogSection(id: trackID, title: entry.title, courses: ordered))
        }
        return sections
    }

    func course(withID courseID: String) -> ClickyCourse? {
        availableCourses.first { $0.id == courseID }
    }

    func progress(forCourseID courseID: String) -> ClickyCourseProgress? {
        progressByCourseID[courseID]
    }

    func isPrerequisiteLikelyMet(for course: ClickyCourse) -> Bool {
        guard let prerequisiteCourseIDs = course.prerequisiteCourseIDs, !prerequisiteCourseIDs.isEmpty else {
            return true
        }
        return prerequisiteCourseIDs.allSatisfy { prerequisiteID in
            progress(forCourseID: prerequisiteID)?.isFullyCompleted == true
        }
    }

    func dismissCompletionCelebration() {
        completionCelebration = nil
    }

    func presentCompletionCelebration(for course: ClickyCourse) {
        let conceptsLearned = globalLearnerProfile.knows.suffix(5)
        let recap: String
        if !conceptsLearned.isEmpty {
            recap = "You learned: \(conceptsLearned.joined(separator: ", "))."
        } else {
            recap = "You completed all \(course.stepCount) goals in this course."
        }

        let nextSteps: [String]
        if course.id == "build-a-website" {
            nextSteps = [
                "add more pages to your site",
                "try a different course to learn something new",
                "build something from scratch without guidance"
            ]
        } else {
            nextSteps = [
                "apply what you learned to a real project",
                "teach someone else what you just learned",
                "explore the next course in this track"
            ]
        }

        completionCelebration = CourseCompletionCelebration(
            courseID: course.id,
            title: course.title,
            message: course.id == "build-a-website"
                ? "You built and deployed a real website. That's a real outcome — keep going."
                : "You finished \(course.title). That's a real outcome — keep going.",
            recap: recap,
            nextSteps: nextSteps
        )
    }

    // MARK: - Session lifecycle

    @discardableResult
    func startCourse(courseID: String) -> ClickyCourseSession? {
        guard activeSession == nil, let course = course(withID: courseID) else { return nil }

        let startIndex = resumeStepIndex(for: course)
        let session = ClickyCourseSession(
            course: course,
            currentStepIndex: startIndex,
            startedAt: Date(),
            stepConversationHistory: [],
            artifactHistory: [],
            failureCountByGoalID: [:]
        )
        activeSession = session
        courseToolStepLog = []
        lastCoachSpokenText = ""
        lastCoachMessage = nil
        learnerProfile = loadLearnerProfile(forCourseID: course.id)
        courseRollingMemory = learnerProfile.rollingNotes
        if courseRollingMemory.isEmpty {
            // Migrate legacy note-only store once.
            courseRollingMemory = loadLearnerMemory(forCourseID: course.id)
            learnerProfile.rollingNotes = courseRollingMemory
        }
        activeTeacherVideoNotes = nil
        courseTeachingPhase = .settingUp
        touchProgress(for: course)
        if startIndex > 0 {
            rememberAcrossGoals("resumed at goal \(startIndex + 1): \(session.currentStep.title)")
        }
        print("📚 Course started: \(course.title) at step \(startIndex + 1)")
        return session
    }

    func exitCourse() {
        guard let session = activeSession else { return }
        print("📚 Course exited early: \(session.course.title) at step \(session.currentStepIndex + 1)")
        persistActiveLearnerProfile(forCourseID: session.course.id)
        activeSession = nil
        courseToolStepLog = []
        lastCoachSpokenText = ""
        lastCoachMessage = nil
        courseRollingMemory = []
        learnerProfile = CourseLearnerProfile()
        activeTeacherVideoNotes = nil
        isCourseInteractionRunning = false
        courseTeachingPhase = .idle
    }

    func detectMoodFromUserResponse(_ response: String) {
        learnerProfile.detectMood(from: response)
    }

    func setCourseTeachingPhase(_ phase: CourseTeachingPhase) {
        courseTeachingPhase = phase
    }

    func recordCourseToolStep(_ step: AgentStep) {
        courseToolStepLog.append(step)
        if courseToolStepLog.count > 20 {
            courseToolStepLog.removeFirst(courseToolStepLog.count - 20)
        }
    }

    func setCourseInteractionRunning(_ isRunning: Bool) {
        isCourseInteractionRunning = isRunning
    }

    /// Advances to the next step. Returns nil when the course is fully complete.
    func advanceToNextStep() -> ClickyCourseStep? {
        guard var session = activeSession else { return nil }

        let completedStep = session.currentStep
        recordStepCompleted(courseID: session.course.id, stepID: completedStep.id)
        rememberAcrossGoals("finished goal: \(completedStep.title)")

        let nextStepIndex = session.currentStepIndex + 1
        if nextStepIndex >= session.course.stepCount {
            markCourseFullyCompleted(courseID: session.course.id)
            persistActiveLearnerProfile(forCourseID: session.course.id)
            activeSession = nil
            courseTeachingPhase = .idle
            lastCoachSpokenText = ""
            lastCoachMessage = nil
            activeTeacherVideoNotes = nil
            print("📚 Course completed: \(session.course.title)")
            return nil
        }

        session.currentStepIndex = nextStepIndex
        // Keep a little step chat for continuity into the next goal — don't wipe everything.
        if session.stepConversationHistory.count > 2 {
            session.stepConversationHistory = Array(session.stepConversationHistory.suffix(2))
        }
        courseToolStepLog = []
        activeTeacherVideoNotes = nil
        courseTeachingPhase = .settingUp
        activeSession = session
        print("📚 Course advanced to step \(nextStepIndex + 1): \(session.currentStep.title)")
        return session.currentStep
    }

    func appendStepConversation(userTranscript: String, assistantResponse: String) {
        let parts = CourseCoachMessageParts.parse(from: assistantResponse)
        guard var session = activeSession else { return }
        session.stepConversationHistory.append(
            ClickyCourseStepExchange(
                userTranscript: userTranscript,
                assistantResponse: parts.spokenText
            )
        )
        if session.stepConversationHistory.count > 8 {
            session.stepConversationHistory.removeFirst(session.stepConversationHistory.count - 8)
        }
        activeSession = session
        lastCoachSpokenText = parts.spokenText
        lastCoachMessage = parts
    }

    /// Jump to a later goal after knowledge-check placement (marks earlier goals skipped/done).
    @discardableResult
    func jumpToGoalIndex(_ goalIndex: Int, reason: String) -> ClickyCourseStep? {
        guard var session = activeSession else { return nil }
        let clampedIndex = max(0, min(goalIndex, session.course.stepCount - 1))
        guard clampedIndex > session.currentStepIndex else {
            return session.currentStep
        }

        for skippedIndex in session.currentStepIndex..<clampedIndex {
            let skippedGoal = session.course.goals[skippedIndex]
            recordStepCompleted(courseID: session.course.id, stepID: skippedGoal.id)
            rememberAcrossGoals("placement skipped goal: \(skippedGoal.title)")
        }

        session.currentStepIndex = clampedIndex
        if session.stepConversationHistory.count > 2 {
            session.stepConversationHistory = Array(session.stepConversationHistory.suffix(2))
        }
        courseToolStepLog = []
        courseTeachingPhase = .settingUp
        activeSession = session
        rememberAcrossGoals(reason)
        print("📚 Placement jump to step \(clampedIndex + 1): \(session.currentStep.title)")
        return session.currentStep
    }

    func rememberAcrossGoals(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        courseRollingMemory.append(trimmed)
        if courseRollingMemory.count > 16 {
            courseRollingMemory.removeFirst(courseRollingMemory.count - 16)
        }
        learnerProfile.appendRollingNote(trimmed)
        if let courseID = activeSession?.course.id {
            persistActiveLearnerProfile(forCourseID: courseID)
        }
    }

    func setActiveTeacherVideoNotes(_ notes: String?) {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTeacherVideoNotes = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    func clearActiveTeacherVideoNotes() {
        activeTeacherVideoNotes = nil
    }

    // MARK: - Failure tracking

    func incrementFailureCount(forGoalID goalID: String) -> Int {
        guard var session = activeSession else { return 0 }
        let current = session.failureCountByGoalID[goalID] ?? 0
        let newCount = current + 1
        session.failureCountByGoalID[goalID] = newCount
        activeSession = session
        return newCount
    }

    func failureCount(forGoalID goalID: String) -> Int {
        activeSession?.failureCountByGoalID[goalID] ?? 0
    }

    // MARK: - Artifact snapshots

    func appendArtifactSnapshot(goalID: String, stateDescription: String) {
        guard var session = activeSession else { return }
        let snapshot = CourseArtifactSnapshot(
            goalID: goalID,
            stateDescription: stateDescription,
            capturedAt: Date()
        )
        session.artifactHistory.append(snapshot)
        activeSession = session
    }

    func appendArtifactSnapshotFromVerifyResult(goalID: String, result: CourseVerificationResult) {
        guard !result.whatsGood.isEmpty else { return }
        appendArtifactSnapshot(goalID: goalID, stateDescription: result.whatsGood)
    }

    func noteLearnerKnows(_ item: String) {
        learnerProfile.noteKnows(item)
        if let courseID = activeSession?.course.id {
            persistActiveLearnerProfile(forCourseID: courseID)
        }
    }

    func noteLearnerConfusedBy(_ item: String) {
        learnerProfile.noteConfusedBy(item)
        if let courseID = activeSession?.course.id {
            persistActiveLearnerProfile(forCourseID: courseID)
        }
    }

    func recordHintPreference() {
        learnerProfile.prefersHintsOverAutomation = true
        if let courseID = activeSession?.course.id {
            persistActiveLearnerProfile(forCourseID: courseID)
        }
    }

    func recordDoItForMePreference() {
        learnerProfile.prefersHintsOverAutomation = false
        if let courseID = activeSession?.course.id {
            persistActiveLearnerProfile(forCourseID: courseID)
        }
    }

    /// Apply `[MEMORY:…]` tags from a coach reply and return speech-safe text.
    @discardableResult
    func ingestCoachMemoryTags(from responseText: String) -> String {
        let parsed = TeachyMemoryTagParser.consumeMemoryTags(from: responseText)
        for item in parsed.knows {
            noteLearnerKnows(item)
        }
        for item in parsed.confused {
            noteLearnerConfusedBy(item)
        }
        return parsed.cleanedText
    }

    /// History the model should see — recent step chat plus durable session notes.
    func tutorConversationHistory(
        for session: ClickyCourseSession
    ) -> [(userTranscript: String, assistantResponse: String)] {
        var history: [(userTranscript: String, assistantResponse: String)] = []

        let profileBlock = learnerProfile.promptSection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profileBlock.isEmpty {
            history.append((
                userTranscript: "[learner model — durable facts about this student]",
                assistantResponse: profileBlock
            ))
        } else if !courseRollingMemory.isEmpty {
            let memoryBlock = courseRollingMemory
                .suffix(10)
                .enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            history.append((
                userTranscript: "[session memory — things you've already helped them with]",
                assistantResponse: memoryBlock
            ))
        }

        for exchange in session.stepConversationHistory {
            history.append((
                userTranscript: exchange.userTranscript,
                assistantResponse: exchange.assistantResponse
            ))
        }
        return history
    }

    private func loadLearnerMemory(forCourseID courseID: String) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: Self.learnerMemoryUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data),
              let notes = decoded[courseID] else {
            return []
        }
        return notes
    }

    private func saveLearnerMemory(_ notes: [String], forCourseID courseID: String) {
        var store: [String: [String]] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.learnerMemoryUserDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            store = decoded
        }
        store[courseID] = Array(notes.suffix(16))
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: Self.learnerMemoryUserDefaultsKey)
        }
    }

    private func loadLearnerProfile(forCourseID courseID: String) -> CourseLearnerProfile {
        guard let data = UserDefaults.standard.data(forKey: Self.learnerProfileUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: CourseLearnerProfile].self, from: data),
              let profile = decoded[courseID] else {
            let legacyNotes = loadLearnerMemory(forCourseID: courseID)
            var profile = CourseLearnerProfile()
            profile.rollingNotes = legacyNotes
            return profile
        }
        return profile
    }

    private func persistActiveLearnerProfile(forCourseID courseID: String) {
        learnerProfile.rollingNotes = courseRollingMemory
        var store: [String: CourseLearnerProfile] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.learnerProfileUserDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: CourseLearnerProfile].self, from: data) {
            store = decoded
        }
        store[courseID] = learnerProfile
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: Self.learnerProfileUserDefaultsKey)
        }
        // Keep legacy key in sync for older readers / debugging.
        saveLearnerMemory(courseRollingMemory, forCourseID: courseID)
    }

    // MARK: - Spoken copy

    func spokenCourseCompletion(for course: ClickyCourse) -> String {
        if course.id == "build-a-website" {
            return "yo you just built and deployed a real website — that’s yours now, live on the internet."
        }
        return "nice — you finished \(course.title). that one’s yours now. keep going when you feel it."
    }

    /// Goal-based courses use `ClickyCourseCatalog.courseCoachSystemPrompt`.
    /// `personalFacts`/`humorReceptivity`/`temporalContinuityLines` are optional —
    /// sourced from `TeachyEngine`'s `LearnerModel` by callers that have a
    /// `CompanionManager` in reach (e.g. `LessonPlayer`); default to empty/nil so
    /// existing call sites without that context still compile.
    func buildCourseSystemPrompt(
        for session: ClickyCourseSession,
        personalFacts: [String] = [],
        humorReceptivity: HumorReceptivity? = nil,
        temporalContinuityLines: [String] = []
    ) -> String {
        ClickyCourseCatalog.courseCoachSystemPrompt(
            for: session,
            learnerProfile: learnerProfile,
            globalLearnerProfile: globalLearnerProfile,
            activeTeacherVideoNotes: activeTeacherVideoNotes,
            personalFacts: personalFacts,
            humorReceptivity: humorReceptivity,
            temporalContinuityLines: temporalContinuityLines
        )
    }

    // MARK: - Custom courses from disk + academy install

    private func loadCustomCoursesFromDisk() -> [ClickyCourse] {
        ensureCoursesDirectoryExists()
        let coursesDirectoryURL = URL(fileURLWithPath: Self.coursesDirectoryPath, isDirectory: true)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: coursesDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return fileURLs
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.courseSourcesFileName }
            .compactMap { fileURL in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(ClickyCourse.self, from: data)
            }
    }

    func isInstalledFromAcademy(courseID: String) -> Bool {
        installedCourseSourcesByID[courseID] != nil
            || FileManager.default.fileExists(atPath: courseFileURL(forCourseID: courseID).path)
    }

    /// Downloads course JSON (GitHub blob or raw URL), validates, saves under ~/.teachy/courses/ (or legacy ~/.clicky/courses/).
    @discardableResult
    func installCourse(fromURLString urlString: String) async throws -> ClickyCourse {
        guard let downloadURL = ClickyCourseInstallURLResolver.resolveJSONDownloadURL(from: urlString) else {
            throw ClickyCourseInstallError.invalidURL
        }

        isInstallingCourse = true
        courseInstallStatusMessage = "Downloading course…"
        defer { isInstallingCourse = false }

        let data: Data
        do {
            let (downloadedData, response) = try await URLSession.shared.data(from: downloadURL)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                throw ClickyCourseInstallError.downloadFailed("HTTP \(httpResponse.statusCode)")
            }
            data = downloadedData
        } catch let error as ClickyCourseInstallError {
            courseInstallStatusMessage = error.localizedDescription
            throw error
        } catch {
            let installError = ClickyCourseInstallError.downloadFailed(error.localizedDescription)
            courseInstallStatusMessage = installError.localizedDescription
            throw installError
        }

        let course: ClickyCourse
        do {
            course = try JSONDecoder().decode(ClickyCourse.self, from: data)
        } catch {
            let installError = ClickyCourseInstallError.invalidCourseJSON
            courseInstallStatusMessage = installError.localizedDescription
            throw installError
        }

        if Self.bundledCourseIDs.contains(course.id) {
            let installError = ClickyCourseInstallError.conflictsWithBundledCourse(course.id)
            courseInstallStatusMessage = installError.localizedDescription
            throw installError
        }

        ensureCoursesDirectoryExists()
        let destinationURL = courseFileURL(forCourseID: course.id)
        do {
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            let installError = ClickyCourseInstallError.writeFailed(error.localizedDescription)
            courseInstallStatusMessage = installError.localizedDescription
            throw installError
        }

        installedCourseSourcesByID[course.id] = downloadURL.absoluteString
        saveInstalledCourseSourcesToDisk()
        reloadCourseCatalog()
        courseInstallStatusMessage = "Installed “\(course.title)”."
        print("📚 Installed academy course: \(course.id) from \(downloadURL.absoluteString)")
        return course
    }

    func uninstallInstalledCourse(courseID: String) throws {
        guard !Self.bundledCourseIDs.contains(courseID) else { return }
        let fileURL = courseFileURL(forCourseID: courseID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        installedCourseSourcesByID.removeValue(forKey: courseID)
        saveInstalledCourseSourcesToDisk()
        reloadCourseCatalog()
        courseInstallStatusMessage = "Removed course."
    }

    func refreshAcademyRegistry() async {
        isLoadingAcademyRegistry = true
        defer { isLoadingAcademyRegistry = false }

        guard let registryURL = URL(string: ClickyAcademyConfiguration.registryURLString) else {
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: registryURL)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("⚠️ Academy registry HTTP \(httpResponse.statusCode)")
                return
            }
            academyRegistry = try JSONDecoder().decode(ClickyAcademyRegistry.self, from: data)
        } catch {
            print("⚠️ Academy registry load failed: \(error.localizedDescription)")
        }
    }

    private func courseFileURL(forCourseID courseID: String) -> URL {
        let safeFileName = courseID
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: Self.coursesDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(safeFileName).json")
    }

    private func ensureCoursesDirectoryExists() {
        let coursesDirectoryURL = URL(fileURLWithPath: Self.coursesDirectoryPath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: coursesDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: coursesDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func loadInstalledCourseSourcesFromDisk() {
        let sourcesURL = URL(fileURLWithPath: Self.coursesDirectoryPath, isDirectory: true)
            .appendingPathComponent(Self.courseSourcesFileName)
        guard let data = try? Data(contentsOf: sourcesURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            installedCourseSourcesByID = [:]
            return
        }
        installedCourseSourcesByID = decoded
    }

    private func saveInstalledCourseSourcesToDisk() {
        ensureCoursesDirectoryExists()
        let sourcesURL = URL(fileURLWithPath: Self.coursesDirectoryPath, isDirectory: true)
            .appendingPathComponent(Self.courseSourcesFileName)
        if let data = try? JSONEncoder().encode(installedCourseSourcesByID) {
            try? data.write(to: sourcesURL, options: .atomic)
        }
    }

    // MARK: - Progress persistence

    private func loadProgressFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.progressUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: ClickyCourseProgress].self, from: data) else {
            return
        }
        progressByCourseID = decoded
    }

    private func saveProgressToDisk() {
        guard let data = try? JSONEncoder().encode(progressByCourseID) else { return }
        UserDefaults.standard.set(data, forKey: Self.progressUserDefaultsKey)
    }

    private func touchProgress(for course: ClickyCourse) {
        var progress = progressByCourseID[course.id] ?? ClickyCourseProgress(
            completedStepIDs: [],
            isFullyCompleted: false,
            lastAccessedAt: nil
        )
        progress.lastAccessedAt = Date()
        progressByCourseID[course.id] = progress
        saveProgressToDisk()
    }

    private func recordStepCompleted(courseID: String, stepID: String) {
        var progress = progressByCourseID[courseID] ?? ClickyCourseProgress(
            completedStepIDs: [],
            isFullyCompleted: false,
            lastAccessedAt: nil
        )
        if !progress.completedStepIDs.contains(stepID) {
            progress.completedStepIDs.append(stepID)
        }
        progress.lastAccessedAt = Date()
        progressByCourseID[courseID] = progress
        saveProgressToDisk()
    }

    private func markCourseFullyCompleted(courseID: String) {
        var progress = progressByCourseID[courseID] ?? ClickyCourseProgress(
            completedStepIDs: [],
            isFullyCompleted: false,
            lastAccessedAt: nil
        )
        progress.isFullyCompleted = true
        progress.lastAccessedAt = Date()
        progressByCourseID[courseID] = progress
        saveProgressToDisk()
        mergeCourseProfileIntoGlobal(courseID: courseID)
    }

    // MARK: - Global learner profile (cross-course memory)

    private static func loadGlobalLearnerProfile() -> CourseLearnerProfile {
        guard let data = UserDefaults.standard.data(forKey: Self.globalLearnerProfileUserDefaultsKey),
              let decoded = try? JSONDecoder().decode(CourseLearnerProfile.self, from: data) else {
            return CourseLearnerProfile()
        }
        return decoded
    }

    private func saveGlobalLearnerProfile() {
        guard let encoded = try? JSONEncoder().encode(globalLearnerProfile) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.globalLearnerProfileUserDefaultsKey)
    }

    private func mergeCourseProfileIntoGlobal(courseID: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.learnerProfileUserDefaultsKey),
              let allProfiles = try? JSONDecoder().decode([String: CourseLearnerProfile].self, from: data),
              let courseProfile = allProfiles[courseID] else { return }

        for concept in courseProfile.knows {
            globalLearnerProfile.noteKnows(concept)
        }
        for concept in courseProfile.confusedBy {
            globalLearnerProfile.noteConfusedBy(concept)
        }
        saveGlobalLearnerProfile()
        print("🧠 Global learner profile updated with \(courseProfile.knows.count) knows from \(courseID)")
    }

    // MARK: - Engine LearnerModel bridge

    /// Sync the legacy CourseLearnerProfile into the engine's rich LearnerModel.
    /// Called on init and when courses complete.
    func syncToEngineLearnerModel(_ engine: TeachyEngine) {
        let legacyProfile = globalLearnerProfile
        if engine.getLearnerModel().skillNodes.isEmpty && (!legacyProfile.knows.isEmpty || !legacyProfile.confusedBy.isEmpty) {
            let migratedModel = LearnerModel(from: legacyProfile)
            engine.setLearnerModel(migratedModel)
            print("🧠 Migrated legacy learner profile to engine LearnerModel (\(migratedModel.skillNodes.count) skills)")
        }
    }

    // MARK: - Open-ended course builder

    /// Generates a custom course plan from a user's description using the LLM.
    func generateCustomCoursePlan(
        description: String,
        apiClient: ClaudeAPI
    ) async throws -> ClickyCourse {
        let systemPrompt = """
        You are a curriculum designer for Teachy, a macOS teaching companion.
        Given a user's description of what they want to learn or build, create a structured course plan.

        Return ONLY a JSON object with this exact structure (no markdown, no explanation):
        {
            "title": "Course Title",
            "subtitle": "One-line description",
            "description": "What they'll learn",
            "estimatedMinutes": 30,
            "learningOutcomes": ["outcome 1", "outcome 2", "outcome 3"],
            "goals": [
                {
                    "id": "goal-1",
                    "title": "Goal Title",
                    "goal": "Success looks like: ...",
                    "coachAsk": "Teaching prompt for this goal",
                    "doneWhen": "How to verify this goal is done"
                }
            ]
        }

        Rules:
        - 3-6 goals, each building on the previous
        - Goals should be concrete and verifiable
        - coachAsk should be a clear teaching instruction
        - doneWhen should be a natural language description of completion
        - Keep it practical — the user is building something, not just learning theory
        - If they already know something (from global learner profile), skip it or make it optional
        """

        let learnerContext: String
        if globalLearnerProfile != CourseLearnerProfile() {
            learnerContext = "\n\nLearner already knows: \(globalLearnerProfile.knows.joined(separator: "; "))"
        } else {
            learnerContext = ""
        }

        let response = try await apiClient.generateText(
            systemPrompt: systemPrompt,
            userPrompt: "Create a course plan for: \(description)\(learnerContext)"
        )

        // Parse the JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let subtitle = json["subtitle"] as? String,
              let description = json["description"] as? String,
              let estimatedMinutes = json["estimatedMinutes"] as? Int,
              let learningOutcomes = json["learningOutcomes"] as? [String],
              let goalsJSON = json["goals"] as? [[String: Any]] else {
            throw NSError(
                domain: "CoursesManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse course plan"]
            )
        }

        let goals = Self.parseCourseLearningGoals(fromGoalsJSON: goalsJSON)

        let courseID = "custom-\(UUID().uuidString.prefix(8))"
        return ClickyCourse(
            id: courseID,
            title: title,
            subtitle: subtitle,
            description: description,
            iconSystemName: "sparkles",
            estimatedMinutes: estimatedMinutes,
            startURL: nil,
            introVideoURL: nil,
            teacherVideoURL: nil,
            teacherName: nil,
            learningOutcomes: learningOutcomes,
            goals: goals,
            trackID: nil,
            trackTitle: nil,
            trackOrder: nil,
            prerequisiteCourseIDs: nil
        )
    }

    /// Shared JSON-goal-array → `CourseLearningGoal` decoding, used by both
    /// `generateCustomCoursePlan` (full course) and `generateGuidedTaskSteps`
    /// (ephemeral companion walkthrough) so the two generators stay in sync.
    private static func parseCourseLearningGoals(fromGoalsJSON goalsJSON: [[String: Any]]) -> [CourseLearningGoal] {
        goalsJSON.compactMap { goalJSON -> CourseLearningGoal? in
            guard let id = goalJSON["id"] as? String,
                  let title = goalJSON["title"] as? String,
                  let goal = goalJSON["goal"] as? String,
                  let coachAsk = goalJSON["coachAsk"] as? String,
                  let doneWhen = goalJSON["doneWhen"] as? String else {
                return nil
            }
            return CourseLearningGoal(
                id: id,
                title: title,
                goal: goal,
                coachAsk: coachAsk,
                doneWhen: doneWhen
            )
        }
    }

    /// Lightweight sibling of `generateCustomCoursePlan`, for the companion's ephemeral
    /// guided walkthroughs (`CompanionGuidedTask`). Same generation mechanism (one
    /// `ClaudeAPI.generateText` call, JSON-in) but asks for 2-5 short ad-hoc steps only —
    /// no course title/subtitle/estimatedMinutes/learningOutcomes ceremony, since these
    /// steps are never shown in any Course UI and never persisted.
    func generateGuidedTaskSteps(
        taskDescription: String,
        apiClient: ClaudeAPI,
        groundingKnowledge: String? = nil
    ) async throws -> [CourseLearningGoal] {
        let systemPrompt = """
        You are helping Teachy, a macOS teaching companion, put together a short ad-hoc
        walkthrough for a quick spoken question — not a full course, just enough concrete
        steps to guide someone through a task on their screen.

        Return ONLY a JSON object with this exact structure (no markdown, no explanation):
        {
            "steps": [
                {
                    "id": "step-1",
                    "title": "Step Title",
                    "goal": "Success looks like: ...",
                    "coachAsk": "Teaching prompt for this step",
                    "doneWhen": "How to verify this step is done by looking at the screen"
                }
            ]
        }

        Rules:
        - 2-5 steps, each building on the previous
        - Each step must be concrete and verifiable by looking at the screen
        - doneWhen should be a short natural-language description of what "done" looks like on screen
        - Keep it tight — this is a quick walkthrough, not a lesson plan
        """

        let learnerContext: String
        if globalLearnerProfile != CourseLearnerProfile() {
            learnerContext = "\n\nLearner already knows: \(globalLearnerProfile.knows.joined(separator: "; "))"
        } else {
            learnerContext = ""
        }

        // When this walkthrough matched a `TeachyRecommendedToolRegistry` entry (e.g.
        // Vapi for phone/voice agents), ground the generated steps in real knowledge
        // about that tool instead of the model guessing generic UI from scratch.
        let groundingContext: String
        if let groundingKnowledge, !groundingKnowledge.isEmpty {
            groundingContext = "\n\nGround the steps in this real knowledge about the tool being used: \(groundingKnowledge)"
        } else {
            groundingContext = ""
        }

        let response = try await apiClient.generateText(
            systemPrompt: systemPrompt,
            userPrompt: "Create short walkthrough steps for: \(taskDescription)\(learnerContext)\(groundingContext)"
        )

        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stepsJSON = json["steps"] as? [[String: Any]] else {
            throw NSError(
                domain: "CoursesManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse guided task steps"]
            )
        }

        return Self.parseCourseLearningGoals(fromGoalsJSON: stepsJSON)
    }

    /// Layer 3: Reflect on what went wrong and return a revised list of remaining steps.
    ///
    /// Called only when reality diverged from the plan (verification `.offTrack`, an `.act`
    /// step's tool loop failed, or post-act verification failed). Mirrors `generateAgenticPlan`
    /// in structure — sends the fresh screenshot + current plan state + divergence description
    /// to the reasoning model, which returns a replacement list for the current-and-remaining
    /// steps. Completed steps (indices < `currentStepIndex`) are kept intact by the caller.
    ///
    /// Returns the revised `[AgenticStep]` list starting from what should now be the active
    /// step. On any failure, throws so the caller can gracefully fall back to coaching.
    func reflectAndRevisePlan(
        taskTitle: String,
        allSteps: [AgenticStep],
        currentStepIndex: Int,
        whatWentWrong: String,
        screenCapture: CompanionScreenCapture?,
        apiClient: ClaudeAPI
    ) async throws -> [AgenticStep] {
        // Build a human-readable summary of the full current plan so the reasoning model
        // has the complete picture — completed steps, the current (diverged) step, and
        // remaining steps — when deciding what to revise.
        let planSummaryLines = allSteps.enumerated().map { index, agenticStep in
            let statusMarker: String
            if index < currentStepIndex {
                statusMarker = "[DONE]"
            } else if index == currentStepIndex {
                statusMarker = "[CURRENT — DIVERGED]"
            } else {
                statusMarker = "[REMAINING]"
            }
            return "\(statusMarker) \(index + 1). \(agenticStep.goal.title) (\(agenticStep.executionMode.rawValue)): \(agenticStep.goal.goal)"
        }.joined(separator: "\n")

        let systemPrompt = """
        You are the replanning brain for Teachy, a macOS teaching companion. A step in a
        guided task just went off-track and the plan needs to be revised.

        You will receive:
        - The original task title
        - The full current plan (showing which steps are done, which diverged, which remain)
        - What went wrong (why the current step failed or was off-track)
        - A fresh screenshot of what the screen looks like RIGHT NOW

        Your job: look at the screen and the divergence, then return a revised list of steps
        covering the CURRENT STEP ONWARD (do not include already-completed steps). You may:
        - Insert a prerequisite step before the current one (e.g. "need to log in first")
        - Replace the current step with a different approach
        - Reorder remaining steps if that makes more sense now
        - Keep steps unchanged if they're still correct

        Return ONLY a JSON object (no markdown fences, no explanation):
        {
            "steps": [
                {
                    "id": "step-1",
                    "title": "Step Title",
                    "goal": "Success looks like: ...",
                    "coachAsk": "Teaching prompt Teachy should use when guiding this step",
                    "doneWhen": "Natural-language description of what 'done' looks like on screen",
                    "executionMode": "coach"
                }
            ]
        }

        executionMode rules — same as original planning:
        - "coach": user does it, Teachy guides. Use for learning moments, risky/irreversible steps.
        - "act": Teachy executes mechanically (click/navigate/fill) — only purely mechanical setup.
        - Default to "coach" whenever in doubt. Never mark destructive/financial steps "act".

        Keep the revised plan tight — 2-5 steps from current point onward.
        """

        let userPrompt = """
        Task: \(taskTitle)

        Current plan:
        \(planSummaryLines)

        What went wrong: \(whatWentWrong)

        Please revise the plan from the current step onward.
        """

        let rawJSONResponse = try await apiClient.generateReasonedPlanJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imageJPEGData: screenCapture?.imageData,
            imageLabel: screenCapture?.label,
            screenshotWidthInPixels: screenCapture?.screenshotWidthInPixels ?? 0,
            screenshotHeightInPixels: screenCapture?.screenshotHeightInPixels ?? 0,
            modelID: OpenRouterModelOption.reasoningPlannerModelID
        )

        // Strip markdown fences the reasoning model sometimes wraps its output in.
        let jsonStringForParsing = rawJSONResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let responseData = jsonStringForParsing.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let stepsJSON = json["steps"] as? [[String: Any]] else {
            throw NSError(
                domain: "CoursesManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse revised steps from reflection model response"]
            )
        }

        let revisedCourseLearningGoals = Self.parseCourseLearningGoals(fromGoalsJSON: stepsJSON)

        return revisedCourseLearningGoals.enumerated().map { index, courseLearningGoal in
            let rawStepJSON = index < stepsJSON.count ? stepsJSON[index] : [:]
            let rawExecutionMode = rawStepJSON["executionMode"] as? String ?? "coach"
            let executionMode = GuidedStepExecutionMode(rawValue: rawExecutionMode) ?? .coach
            return AgenticStep(goal: courseLearningGoal, executionMode: executionMode)
        }
    }

    /// Screen-grounded, reasoning-model plan generator — Layer 1 upgrade over `generateGuidedTaskSteps`.
    ///
    /// Sends a real screenshot to `google/gemini-2.5-pro` with high reasoning effort so the plan
    /// is decomposed against what's *actually on screen right now*, not a blind guess from the task
    /// title alone. Each step comes back with an `executionMode` tag (`coach` or `act`).
    ///
    /// Layer 1 behavior: `executionMode` is recorded on each `AgenticStep` but has no behavioral
    /// effect — all steps are coached regardless of tag. Acting is wired in Layer 2.
    func generateAgenticPlan(
        taskDescription: String,
        screenCapture: CompanionScreenCapture?,
        learnerContext: String?,
        groundingKnowledge: String?,
        apiClient: ClaudeAPI
    ) async throws -> [AgenticStep] {
        let systemPrompt = """
        You are the planning brain for Teachy, a macOS teaching companion. Your job is to
        look at what's ACTUALLY on the user's screen right now and decompose the task into
        a concrete, screen-grounded plan.

        Return ONLY a JSON object with this exact structure (no markdown fences, no explanation):
        {
            "steps": [
                {
                    "id": "step-1",
                    "title": "Step Title",
                    "goal": "Success looks like: ...",
                    "coachAsk": "Teaching prompt Teachy should use when guiding this step",
                    "doneWhen": "Natural-language description of what 'done' looks like on screen",
                    "executionMode": "coach"
                }
            ]
        }

        executionMode rules — think carefully:
        - "coach": user does it, Teachy guides. Use this for anything that is a genuine learning
          moment, requires judgment, is risky, irreversible, financial, or where doing it yourself
          would deprive the user of understanding.
        - "act": Teachy should execute this step itself (click, navigate, fill a form field) — only
          for purely mechanical/tedious/unambiguous setup with zero learning value (e.g. open a URL,
          navigate to a specific page, click an obvious button to reach a starting point).
        - Default to "coach" whenever in doubt. Never mark anything destructive, irreversible, or
          financial as "act". Never mark a step "act" if it's a genuine skill moment.

        Planning rules:
        - 2-5 steps, each building on the previous
        - Ground each step in what you can actually SEE on screen right now — reference real UI
          elements, current state, and any obstacles visible (login walls, wrong page, etc.)
        - Each step must be concretely verifiable by looking at the screen
        - doneWhen: short natural-language description of what "done" looks like visually
        - Think hard about the real sequence: what order makes sense given the current screen state?
        """

        // Build learner-context section from the CourseLearnerProfile `knows` array —
        // same context `generateGuidedTaskSteps` includes, kept consistent.
        let learnerProfileContext: String
        if let learnerContext, !learnerContext.isEmpty {
            learnerProfileContext = "\n\nLearner context: \(learnerContext)"
        } else if globalLearnerProfile != CourseLearnerProfile() {
            // Fall back to reading the profile directly, just as `generateGuidedTaskSteps` does.
            learnerProfileContext = "\n\nLearner already knows: \(globalLearnerProfile.knows.joined(separator: "; "))"
        } else {
            learnerProfileContext = ""
        }

        let groundingContext: String
        if let groundingKnowledge, !groundingKnowledge.isEmpty {
            groundingContext = "\n\nGround the steps in this real knowledge about the tool being used: \(groundingKnowledge)"
        } else {
            groundingContext = ""
        }

        let userPrompt = "Plan the walkthrough for: \(taskDescription)\(learnerProfileContext)\(groundingContext)"

        let rawJSONResponse = try await apiClient.generateReasonedPlanJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imageJPEGData: screenCapture?.imageData,
            imageLabel: screenCapture?.label,
            screenshotWidthInPixels: screenCapture?.screenshotWidthInPixels ?? 0,
            screenshotHeightInPixels: screenCapture?.screenshotHeightInPixels ?? 0,
            modelID: OpenRouterModelOption.reasoningPlannerModelID
        )

        // The reasoning model sometimes wraps its output in markdown fences — strip them
        // before JSON parsing so a stray ```json block doesn't blow up the parse.
        let jsonStringForParsing = rawJSONResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let responseData = jsonStringForParsing.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let stepsJSON = json["steps"] as? [[String: Any]] else {
            throw NSError(
                domain: "CoursesManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse agentic plan steps from reasoning model response"]
            )
        }

        let courseLearningGoals = Self.parseCourseLearningGoals(fromGoalsJSON: stepsJSON)

        return courseLearningGoals.enumerated().map { index, courseLearningGoal in
            // Parse the `executionMode` field from the raw JSON step; default to `.coach`
            // when absent or unrecognized — safety-first, never silently act when unsure.
            let rawStepJSON = index < stepsJSON.count ? stepsJSON[index] : [:]
            let rawExecutionMode = rawStepJSON["executionMode"] as? String ?? "coach"
            let executionMode = GuidedStepExecutionMode(rawValue: rawExecutionMode) ?? .coach
            return AgenticStep(goal: courseLearningGoal, executionMode: executionMode)
        }
    }
}
