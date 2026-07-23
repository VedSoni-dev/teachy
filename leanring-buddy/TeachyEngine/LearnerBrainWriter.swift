//
//  LearnerBrainWriter.swift
//  leanring-buddy
//
//  Mirrors Teachy's live learning signals into the durable, evidence-cited
//  learner record ("MyChart for education" — see learner-brain/README.md).
//
//  The key idea: Teachy ALREADY produces every signal this record needs — they
//  all flow through `TeachyEngine.processEvent(_:)` today and collapse into a
//  flat blob. This writer restructures the same signals into typed pages and
//  typed edges, so a skill's proficiency ends up BACKED BY the teachbacks and
//  reviews that earned it, instead of merely asserted by a number.
//
//  Nothing new has to be measured — only restructured. The writer is additive
//  and nil-safe: with no client (pre-P1) it is simply absent and Teachy behaves
//  exactly as before.
//

import Foundation

/// A Sendable snapshot of just enough engine state to write a record entry,
/// captured on the main actor before the (async) write. Keeps the writer from
/// reaching back into live, mutating engine state.
struct LearnerBrainContext {
    let occurredAt: Date
    let sessionID: String?
    let courseID: String?
    let currentGoalID: String?
    /// Skills the current goal exercises (from the engine's goal→skill mapping).
    /// A teach-back during this goal `demonstrates` these skills.
    let currentGoalSkillIDs: [String]
    /// skillID → human-readable skill name, for any skill page we touch.
    let skillNames: [String: String]
    /// skillID → current proficiency (displayName), for skill-page frontmatter.
    let skillProficiencies: [String: String]
}

@MainActor
final class LearnerBrainWriter {
    private let client: GBrainClient

    init(client: GBrainClient) {
        self.client = client
    }

    // MARK: - Event mirror (called from TeachyEngine.processEvent)

    /// Translate one learner event into record writes. Best-effort: any failure
    /// is logged and swallowed so the coaching path is never affected.
    func mirror(_ event: LearnerEvent, context: LearnerBrainContext) async {
        guard await client.isBrainReady() else { return }
        do {
            switch event {
            case .courseStarted(let courseID):
                try await upsertCoursePage(courseID: courseID, completed: false)
                try await writeSessionPage(context: context, courseID: courseID)

            case .goalAttempted(let goalID, let attemptDescription):
                try await upsertGoalPage(goalID: goalID, note: attemptDescription, completed: false, context: context)
                if let sessionSlug = sessionSlug(context) {
                    try await client.addLink(fromSlug: sessionSlug, toSlug: goalSlug(goalID), linkType: "targets")
                }

            case .goalCompleted(let goalID, let verificationSummary):
                try await upsertGoalPage(goalID: goalID, note: verificationSummary, completed: true, context: context)

            case .teachBackResponse(let responseText):
                try await writeTeachBackPage(explanation: responseText, context: context)

            case .retentionCheckAnswered(let skillID, let correct, let responseTimeMs):
                try await writeReviewPage(skillID: skillID, correct: correct, responseTimeMs: responseTimeMs, context: context)

            case .skillUsed(let skillID, _):
                try await upsertSkillPage(skillID: skillID, context: context)

            case .personalFactShared(let factText):
                try await appendLearnerFact(factText, context: context)

            case .courseCompleted(let courseID):
                try await upsertCoursePage(courseID: courseID, completed: true)

            case .screenCaptured, .actionPerformed, .questionAsked,
                 .sessionResumed, .sessionPaused, .userMoodDetected:
                break
            }
        } catch {
            logFailure(error)
        }
    }

    // MARK: - The "I shipped it" moment (called from TeachyEngine.shipProject)

