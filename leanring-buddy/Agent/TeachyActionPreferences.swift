//
//  TeachyActionPreferences.swift
//  leanring-buddy
//
//  How the person wants Teachy to act, applied to every agent job:
//
//    - websites: their own Chrome (the Teachy extension, else their tabs),
//      Teachy's own background browser (Playwright MCP, `mcp__browser__…`),
//      their screen with the real mouse, or "let Teachy choose";
//    - the real pointer (`computer`, `drive_click_point`): allowed, ask first, never.
//
//  Two levers, so the choice is not left to the model's mood: tools the
//  preference rules out are removed from the job's tool list, and the job's
//  system prompt says plainly which way to work. Habits Teachy learned
//  ("How I like things done" in PROFILE.md) come with the memory in the prompt
//  and win over the general rule for that site or app.
//
//  Pure (Foundation only), so `scripts/tests/run_action_preferences_tests.sh` can test it.
//

import Foundation

nonisolated enum TeachyActionPreferences {
    static let backgroundBrowserToolPrefix = "mcp__browser__"
    static let chromeExtensionToolPrefix = "browser_"
    /// Their own browser's tabs, through AppleScript.
    static let ownBrowserTabToolNames: Set<String> = ["open_browser_tab", "control_browser"]
    static let pointerToolNames: Set<String> = ["computer", "drive_click_point"]

    /// Whether a call moves the person's real pointer or types with their keyboard.
    static func takesThePointer(toolName: String, arguments: [String: Any]) -> Bool {
        if toolName == "drive_click_point" { return true }
        guard toolName == "computer" else { return false }
        let action = (arguments["action"] as? String ?? "").lowercased()
        return !["screenshot", "cursor_position", "wait"].contains(action)
    }

    /// The job's tools with the ones the preferences rule out removed.
    static func filteredToolNames(
        _ toolNames: Set<String>,
        web: TeachyWebControlPreference,
        pointer: TeachyPointerControlPreference
    ) -> Set<String> {
        var allowed = toolNames
        if pointer == .never {
            allowed.subtract(pointerToolNames)
        }
        switch web {
        case .automatic:
            break
        case .myChrome, .myScreen:
            allowed = allowed.filter { !$0.hasPrefix(backgroundBrowserToolPrefix) }
        case .backgroundBrowser:
            // Only when the background browser is really there; otherwise their browser is the only way to the web.
            if allowed.contains(where: { $0.hasPrefix(backgroundBrowserToolPrefix) }) {
                allowed = allowed.filter { !$0.hasPrefix(chromeExtensionToolPrefix) }
                allowed.subtract(ownBrowserTabToolNames)
            }
        }
        return allowed
    }

    /// The system prompt section that tells a job which way to work.
    static func promptSection(
        web: TeachyWebControlPreference,
        pointer: TeachyPointerControlPreference,
        availableTools: Set<String>
    ) -> String {
        let hasBackgroundBrowser = availableTools.contains { $0.hasPrefix(backgroundBrowserToolPrefix) }
        let hasChromeExtension = availableTools.contains { $0.hasPrefix(chromeExtensionToolPrefix) }
        let hasPointer = availableTools.contains("computer")

        let theirChrome = hasChromeExtension
            ? "their own Chrome through the browser_ tools (their tabs and sign-ins, no mouse needed)"
            : "their own browser: open_browser_tab / control_browser to open and switch tabs" + (hasPointer ? ", then computer for clicks inside the page" : "")
        let background = hasBackgroundBrowser
            ? "Teachy's own background browser (the mcp__browser__ tools: out of sight, NOT signed in to their accounts)"
            : nil

        var lines: [String] = ["HOW THIS PERSON WANTS YOU TO ACT (their setting; follow it):"]
        switch web {
        case .automatic:
            lines.append("- Websites, pick by what the task needs:")
            lines.append("  • Their accounts (email, YouTube history, shopping carts, anything signed in) or something they will watch or listen to (play a song or video, open a page for them): \(theirChrome).")
            if let background {
                lines.append("  • Research, reading, comparing, filling public forms, anything they do not need to see: \(background). Their screen stays free.")
            }
            if hasPointer {
                lines.append("  • Their real mouse and keyboard (computer) only when neither can do the step.")
            }
        case .myChrome:
            lines.append("- Websites: always \(theirChrome). Do not use another browser.")
        case .backgroundBrowser:
            if let background {
                lines.append("- Websites: always \(background). Do not touch their own browser or their mouse for web work. If a site needs their sign-in, say so in your answer instead of switching browsers.")
            } else {
                lines.append("- They prefer a background browser, but it is not available right now: use \(theirChrome) and keep it brief.")
            }
        case .myScreen:
            if hasPointer {
                lines.append("- Websites: in their own browser, using computer (their real mouse and keyboard) so they can watch each step. Open pages with open_browser_tab first.")
            } else {
                lines.append("- Websites: they like to watch, but may not move the mouse, so use \(theirChrome).")
            }
        }
        switch pointer {
        case .allowed:
            if hasPointer { lines.append("- Their mouse and keyboard: allowed when needed; prefer drive_ tools and browser tools, which leave the pointer alone.") }
        case .askFirst:
            if hasPointer { lines.append("- Their mouse and keyboard: Teachy asks them once before computer moves it; prefer tools that leave the pointer alone.") }
        case .never:
            lines.append("- Never move their mouse or type with their keyboard: there is no computer tool in this job. Use drive_ tools, browser tools, AppleScript or bash.")
        }
        lines.append("- A habit under \"How I like things done\" in their memory wins over these general rules for that site or app.")
        return lines.joined(separator: "\n")
    }

    /// One line for the voice prompt, so a quick request ("play that song") goes the right way.
    static func voicePromptLine(web: TeachyWebControlPreference) -> String {
        switch web {
        case .automatic, .myChrome, .myScreen:
            return "- To play, watch or open something for them (a song, a video, a page), [OPEN:] it in their own browser rather than starting a [JOB:]. Follow any habit in \"How I like things done\"."
        case .backgroundBrowser:
            return "- They like web work done out of sight: use [JOB:] for web tasks, and [OPEN:] only when they want to see or hear the page themselves (a song, a video). Follow any habit in \"How I like things done\"."
        }
    }
}
