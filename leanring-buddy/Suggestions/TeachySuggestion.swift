//
//  TeachySuggestion.swift
//  leanring-buddy
//
//  Suggestions: a few things Teachy offers to take off the person's plate, shown
//  once a day from the notch ("3 things I can take off your plate"). Each one has
//  a plan the person sees before anything happens, and a task that becomes a
//  normal agent job when they press Do it. Nothing runs without that press, and
//  the task always leaves its results as drafts (never sends, posts or pays).
//
//  This file is the pure part: the model, reading the model's JSON answer, and
//  the rules for when to offer and what to keep. `SuggestionCenter` does the I/O.
//

import Foundation

struct TeachySuggestion: Codable, Identifiable, Equatable {
    let id: String
    /// The app or site it is about ("Gmail", "Linear", "YouTube"). Shown with its symbol.
    let appName: String
    /// An SF Symbol for the card's top strip.
    let symbolName: String
    /// Rough time the person saves, in minutes.
    let estimatedMinutes: Int
    /// First person, one line: "I'll draft replies to the 3 people waiting on you".
    let headline: String
    /// What they get, a few words: "3 replies, in your voice".
    let outcome: String
    /// Two to four short steps, shown before anything happens.
    let planSteps: [String]
    /// Where the result lands: "In your Gmail drafts".
    let resultLocation: String
    /// The full instruction for the agent job when the person presses Do it.
    let task: String
}

enum TeachySuggestionRules {
    static let maximumSuggestions = 3
    /// The first offer of the day waits until the morning.
    static let earliestHourToOffer = 8
    /// How many dismissed headlines are remembered, so the same idea isn't offered again.
    static let rememberedDismissalLimit = 60

    /// What the person sees in the notch: "3 things I can take off your plate".
    static func title(forCount count: Int) -> String {
        switch count {
        case 0: return "Nothing to take off your plate"
        case 1: return "1 thing I can take off your plate"
        default: return "\(count) things I can take off your plate"
        }
    }

    /// Added to every suggested task: results stay drafts and the person approves anything outward.
    static let draftsOnlyInstruction = "Leave every result as a draft or a file for the person to review. Never send, post, publish, buy, delete or pay; if a step needs that, stop there and say what is ready."

    /// The instruction the agent job gets for a suggestion the person said yes to.
    static func jobInstruction(for suggestion: TeachySuggestion) -> String {
        var lines = [suggestion.task.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !suggestion.planSteps.isEmpty {
            lines.append("The plan the person approved: " + suggestion.planSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " "))
        }
        if !suggestion.resultLocation.isEmpty {
            lines.append("Where the result should end up: \(suggestion.resultLocation).")
        }
        lines.append(draftsOnlyInstruction)
        return lines.joined(separator: "\n")
    }

