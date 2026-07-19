//
//  LearnerTemporalContext.swift
//  leanring-buddy
//
//  Pure helper that derives human-readable continuity phrases from temporal
//  signals that already exist in LearnerModel. None of these strings require
//  a network call — they are built from local dates only and injected into
//  coaching prompts so the model can reference time meaningfully.
//

import Foundation

enum LearnerTemporalContext {

    // MARK: - Primary API

    /// Build coaching-prompt continuity lines from existing temporal data.
    ///
    /// `daysSinceLastSession` is passed in rather than recomputed here because
    /// `TeachyEngine.startSession` captures the pre-update `lastActiveDate` before
    /// `recordActivity()` overwrites it — callers must snapshot it at that moment.
    ///
    /// Returns an empty array when no meaningful temporal signal applies (e.g. a
    /// brand-new learner on day 1 with no session gap to report), so callers can
    /// guard on `!lines.isEmpty` before adding a prompt section.
    static func continuityLines(
        model: LearnerModel,
        daysSinceLastSession: Int?
    ) -> [String] {
        var lines: [String] = []

        // How long this learner has been using Teachy in total.
        let totalDaysWithTeachy = Calendar.current.dateComponents(
            [.day],
            from: model.createdAt,
            to: Date()
        ).day ?? 0
        if totalDaysWithTeachy >= 1 {
            lines.append("You've been working with this learner for \(totalDaysWithTeachy) day\(totalDaysWithTeachy == 1 ? "" : "s").")
        }

        // Gap since the previous session — helps the coach pick up naturally.
        if let daysSince = daysSinceLastSession {
            if daysSince == 0 {
                lines.append("Back again the same day — they're on a roll.")
            } else if daysSince == 1 {
                lines.append("Last session was yesterday — good momentum.")
            } else if daysSince <= 3 {
                lines.append("Last session was \(daysSince) days ago — pick up where you left off.")
            } else if daysSince <= 7 {
                lines.append("It's been \(daysSince) days since the last session — a short re-warm may help.")
            } else {
                lines.append("It's been \(daysSince) days since they last showed up — they may need context re-established.")
            }
        }

        // Active streak — a signal the learner is building a habit.
        if model.currentStreakDays > 1 {
            lines.append("\(model.currentStreakDays)-day learning streak — acknowledge it.")
        }

        // Stale skills — flag the 1-2 most relevant for a potential refresher.
        let staleSkillLines = staleSkillReminderLines(from: model)
        lines.append(contentsOf: staleSkillLines)

        // Personality trend derived from humor-receptivity history.
        if let trendLine = humorTrendLine(from: model) {
            lines.append(trendLine)
        }

        return lines
    }

    // MARK: - Companion-mode short line

    /// A single short line for the non-course companion prompt when the learner
    /// is returning after a gap. Returns nil when there is no meaningful gap to
    /// mention (first session, or same-day return where no warmth nudge is needed).
    static func companionContinuityLine(daysSinceLastSession: Int?) -> String? {
        guard let daysSince = daysSinceLastSession, daysSince > 0 else { return nil }
        if daysSince == 1 {
            return "You've talked with this person before — last chat was yesterday. Be warm, pick up naturally, no re-introduction."
        } else if daysSince <= 7 {
            return "You've talked with this person before — last chat was \(daysSince) days ago. Be warm, don't reintroduce yourself."
        } else {
            return "You've talked with this person before — last chat was \(daysSince) days ago. Ease back in warmly, re-establish context gently."
        }
    }

    // MARK: - Daily-workflow recognition

    /// Summarizes which apps the learner recurringly works in, from `workflowSignals`
    /// (sightings captured only at conversation moments). Returns nil until at least
    /// one app has been seen 3+ times across 2+ distinct days — one-off sightings are
    /// noise, not a workflow. Feeds the companion prompt's AI-fluency recommendations.
    static func recurringWorkflowSummary(from model: LearnerModel) -> String? {
        let calendar = Calendar.current
        var sightingCountByApp: [String: Int] = [:]
        var distinctDaysByApp: [String: Set<Date>] = [:]

        for signal in model.workflowSignals {
            let appName = LearnerModel.workflowSignalAppName(from: signal.text)
            guard !appName.isEmpty else { continue }
            sightingCountByApp[appName, default: 0] += 1
            distinctDaysByApp[appName, default: []].insert(calendar.startOfDay(for: signal.capturedAt))
        }

        let recurringApps = sightingCountByApp
            .filter { appName, count in
                count >= 3 && (distinctDaysByApp[appName]?.count ?? 0) >= 2
            }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key) (\($0.value)×)" }