    /// Record a shipped artifact — the deployed thing the learner built. This is
    /// the data source behind the shareable "I shipped it" receipt (Approach A):
    /// an `artifact` page that `evidences` each skill it took to build.
    func recordShippedArtifact(
        projectID: String,
        title: String,
        deployedURL: String?,
        skillIDs: [String],
        context: LearnerBrainContext
    ) async {
        guard await client.isBrainReady() else { return }
        let slug = "artifacts/\(slugSafe(projectID))"
        var frontmatter: [String: String] = [
            "title": title,
            "date": dateStamp(context.occurredAt),
            "status": "shipped",
        ]
        if let deployedURL, !deployedURL.isEmpty {
            frontmatter["deployed_url"] = deployedURL
        }
        let body = "# \(title)\n\nShipped and deployed by the learner"
            + (deployedURL.map { " — live at \($0)" } ?? "")
            + "."
        do {
            try await client.writePage(slug: slug, pageType: "artifact", frontmatter: frontmatter, bodyMarkdown: body)
            for skillID in skillIDs {
                try await client.addLink(fromSlug: slug, toSlug: skillSlug(skillID), linkType: "evidences")
            }
            if let goalID = context.currentGoalID {
                try await client.addLink(fromSlug: slug, toSlug: goalSlug(goalID), linkType: "evidences")
            }
        } catch {
            logFailure(error)
        }
    }

    /// Upsert a skill page with the current proficiency. Called when a skill's
    /// level changes (e.g. from a completed goal), so the number on the page
    /// stays current while its *justification* lives in the incoming edges.
    func recordSkillLevel(skillID: String, skillName: String, proficiency: String, context: LearnerBrainContext) async {
        guard await client.isBrainReady() else { return }
        do {
            try await writeSkillPage(skillID: skillID, skillName: skillName, proficiency: proficiency, context: context)
        } catch {
            logFailure(error)
        }
    }

    // MARK: - Page writers

    private func upsertCoursePage(courseID: String, completed: Bool) async throws {
        let frontmatter: [String: String] = [
            "course_id": courseID,
            "status": completed ? "completed" : "active",
        ]
        try await client.writePage(
            slug: courseSlug(courseID),
            pageType: "course",
            frontmatter: frontmatter,
            bodyMarkdown: "# Course: \(courseID)"
        )
    }

    private func writeSessionPage(context: LearnerBrainContext, courseID: String?) async throws {
        guard let sessionSlug = sessionSlug(context) else { return }
        var frontmatter: [String: String] = ["date": dateStamp(context.occurredAt)]
        if let courseID { frontmatter["course"] = courseSlug(courseID) }
        try await client.writePage(
            slug: sessionSlug,
            pageType: "session",
            frontmatter: frontmatter,
            bodyMarkdown: "# Learning session \(dateStamp(context.occurredAt))"
        )
        if let courseID {
            try await client.addLink(fromSlug: sessionSlug, toSlug: courseSlug(courseID), linkType: "part_of")
        }
    }

    private func upsertGoalPage(goalID: String, note: String, completed: Bool, context: LearnerBrainContext) async throws {
        var frontmatter: [String: String] = [
            "goal_id": goalID,
            "status": completed ? "done" : "in-progress",
        ]
        if let courseID = context.courseID { frontmatter["course"] = courseSlug(courseID) }
        try await client.writePage(
            slug: goalSlug(goalID),
            pageType: "goal",
            frontmatter: frontmatter,
            bodyMarkdown: "# Goal\n\n\(note)"
        )
    }

    private func writeTeachBackPage(explanation: String, context: LearnerBrainContext) async throws {
        // One page per teach-back; the timestamp keeps the slug unique and
        // sortable without needing a random id.
        let stamp = Int(context.occurredAt.timeIntervalSince1970)
        let slug = "teachbacks/\(dateStamp(context.occurredAt))-\(stamp)"
        let frontmatter: [String: String] = [
            "date": dateStamp(context.occurredAt),
            "verified": "explanation",
        ]
        let body = "# Teach-back \(dateStamp(context.occurredAt))\n\nThe learner explained:\n\n> \(explanation)"
        try await client.writePage(slug: slug, pageType: "teachback", frontmatter: frontmatter, bodyMarkdown: body)
        // The strongest evidence a skill page can cite: this explanation
        // demonstrates every skill the current goal exercises.
        for skillID in context.currentGoalSkillIDs {
            try await client.addLink(fromSlug: slug, toSlug: skillSlug(skillID), linkType: "demonstrates")
        }
    }

