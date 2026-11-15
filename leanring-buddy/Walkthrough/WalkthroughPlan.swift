//
//  WalkthroughPlan.swift
//  leanring-buddy / Walkthrough
//
//  The planner's contract: the prompts that ask for a plan, a re-plan, a quick
//  yes/no check and a "how far did they get" check, and the strict reading of
//  what comes back. A plan is JSON:
//
//    {"steps":[{"say":"Click Me at the top right.",
//               "kind":"click",
//               "target":{"role":"button","label":"Me","point":[930,42]},
//               "doneWhen":"A menu with Settings & Privacy is open",
//               "check":{"type":"appears","role":"link","label":"Settings & Privacy"}}]}
//
//  or {"steps":[],"problem":"why it cannot be done"}.
//
//  Pure (Foundation). Tested by scripts/tests/run_walk_tests.sh.
//

import Foundation

enum WalkthroughPlanIssue: Equatable {
    /// The answer has to be asked for again.
    case invalid(String)
    /// This step says a failed step's words again. It is dropped if asking again does not fix it.
    case repeatsFailedStep(stepNumber: Int)

    var text: String {
        switch self {
        case .invalid(let text): return text
        case .repeatsFailedStep(let stepNumber): return "step \(stepNumber) repeats an instruction that already failed, word for word; say it differently or take another route"
        }
    }
}

struct WalkthroughPlanOutcome: Equatable {
    /// The steps that are individually valid, in order.
    var steps: [WalkthroughStep] = []
    /// Set when the planner said the goal cannot be walked through.
    var problem: String?
    var issues: [WalkthroughPlanIssue] = []
    /// Things that were fixed quietly (too many steps, an unknown check).
    var notes: [String] = []

    var isValid: Bool { issues.isEmpty && (problem != nil || !steps.isEmpty) }
}

enum WalkthroughPlanParser {
    static let maximumSayLength = 220