        guard !recurringApps.isEmpty else { return nil }
        return "They regularly work in: \(recurringApps.joined(separator: ", "))"
    }

    // MARK: - UI helper — relative date label

    /// Human-readable relative time label for use in the "Teachy remembers" UI.
    /// Examples: "just now", "2 days ago", "3 weeks ago", "4 months ago".
    static func relativeTimeLabel(for date: Date, relativeTo now: Date = Date()) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day, .weekOfYear, .month], from: date, to: now)

        if let months = components.month, months >= 2 {
            return "\(months) months ago"
        } else if let months = components.month, months == 1 {
            return "1 month ago"
        } else if let weeks = components.weekOfYear, weeks >= 2 {
            return "\(weeks) weeks ago"
        } else if let weeks = components.weekOfYear, weeks == 1 {
            return "1 week ago"
        } else if let days = components.day, days >= 2 {
            return "\(days) days ago"
        } else if let days = components.day, days == 1 {
            return "yesterday"
        } else if let hours = components.hour, hours >= 1 {
            return "\(hours)h ago"
        } else {
            return "just now"
        }
    }

    // MARK: - Private helpers

    /// Returns up to 2 reminder lines for skills that haven't been practiced in
    /// over 7 days. Capped at 2 to avoid flooding the prompt with skill noise.
    private static func staleSkillReminderLines(from model: LearnerModel) -> [String] {
        let staleThresholdDays = 7
        let staleSkills = model.skillNodes
            .filter { node in
                guard node.proficiencyLevel > .novice,
                      let daysSince = node.daysSinceLastVerified
                else { return false }
                return daysSince >= staleThresholdDays
            }
            .sorted { (nodeA, nodeB) -> Bool in
                // Prioritize skills with the highest day count — most overdue first.
                let daysA = nodeA.daysSinceLastVerified ?? 0
                let daysB = nodeB.daysSinceLastVerified ?? 0
                return daysA > daysB
            }
            .prefix(2)

        return staleSkills.compactMap { node in
            guard let daysSince = node.daysSinceLastVerified else { return nil }
            return "It's been \(daysSince) days since they practiced \(node.skillName) — a brief refresher may help."
        }
    }

    /// Derives a trend phrase from `humorReceptivityHistory` when there is a
    /// meaningful warming pattern across entries spanning at least 2 distinct days.
    /// Returns nil when history is too short or shows no clear trend.
    private static func humorTrendLine(from model: LearnerModel) -> String? {
        let history = model.humorReceptivityHistory
        // Need at least 3 entries to draw a meaningful trend.
        guard history.count >= 3 else { return nil }

        // Check that entries span multiple distinct calendar days.
        let distinctDays = Set(history.map { Calendar.current.startOfDay(for: $0.at) })
        guard distinctDays.count >= 2 else { return nil }

        let recentEntries = history.suffix(6)
        let warmCount = recentEntries.filter { $0.value == .warm }.count
        let efficientCount = recentEntries.filter { $0.value == .efficient }.count

        // Warming trend: recent entries have more warm signals than efficient.
        if warmCount >= 3 && warmCount > efficientCount {
            // Confirm the earliest entries in the window were not already all warm.
            let earliestEntry = history.prefix(3).last
            if earliestEntry?.value != .warm {
                return "They've warmed up over your recent sessions — lean into the rapport."
            }
        }

        // Cooling trend: recent entries trending toward efficient/business-only.
        if efficientCount >= 3 && efficientCount > warmCount {
            return "They've been in efficient mode lately — keep coaching tight and purposeful."
        }

        return nil
    }
}
