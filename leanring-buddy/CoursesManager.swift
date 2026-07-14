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
    private static let simplifiedCatalogUserDefaultsKey = "teachyPreferSimplifiedCatalog"
    private static let bundledCourseIDs: Set<String> = Set(ClickyCourseCatalog.bundledCourses.map(\.id))

    var isCourseActive: Bool { activeSession != nil }

    init() {
        loadProgressFromDisk()
        loadInstalledCourseSourcesFromDisk()
        preferSimplifiedCatalog = UserDefaults.standard.object(forKey: Self.simplifiedCatalogUserDefaultsKey) as? Bool ?? true
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
        if progress(forCourseID: "ai-first-win")?.isFullyCompleted != true {
            return course(withID: "ai-first-win")
        }
        if progress(forCourseID: "ai-to-code")?.isFullyCompleted != true {
            return course(withID: "ai-to-code")
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
        completionCelebration = CourseCompletionCelebration(
            courseID: course.id,
            title: course.title,
            message: course.id == "ai-first-win"
                ? "You built something with AI. Next up: Use AI to Code."
                : "You finished \(course.title). That’s a real outcome — keep going."
        )
        if course.id == "ai-first-win" {
            // After first win, gently open the full catalog.
            setPreferSimplifiedCatalog(false)
        }
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
            stepConversationHistory: []
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
        if course.id == "ai-first-win" {
            return "yo that’s a real win — you made something with AI. next up, Use AI to Code whenever you’re ready."
        }
        if course.id == "ai-to-code" {
            return "you finished Use AI to Code. that’s a real build — i’m hyped for you."
        }
        return "nice — you finished \(course.title). that one’s yours now. keep going when you feel it."
    }

    /// Goal-based courses use `ClickyCourseCatalog.courseCoachSystemPrompt`.
    func buildCourseSystemPrompt(for session: ClickyCourseSession) -> String {
        ClickyCourseCatalog.courseCoachSystemPrompt(
            for: session,
            learnerProfile: learnerProfile,
            activeTeacherVideoNotes: activeTeacherVideoNotes
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
    }
}
