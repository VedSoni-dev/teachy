//
//  RoutineTools.swift
//  leanring-buddy
//
//  Tools the agent model can call for routines and for a named agent's memory:
//  create_routine (asks first), list_routines, pause_routine, delete_routine
//  (asks every time), remember. Like every tool they only run through
//  AgentToolRegistry.invoke, and the routine-changing ones are left out of
//  unattended runs altogether (AgentJobCenter.toolNames).
//

import Foundation

private struct RoutineToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func describe(_ routine: Routine, calendar: Calendar = .autoupdatingCurrent) -> String {
    var parts = ["id \(routine.id.prefix(8))", routine.schedule.summary, routine.task]
    if let slug = routine.agentSlug { parts.append("agent: \(AgentRoster.shared.agent(slug: slug)?.name ?? slug)") }
    if routine.enabled {
        if let next = routine.nextRun(calendar: calendar) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM HH:mm"
            parts.append("next run \(formatter.string(from: next))")
        }
    } else {
        parts.append(routine.pausedReason ?? "paused")
    }
    if let status = routine.lastStatus { parts.append("last run: \(status)") }
    return parts.joined(separator: " | ")
}

final class CreateRoutineTool: BackgroundAgentTool {
    let name = "create_routine"
    let description = "Set up a routine: a task Teachy runs by itself on a schedule while the app is open. Use when the person asks for something to happen regularly (\"every weekday at 9 check my GitHub notifications\"). Routine runs cannot ask for permission, so they suit read-and-report work."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": ["type": "string", "description": "What to do each time, as a full instruction, without the schedule words."],
            "schedule": [
                "type": "object",
                "description": "One of: {\"kind\":\"every\",\"every\":30,\"unit\":\"minutes\"|\"hours\"}, {\"kind\":\"daily\",\"time\":\"09:00\"}, {\"kind\":\"weekdays\",\"time\":\"09:00\"}, {\"kind\":\"weekly\",\"day\":\"monday\",\"time\":\"09:00\"}. Times are 24-hour local time.",
                "properties": [
                    "kind": ["type": "string", "enum": ["every", "daily", "weekdays", "weekly"]],
                    "every": ["type": "integer"],
                    "unit": ["type": "string", "enum": ["minutes", "hours"]],
                    "time": ["type": "string"],
                    "day": ["type": "string"]
                ],
                "required": ["kind"]
            ] as [String: Any],
            "agent": ["type": "string", "description": "Name of the agent that should run it. Leave out to use the agent you are, or none."]
        ],
        "required": ["task", "schedule"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let scheduleJSON = arguments["schedule"] as? [String: Any] else {
            throw RoutineToolError(message: "schedule must be an object like {\"kind\":\"weekdays\",\"time\":\"09:00\"}.")
        }
        let schedule = try RoutineSchedule.parse(scheduleJSON)
        let task = (arguments["task"] as? String) ?? ""
        let agentSlug: String? = await MainActor.run {
            if let named = arguments["agent"] as? String, !named.trimmingCharacters(in: .whitespaces).isEmpty {
                return AgentRoster.bestMatch(for: named, among: AgentRoster.shared.reload())?.slug
            }
            return AgentJobContext.current?.agentSlug
        }
        if let named = arguments["agent"] as? String, !named.trimmingCharacters(in: .whitespaces).isEmpty, agentSlug == nil {
            throw RoutineToolError(message: "There is no agent called \(named).")
        }
        let routine = try await MainActor.run {
            try RoutineScheduler.shared.create(task: task, schedule: schedule, agentSlug: agentSlug)
        }
        return "Routine saved. " + describe(routine) + ". It runs while Teachy is open and cannot ask for permission during a run."
    }
}

final class ListRoutinesTool: BackgroundAgentTool {
    let name = "list_routines"
    let description = "List the person's routines: id, schedule, task, whether each is paused, and how the last run went."
    let jsonSchema: [String: Any] = ["type": "object", "properties": [String: Any]()]

    func execute(arguments: [String: Any]) async throws -> String {
        let routines = await MainActor.run { () -> [Routine] in
            RoutineScheduler.shared.loadIfNeeded()
            return RoutineScheduler.shared.routines
        }
        guard !routines.isEmpty else { return "There are no routines." }
        return routines.map { describe($0) }.joined(separator: "\n")
    }
}

final class PauseRoutineTool: BackgroundAgentTool {
    let name = "pause_routine"
    let description = "Pause a routine so it stops running, or resume a paused one. Get the id from list_routines."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "The routine's id (the first 8 characters are enough)."],
            "resume": ["type": "boolean", "description": "true to resume a paused routine. Default false (pause)."]
        ],
        "required": ["id"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let wanted = (arguments["id"] as? String) ?? ""
        let resume = (arguments["resume"] as? Bool) == true
        return try await MainActor.run {
            guard let routine = RoutineScheduler.shared.routine(matching: wanted) else {
                throw RoutineToolError(message: "No routine has the id \(wanted). Call list_routines for the ids.")
            }
            RoutineScheduler.shared.setEnabled(id: routine.id, resume)
            return resume ? "Resumed: \(routine.task)" : "Paused: \(routine.task)"
        }
    }
}

final class DeleteRoutineTool: BackgroundAgentTool {
    let name = "delete_routine"
    let description = "Delete a routine for good. Get the id from list_routines. Prefer pause_routine unless the person asked to delete it."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "The routine's id (the first 8 characters are enough)."]
        ],
        "required": ["id"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let wanted = (arguments["id"] as? String) ?? ""
        return try await MainActor.run {
            guard let routine = RoutineScheduler.shared.routine(matching: wanted) else {
                throw RoutineToolError(message: "No routine has the id \(wanted). Call list_routines for the ids.")
            }
            RoutineScheduler.shared.delete(id: routine.id)
            return "Deleted the routine: \(routine.task)"
        }
    }
}

/// Only offered to jobs run as a named agent: one more line in that agent's MEMORY.md.
final class RememberTool: BackgroundAgentTool {
    let name = "remember"
    let description = "Save one short note to your own memory so you have it in later jobs: a preference of the person, where something lives, what worked. One sentence. Never secrets, keys or passwords."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "note": ["type": "string", "description": "One short sentence worth knowing next time."]
        ],
        "required": ["note"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let note = (arguments["note"] as? String) ?? ""
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoutineToolError(message: "note is empty.")
        }
        if AgentRoster.looksLikeSecret(note) {
            throw RoutineToolError(message: "That looks like a secret. Teachy does not keep secrets in agent notes.")
        }
        return try await MainActor.run {
            guard let slug = AgentJobContext.current?.agentSlug else {
                throw RoutineToolError(message: "remember only works in a job run as a named agent.")
            }
            let added = try AgentRoster.shared.remember(note, slug: slug)
            return added ? "Saved to your notes." : "You already had that note."
        }
    }
}
