//
//  brain_tests.swift
//
//  Standalone tests for Teachy's memory (leanring-buddy/Brain). Run with
//  scripts/tests/run_brain_tests.sh. Everything happens in a temporary
//  directory — the real ~/.teachy is never touched.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("  FAIL (line \(line)): \(message)")
    }
}

func checkEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ message: String, line: Int = #line) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("  FAIL (line \(line)): \(message)\n    expected: \(expected)\n    actual:   \(actual)")
    }
}

func section(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

let fixedTimeZone = TimeZone(identifier: "UTC")!
/// 2026-11-14 15:04:00 UTC
let fixedDate = Date(timeIntervalSince1970: 1_794_668_640)

func bullets(_ document: BrainDocument, _ title: String) -> [String] {
    guard let sectionIndex = document.sectionIndex(titled: title) else { return [] }
    return document.items(inSectionAt: sectionIndex).map(\.text)
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teachy-brain-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let handEditedProfile = """
    # My notes\r
    Some intro I wrote myself.

    ## About me
    - Name is Vedant
      - goes by Ved
    I also wrote this sentence without a bullet.

    ## My cats
    Two cats: Miso and Udon.
    * Miso hates the vacuum

    ```
    ## not a heading, this is code
    ```

    ## How I like answers
    - Length: long and detailed
    - No emoji

    ### A sub heading stays in its section
    + plus bullets work too
    ## Things that keep catching me
    - Forgets to save before running

    ## Empty one I added
    """

@main
enum BrainTests {
    static func main() {
        let realBrainPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teachy/brain").path
        let realBrainExistedBefore = FileManager.default.fileExists(atPath: realBrainPath)

        section("round-trip is lossless, including hand edits and unknown sections") {
            let samples = [
                handEditedProfile,
                "",
                "\n",
                "no headings at all",
                "## Only heading",
                "## A\n\n\n## B\n- x\n\n\n",
                "intro\r\n## A\r\n- one\r\n",
                BrainFile.profile.template,
                BrainFile.volatile.template,
            ]
            for sample in samples {
                checkEqual(BrainDocument(markdown: sample).markdown, sample, "round trip changed the text")
            }

            let document = BrainDocument(markdown: handEditedProfile)
            checkEqual(
                document.sections.map(\.title),
                ["About me", "My cats", "How I like answers", "Things that keep catching me", "Empty one I added"],
                "sections and their order"
            )
            checkEqual(
                bullets(document, "About me"),
                ["Name is Vedant - goes by Ved", "I also wrote this sentence without a bullet."],
                "nested bullets belong to their parent; prose is kept as an item"
            )
            check(
                bullets(document, "My cats").contains("## not a heading, this is code"),
                "a heading inside a code fence is not a section"
            )

            // Remembering must not disturb anything else in the file.
            var memory = BrainMemory(profile: document, volatile: BrainDocument(markdown: ""))
            checkEqual(memory.remember("Lives in Austin", kind: .aboutMe), .added, "remember into hand-edited file")
            checkEqual(memory.remember("Uses Figma", kind: .tools), .added, "remember into a section the file lacks")
            let edited = memory.profile
            checkEqual(
                edited.sections.map(\.title),
                ["About me", "My cats", "How I like answers", "Things that keep catching me", "Empty one I added",
                 "Tools and apps I use"],
                "existing order kept, missing section appended at the end"
            )
            for untouchedTitle in ["My cats", "How I like answers", "Things that keep catching me"] {
                let before = document.sections[document.sectionIndex(titled: untouchedTitle)!]
                let after = edited.sections[edited.sectionIndex(titled: untouchedTitle)!]
                checkEqual(after, before, "section '\(untouchedTitle)' must be preserved verbatim")
            }
            checkEqual(edited.preamble, document.preamble, "preamble preserved verbatim")
            checkEqual(
                edited.sections[0].lines,
                ["- Name is Vedant", "  - goes by Ved", "I also wrote this sentence without a bullet.",
                 "- Lives in Austin", ""],
                "new bullet goes after the last item, before the blank line"
            )
            check(edited.markdown.hasSuffix("## Empty one I added\n\n## Tools and apps I use\n- Uses Figma\n"),
                  "appended section is separated by one blank line")
            checkEqual(BrainDocument(markdown: edited.markdown), edited, "edited file re-parses to the same document")
        }

        section("de-duplication and mistake counts") {
            var memory = BrainMemory()
            checkEqual(memory.remember("Works as a nurse.", kind: .aboutMe), .added, "first")
            checkEqual(memory.remember("works as a NURSE", kind: .aboutMe), .duplicate, "case and punctuation ignored")
            checkEqual(memory.remember("  - Works, as a nurse!  ", kind: .aboutMe), .duplicate, "marker and spacing ignored")
            checkEqual(memory.remember("Doesn't like jargon", kind: .aboutMe), .added, "different note")
            checkEqual(memory.remember("doesnt like jargon", kind: .aboutMe), .duplicate, "apostrophes ignored")
            checkEqual(bullets(memory.profile, "About me"), ["Works as a nurse.", "Doesn't like jargon"], "no duplicates")

            checkEqual(memory.remember("", kind: .aboutMe), .rejected, "empty note")
            checkEqual(memory.remember(" ... ", kind: .aboutMe), .rejected, "punctuation-only note")
            checkEqual(memory.remember("line one\nline two\n## Fake heading", kind: .aboutMe), .added, "multi-line note")
            checkEqual(bullets(memory.profile, "About me").last, "line one line two ## Fake heading",
                       "a note can never add lines or headings")
            checkEqual(memory.profile.sections.count, 8, "no section was injected")

            checkEqual(memory.remember("Forgets to save before running", kind: .mistakes), .added, "mistake 1")
            checkEqual(memory.remember("forgets to save before running.", kind: .mistakes), .repeated(count: 2), "mistake 2")
            checkEqual(memory.remember("Forgets to save before running", kind: .mistakes), .repeated(count: 3), "mistake 3")
            checkEqual(memory.remember("Mixes up = and ==", kind: .mistakes), .added, "another mistake")
            checkEqual(
                bullets(memory.profile, "Things that keep catching me"),
                ["Forgets to save before running (x3)", "Mixes up = and =="],
                "repeat counter"
            )
            // A hand-written counter is respected.
            var edited = BrainMemory(
                profile: BrainDocument(markdown: "## Things that keep catching me\n- Off by one errors (x7)\n"),
                volatile: BrainDocument(markdown: "")
            )
            checkEqual(edited.remember("off-by-one errors", kind: .mistakes), .repeated(count: 8), "continues hand-set count")
            checkEqual(edited.profile.markdown, "## Things that keep catching me\n- Off by one errors (x8)\n", "file text")
        }

        section("a note about the same subject replaces the older one") {
            var memory = BrainMemory()
            memory.remember("Length: long and detailed", kind: .answerStyle)
            memory.remember("No emoji", kind: .answerStyle)
            checkEqual(
                memory.remember("length: two sentences at most", kind: .answerStyle),
                .replaced(previous: "Length: long and detailed"),
                "same leading key replaces"
            )
            checkEqual(bullets(memory.profile, "How I like answers"), ["length: two sentences at most", "No emoji"],
                       "replaced in place, order kept")

            memory.remember("Food truck site: active; blocked on DNS", kind: .project)
            memory.remember("Resume: paused", kind: .project)
            checkEqual(
                memory.remember("Food truck site: active; DNS fixed; https://tacos.example.com", kind: .project),
                .replaced(previous: "Food truck site: active; blocked on DNS"),
                "project status update replaces"
            )
            checkEqual(bullets(memory.volatile, "Working on now").count, 2, "still two projects")

            // Conservative: these must NOT be treated as keyed.
            memory.remember("Portfolio is at https://a.example.com", kind: .aboutMe)
            checkEqual(memory.remember("Blog is at https://b.example.com", kind: .aboutMe), .added, "URL colon is not a key")
            memory.remember("Standup is at 10:30 every day", kind: .aboutMe)
            checkEqual(memory.remember("Lunch is at 10:45 usually", kind: .aboutMe), .added, "time colon is not a key")
            memory.remember("Git: forgets to pull first", kind: .mistakes)
            checkEqual(memory.remember("Git: force pushes to main", kind: .mistakes), .added,
                       "mistakes never replace each other")
            checkEqual(BrainText.leadingSubject("One very long sentence that happens to have a colon: here"), nil,
                       "long sentence is not a key")
        }

        section("dated sections: newest first, trimmed, refreshed") {
            var memory = BrainMemory()
            for index in 1...45 {
                memory.remember("Recent note \(index)", kind: .recent, date: fixedDate, timeZone: fixedTimeZone)
                memory.remember("Saw screen \(index)", kind: .screen, date: fixedDate, timeZone: fixedTimeZone)
            }
            let recent = bullets(memory.volatile, "Recently")
            let screen = bullets(memory.volatile, "Screen memory")
            checkEqual(recent.count, 30, "Recently trimmed to 30")
            checkEqual(screen.count, 15, "Screen memory trimmed to 15")
            checkEqual(recent.first, "2026-11-14: Recent note 45", "newest first, dated")
            checkEqual(recent.last, "2026-11-14: Recent note 16", "oldest dropped")
            checkEqual(screen.first, "2026-11-14 15:04: Saw screen 45", "screen notes carry a time")

            let laterDate = fixedDate.addingTimeInterval(86_400)
            checkEqual(
                memory.remember("recent note 20", kind: .recent, date: laterDate, timeZone: fixedTimeZone),
                .refreshed, "repeat of a dated note"
            )
            let refreshed = bullets(memory.volatile, "Recently")
            checkEqual(refreshed.count, 30, "refresh does not grow the section")
            checkEqual(refreshed.first, "2026-11-15: recent note 20", "refreshed note moves to the top with the new date")
            checkEqual(refreshed.filter { BrainText.comparisonKey($0) == "recent note 20" }.count, 1, "no duplicate left")
        }

        section("prompt context: whole sections, never over budget") {
            var memory = BrainMemory()
            memory.remember("Length: two sentences at most", kind: .answerStyle)
            memory.remember("Tone: casual, no pep talk", kind: .answerStyle)
            memory.remember("Language: English", kind: .answerStyle)
            for index in 1...12 {
                memory.remember("Personal fact number \(index) that is a moderately long sentence", kind: .aboutMe)
                memory.remember("Tool \(index)", kind: .tools)
                memory.remember("Skill \(index) with some description", kind: .skills)
                memory.remember("Mistake \(index) that keeps happening", kind: .mistakes)
                memory.remember("Word\(index)", kind: .words)
                memory.remember("Habit \(index): do it this way", kind: .howToDoThings)
                memory.remember("Favourite \(index): something", kind: .likes)
                memory.remember("Project \(index): active; blocker \(index)", kind: .project)
                memory.remember("Recent \(index)", kind: .recent, date: fixedDate, timeZone: fixedTimeZone)
                memory.remember("Screen \(index)", kind: .screen, date: fixedDate, timeZone: fixedTimeZone)
            }
            var profileWithCustomSection = memory.profile
            let customIndex = profileWithCustomSection.appendSection(titled: "My family")
            profileWithCustomSection.sections[customIndex].lines = ["- Sister is Priya", ""]
            memory.profile = profileWithCustomSection

            // Every original item, as it would be rendered, to prove nothing is ever cut.
            var wholeItemLines = Set<String>()
            for file in BrainFile.allCases {
                let document = memory[file]
                for sectionIndex in document.sections.indices {
                    for item in document.items(inSectionAt: sectionIndex) {
                        document.sections[sectionIndex].lines[item.range].forEach { wholeItemLines.insert($0) }
                    }
                }
            }
            let styleBlock = "## How I like answers\n- Length: two sentences at most\n- Tone: casual, no pep talk\n- Language: English"
            let minimumWithStyle = BrainMemory.promptHeader.count + 2 + styleBlock.count

            let full = memory.promptContext(budgetCharacters: 1_000_000)
            for title in BrainKind.allCases.map(\.sectionTitle) + ["My family"] {
                check(full.contains("## \(title)\n- "), "unlimited budget includes '\(title)'")
            }
            let fullHeadings = full.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
            checkEqual(
                fullHeadings,
                ["How I like answers", "How I like things done", "Working on now", "About me", "Likes and favourites", "Things that keep catching me",
                 "Tools and apps I use", "Skills", "Words and names", "Recently", "Screen memory", "My family"]
                    .map { "## \($0)" },
                "priority order, hand-added sections last"
            )
            check(!full.contains("more)"), "nothing shortened with an unlimited budget")

            var sawShortenedSection = false
            for budget in stride(from: 0, through: 6000, by: 13) {
                let context = memory.promptContext(budgetCharacters: budget)
                check(context.contains(styleBlock), "budget \(budget): 'How I like answers' must be whole")
                if budget >= minimumWithStyle {
                    check(context.count <= budget, "budget \(budget): context is \(context.count) characters")
                } else {
                    checkEqual(context.count, minimumWithStyle, "budget \(budget): only the style section when tiny")
                }

                let lines = context.components(separatedBy: "\n")
                checkEqual(lines.first, BrainMemory.promptHeader, "budget \(budget): starts with the header")
                for (lineIndex, line) in lines.enumerated() {
                    if line.hasPrefix("## ") {
                        let nextLine = lineIndex + 1 < lines.count ? lines[lineIndex + 1] : ""
                        check(nextLine.hasPrefix("- "), "budget \(budget): heading '\(line)' has no bullet under it")
                    } else if line.hasSuffix(" more)") && line.hasPrefix("(") {
                        sawShortenedSection = true
                        check(lineIndex >= 2 && lines[lineIndex - 1].hasPrefix("- "),
                              "budget \(budget): '(N more)' must follow a bullet")
                    } else if !line.isEmpty && lineIndex > 0 {
                        check(wholeItemLines.contains(line), "budget \(budget): cut or invented line '\(line)'")
                    }
                }
            }
            check(sawShortenedSection, "some budget should produce a shortened section")

            // A shortened section keeps its MOST RECENT bullets and counts the rest.
            let aboutOnly: BrainMemory = {
                var memory = BrainMemory()
                for index in 1...10 { memory.remember("Fact \(index)", kind: .aboutMe) }
                for index in 1...10 {
                    memory.remember("Recent \(index)", kind: .recent, date: fixedDate, timeZone: fixedTimeZone)
                }
                return memory
            }()
            let tight = aboutOnly.promptContext(budgetCharacters: BrainMemory.promptHeader.count + 2 + 60)
            checkEqual(
                tight,
                BrainMemory.promptHeader + "\n\n## About me\n- Fact 7\n- Fact 8\n- Fact 9\n- Fact 10\n(6 more)",
                "appended sections keep their last bullets"
            )
            let recentOnly = BrainMemory(profile: BrainDocument(markdown: ""), volatile: aboutOnly.volatile)
            let tightRecent = recentOnly.promptContext(budgetCharacters: BrainMemory.promptHeader.count + 2 + 75)
            checkEqual(
                tightRecent,
                BrainMemory.promptHeader + "\n\n## Recently\n- 2026-11-14: Recent 10\n- 2026-11-14: Recent 9\n(8 more)",
                "newest-first sections keep their first bullets"
            )

            checkEqual(BrainMemory().promptContext(), "", "nothing remembered → empty context")
            checkEqual(memory.promptContext(), memory.promptContext(budgetCharacters: 2400), "default budget is 2400")
        }

        section("forget") {
            var memory = BrainMemory(
                profile: BrainDocument(markdown: handEditedProfile),
                volatile: BrainDocument(markdown: BrainFile.volatile.template)
            )
            memory.remember("Food truck site: active", kind: .project)
            memory.remember("Talked about the food-truck menu", kind: .recent, date: fixedDate, timeZone: fixedTimeZone)
            memory.remember("Started a new job", kind: .aboutMe)

            checkEqual(memory.forget(matching: "ab"), [], "too-short phrase removes nothing")
            checkEqual(memory.forget(matching: "art"), [], "must match from the start of a word ('started' stays)")
            checkEqual(
                memory.forget(matching: "Food Truck"),
                ["Food truck site: active", "2026-11-14: Talked about the food-truck menu"],
                "removes from every section, ignoring case and punctuation"
            )
            checkEqual(memory.forget(matching: "miso"), ["Two cats: Miso and Udon.", "Miso hates the vacuum"],
                       "also forgets from hand-added sections and prose")
            checkEqual(memory.forget(matching: "vedant"), ["Name is Vedant - goes by Ved"],
                       "a bullet goes with its nested lines")
            check(!memory.profile.markdown.contains("goes by Ved"), "nested line removed with its parent")
            check(memory.profile.markdown.contains("## My cats"), "headings stay")
            check(memory.profile.markdown.contains("- No emoji"), "unrelated bullets stay")
        }

        section("memory actions") {
            let actions = BrainAction.decodeList(fromJSON: """
                [{"type":"remember","kind":"answerStyle","note":"Length: short"},
                 {"action":"remember","kind":"answer_style","note":"Tone: dry"},
                 {"type":"remember","kind":"preference","note":"No emoji"},
                 {"type":"remember","kind":"nonsense","note":"dropped"},
                 {"type":"remember","kind":"tools"},
                 {"type":"forget","phrase":"food truck"},
                 {"type":"explode"},
                 "not an object"]
                """)
            checkEqual(actions, [
                .remember(kind: .answerStyle, note: "Length: short"),
                .remember(kind: .answerStyle, note: "Tone: dry"),
                .remember(kind: .answerStyle, note: "No emoji"),
                .forget(phrase: "food truck"),
            ], "lenient list decoding skips invalid actions")
            checkEqual(
                BrainAction.decodeList(fromJSON: #"{"type":"forget","phrase":"x y z"}"#),
                [.forget(phrase: "x y z")], "single object"
            )
            checkEqual(BrainAction.decodeList(fromJSON: "not json"), [], "garbage")
            let decoded = try? JSONDecoder().decode(
                [BrainAction].self,
                from: Data(#"[{"type":"remember","kind":"words","note":"Faker, not Faker"}]"#.utf8)
            )
            checkEqual(decoded, [.remember(kind: .words, note: "Faker, not Faker")], "Decodable conformance")
            for kind in BrainKind.allCases {
                checkEqual(BrainKind.parse(kind.rawValue), kind, "kind \(kind.rawValue) parses")
                check(BrainAction.schemaDescription.contains("- \(kind.rawValue):"),
                      "schema description lists \(kind.rawValue)")
            }
        }

        section("conversation window (pure)") {
            var messages: [BrainMessage] = []
            for index in 1...100 {
                messages = BrainConversationLog.appending(
                    BrainMessage(
                        role: index.isMultiple(of: 2) ? .assistant : .user,
                        text: "message \(index)",
                        date: fixedDate.addingTimeInterval(Double(index))
                    ),
                    to: messages
                )
                check(messages.count <= 40, "window never exceeds 40")
            }
            checkEqual(messages.count, 40, "window is 40")
            checkEqual(messages.first?.text, "message 61", "oldest kept")
            checkEqual(messages.last?.text, "message 100", "newest kept")

            let encoded = BrainConversationLog.encode(messages)
            checkEqual(encoded.split(separator: "\n").count, 40, "one line per message")
            checkEqual(BrainConversationLog.decode(encoded), messages, "JSONL round trip")
            checkEqual(
                BrainConversationLog.decode("garbage\n" + encoded + "{\"role\":\"robot\",\"text\":\"x\"}\n").count,
                40, "bad lines are skipped"
            )
            let multiline = BrainConversationLog.appending(
                BrainMessage(role: .user, text: "  two\nlines \"quoted\"  ", date: fixedDate), to: []
            )
            checkEqual(BrainConversationLog.encode(multiline).split(separator: "\n").count, 1, "newlines are escaped")
            checkEqual(BrainConversationLog.decode(BrainConversationLog.encode(multiline)).first?.text,
                       "two\nlines \"quoted\"", "text survives")
            checkEqual(
                BrainConversationLog.appending(BrainMessage(role: .user, text: "   ", date: fixedDate), to: messages),
                messages, "blank messages are not stored"
            )
            let long = BrainConversationLog.appending(
                BrainMessage(role: .assistant, text: String(repeating: "a", count: 10_000), date: fixedDate), to: []
            )
            checkEqual(long.first?.text.count, BrainConversationLog.maximumMessageCharacters, "long messages are capped")
        }

        section("BrainStore on disk (temporary directory)") {
            let directory = makeTemporaryDirectory().appendingPathComponent("brain", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
            let store = BrainStore(directoryURL: directory)

            checkEqual(store.promptContext(), "", "empty before anything is remembered")
            checkEqual(store.rememberedCount, 0, "count 0")
            check(!FileManager.default.fileExists(atPath: directory.path), "reading does not create files")

            checkEqual(store.remember("Name is Vedant", kind: .aboutMe), .added, "remember")
            check(FileManager.default.fileExists(atPath: store.profileFileURL.path), "PROFILE.md created")
            check(FileManager.default.fileExists(atPath: store.volatileFileURL.path), "VOLATILE.md created")
            let permissions = (try? FileManager.default.attributesOfItem(atPath: store.profileFileURL.path))?[.posixPermissions] as? Int
            checkEqual(permissions, 0o600, "memory files are private to the user")

            // A hand edit in another editor is picked up by the next call (and by a second store).
            var text = try! String(contentsOf: store.profileFileURL, encoding: .utf8)
            text += "\n## My cats\n- Miso hates the vacuum\n"
            text = text.replacingOccurrences(of: "## How I like answers\n", with: "## How I like answers\n- Be blunt\n")
            try! text.write(to: store.profileFileURL, atomically: true, encoding: .utf8)
            checkEqual(store.rememberedCount, 3, "hand edits are counted")
            check(store.promptContext().contains("- Be blunt"), "hand edits reach the prompt")
            check(BrainStore(directoryURL: directory).promptContext().contains("- Miso hates the vacuum"),
                  "a second store sees the same files")
            checkEqual(store.remember("be blunt!", kind: .answerStyle), .duplicate, "dedupes against hand edits")
            checkEqual(try! String(contentsOf: store.profileFileURL, encoding: .utf8), text,
                       "a no-op remember leaves the file byte-identical")

            let result = store.apply(actions: [
                .remember(kind: .project, note: "Food truck site: active; blocked on DNS"),
                .remember(kind: .mistakes, note: "Forgets to save"),
                .remember(kind: .mistakes, note: "forgets to save"),
                .forget(phrase: "vacuum"),
            ])
            checkEqual(result.rememberOutcomes, [.added, .added, .repeated(count: 2)], "apply outcomes")
            checkEqual(result.forgotten, ["Miso hates the vacuum"], "apply forgot")
            checkEqual(store.apply(actions: []), BrainApplyResult(), "empty apply")

            for index in 1...50 {
                store.appendMessage(role: index.isMultiple(of: 2) ? .assistant : .user, text: "turn \(index)")
            }
            store.appendMessage(role: .user, text: "my food truck is called Taco Cat")
            let reopened = BrainStore(directoryURL: directory)
            checkEqual(reopened.recentMessages().count, 40, "conversation persisted and trimmed to 40")
            checkEqual(reopened.recentConversation.first?.text, "turn 12", "oldest kept message")
            checkEqual(reopened.recentMessages(limit: 3).map(\.text),
                       ["turn 49", "turn 50", "my food truck is called Taco Cat"], "limit returns the newest, oldest first")
            let linesOnDisk = try! String(contentsOf: store.conversationFileURL, encoding: .utf8).split(separator: "\n")
            checkEqual(linesOnDisk.count, 40, "file trimmed on write")

            checkEqual(store.forget(matching: "food truck"), ["Food truck site: active; blocked on DNS"], "store forget")
            check(!reopened.recentMessages().contains { $0.text.contains("food truck") },
                  "forget also drops the matching conversation messages")
            checkEqual(reopened.recentMessages().count, 39, "other messages stay")

            // A file we cannot read as text is never overwritten.
            let unreadable = Data([0xFF, 0xFE, 0xFF, 0x00, 0xC3, 0x28])
            let goodProfile = try! Data(contentsOf: store.profileFileURL)
            try! unreadable.write(to: store.profileFileURL)
            checkEqual(store.remember("Should not be written", kind: .aboutMe), .rejected, "unreadable file → rejected")
            checkEqual(store.remember("Nor this", kind: .recent), .rejected, "nothing is written while a file is unreadable")
            checkEqual(try! Data(contentsOf: store.profileFileURL), unreadable, "unreadable file left untouched")
            checkEqual(store.promptContext(), "", "unreadable memory → empty context, no crash")
            try! goodProfile.write(to: store.profileFileURL)

            check(store.forgetEverything(), "forget everything")
            checkEqual(try! String(contentsOf: store.profileFileURL, encoding: .utf8), BrainFile.profile.template, "profile reset")
            checkEqual(try! String(contentsOf: store.volatileFileURL, encoding: .utf8), BrainFile.volatile.template, "volatile reset")
            checkEqual(store.recentMessages(), [], "conversation cleared")
            checkEqual(store.rememberedCount, 0, "nothing remembered")
            checkEqual(store.promptContext(), "", "empty context after forgetting everything")

            let fresh = BrainStore(directoryURL: directory.appendingPathComponent("nested/never-made"))
            check(fresh.ensureFilesExist(), "ensureFilesExist creates the folder and templates")
            checkEqual(try? String(contentsOf: fresh.profileFileURL, encoding: .utf8), BrainFile.profile.template, "template written")
        }

        section("migration from the old stores") {
            let engineStateJSON = Data("""
                {
                  "learnerModel": {
                    "skillNodes": [], "rollingNotes": ["ignored"],
                    "datedPersonalFacts": [
                      {"text": "Works as a nurse", "capturedAt": 800000000.5},
                      {"text": "Has a dog named Rex", "capturedAt": 800086400}
                    ],
                    "workflowSignals": [
                      {"text": "Figma — Landing page v3", "capturedAt": 800000000},
                      {"text": "Figma — Private client file", "capturedAt": 800000100},
                      {"text": "Xcode — teachy", "capturedAt": 800000200}
                    ],
                    "prefersHintsOverAutomation": true,
                    "createdAt": 790000000, "updatedAt": 800000000
                  },
                  "projects": [
                    {"id": "p2", "title": "Resume", "goalDescription": "One page resume", "steps": [],
                     "currentStepIndex": 0, "status": "abandoned", "stepJournal": [],
                     "createdAt": 800000000, "lastWorkedAt": 800000300},
                    {"id": "p1", "title": "Food truck site", "goalDescription": "A one-page site; with a menu",
                     "steps": [{"id": "a", "anything": 1}, {"id": "b"}, {"id": "c"}], "currentStepIndex": 1,
                     "status": "active", "stepJournal": [{"text": "Picked a template", "capturedAt": 800000400},
                     {"text": "Stuck on DNS", "capturedAt": 800000500}],
                     "createdAt": 800000000, "lastWorkedAt": 800000500},
                    {"id": "p0", "title": "Portfolio", "goalDescription": "Show my work", "steps": [],
                     "currentStepIndex": 0, "status": "shipped", "deployedURL": "https://ved.example.com",
                     "stepJournal": [], "createdAt": 799000000, "lastWorkedAt": 799500000}
                  ],
                  "config": {"some": "thing"}
                }
                """.utf8)
            let globalProfileJSON = Data("""
                {"knows": ["what a terminal is", "git commit"], "confusedBy": ["git rebase", "Git Commit"],
                 "rollingNotes": [], "prefersHintsOverAutomation": false}
                """.utf8)
            let courseProfilesJSON = Data("""
                {"course-b": {"knows": ["CSS flexbox"], "confusedBy": ["z-index"]},
                 "course-a": {"knows": ["What a terminal is."], "confusedBy": []}}
                """.utf8)

            let notes = BrainMigration.plan(
                engineStateJSON: engineStateJSON,
                globalLearnerProfileJSON: globalProfileJSON,
                courseLearnerProfilesJSON: courseProfilesJSON,
                now: fixedDate
            )
            func planned(_ kind: BrainKind) -> [String] { notes.filter { $0.kind == kind }.map(\.note) }
            checkEqual(planned(.aboutMe), ["Works as a nurse", "Has a dog named Rex"], "facts → About me")
            checkEqual(planned(.tools), ["Figma", "Xcode"], "apps → Tools, app name only, no window titles")
            checkEqual(
                planned(.project),
                ["Food truck site: active; step 2 of 3; goal: A one-page site, with a menu; last: Stuck on DNS"],
                "active project → Working on now; abandoned dropped"
            )
            checkEqual(planned(.recent), ["Shipped Portfolio — https://ved.example.com"], "shipped project → Recently")
            checkEqual(planned(.skills), ["Knows what a terminal is", "Knows git commit", "Knows CSS flexbox"],
                       "knows → Skills, unique across profiles")
            checkEqual(planned(.mistakes), ["Confused by git rebase", "Confused by z-index"],
                       "confusedBy → mistakes, minus anything they now know")
            checkEqual(planned(.answerStyle), ["Help style: give me hints and let me try before showing the answer"],
                       "hint preference → How I like answers (engine value wins)")
            checkEqual(
                notes.first { $0.note == "Works as a nurse" }?.date,
                Date(timeIntervalSinceReferenceDate: 800000000.5), "fact dates are kept"
            )

            // Oldest engine-state format: flat strings.
            let flat = BrainMigration.plan(
                engineStateJSON: Data(#"{"learnerModel": {"personalFacts": ["Likes chess"]}}"#.utf8),
                globalLearnerProfileJSON: nil, courseLearnerProfilesJSON: nil, now: fixedDate
            )
            checkEqual(flat, [BrainMigration.Note(kind: .aboutMe, note: "Likes chess", date: fixedDate)], "flat facts")

            // Missing and broken inputs are safe.
            checkEqual(BrainMigration.plan(engineStateJSON: nil, globalLearnerProfileJSON: nil,
                                           courseLearnerProfilesJSON: nil), [], "nothing to import")
            checkEqual(BrainMigration.plan(engineStateJSON: Data("{ broken".utf8),
                                           globalLearnerProfileJSON: Data("[1,2]".utf8),
                                           courseLearnerProfilesJSON: Data()), [], "broken JSON is ignored")

            // End to end, against temp files and a throwaway defaults suite.
            let root = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let suiteName = "teachy-brain-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let engineStateURL = root.appendingPathComponent("engine-state.json")

            // 1. No old stores at all.
            let emptyStore = BrainStore(directoryURL: root.appendingPathComponent("brain-empty"))
            BrainMigration.runIfNeeded(into: emptyStore, defaults: defaults, engineStateFileURL: engineStateURL)
            check(defaults.bool(forKey: BrainMigration.didMigrateDefaultsKey), "flag set even with nothing to import")
            checkEqual(emptyStore.rememberedCount, 0, "nothing imported")
            defaults.removeObject(forKey: BrainMigration.didMigrateDefaultsKey)

            // 2. With the old stores.
            try! engineStateJSON.write(to: engineStateURL)
            defaults.set(globalProfileJSON, forKey: BrainMigration.globalLearnerProfileDefaultsKey)
            defaults.set(courseProfilesJSON, forKey: BrainMigration.courseLearnerProfilesDefaultsKey)
            let store = BrainStore(directoryURL: root.appendingPathComponent("brain"))
            store.remember("Works as a NURSE", kind: .aboutMe)
            BrainMigration.runIfNeeded(into: store, defaults: defaults, engineStateFileURL: engineStateURL)
            check(defaults.bool(forKey: BrainMigration.didMigrateDefaultsKey), "flag set")
            let profile = BrainDocument(markdown: try! String(contentsOf: store.profileFileURL, encoding: .utf8))
            let volatile = BrainDocument(markdown: try! String(contentsOf: store.volatileFileURL, encoding: .utf8))
            checkEqual(bullets(profile, "About me"), ["Works as a NURSE", "Has a dog named Rex"],
                       "imported, de-duplicated against what was already there")
            checkEqual(bullets(profile, "Tools and apps I use"), ["Figma", "Xcode"], "tools imported")
            checkEqual(bullets(profile, "Skills").count, 3, "skills imported")
            checkEqual(bullets(volatile, "Working on now").count, 1, "project imported")
            check(bullets(volatile, "Recently").first?.hasSuffix("Shipped Portfolio — https://ved.example.com") == true,
                  "shipped project imported with its date")
            checkEqual(try! Data(contentsOf: engineStateURL), engineStateJSON, "old engine state left untouched")
            checkEqual(defaults.data(forKey: BrainMigration.globalLearnerProfileDefaultsKey), globalProfileJSON,
                       "old profile left untouched")

            // 3. Runs once: forgetting everything must not bring the old facts back.
            store.forgetEverything()
            BrainMigration.runIfNeeded(into: store, defaults: defaults, engineStateFileURL: engineStateURL)
            checkEqual(store.rememberedCount, 0, "import does not run twice")
        }

        section("saved chats: store, switch, idle split, legacy import") {
            let directory = makeTemporaryDirectory()
            // The older single conversation becomes the first saved chat.
            let legacyURL = directory.appendingPathComponent("conversation.jsonl")
            let legacy = [
                BrainMessage(role: .user, text: "help me plan the food truck menu", date: fixedDate.addingTimeInterval(-90_000)),
                BrainMessage(role: .assistant, text: "Tacos first.", date: fixedDate.addingTimeInterval(-89_990)),
            ]
            try! BrainConversationLog.encode(legacy).write(to: legacyURL, atomically: true, encoding: .utf8)
            var clock = fixedDate
            let store = ChatSessionStore(
                directoryURL: directory.appendingPathComponent("sessions"),
                journalFileURL: directory.appendingPathComponent("JOURNAL.md"),
                legacyConversationFileURL: legacyURL,
                now: { clock }
            )
            let imported = store.index()
            checkEqual(imported.sessions.count, 1, "legacy conversation imported as one chat")
            checkEqual(store.currentMessages().count, 2, "with its messages")
            checkEqual(imported.sessions.first?.title, "help me plan the food truck menu", "titled from its first question")

            // Recent enough: the next message goes into the same chat.
            store.append(BrainMessage(role: .user, text: "and drinks?", date: fixedDate.addingTimeInterval(-89_000)))
            checkEqual(store.index().sessions.count, 1, "same chat while active")
            // Idle past the gap: a new chat starts by itself.
            let idleID = store.currentSessionID
            store.append(BrainMessage(role: .user, text: "Fix the failing login test in ~/code/teachy", date: fixedDate))
            store.append(BrainMessage(role: .assistant, text: "Looking at LoginTests.swift now.", date: fixedDate.addingTimeInterval(5)))
            checkEqual(store.index().sessions.count, 2, "idle chat → new chat on the next question")
            check(store.currentSessionID != idleID, "the new chat is open")
            checkEqual(store.currentMessages().map(\.text), ["Fix the failing login test in ~/code/teachy", "Looking at LoginTests.swift now."], "new chat holds only its messages")
            checkEqual(store.messages(in: idleID!).count, 3, "old chat kept whole")

            // New chat button: an empty open chat is reused, not stacked.
            let fresh = store.startNewSession()
            let again = store.startNewSession()
            checkEqual(fresh.id, again.id, "an empty new chat is reused")
            checkEqual(store.currentMessages(), [], "new chat is empty")
            // Switching away from an empty chat drops it.
            check(store.switchToSession(idleID!), "switch to an old chat")
            checkEqual(store.index().sessions.count, 2, "the empty chat left behind is removed")
            checkEqual(store.currentMessages().count, 3, "the old chat's messages are back")
            check(!store.switchToSession("nope"), "unknown chat refused")

            // Rename: a typed title is not overwritten by a model title.
            store.renameSession(idleID!, to: "Food truck")
            store.renameSession(idleID!, to: "Menu planning", isAutomatic: true)
            checkEqual(store.currentSession?.title, "Food truck", "person's title wins")

            // Search across chats.
            let hits = store.search("what did we do on the login test")
            checkEqual(hits.first?.sessionID == idleID, false, "search finds the other chat")
            check(hits.first?.snippet.lowercased().contains("login") == true, "snippet shows the match")
            checkEqual(store.search("zzzz nothing"), [], "no false hits")

            // Forget removes from every chat and resets the summary.
            store.saveCompactSummary("They like tacos.", for: idleID!, throughMessageCount: 2)
            checkEqual(store.currentSession?.summarizedMessageCount, 2, "summary saved")
            store.removeMessages(mentioning: "food truck")
            checkEqual(store.currentMessages().count, 2, "forgotten message gone")
            checkEqual(store.currentSession?.compactSummary, "", "summary cleared after forgetting")

            // Delete the open chat: the newest other one opens.
            store.deleteSession(idleID!)
            checkEqual(store.index().sessions.count, 1, "deleted")
            check(store.currentSessionID != nil && store.currentSessionID != idleID, "another chat opens")
            clock = fixedDate.addingTimeInterval(60)
            _ = clock
        }

        section("context window: what is sent, when to compact") {
            var messages: [BrainMessage] = []
            for turn in 0..<30 {
                messages.append(BrainMessage(role: .user, text: "question \(turn) " + String(repeating: "q", count: 500), date: fixedDate))
                messages.append(BrainMessage(role: .assistant, text: "answer \(turn) " + String(repeating: "a", count: 500), date: fixedDate))
            }
            let range = ChatContextWindow.messagesToCompact(allMessages: messages, summarizedMessageCount: 0)
            checkEqual(range, 0..<48, "fold all but the last 12")
            checkEqual(messages[range!.upperBound].role, .user, "the kept part starts on a question")
            checkEqual(ChatContextWindow.messagesToCompact(allMessages: messages, summarizedMessageCount: 48), nil, "nothing more to fold right after")
            checkEqual(ChatContextWindow.messagesToCompact(allMessages: Array(messages.prefix(6)), summarizedMessageCount: 0), nil, "a short chat is never folded")

            let recent = ChatContextWindow.recentMessagesForModel(allMessages: messages, summarizedMessageCount: 48)
            checkEqual(recent.count, 12, "everything after the summary fits")
            var budget = ChatContextWindow.Budget()
            budget.recentCharacters = 2_000
            let trimmed = ChatContextWindow.recentMessagesForModel(allMessages: messages, summarizedMessageCount: 0, budget: budget)
            check(trimmed.count < 6 && trimmed.first?.role == .user, "budget trims from the old end, starting on a question")
            checkEqual(trimmed.last?.text.hasPrefix("answer 29"), true, "newest kept")

            let pairs = ChatContextWindow.exchanges(from: Array(messages.suffix(4)))
            checkEqual(pairs.count, 2, "pairs built")
            check(ChatContextWindow.questionWantsRecall("what did we do yesterday on the deck?"), "recall cue spotted")
            check(!ChatContextWindow.questionWantsRecall("open spotify"), "no recall for a command")

            let section = ChatContextWindow.promptSection(
                sessionSummary: "They are fixing LoginTests.",
                journal: "2026-11-13 (Friday):\n- Fixed the login test.",
                previousSession: ("Menu", fixedDate.addingTimeInterval(-86_400), [BrainMessage(role: .user, text: "tacos?", date: fixedDate)]),
                recalled: [],
                now: fixedDate
            )
            check(section.contains("EARLIER IN THIS CHAT") && section.contains("YOUR JOURNAL") && section.contains("yesterday"), "prompt section has summary, previous chat and journal")
            checkEqual(ChatContextWindow.promptSection(sessionSummary: "", journal: "", previousSession: nil, recalled: [], now: fixedDate), "", "empty when nothing to say")
            checkEqual(ChatSessionSummary.automaticTitle(fromFirstQuestion: "  short\nquestion "), "short question", "title on one line")
            check(ChatSessionSummary.automaticTitle(fromFirstQuestion: String(repeating: "word ", count: 40)).hasSuffix("…"), "long title cut at a word")
        }

        section("journal: day by day, read back within budget") {
            var journal = ""
            journal = ChatJournal.appending(lines: ["- Planned the food truck menu."], on: fixedDate.addingTimeInterval(-2 * 86_400), to: journal)
            journal = ChatJournal.appending(lines: ["Fixed the login test in teachy.", "- Fixed the login test in teachy."], on: fixedDate, to: journal)
            journal = ChatJournal.appending(lines: ["- Booked the Bergen flight."], on: fixedDate.addingTimeInterval(-86_400), to: journal)
            let parsed = ChatJournal.parse(journal)
            checkEqual(parsed.days.map(\.key), ["2026-11-12", "2026-11-13", "2026-11-14"], "days in date order")
            checkEqual(parsed.days.last?.lines, ["- Fixed the login test in teachy."], "bullets normalised and de-duplicated")
            check(journal.hasPrefix("# Journal"), "has the header")
            let recent = ChatJournal.recent(journal, now: fixedDate, budgetCharacters: 90)
            check(recent.contains("login test") && !recent.contains("food truck"), "budget keeps the newest days")
            checkEqual(ChatJournal.lines(fromModelAnswer: "NOTHING"), [], "NOTHING writes nothing")
            checkEqual(ChatJournal.lines(fromModelAnswer: "• one\n* two\nthree\nfour"), ["- one", "- two", "- three"], "at most three lines")

            let directory = makeTemporaryDirectory()
            var clock = fixedDate
            let store = ChatSessionStore(directoryURL: directory.appendingPathComponent("sessions"), journalFileURL: directory.appendingPathComponent("JOURNAL.md"), now: { clock })
            let chatID = store.append(BrainMessage(role: .user, text: "rename my screenshots", date: fixedDate))!
            checkEqual(store.sessionsNeedingJournal().count, 0, "the open chat waits until it goes quiet")
            clock = fixedDate.addingTimeInterval(30 * 60)
            checkEqual(store.sessionsNeedingJournal().map(\.id), [chatID], "quiet chat needs journaling")
            store.addJournalLines(["- Renamed the screenshots."], on: fixedDate, for: chatID, throughMessageCount: 1)
            checkEqual(store.sessionsNeedingJournal().count, 0, "journaled")
            check(store.recentJournal().contains("Renamed the screenshots"), "journal read back")
        }

        let realBrainExistsAfter = FileManager.default.fileExists(atPath: realBrainPath)
        checkEqual(realBrainExistsAfter, realBrainExistedBefore, "tests must not create the real ~/.teachy/brain")

        print("")
        if failureCount == 0 {
            print("brain tests: all \(checkCount) checks passed")
            exit(0)
        } else {
            print("brain tests: \(failureCount) of \(checkCount) checks FAILED")
            exit(1)
        }
    }
}
