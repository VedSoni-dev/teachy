//
//  RoutineSchedule.swift
//  leanring-buddy
//
//  When a routine runs. Pure date maths (the calendar is passed in, so tests
//  pin a time zone) plus a strict reader for the small JSON a model writes:
//
//      {"kind":"every","every":30,"unit":"minutes"}
//      {"kind":"daily","time":"09:00"}
//      {"kind":"weekdays","time":"09:00"}
//      {"kind":"weekly","day":"monday","time":"09:00"}
//
//  Rules:
//  - One catch-up, never a backlog: a routine is due when its next slot after
//    the last run has passed. Running it moves "last run" to now, so however
//    many slots were missed while the Mac slept, it runs once.
//  - Clock changes: a time that does not exist on a spring-forward day runs at
//    the next time that does (02:30 becomes 03:00); a time that happens twice
//    on a fall-back day runs once.
//

import Foundation

nonisolated struct RoutineScheduleError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum RoutineSchedule: Equatable, Sendable {
    /// Every N minutes (hours are stored as minutes).
    case every(minutes: Int)
    case daily(hour: Int, minute: Int)
    /// Monday to Friday.
    case weekdays(hour: Int, minute: Int)
    /// `weekday`: 1 = Sunday … 7 = Saturday, as in `Calendar`.
    case weekly(weekday: Int, hour: Int, minute: Int)

    static let minimumIntervalMinutes = 5
    static let maximumIntervalMinutes = 7 * 24 * 60
    static let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    // MARK: Next run

    /// The first moment strictly after `date` at which this schedule fires.
    func nextFire(after date: Date, calendar: Calendar) -> Date {
        switch self {
        case .every(let minutes):
            return date.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        case .daily(let hour, let minute):
            return Self.next(after: date, hour: hour, minute: minute, weekday: nil, calendar: calendar)
        case .weekly(let weekday, let hour, let minute):
            return Self.next(after: date, hour: hour, minute: minute, weekday: weekday, calendar: calendar)
        case .weekdays(let hour, let minute):
            var candidate = Self.next(after: date, hour: hour, minute: minute, weekday: nil, calendar: calendar)
            // At most a weekend to skip.
            for _ in 0..<7 {
                let weekday = calendar.component(.weekday, from: candidate)
                if (2...6).contains(weekday) { return candidate }
                candidate = Self.next(after: candidate, hour: hour, minute: minute, weekday: nil, calendar: calendar)
            }
            return candidate
        }
    }

    private static func next(after date: Date, hour: Int, minute: Int, weekday: Int?, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let weekday { components.weekday = weekday }
        // `.nextTime`: a wall-clock time skipped by the clocks going forward moves to the next
        // real time. `.first`: a time that repeats when they go back counts once.
        var searchFrom = date
        for _ in 0..<3 {
            guard let found = calendar.nextDate(after: searchFrom, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { break }
            if isRepeatOfSameWallClockTime(found, as: date, calendar: calendar) {
                // The clocks went back and this is the same HH:MM a second time: it already ran.
                searchFrom = found
                continue
            }
            return found
        }
        return date.addingTimeInterval(24 * 3_600)
    }

    /// True when `later` shows the same day, hour and minute as `earlier` but is a different
    /// moment (the hour that happens twice when the clocks go back).
    private static func isRepeatOfSameWallClockTime(_ later: Date, as earlier: Date, calendar: Calendar) -> Bool {
        guard later > earlier, later.timeIntervalSince(earlier) <= 2 * 3_600 else { return false }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        return calendar.dateComponents(fields, from: later) == calendar.dateComponents(fields, from: earlier)
    }

    /// True when a run is owed: the slot after `anchor` (the last run, or when the routine was
    /// made if it has never run) is not in the future.
    func isDue(anchor: Date, now: Date, calendar: Calendar) -> Bool {
        nextFire(after: anchor, calendar: calendar) <= now
    }

    /// How many slots passed between `anchor` and `now` (for the record; only one run happens).
    func missedSlots(anchor: Date, now: Date, calendar: Calendar, cap: Int = 500) -> Int {
        var count = 0
        var cursor = anchor
        while count < cap {
            let next = nextFire(after: cursor, calendar: calendar)
            if next > now { break }
            count += 1
            cursor = next
        }
        return count
    }

    // MARK: Words

    var summary: String {
        func clock(_ hour: Int, _ minute: Int) -> String {
            let suffix = hour < 12 ? "am" : "pm"
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return minute == 0 ? "\(twelve) \(suffix)" : String(format: "%d:%02d %@", twelve, minute, suffix)
        }
        switch self {
        case .every(let minutes):
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return hours == 1 ? "Every hour" : "Every \(hours) hours"
            }
            return "Every \(minutes) minutes"
        case .daily(let hour, let minute):
            return "Every day at \(clock(hour, minute))"
        case .weekdays(let hour, let minute):
            return "Weekdays at \(clock(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            let name = Self.dayNames[max(1, min(7, weekday)) - 1].capitalized
            return "\(name)s at \(clock(hour, minute))"
        }
    }

    // MARK: Reading the JSON form

    /// Reads and checks a schedule. Throws a sentence that says what is wrong.
    static func parse(_ json: [String: Any]) throws -> RoutineSchedule {
        let kind = ((json["kind"] as? String) ?? (json["type"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch kind {
        case "every", "interval":
            guard let amount = integer(json["every"] ?? json["interval"] ?? json["n"]), amount > 0 else {
                throw RoutineScheduleError(message: "An \"every\" schedule needs a number, like every 30 minutes.")
            }
            let unit = ((json["unit"] as? String) ?? "minutes").lowercased()
            let minutes: Int
            if unit.hasPrefix("min") { minutes = amount } else if unit.hasPrefix("hour") || unit == "h" || unit == "hr" || unit == "hrs" { minutes = amount * 60 } else if unit.hasPrefix("day") { minutes = amount * 24 * 60 } else {
                throw RoutineScheduleError(message: "The unit must be minutes or hours, not \"\(unit)\".")
            }
            guard minutes >= minimumIntervalMinutes else {
                throw RoutineScheduleError(message: "Routines can run every \(minimumIntervalMinutes) minutes at the most.")
            }
            guard minutes <= maximumIntervalMinutes else {
                throw RoutineScheduleError(message: "The longest gap between runs is a week. Use a weekly schedule instead.")
            }
            return .every(minutes: minutes)
        case "daily", "weekdays", "weekly":
            let (hour, minute) = try time(from: json)
            if kind == "daily" { return .daily(hour: hour, minute: minute) }
            if kind == "weekdays" { return .weekdays(hour: hour, minute: minute) }
            guard let weekday = weekday(json["day"] ?? json["weekday"]) else {
                throw RoutineScheduleError(message: "A weekly schedule needs a day, like \"monday\".")
            }
            return .weekly(weekday: weekday, hour: hour, minute: minute)
        default:
            throw RoutineScheduleError(message: "The schedule kind must be every, daily, weekdays or weekly.")
        }
    }

    /// The same shape `parse` reads.
    var json: [String: Any] {
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch self {
        case .every(let minutes):
            return minutes % 60 == 0 ? ["kind": "every", "every": minutes / 60, "unit": "hours"] : ["kind": "every", "every": minutes, "unit": "minutes"]
        case .daily(let hour, let minute):
            return ["kind": "daily", "time": clock(hour, minute)]
        case .weekdays(let hour, let minute):
            return ["kind": "weekdays", "time": clock(hour, minute)]
        case .weekly(let weekday, let hour, let minute):
            return ["kind": "weekly", "day": Self.dayNames[max(1, min(7, weekday)) - 1], "time": clock(hour, minute)]
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double == double.rounded() ? number.intValue : nil
        }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func weekday(_ value: Any?) -> Int? {
        if let number = integer(value) { return (1...7).contains(number) ? number : nil }
        guard let text = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces), text.count >= 3 else { return nil }
        return dayNames.firstIndex { $0 == text || $0.hasPrefix(text) }.map { $0 + 1 }
    }

    /// "09:00", "9:30", "21:15", "9", "9am", "9:30 pm", or separate hour / minute numbers.
    private static func time(from json: [String: Any]) throws -> (Int, Int) {
        if let hour = integer(json["hour"]) {
            let minute = integer(json["minute"]) ?? 0
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw RoutineScheduleError(message: "That is not a time of day.")
            }
            return (hour, minute)
        }
        let raw: String
        if let text = json["time"] as? String { raw = text } else if let number = integer(json["time"]) { raw = String(number) } else {
            throw RoutineScheduleError(message: "The schedule needs a time, like \"09:00\".")
        }
        var text = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
            meridiem = suffix
            text = String(text.dropLast(2))
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), var hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0 else {
            throw RoutineScheduleError(message: "\"\(raw)\" is not a time. Use 24-hour HH:MM, like 09:00 or 17:30.")
        }
        if let meridiem {
            guard (1...12).contains(hour) else { throw RoutineScheduleError(message: "\"\(raw)\" is not a time.") }
            if meridiem == "am" { hour = hour == 12 ? 0 : hour } else { hour = hour == 12 ? 12 : hour + 12 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw RoutineScheduleError(message: "\"\(raw)\" is not a time of day.")
        }
        return (hour, minute)
    }
}

extension RoutineSchedule: Codable {
    private struct Wire: Codable {
        var kind: String
        var every: Int?
        var unit: String?
        var time: String?
        var day: String?
    }

    init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        var json: [String: Any] = ["kind": wire.kind]
        if let every = wire.every { json["every"] = every }
        if let unit = wire.unit { json["unit"] = unit }
        if let time = wire.time { json["time"] = time }
        if let day = wire.day { json["day"] = day }
        do {
            self = try RoutineSchedule.parse(json)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription))
        }
    }

    func encode(to encoder: Encoder) throws {
        let json = self.json
        try Wire(
            kind: json["kind"] as? String ?? "",
            every: json["every"] as? Int,
            unit: json["unit"] as? String,
            time: json["time"] as? String,
            day: json["day"] as? String
        ).encode(to: encoder)
    }
}

