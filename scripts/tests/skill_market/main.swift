// Tests for the Skill Market's pure logic. Run with scripts/tests/run_skill_market_tests.sh.
// Uses a temp folder for installs; never touches ~/.teachy or the network.
// The first argument is the market folder (academy/skillmarket) whose index.json and files are checked.
import Foundation

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !condition() { failures += 1; print("FAIL (line \(line)): \(message())") }
}
func section(_ name: String) { print("— \(name)") }

func skillText(name: String = "Linear", id: String? = "linear", version: String? = "1.0", sites: String = "[linear.app]", bundleIds: String = "[]") -> String {
    var lines = ["---", "name: \(name)"]
    if let id { lines.append("id: \(id)") }
    if let version { lines.append("version: \(version)") }
    lines += ["author: Someone", "bundleIds: \(bundleIds)", "sites: \(sites)", "summary: Issue tracker.", "---", "## Layout", "- Sidebar on the left."]
    return lines.joined(separator: "\n")
}

section("IDs and slugs")
expect(SkillMarketRules.isValidID("google-sheets"), "plain id")
expect(SkillMarketRules.isValidID("x1"), "digits")
expect(!SkillMarketRules.isValidID(""), "empty")
expect(!SkillMarketRules.isValidID("../evil"), "path")
expect(!SkillMarketRules.isValidID("Linear"), "uppercase")
expect(!SkillMarketRules.isValidID("-a"), "leading hyphen")
expect(!SkillMarketRules.isValidID("a--b"), "double hyphen")
expect(!SkillMarketRules.isValidID(String(repeating: "a", count: 65)), "too long")
expect(SkillMarketRules.slug(from: "Google Sheets (mine)") == "google-sheets-mine", "slug \(SkillMarketRules.slug(from: "Google Sheets (mine)"))")
expect(SkillMarketRules.slug(from: "!!!") == "", "empty slug")

section("Versions")
expect(SkillMarketRules.isVersion("1.10", newerThan: "1.9"), "1.10 > 1.9")
expect(!SkillMarketRules.isVersion("1.0", newerThan: "1"), "1.0 == 1")
expect(SkillMarketRules.isVersion("2", newerThan: "1.9.9"), "2 > 1.9.9")
expect(!SkillMarketRules.isVersion("1.2", newerThan: "1.3"), "1.2 < 1.3")

section("File URLs")
let indexURL = URL(string: "https://vedsoni-dev.github.io/teachy/skillmarket/index.json")!
func listing(_ file: String, id: String = "linear", version: String = "1.0") -> SkillMarketListing {
    SkillMarketListing(id: id, name: "Linear", summary: "s", author: "a", authorURL: nil, category: nil, apps: nil, version: version, file: file)
}
expect(SkillMarketRules.fileURL(for: listing("skills/linear.skill.md"), indexURL: indexURL)?.absoluteString == "https://vedsoni-dev.github.io/teachy/skillmarket/skills/linear.skill.md", "relative file")
expect(SkillMarketRules.fileURL(for: listing("https://example.com/x.md"), indexURL: indexURL) != nil, "absolute https")
expect(SkillMarketRules.fileURL(for: listing("http://example.com/x.md"), indexURL: indexURL) == nil, "http refused")
expect(SkillMarketRules.fileURL(for: listing("file:///etc/passwd"), indexURL: indexURL) == nil, "file refused for a web index")

section("Index decoding")
let indexJSON = """
{"version":1,"skills":[
 {"id":"linear","name":"Linear","summary":"s","author":"a","version":"1.0","file":"skills/linear.skill.md"},
 {"id":"../bad","name":"Bad","summary":"s","author":"a","version":"1.0","file":"x.md"},
 {"id":"nofile","name":"No file","summary":"s","author":"a","version":"1.0","file":""}
]}
"""
let decoded = SkillMarketIndex.decode(Data(indexJSON.utf8))
expect(decoded?.skills.map(\.id) == ["linear"], "bad listings dropped: \(decoded?.skills.map(\.id) ?? [])")
expect(SkillMarketIndex.decode(Data("[]".utf8)) == nil, "not an index")

