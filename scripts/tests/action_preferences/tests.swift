// Run: scripts/tests/run_action_preferences_tests.sh
// Which tools a job gets and what it is told, for each website / mouse preference.
import Foundation

var failureCount = 0
var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition() { failureCount += 1; print("  FAIL (line \(line)): \(message)") }
}

@main
enum ActionPreferencesTests {
    static func main() {
        let everything: Set<String> = ["computer", "drive_click_point", "drive_snapshot", "browser_click", "browser_navigate",
                                        "mcp__browser__browser_navigate", "open_browser_tab", "control_browser", "bash"]
        typealias Prefs = TeachyActionPreferences

        print("• tool filtering")
        let automatic = Prefs.filteredToolNames(everything, web: .automatic, pointer: .allowed)
        check(automatic == everything, "automatic + allowed keeps everything")

        let chrome = Prefs.filteredToolNames(everything, web: .myChrome, pointer: .allowed)
        check(!chrome.contains("mcp__browser__browser_navigate"), "my Chrome drops the background browser")
        check(chrome.contains("browser_click") && chrome.contains("open_browser_tab"), "my Chrome keeps extension and tabs")

        let background = Prefs.filteredToolNames(everything, web: .backgroundBrowser, pointer: .allowed)
        check(background.contains("mcp__browser__browser_navigate"), "background keeps its browser")
        check(!background.contains("browser_click") && !background.contains("open_browser_tab") && !background.contains("control_browser"),
              "background leaves their browser alone")
        let noBackgroundAvailable = everything.filter { !$0.hasPrefix("mcp__browser__") }
        check(Prefs.filteredToolNames(noBackgroundAvailable, web: .backgroundBrowser, pointer: .allowed).contains("open_browser_tab"),
              "without a background browser their tabs stay, or the job has no web at all")

        let never = Prefs.filteredToolNames(everything, web: .automatic, pointer: .never)
        check(!never.contains("computer") && !never.contains("drive_click_point"), "never drops the pointer tools")
        check(never.contains("drive_snapshot"), "never keeps accessibility Drive")
        check(Prefs.filteredToolNames(everything, web: .automatic, pointer: .askFirst).contains("computer"), "ask first keeps computer (asked at call time)")

        print("• which calls take the pointer")
        check(Prefs.takesThePointer(toolName: "computer", arguments: ["action": "left_click"]), "click")
        check(Prefs.takesThePointer(toolName: "computer", arguments: ["action": "type"]), "type")
        check(!Prefs.takesThePointer(toolName: "computer", arguments: ["action": "screenshot"]), "screenshot only looks")
        check(Prefs.takesThePointer(toolName: "drive_click_point", arguments: [:]), "drive click point")
        check(!Prefs.takesThePointer(toolName: "drive_press", arguments: [:]), "drive press uses accessibility")

        print("• prompt")
        let automaticPrompt = Prefs.promptSection(web: .automatic, pointer: .askFirst, availableTools: automatic)
        check(automaticPrompt.contains("play a song or video") && automaticPrompt.contains("mcp__browser__"), "automatic explains both browsers")
        check(automaticPrompt.contains("browser_ tools"), "extension named when connected")
        let noExtension = Prefs.promptSection(web: .myChrome, pointer: .allowed, availableTools: ["open_browser_tab", "computer"])
        check(noExtension.contains("open_browser_tab"), "falls back to tabs without the extension")
        let neverPrompt = Prefs.promptSection(web: .myScreen, pointer: .never, availableTools: never)
        check(neverPrompt.contains("Never move their mouse") && neverPrompt.contains("may not move the mouse"), "never + my screen degrades to Chrome")
        check(Prefs.promptSection(web: .backgroundBrowser, pointer: .allowed, availableTools: ["computer"]).contains("not available right now"),
              "background preference without a background browser says so")
        for web in TeachyWebControlPreference.allCases {
            check(Prefs.promptSection(web: web, pointer: .allowed, availableTools: everything).contains("How I like things done"), "learned habits win (\(web))")
            check(Prefs.voicePromptLine(web: web).contains("[OPEN:]"), "voice line (\(web))")
        }

        print("• settings storage")
        let defaults = UserDefaults(suiteName: "teachy-action-preferences-tests-\(UUID().uuidString)")!
        check(TeachySettingsStorage.webControlPreference(defaults) == .automatic, "web default")
        check(TeachySettingsStorage.pointerControlPreference(defaults) == .askFirst, "pointer default is ask first")
        defaults.set("backgroundBrowser", forKey: TeachySettingsKey.webControlPreference)
        defaults.set("bogus", forKey: TeachySettingsKey.pointerControlPreference)
        check(TeachySettingsStorage.webControlPreference(defaults) == .backgroundBrowser, "saved web value")
        check(TeachySettingsStorage.pointerControlPreference(defaults) == .askFirst, "unknown value falls back")

        print(failureCount == 0 ? "action preference tests: all \(checkCount) checks passed" : "action preference tests: \(failureCount) of \(checkCount) checks FAILED")
        exit(failureCount == 0 ? 0 : 1)
    }
}