    static func parse(_ raw: String, maximumSteps: Int = WalkthroughSession.maximumSteps, forbiddenSays: [String] = []) -> WalkthroughPlanOutcome {
        var outcome = WalkthroughPlanOutcome()
        guard let object = jsonObject(in: raw) else {
            outcome.issues.append(.invalid("the answer was not a JSON object"))
            return outcome
        }

        let rawSteps: [Any]
        if let dictionary = object as? [String: Any] {
            if let problem = (dictionary["problem"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !problem.isEmpty {
                outcome.problem = problem
            }
            guard let steps = dictionary["steps"] as? [Any] else {
                if outcome.problem == nil { outcome.issues.append(.invalid("there is no \"steps\" array")) }
                return outcome
            }
            rawSteps = steps
        } else if let array = object as? [Any] {
            rawSteps = array
        } else {
            outcome.issues.append(.invalid("the answer was not a JSON object"))
            return outcome
        }

        if rawSteps.isEmpty {
            if outcome.problem == nil { outcome.issues.append(.invalid("\"steps\" is empty; give at least one step, or a \"problem\"")) }
            return outcome
        }
        // Steps win over a stray problem note.
        outcome.problem = nil

        var limited = rawSteps
        if rawSteps.count > maximumSteps {
            limited = Array(rawSteps.prefix(maximumSteps))
            outcome.notes.append("the plan had \(rawSteps.count) steps; kept the first \(maximumSteps)")
        }

        let forbidden = Set(forbiddenSays.map { WalkthroughTargetMatcher.normalize($0) })
        for (offset, rawStep) in limited.enumerated() {
            let number = offset + 1
            guard let dictionary = rawStep as? [String: Any] else {
                outcome.issues.append(.invalid("step \(number) is not an object"))
                continue
            }
            switch step(from: dictionary, number: number, notes: &outcome.notes) {
            case .failure(let failure):
                outcome.issues.append(contentsOf: failure.problems.map { .invalid($0) })
            case .success(let step):
                if forbidden.contains(WalkthroughTargetMatcher.normalize(step.say)) {
                    outcome.issues.append(.repeatsFailedStep(stepNumber: number))
                } else {
                    outcome.steps.append(step)
                }
            }
        }
        return outcome
    }

    private static func step(from dictionary: [String: Any], number: Int, notes: inout [String]) -> Result<WalkthroughStep, StepProblemsList> {
        var problems: [String] = []

        let say = string(dictionary["say"])
        if say.isEmpty {
            problems.append("step \(number) has no \"say\"")
        } else if say.count > maximumSayLength {
            problems.append("step \(number): \"say\" must be one short sentence (it is \(say.count) characters)")
        }

        let kind = stepKind(string(dictionary["kind"]))
        if kind == nil {
            problems.append("step \(number): \"kind\" must be click, type, wait or look")
        }

        let doneWhen = string(dictionary["doneWhen"]).isEmpty ? string(dictionary["done_when"]) : string(dictionary["doneWhen"])
        if doneWhen.isEmpty {
            problems.append("step \(number) has no \"doneWhen\"")
        }

        var target: WalkthroughTarget?
        if let rawTarget = dictionary["target"] as? [String: Any] {
            let label = string(rawTarget["label"])
            let point = point(from: rawTarget["point"])
            if label.isEmpty && point == nil {
                if kind == .click || kind == .type {
                    problems.append("step \(number): \"target\" needs a \"label\" or a \"point\"")
                }
            } else {
                target = WalkthroughTarget(role: WalkthroughTargetMatcher.normalizeRole(string(rawTarget["role"])), label: label, point: point)
            }
        } else if kind == .click || kind == .type {
            problems.append("step \(number): a \(kind == .click ? "click" : "type") step needs a \"target\"")
        }

        var check: WalkthroughCheck?
        if let rawCheck = dictionary["check"] as? [String: Any] {
            check = self.check(from: rawCheck)
            if check == nil { notes.append("step \(number): dropped a check that could not be read") }
        }

        guard problems.isEmpty, let kind else { return .failure(StepProblemsList(problems)) }
        return .success(WalkthroughStep(say: say, kind: kind, target: target, doneWhen: doneWhen, check: check))
    }

    // MARK: Pieces

    private static func string(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        return text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stepKind(_ raw: String) -> WalkthroughStepKind? {
        switch raw.lowercased() {
        case "click", "press", "tap", "select", "choose", "open", "pick", "toggle", "check": return .click
        case "type", "enter", "input", "fill", "write": return .type
        case "wait", "load": return .wait
        case "look", "observe", "read", "notice", "see": return .look
        default: return nil
        }
    }

    /// `[x, y]` or `{"x":…,"y":…}`, each clamped to 0…1000.
    static func point(from value: Any?) -> WalkthroughPoint? {
        var x: Double?, y: Double?
        if let pair = value as? [Any], pair.count >= 2 {
            x = number(pair[0])
            y = number(pair[1])
        } else if let dictionary = value as? [String: Any] {
            x = number(dictionary["x"])
            y = number(dictionary["y"])
        }
        guard let x, let y, x.isFinite, y.isFinite else { return nil }
        return WalkthroughPoint(x: min(max(x, 0), 1000), y: min(max(y, 0), 1000))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func check(from dictionary: [String: Any]) -> WalkthroughCheck? {
        let rawType = string(dictionary["type"]).lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        let kind: WalkthroughCheck.Kind
        switch rawType {
        case "appears", "appear", "visible", "exists", "present": kind = .appears
        case "disappears", "disappear", "gone", "hidden": kind = .disappears
        case "titlecontains", "windowtitlecontains", "title": kind = .titleContains
        case "focused", "focus", "hasfocus": kind = .focused
        case "valuecontains", "value": kind = .valueContains
        default: return nil
        }
        let role = string(dictionary["role"])
        let label = string(dictionary["label"])
        let text = string(dictionary["text"])
        let check = WalkthroughCheck(
            type: kind,
            role: role.isEmpty ? nil : WalkthroughTargetMatcher.normalizeRole(role),
            label: label.isEmpty ? nil : label,
            text: text.isEmpty ? nil : text
        )
        // A check with nothing to look for can never be answered.
        switch kind {
        case .titleContains: return (check.text ?? check.label) == nil ? nil : check
        case .valueContains: return check.label == nil || check.text == nil ? nil : check
        case .appears, .disappears, .focused: return (check.label ?? check.text) == nil ? nil : check
        }
    }

    /// The first JSON object or array in `raw`, tolerating a code fence or a sentence around it.
    static func jsonObject(in raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) { return object }
        for (open, close) in [(Character("{"), Character("}")), (Character("["), Character("]"))] {
            guard let start = trimmed.firstIndex(of: open), let end = trimmed.lastIndex(of: close), start < end else { continue }
            if let data = String(trimmed[start...end]).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        return nil
    }

    // MARK: Small answers

    /// "YES" / "NO" from a quick check. Nil when the answer is neither.
    static func yesNo(_ raw: String) -> Bool? {
        let word = raw.lowercased().components(separatedBy: CharacterSet.letters.inverted).first { !$0.isEmpty } ?? ""
        switch word {
        case "yes", "true", "done": return true
        case "no", "false", "not": return false
        default: return nil
        }
    }

    /// The first whole number in a resume-check answer, limited to 0…`maximum`.
    static func count(_ raw: String, maximum: Int) -> Int? {
        let digits = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty }
        guard let digits, let value = Int(digits) else { return nil }
        return min(max(value, 0), maximum)
    }
}

/// Why one step could not be read. (A plain wrapper so `Result` has an `Error` to carry.)
struct StepProblemsList: Error {
    let problems: [String]
    init(_ problems: [String]) { self.problems = problems }
}

// MARK: - Prompts

struct WalkthroughPlanRequest {
    var goal: String
    var appName: String
    var windowTitle: String
    /// `AXSnapshotFormatter.text(for:)` of the front window, or empty when accessibility gave nothing.
    var controlList: String
    /// `SkillLibrary.promptSection(for:)` for the app or site, or empty.
    var skillSection: String
    /// Set for a re-plan.
    var logText: String?
    var failedSays: [String] = []
    var maximumSteps: Int = WalkthroughSession.maximumSteps
    var hasScreenshot: Bool = true
}

enum WalkthroughPrompts {
    static let controlListBudget = 9_000

    static let planSystem = """
    You plan a step-by-step walkthrough that a person will carry out THEMSELVES on their Mac while a voice assistant talks them through it. You are given their goal, a screenshot of their screen right now, and a list of the controls in the front window read from accessibility.

    Return ONLY a JSON object. No prose, no code fence.
    {"steps":[{"say":"Click Me at the top right.","kind":"click","target":{"role":"button","label":"Me","point":[930,42]},"doneWhen":"A menu with Settings & Privacy is open","check":{"type":"appears","role":"link","label":"Settings & Privacy"}}]}

    Rules:
    - 1 to MAXSTEPS steps, one action per step. Start from what is on screen NOW and leave out anything that is already done. Prefer the shortest reliable route.
    - say: ONE short sentence spoken to the person, naming the control by its real on-screen name and roughly where it is ("Click Me at the top right."). No step numbers, no markdown, no "simply".
    - kind: "click" (they click or choose one control), "type" (they type into one field), "wait" (something has to load or finish), "look" (nothing to click in this window: they read something, or do something somewhere else such as opening an email; use rarely, and end its say with "say next when you're done").
    - target: the one control to draw a ring around. role is one of: button, link, text field, text area, search field, secure field, checkbox, radio, popup, menu button, menu, menu item, tab, switch, slider, cell, text, image, heading, combo box. label is the control's exact visible text or accessible name; copy it from the control list whenever it is listed there. point is [x, y], each 0 to 1000, across and down the SCREENSHOT (0,0 top-left, 1000,1000 bottom-right) at the control's centre; give it only when you can see the control in the screenshot, otherwise null. target may be null only for "wait" and "look".
    - doneWhen: a short visible condition that becomes true once the step is done ("The Sign in & security page is showing").
    - check: a machine-checkable form of doneWhen against the control list, or null when none fits. It must be FALSE before the step and TRUE after it. One of:
      {"type":"appears","role":"link","label":"..."}          a control with this label is now on screen
      {"type":"disappears","label":"..."}                      a control with this label is gone
      {"type":"titleContains","text":"..."}                    the window title contains this
      {"type":"focused","label":"..."}                         the keyboard focus is in this control
      {"type":"valueContains","label":"...","text":"..."}      this field's value contains the text
    - Never put a password, verification code or card number in a step. Say "type your password" and let them do it; such a step has check null.
    - Never plan a step that deletes data, pays, or sends something without the say making that plain.
    - If the app or page the goal needs is not open, the first steps open it.
    - Controls you cannot see yet (on a later screen) still get your best role and label, with point null.
    - If the goal cannot be done or you cannot tell what they want, return {"steps":[],"problem":"one sentence saying why"}.
    """

    static func planUserText(_ request: WalkthroughPlanRequest) -> String {
        var parts: [String] = ["GOAL: \(request.goal)"]
        var place = "They are in: \(request.appName.isEmpty ? "(unknown app)" : request.appName)"
        if !request.windowTitle.isEmpty { place += " — window \"\(request.windowTitle)\"" }
        parts.append(place)

        if !request.skillSection.isEmpty {
            parts.append(request.skillSection)
        }

        if let logText = request.logText {
            parts.append("""
            This walkthrough is already under way and has gone off course. What has happened so far:
            \(logText)

            Plan ONLY the steps that remain, starting from the screen as it is now.
            """)
            if !request.failedSays.isEmpty {
                let list = request.failedSays.map { "- \"\($0)\"" }.joined(separator: "\n")
                parts.append("These instructions FAILED. Do not give any of them again in the same words: find a different control, a different route (a menu, a search field, a keyboard shortcut), or explain where the thing really is.\n\(list)")
            }
        }

        if request.controlList.isEmpty {
            parts.append("CONTROLS: accessibility gave nothing for this window. Work from the screenshot and give a point for every target you can see.")
        } else {
            parts.append("CONTROLS in the front window (role \"label\" = \"value\"):\n\(clip(request.controlList, to: controlListBudget))")
        }
        if !request.hasScreenshot {
            parts.append("There is no screenshot this time: set every point to null.")
        }
        return parts.joined(separator: "\n\n")
    }

    static func planSystemText(maximumSteps: Int) -> String {
        planSystem.replacingOccurrences(of: "MAXSTEPS", with: "\(maximumSteps)")
    }

    /// OpenAI chat-completions messages for a plan or re-plan.
    static func planMessages(_ request: WalkthroughPlanRequest, screenshotJPEG: Data?) -> [[String: Any]] {
        [
            ["role": "system", "content": planSystemText(maximumSteps: request.maximumSteps)],
            ["role": "user", "content": userContent(text: planUserText(request), screenshotJPEG: screenshotJPEG)],
        ]
    }

    /// The one repair retry: the same request without the image, the bad answer, and what was wrong with it.
    static func repairMessages(_ request: WalkthroughPlanRequest, badAnswer: String, issues: [WalkthroughPlanIssue]) -> [[String: Any]] {
        var textOnly = request
        textOnly.hasScreenshot = false
        let problems = issues.map { "- \($0.text)" }.joined(separator: "\n")
        return [
            ["role": "system", "content": planSystemText(maximumSteps: request.maximumSteps)],
            ["role": "user", "content": planUserText(textOnly)],
            ["role": "assistant", "content": clip(badAnswer, to: 6_000)],
            ["role": "user", "content": "That answer cannot be used:\n\(problems)\n\nReturn the corrected JSON object only. Keep the points you already gave."],
        ]
    }

    static let quickCheckSystem = """
    You check ONE condition against a screenshot of a Mac screen and a list of the controls in the front window. The condition was written by a planner before it had seen this screen, so read it for what it means, not word for word: if the thing it describes is visibly there (the named control, page, menu, field or value), the condition is true even when a section or page is named a little differently. Answer with exactly one word and nothing after it: YES if the condition is true right now, NO if it is not or you cannot tell.
    """

    static func quickCheckMessages(condition: String, controlList: String, screenshotJPEG: Data?) -> [[String: Any]] {
        var text = "CONDITION: \(condition)"
        if !controlList.isEmpty { text += "\n\nCONTROLS in the front window:\n\(clip(controlList, to: 5_000))" }
        return [
            ["role": "system", "content": quickCheckSystem],
            ["role": "user", "content": userContent(text: text, screenshotJPEG: screenshotJPEG)],
        ]
    }

    static let resumeCheckSystem = """
    A person paused a step-by-step walkthrough and may have done some of the remaining steps on their own. You get the remaining steps in order, a screenshot of their screen now, and a list of the controls in the front window. Answer with ONE whole number and nothing else: how many of the remaining steps, counted from the first, are already done. Go through them in order. Count a step only when its "done when" is plainly true on the screen right now, and stop counting at the first step where it is not. Seeing the control a step tells them to click does NOT mean that step is done; it means it is still to do. When unsure, give the lower number. Answer 0 if the first step is not plainly done.
    """

    static func resumeCheckMessages(goal: String, remaining: [WalkthroughStep], controlList: String, screenshotJPEG: Data?) -> [[String: Any]] {
        let steps = remaining.enumerated()
            .map { "\($0.offset + 1). \($0.element.say) (done when: \($0.element.doneWhen))" }
            .joined(separator: "\n")
        var text = "GOAL: \(goal)\n\nREMAINING STEPS:\n\(steps)"
        if !controlList.isEmpty { text += "\n\nCONTROLS in the front window:\n\(clip(controlList, to: 5_000))" }
        return [
            ["role": "system", "content": resumeCheckSystem],
            ["role": "user", "content": userContent(text: text, screenshotJPEG: screenshotJPEG)],
        ]
    }

    private static func userContent(text: String, screenshotJPEG: Data?) -> Any {
        guard let screenshotJPEG else { return text }
        return [
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(screenshotJPEG.base64EncodedString())"]],
            ["type": "text", "text": text],
        ] as [[String: Any]]
    }

    /// Cuts at a line end, never mid-line.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var kept: [Substring] = []
        var used = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if used + line.count + 1 > limit { break }
            kept.append(line)
            used += line.count + 1
        }
        return kept.joined(separator: "\n") + "\n(list cut short)"
    }

    /// The assistant's text from a chat-completions response body.
    static func assistantText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        else { return nil }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}