section("Validation")
let good = Data(skillText().utf8)
if case .success(let file) = SkillInstaller.validate(data: good, expectedMarketID: "linear") {
    expect(file.fileName == "linear.md", "market file name \(file.fileName)")
    expect(file.skill.marketID == "linear" && file.skill.version == "1.0" && file.skill.author == "Someone", "front matter fields")
} else { expect(false, "valid market skill rejected") }
expect(SkillInstaller.validate(data: good, expectedMarketID: "notion") == .failure(.wrongListing(expected: "notion", found: "linear")), "listing must match the file's id")
expect(SkillInstaller.validate(data: Data("# just markdown".utf8)) == .failure(.notASkill), "no front matter")
expect(SkillInstaller.validate(data: Data(skillText(sites: "[]").utf8)) == .failure(.noMatchingApp), "no app or site")
expect(SkillInstaller.validate(data: Data(repeating: 65, count: 40_000)) == .failure(.tooLarge), "too large")
expect(SkillInstaller.validate(data: Data([0xff, 0xfe, 0x00, 0x41])) == .failure(.notText), "binary")
let own = Data(skillText(name: "My Tool", id: nil, version: nil).utf8)
if case .success(let file) = SkillInstaller.validate(data: own, existingFileNames: ["my-tool.md", "my-tool-2.md"]) {
    expect(file.fileName == "my-tool-3.md", "own file avoids clashes: \(file.fileName)")
} else { expect(false, "own skill rejected") }
let badID = Data(skillText(id: "../../x").utf8)
if case .success(let file) = SkillInstaller.validate(data: badID) {
    expect(file.fileName == "linear.md", "a bad id falls back to the name: \(file.fileName)")
} else { expect(false, "bad-id skill rejected") }

section("Install, state, remove")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-skill-market-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: temp) }
let library = SkillLibrary(bundledDirectories: [], userDirectory: temp)
expect(library.userSkills.isEmpty, "starts empty")
if case .success(let file) = SkillInstaller.validate(data: good, expectedMarketID: "linear") {
    let written = try! SkillInstaller.install(file, into: temp)
    expect(FileManager.default.fileExists(atPath: written.path), "file written")
}
library.reload()
let installed = library.userSkills
expect(installed.count == 1 && installed.first?.fileURL != nil, "picked up by the library")
expect(SkillMarketInstallState.of(listing("f", version: "1.0"), userSkills: installed) == .installed, "same version installed")
expect(SkillMarketInstallState.of(listing("f", version: "1.1"), userSkills: installed) == .updateAvailable(installedVersion: "1.0"), "update available")
expect(SkillMarketInstallState.of(listing("f", id: "notion"), userSkills: installed) == .notInstalled, "other listing")
expect(library.skill(forBundleID: nil, browserHost: "https://linear.app/team/issues")?.name == "Linear", "installed skill matches its site")

let outside = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-outside-\(UUID().uuidString).md")
try! Data("x".utf8).write(to: outside)
defer { try? FileManager.default.removeItem(at: outside) }
expect((try? SkillInstaller.remove(fileURL: outside, from: temp)) == nil, "refuses files outside the folder")
expect(FileManager.default.fileExists(atPath: outside.path), "outside file kept")
try! SkillInstaller.remove(fileURL: installed[0].fileURL!, from: temp)
library.reload()
expect(library.userSkills.isEmpty, "removed")

section("Install links")
expect(SkillInstallLink.skillFileURL(from: URL(string: "teachy://skill?url=https%3A%2F%2Fexample.com%2Fa.md")!)?.absoluteString == "https://example.com/a.md", "skill link")
expect(SkillInstallLink.skillFileURL(from: URL(string: "teachy://skill?url=http://example.com/a.md")!) == nil, "http link refused")
expect(SkillInstallLink.skillFileURL(from: URL(string: "teachy://open")!) == nil, "other link")
expect(SkillInstallLink.skillFileURL(from: URL(string: "https://skill?url=https://a.com/x")!) == nil, "not teachy scheme")

