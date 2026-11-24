// Suggestion rules: parsing the model's answer, when to offer, what the job is told.
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let answer = """
Here you go:
```json
{"suggestions": [
 {"app": "Gmail", "minutes": 9, "headline": "I'll move next week's plans", "outcome": "3 replies, in your voice",
  "plan": ["See what's on", "Write to Sam and Aisha", "Leave replies in drafts", "Tell you", "extra step"],
  "result_location": "In your Gmail drafts", "task": "Draft replies moving next week's meetings."},
 {"app": "Linear", "headline": "I'll close stale tickets", "task": ""},
 {"app": "YouTube", "minutes": 900, "headline": "I'll score your thumbnails", "outcome": "what works", "plan": [], "task": "Score the thumbnails."},
 {"app": "Notes", "headline": "Old idea I tossed", "task": "x"},
 {"app": "Slack", "headline": "I'll summarize #design", "task": "Summarize."},
 {"app": "Calendar", "headline": "Fourth good one", "task": "y"}
]}
```
"""
var counter = 0
let parsed = TeachySuggestionRules.parse(modelAnswer: answer, dismissedHeadlines: ["old idea I TOSSED!"]) { counter += 1; return "s\(counter)" }
check(parsed.count == 3, "keeps at most three")
check(parsed.map(\.appName) == ["Gmail", "YouTube", "Slack"], "drops entries without a task and dismissed ideas")
check(parsed[0].planSteps.count == 4, "plan capped at four steps")
check(parsed[1].estimatedMinutes == 120, "minutes clamped")
check(parsed[0].symbolName == "envelope.fill" && parsed[2].symbolName.contains("bubble"), "app symbols")
check(TeachySuggestionRules.parse(modelAnswer: "[{\"headline\":\"A\",\"task\":\"B\"}]", dismissedHeadlines: []).count == 1, "bare array works")
check(TeachySuggestionRules.parse(modelAnswer: "no ideas today", dismissedHeadlines: []).isEmpty, "prose → nothing")
check(TeachySuggestionRules.parse(modelAnswer: "{\"suggestions\": []}", dismissedHeadlines: []).isEmpty, "empty list → nothing")

let instruction = TeachySuggestionRules.jobInstruction(for: parsed[0])
check(instruction.contains("1. See what's on") && instruction.contains("In your Gmail drafts"), "job gets the approved plan and destination")
check(instruction.contains("Never send, post"), "job is told results stay drafts")
check(TeachySuggestionRules.adjustedJobInstruction(for: parsed[0], change: "only Sam").hasSuffix("only Sam"), "adjust adds the change")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Chicago")!
let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9))!
let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 6))!
check(TeachySuggestionRules.shouldOffer(now: morning, lastOfferedDay: nil, isEnabled: true, isBusy: false, calendar: calendar), "offers in the morning")
check(!TeachySuggestionRules.shouldOffer(now: night, lastOfferedDay: nil, isEnabled: true, isBusy: false, calendar: calendar), "not before 8")
check(!TeachySuggestionRules.shouldOffer(now: morning, lastOfferedDay: "2026-11-23", isEnabled: true, isBusy: false, calendar: calendar), "once a day")
check(!TeachySuggestionRules.shouldOffer(now: morning, lastOfferedDay: nil, isEnabled: true, isBusy: true, calendar: calendar), "not while busy")
check(!TeachySuggestionRules.shouldOffer(now: morning, lastOfferedDay: nil, isEnabled: false, isBusy: false, calendar: calendar), "not when switched off")

var dismissed: [String] = []
for index in 0..<70 { dismissed = TeachySuggestionRules.remembering(dismissal: "idea \(index)", in: dismissed) }
dismissed = TeachySuggestionRules.remembering(dismissal: "IDEA 69", in: dismissed)
check(dismissed.count == TeachySuggestionRules.rememberedDismissalLimit && dismissed.last == "IDEA 69", "dismissals capped and de-duplicated")
check(TeachySuggestionRules.title(forCount: 1) == "1 thing I can take off your plate", "singular title")

print(failures == 0 ? "All suggestion checks passed." : "\(failures) suggestion check(s) failed.")
exit(failures == 0 ? 0 : 1)