    /// The instruction for "Adjust": the same idea with the person's change.
    static func adjustedJobInstruction(for suggestion: TeachySuggestion, change: String) -> String {
        jobInstruction(for: suggestion) + "\nThe person asked for this change first: \(change.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Whether to offer today's suggestions now.
    static func shouldOffer(
        now: Date,
        lastOfferedDay: String?,
        isEnabled: Bool,
        isBusy: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        guard isEnabled, !isBusy else { return false }
        guard calendar.component(.hour, from: now) >= earliestHourToOffer else { return false }
        return lastOfferedDay != dayKey(for: now, calendar: calendar)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Reads the model's answer: a JSON object `{"suggestions": [...]}` or a bare array, possibly
    /// inside a ```json fence. Drops incomplete entries, ideas the person already dismissed, and
    /// anything past the maximum.
    static func parse(modelAnswer: String, dismissedHeadlines: Set<String>, makeID: () -> String = { UUID().uuidString }) -> [TeachySuggestion] {
        guard let jsonText = extractJSON(from: modelAnswer),
              let data = jsonText.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let entries: [[String: Any]]
        if let object = decoded as? [String: Any], let list = object["suggestions"] as? [[String: Any]] {
            entries = list
        } else if let list = decoded as? [[String: Any]] {
            entries = list
        } else {
            return []
        }

        let normalizedDismissals = Set(dismissedHeadlines.map(normalizedHeadline))
        var suggestions: [TeachySuggestion] = []
        for entry in entries {
            func text(_ key: String) -> String { ((entry[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let headline = text("headline")
            let task = text("task")
            guard !headline.isEmpty, !task.isEmpty else { continue }
            guard !normalizedDismissals.contains(normalizedHeadline(headline)) else { continue }
            let planSteps = ((entry["plan"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let minutes = (entry["minutes"] as? NSNumber)?.intValue ?? 5
            let appName = text("app").isEmpty ? "Teachy" : text("app")
            suggestions.append(TeachySuggestion(
                id: makeID(),
                appName: appName,
                symbolName: symbol(forApp: appName),
                estimatedMinutes: min(max(minutes, 1), 120),
                headline: headline,
                outcome: text("outcome"),
                planSteps: Array(planSteps.prefix(4)),
                resultLocation: text("result_location"),
                task: task
            ))
            if suggestions.count == maximumSuggestions { break }
        }
        return suggestions
    }

    static func normalizedHeadline(_ headline: String) -> String {
        headline.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Adds a dismissed headline, keeping the newest `rememberedDismissalLimit`.
    static func remembering(dismissal headline: String, in dismissed: [String]) -> [String] {
        var updated = dismissed.filter { normalizedHeadline($0) != normalizedHeadline(headline) }
        updated.append(headline)
        return Array(updated.suffix(rememberedDismissalLimit))
    }

    /// A symbol for common apps; a generic one otherwise.
    static func symbol(forApp appName: String) -> String {
        let name = appName.lowercased()
        let table: [(String, String)] = [
            ("mail", "envelope.fill"), ("gmail", "envelope.fill"), ("outlook", "envelope.fill"),
            ("calendar", "calendar"), ("youtube", "play.rectangle.fill"), ("linkedin", "person.2.fill"),
            ("slack", "bubble.left.and.bubble.right.fill"), ("messages", "message.fill"),
            ("linear", "checklist"), ("jira", "checklist"), ("notion", "doc.text.fill"),
            ("github", "chevron.left.forwardslash.chevron.right"), ("drive", "folder.fill"),
            ("finder", "folder.fill"), ("files", "folder.fill"), ("sheets", "tablecells.fill"),
            ("excel", "tablecells.fill"), ("x", "text.bubble.fill"), ("twitter", "text.bubble.fill"),
            ("instagram", "camera.fill"), ("photos", "photo.fill"), ("notes", "note.text"),
            ("reminders", "checklist"), ("safari", "safari.fill"), ("chrome", "globe"),
        ]
        for (key, symbol) in table where name == key || name.contains(key) && key.count > 2 {
            return symbol
        }
        return "sparkles"
    }

    private static func extractJSON(from answer: String) -> String? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = text.range(of: "```") {
            let afterFence = text[fenceStart.upperBound...]
            let bodyStart = afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex
            if let fenceEnd = afterFence[bodyStart...].range(of: "```") {
                text = String(afterFence[bodyStart..<fenceEnd.lowerBound])
            }
        }
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }),
              start <= end
        else { return nil }
        return String(text[start...end])
    }

    /// The system prompt for the model that picks today's suggestions.
    static let systemPrompt = """
    You are Teachy, a Mac assistant that can do work for the person: it can use their apps, browser, \
    files and connected services, and leaves results as drafts for them to review.
    Pick up to 3 concrete things you could take off their plate today, based on what you know about \
    them below (their memory, recent chats and journal) and the apps they have connected. Good ideas \
    are specific, finish in minutes, and end in a draft or file: replies to people waiting on them, \
    tidying a backlog, a summary they keep asking for, follow-ups from a recent win, prep for \
    something coming up. Never suggest sending, posting, buying, deleting or paying anything. Skip \
    anything vague ("organize your life") or that needs information you don't have. If nothing good \
    comes to mind, return an empty list.
    Answer with JSON only, no prose:
    {"suggestions": [{
      "app": "Gmail",
      "minutes": 9,
      "headline": "I'll move next week's plans while you're away",   (first person, under 70 characters)
      "outcome": "3 replies, in your voice",                        (what they get, under 40 characters)
      "plan": ["See what's on next week", "Write to the 3 people affected", "Leave each reply in drafts"],
      "result_location": "In your Gmail drafts",
      "task": "The full instruction for an agent doing this, with every detail it needs."
    }]}
    """
}