section("Library fields")
let rich = """
---
name: Zoom
id: zoom
version: 1.0
author: Teachy
category: Meetings
icon: 🎥
headline: Run a meeting.
description: Before a call: mic, sharing, recording.
goodFor: [Zoom, Meetings]
added: 2026-11-19
highlights:
  - The toolbar
  - Sharing, with sound
bundleIds: [us.zoom.xos]
---
## Layout
- x
"""
let richSkill = SkillParser.parse(rich)
expect(richSkill?.icon == "🎥" && richSkill?.headline == "Run a meeting.", "icon and headline")
expect(richSkill?.details == "Before a call: mic, sharing, recording.", "description keeps colons and commas: \(richSkill?.details ?? "nil")")
expect(richSkill?.goodFor == ["Zoom", "Meetings"], "goodFor")
expect(richSkill?.highlights == ["The toolbar", "Sharing, with sound"], "highlights list: \(richSkill?.highlights ?? [])")
expect(richSkill?.category == "Meetings", "category")
expect(richSkill?.bundleIDs == ["us.zoom.xos"], "a list before bundleIds doesn't swallow it")
var dated = listing("f")
dated.added = "2026-11-19"
let addedDay = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!
expect(dated.isNew(now: addedDay.addingTimeInterval(86_400)), "new the day after")
expect(!dated.isNew(now: addedDay.addingTimeInterval(31 * 86_400)), "not new after 30 days")
expect(!dated.isNew(now: addedDay.addingTimeInterval(-86_400)), "not new before it was added")
dated.added = "yesterday"
expect(!dated.isNew(now: addedDay), "bad date is never new")

section("Download counts")
expect(SkillDownloadCounts.decode(Data(#"{"counts":{"linear":3}}"#.utf8)) == ["linear": 3], "decode counts")
expect(SkillDownloadCounts.decode(Data(#"{"nope":1}"#.utf8)) == nil, "not counts")
expect(SkillDownloadCounts.label(for: nil) == nil, "unknown count shows nothing")
expect(SkillDownloadCounts.label(for: 0) == "No downloads yet", "zero")
expect(SkillDownloadCounts.label(for: 1) == "1 download", "one")
expect(SkillDownloadCounts.label(for: 1204) == "1,204 downloads", "many: \(SkillDownloadCounts.label(for: 1204) ?? "")")

section("Template")
expect(SkillParser.parse(SkillInstaller.newSkillTemplate) != nil, "template parses")

section("Published market")
if CommandLine.arguments.count > 1 {
    let marketFolder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let localIndexURL = marketFolder.appendingPathComponent("index.json")
    if let data = try? Data(contentsOf: localIndexURL), let index = SkillMarketIndex.decode(data) {
        let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["skills"] as? [Any]
        expect(raw?.count == index.skills.count, "every listing in index.json is valid")
        expect(!index.skills.isEmpty, "market lists at least one skill")
        expect(Set(index.skills.map(\.id)).count == index.skills.count, "listing ids are unique")
        for item in index.skills {
            guard let fileURL = SkillMarketRules.fileURL(for: item, indexURL: localIndexURL), let fileData = try? Data(contentsOf: fileURL) else {
                expect(false, "\(item.id): file missing"); continue
            }
            switch SkillInstaller.validate(data: fileData, expectedMarketID: item.id) {
            case .success(let file):
                expect(file.skill.name == item.name, "\(item.id): name matches index")
                expect(file.skill.version == item.version, "\(item.id): version matches index")
                expect(SkillPrompt.section(for: file.skill, budgetCharacters: SkillLibrary.defaultPromptBudget).count > 100, "\(item.id): fits the prompt budget with content")
            case .failure(let error):
                expect(false, "\(item.id): \(error.localizedDescription)")
            }
        }
    } else {
        expect(false, "index.json missing or unreadable at \(localIndexURL.path)")
    }
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