// MARK: - Turning a sentence into a routine (the model's answer, checked)

/// What the model returns for "every weekday at 9 check my GitHub notifications".
nonisolated struct RoutineDraft: Equatable, Sendable {
    var task: String
    var schedule: RoutineSchedule
    /// The agent named in the sentence, if any (matched against the roster by the caller).
    var agentName: String?

    static let systemPrompt = """
    You turn one sentence into a scheduled routine. Reply with ONE JSON object and nothing else:
    {"task": "<what to do each time, as an instruction, without the schedule words>", "schedule": <schedule>, "agent": "<agent name if one is named, else null>"}
    Keep the task in the person's own words: "my" stays "my" (an assistant working for this person reads it later).
    <schedule> is exactly one of:
    {"kind":"every","every":<whole number>,"unit":"minutes"|"hours"}
    {"kind":"daily","time":"HH:MM"}
    {"kind":"weekdays","time":"HH:MM"}        (Monday to Friday)
    {"kind":"weekly","day":"monday"|"tuesday"|"wednesday"|"thursday"|"friday"|"saturday"|"sunday","time":"HH:MM"}
    Times are 24-hour local time. "morning" with no time is 09:00, "noon" 12:00, "afternoon" 15:00, "evening" 18:00, "night" 21:00. \
    "hourly" is every 1 hours. "twice a day" is every 12 hours. "every day" with no time is daily at 09:00.
    If the sentence has no schedule at all, or asks for something these four shapes cannot express \
    (several days a week that are not Monday to Friday, monthly, a date, "once"), reply {"error": "<one short sentence saying what you need>"}.
    """

    /// Reads the model's reply. Accepts the JSON bare or inside a code fence. Throws a plain sentence on anything off.
    static func parse(modelReply: String) throws -> RoutineDraft {
        guard let object = firstJSONObject(in: modelReply) else {
            throw RoutineScheduleError(message: "I could not work out a schedule from that. Try \"every weekday at 9, …\".")
        }
        if let error = object["error"] as? String, !error.trimmingCharacters(in: .whitespaces).isEmpty {
            throw RoutineScheduleError(message: error)
        }
        guard let scheduleJSON = object["schedule"] as? [String: Any] else {
            throw RoutineScheduleError(message: "I could not work out when that should run. Try \"every weekday at 9, …\".")
        }
        let schedule = try RoutineSchedule.parse(scheduleJSON)
        let task = ((object["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.count >= 3 else {
            throw RoutineScheduleError(message: "I got the schedule but not what to do. Say what the routine should do each time.")
        }
        let agent = (object["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RoutineDraft(task: String(task.prefix(1_000)), schedule: schedule, agentName: agent?.isEmpty == false && agent?.lowercased() != "null" ? agent : nil)
    }

    static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