    private func writeReviewPage(skillID: String, correct: Bool, responseTimeMs: Int, context: LearnerBrainContext) async throws {
        // Mirror the engine's own review grading so the record agrees with the
        // spaced-repetition scheduler: fast+correct = recalled, slow+correct =
        // struggled, wrong = forgot.
        let outcome: String
        if correct {
            outcome = responseTimeMs < 5000 ? "recalled" : "struggled"
        } else {
            outcome = "forgot"
        }
        let stamp = Int(context.occurredAt.timeIntervalSince1970)
        let slug = "reviews/\(dateStamp(context.occurredAt))-\(slugSafe(skillID))-\(stamp)"
        let frontmatter: [String: String] = [
            "date": dateStamp(context.occurredAt),
            "skill": skillSlug(skillID),
            "outcome": outcome,
        ]
        let body = "# Review \(dateStamp(context.occurredAt)) — \(outcome)"
        try await client.writePage(slug: slug, pageType: "review", frontmatter: frontmatter, bodyMarkdown: body)
        try await client.addLink(fromSlug: slug, toSlug: skillSlug(skillID), linkType: "checks")
    }

    private func upsertSkillPage(skillID: String, context: LearnerBrainContext) async throws {
        let name = context.skillNames[skillID] ?? skillID
        let proficiency = context.skillProficiencies[skillID] ?? "novice"
        try await writeSkillPage(skillID: skillID, skillName: name, proficiency: proficiency, context: context)
    }

    private func writeSkillPage(skillID: String, skillName: String, proficiency: String, context: LearnerBrainContext) async throws {
        let frontmatter: [String: String] = [
            "skill_id": skillID,
            "proficiency": proficiency,
            "last_exercised": dateStamp(context.occurredAt),
        ]
        let body = "# \(skillName)\n\nProficiency is justified by the incoming `demonstrated_by` and `checked_by` edges — the moments that earned it."
        try await client.writePage(slug: skillSlug(skillID), pageType: "skill", frontmatter: frontmatter, bodyMarkdown: body)
    }

    private func appendLearnerFact(_ fact: String, context: LearnerBrainContext) async throws {
        // The learner page is a single durable identity page. We overwrite it
        // with the latest fact appended in the body; the timeline of when facts
        // were learned lives in the session pages, not here.
        let frontmatter: [String: String] = ["updated": dateStamp(context.occurredAt)]
        let body = "# Learner\n\nA fact the learner shared (\(dateStamp(context.occurredAt))): \(fact)"
        try await client.writePage(slug: "learner/me", pageType: "learner", frontmatter: frontmatter, bodyMarkdown: body)
    }

    // MARK: - Slug + date helpers

    private func courseSlug(_ id: String) -> String { "courses/\(slugSafe(id))" }
    private func goalSlug(_ id: String) -> String { "goals/\(slugSafe(id))" }
    private func skillSlug(_ id: String) -> String { "skills/\(slugSafe(id))" }
    private func sessionSlug(_ context: LearnerBrainContext) -> String? {
        guard let sessionID = context.sessionID else { return nil }
        return "sessions/\(slugSafe(sessionID))"
    }

    /// Lowercase, keep alphanumerics, collapse everything else to single dashes.
    private func slugSafe(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var result = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// yyyy-MM-dd in the POSIX/en-US-POSIX calendar so slugs are stable across
    /// locales. (Date.now / new Date are fine in Swift; this only formats.)
    private func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func logFailure(_ error: Error) {
        #if DEBUG
        print("[LearnerBrain] write failed: \(error)")
        #endif
    }
}
