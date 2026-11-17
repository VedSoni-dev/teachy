// Tests for concurrent jobs, history, compaction, named agents, routines, the unattended
// consent rule, the connector catalog and the agent loop. Run: scripts/tests/run_agents2_tests.sh

import Foundation

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: @autoclosure () -> String, line: UInt = #line) {
    expect(got == want, "\(message()): got \(got), want \(want)", line: line)
}

func section(_ name: String) { print("— \(name)") }

let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-agents2-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// MARK: - Concurrency

section("slots: four at once, the fifth waits, in order")
do {
    var book = AgentSlotBook()
    for id in ["a", "b", "c", "d"] { expectEqual(book.request(id), .runNow, "job \(id) starts") }
    expectEqual(book.request("e"), .queued(position: 1), "fifth job waits")
    expectEqual(book.request("f"), .queued(position: 2), "sixth job waits behind it")
    expectEqual(book.request("e"), .queued(position: 1), "asking again changes nothing")
    expectEqual(book.request("a"), .runNow, "a running job asking again still runs")
    expectEqual(book.running.count, 4, "never more than four running")
    expectEqual(book.release("b"), ["e"], "a finished job lets the next one in")
    expectEqual(book.running, ["a", "c", "d", "e"], "running set after one release")
    expectEqual(book.release("f"), [], "a waiting job that gives up frees nothing")
    expectEqual(book.waiting, [], "and it leaves the queue")
    expectEqual(book.release("a"), [], "nobody waiting: nothing promoted")
    expectEqual(book.request("g"), .runNow, "a slot is free again")
    expectEqual(book.release("nope"), [], "releasing an unknown job is harmless")

    var small = AgentSlotBook(limit: 1)
    _ = small.request("x"); _ = small.request("y"); _ = small.request("z")
    expectEqual(small.release("x"), ["y"], "one promoted at a time with limit 1")
    expectEqual(small.release("y"), ["z"], "then the next")
}

section("drive is exclusive")
do {
    var lease = DriveLease()
    expectEqual(lease.claim("job1"), .granted, "first job gets Drive")
    expectEqual(lease.claim("job1"), .granted, "the holder can claim again")
    expectEqual(lease.claim("job2"), .busy(holder: "job1"), "a second job is told who holds it")
    lease.release("job2")
    expectEqual(lease.holder, "job1", "a non-holder cannot release it")
    lease.release("job1")
    expectEqual(lease.claim("job2"), .granted, "free once the holder ends")
    expect(DriveLease.busyMessage(holderTitle: "Crop Photo").contains("Crop Photo"), "busy message names the holder")
}

section("which job a follow-up belongs to")
do {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    typealias C = AgentFollowUpRouter.Candidate
    let inbox = C(id: "1", title: "Inbox Hunter", agentName: nil, isActive: true)
    let research = C(id: "2", title: "Price Check", agentName: "Research buddy", isActive: true)
    let old = C(id: "3", title: "Old Job", isActive: false, finishedAt: now.addingTimeInterval(-3_600))
    let recent = C(id: "4", title: "Crop Photo", isActive: false, finishedAt: now.addingTimeInterval(-60))

    expectEqual(AgentFollowUpRouter.target(for: "tell inbox hunter to skip newsletters", candidates: [inbox, research], frontJobID: "2", now: now), "1", "a job named by title wins")
    expectEqual(AgentFollowUpRouter.target(for: "Research Buddy, also check eBay", candidates: [inbox, research], frontJobID: "1", now: now), "2", "a job named by its agent wins")
    expectEqual(AgentFollowUpRouter.target(for: "also include last week", candidates: [inbox], frontJobID: nil, now: now), "1", "the only running job takes it")
    expectEqual(AgentFollowUpRouter.target(for: "also include last week", candidates: [inbox, research], frontJobID: "2", now: now), "2", "two running: the card in front takes it")
    expectEqual(AgentFollowUpRouter.target(for: "also include last week", candidates: [inbox, research], frontJobID: nil, now: now), nil, "two running and none in front: nobody")
    expectEqual(AgentFollowUpRouter.target(for: "make it square instead", candidates: [recent], frontJobID: "4", now: now), "4", "a job that just finished still takes a follow-up")
    expectEqual(AgentFollowUpRouter.target(for: "about the old job, redo it", candidates: [old], frontJobID: "3", now: now), nil, "a job finished long ago does not")
    expectEqual(AgentFollowUpRouter.target(for: "anything", candidates: [], frontJobID: nil, now: now), nil, "no jobs: nobody")
}

section("card deck: newest in front, arrows wrap")
do {
    var deck = AgentCardDeck()
    deck.sync(visible: ["a"], active: ["a"])
    expectEqual(deck.frontID, "a", "first card is in front")
    deck.sync(visible: ["a", "b"], active: ["a", "b"])
    expectEqual(deck.frontID, "b", "a new job comes to the front")
    expectEqual(deck.frontIndex, 2, "its place is 2 of 2")
    deck.flip(by: 1)
    expectEqual(deck.frontID, "a", "→ wraps to the first")
    deck.flip(by: -1)
    expectEqual(deck.frontID, "b", "← wraps back")
    deck.setCollapsed(true, id: "a")
    deck.sync(visible: ["a", "b"], active: ["b"])
    expectEqual(deck.frontID, "b", "no new job: the front card stays")
    expect(deck.isCollapsed("a"), "folded state survives a sync")
    deck.sync(visible: ["a"], active: [])
    expectEqual(deck.frontID, "a", "front card left: the remaining one takes over")
    deck.sync(visible: [], active: [])
    expectEqual(deck.frontID, nil, "empty deck has no front")
    expect(!deck.isCollapsed("a"), "folded state is dropped with the card")
    var single = AgentCardDeck()
    single.sync(visible: ["x"], active: ["x"])
    single.flip(by: 1)
    expectEqual(single.frontID, "x", "one card: arrows do nothing")
}

section("tools offered to a job")
do {
    let all = ["bash", "remember", "create_routine", "list_routines", "pause_routine", "delete_routine"]
    expectEqual(AgentToolAvailability.names(registered: all, hasAgent: false, isUnattended: false), ["bash", "create_routine", "list_routines", "pause_routine", "delete_routine"], "plain job: no remember")
    expectEqual(AgentToolAvailability.names(registered: all, hasAgent: true, isUnattended: false), Set(all), "agent job: everything")
    expectEqual(AgentToolAvailability.names(registered: all, hasAgent: true, isUnattended: true), ["bash", "remember", "list_routines"], "a routine run cannot create, wake or delete routines")
}

// MARK: - History

func makeRecord(_ id: String, startedAt: Date, title: String = "Job", status: String = "done") -> AgentJobRecord {
    AgentJobRecord(
        id: id, title: title, request: "do \(id)", agentSlug: nil, agentName: nil, routineID: nil,
        plan: [.init(text: "Look", state: "done")],
        steps: [.init(tool: "web_search", result: "found it", seconds: 1.2)],
        answer: "Answer \(id)", status: status, statusDetail: "", refusals: [], followUps: [],
        startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(30)
    )
}

section("projects: active selection, legacy jobs and saved membership")
do {
    let file = scratch.appendingPathComponent("projects.json")
    let projects = AgentProjectStore(file: file)
    let history = AgentHistoryStore(directory: scratch.appendingPathComponent("project-history"))
    let first = try projects.create(name: "  Calculus  ")
    var job = makeRecord("lesson", startedAt: Date())
    job.projectID = projects.activeProjectID
    try history.save(job)

    let second = try projects.create(name: "Robotics")
    expectEqual(first.name, "Calculus", "project names are trimmed")
    expectEqual(projects.activeProjectID, second.id, "creating a project selects it")
    expectEqual(history.record(id: job.id)?.projectID, first.id, "switching leaves job membership intact")
    try projects.rename(id: first.id, name: "Math")
    try projects.select(first.id)
    let reopened = AgentProjectStore(file: file)
    expectEqual(reopened.projects.first?.name, "Math", "rename survives relaunch")
    expectEqual(reopened.activeProjectID, first.id, "selection survives relaunch")
    do {
        try reopened.rename(id: first.id, name: "robotics")
        expect(false, "duplicate names should fail")
    } catch {
        expectEqual(reopened.projects.first?.name, "Math", "rejected rename preserves the old name")
    }
    try reopened.select(nil)
    expectEqual(AgentProjectStore(file: file).activeProjectID, nil, "All projects survives relaunch")
    try history.save(makeRecord("legacy", startedAt: Date()))
    let legacy = history.record(id: "legacy")
    expect(legacy != nil && legacy?.projectID == nil, "records with no project key remain available")

    let malformed = Data("broken".utf8)
    try malformed.write(to: file)
    let unreadable = AgentProjectStore(file: file)
    do {
        try unreadable.create(name: "New")
        expect(false, "unreadable catalogs should not be overwritten")
    } catch {
        expectEqual(try Data(contentsOf: file), malformed, "preserves an unreadable catalog")
    }
}

section("history: saved, listed newest first, pruned to the cap")
do {
    let directory = scratch.appendingPathComponent("history", isDirectory: true)
    let store = AgentHistoryStore(directory: directory, cap: 5)
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<8 {
        try store.save(makeRecord("JOB-\(index)", startedAt: base.addingTimeInterval(Double(index) * 3_600)))
    }
    let listed = store.list()
    expectEqual(listed.count, 5, "only the cap is kept")
    expectEqual(listed.map(\.id), ["JOB-7", "JOB-6", "JOB-5", "JOB-4", "JOB-3"], "newest first, oldest pruned")
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
    expectEqual(files.count, 5, "pruned files are gone from disk")

    var updated = makeRecord("JOB-7", startedAt: base.addingTimeInterval(7 * 3_600))
    updated.answer = "Answer after a follow-up"
    updated.followUps = ["also do this"]
    try store.save(updated)
    expectEqual(store.list().count, 5, "saving a job again rewrites its file, no duplicate")
    expectEqual(store.record(id: "JOB-7")?.answer, "Answer after a follow-up", "the rewrite is what is read back")
    expectEqual(store.list(limit: 2).count, 2, "limit is honoured")

    let utc = TimeZone(identifier: "UTC")!
    expectEqual(AgentHistoryStore.fileName(for: makeRecord("3F2A9C1B-AAAA", startedAt: Date(timeIntervalSince1970: 1_794_614_400)), timeZone: utc), "2026-11-14-3F2A9C1B-AAAA.json", "file name is <date>-<id>.json")
    expectEqual(AgentHistoryStore.fileName(for: makeRecord("../../etc", startedAt: base), timeZone: utc).contains("/"), false, "an id can never climb out of the folder")

    try "not json".write(to: directory.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
    try store.save(makeRecord("JOB-9", startedAt: base.addingTimeInterval(9 * 3_600)))
    expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.json").path), "an unreadable file is pruned first")
    expectEqual(store.list().first?.id, "JOB-9", "and the new job is kept")

    store.delete(id: "JOB-9")
    expect(store.record(id: "JOB-9") == nil, "delete removes one job")

    let entries: [(name: String, startedAt: Date?)] = [("c", base.addingTimeInterval(3)), ("a", base.addingTimeInterval(1)), ("b", base.addingTimeInterval(2)), ("x", nil)]
    expectEqual(AgentHistoryStore.namesToPrune(entries, cap: 2), ["x", "a"], "unreadable first, then oldest")
    expectEqual(AgentHistoryStore.namesToPrune(entries, cap: 4), [], "at the cap nothing goes")
    expectEqual(AgentHistoryStore.defaultCap, 200, "default cap")

    let long = String(repeating: "word ", count: 200)
    expect(AgentJobRecord.shortResult(long).count <= AgentJobRecord.stepResultLimit, "step results are kept short")
    expectEqual(AgentJobRecord.shortResult("a\n\n  b\tc"), "a b c", "whitespace is squeezed")
}

// MARK: - Compaction

func toolCallMessage(id: String, name: String, arguments: String) -> [String: Any] {
    ["role": "assistant", "content": NSNull(), "tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]]]
}

section("compaction: the budget rule")
do {
    typealias E = AgentCompaction.Entry
    var budget = AgentCompaction.Budget()
    budget.maxCost = 1_000
    budget.targetCost = 500
    budget.keepRecentToolResults = 2

    func tool(_ cost: Int, compacted: Bool = false) -> E { E(kind: .tool, cost: cost, bytes: cost, hasImages: false, isCompacted: compacted) }
    let system = E(kind: .system, cost: 100, bytes: 100, hasImages: false, isCompacted: false)
    let user = E(kind: .user, cost: 50, bytes: 50, hasImages: false, isCompacted: false)
    let call = E(kind: .assistant, cost: 20, bytes: 20, hasImages: false, isCompacted: false)

    expectEqual(AgentCompaction.plan([system, user, call, tool(300), call, tool(300)], budget: budget), [], "under the maximum: nothing happens")

    let over = [system, user, call, tool(300), call, tool(300), call, tool(300), call, tool(300), call, tool(300)]
    let actions = AgentCompaction.plan(over, budget: budget)
    expectEqual(actions, [.dropToolResult(index: 3), .dropToolResult(index: 5), .dropToolResult(index: 7)], "oldest results go; the newest two stay whole")

    let barely = [system, user, call, tool(450), call, tool(450), call, tool(50), call, tool(50)]
    expectEqual(AgentCompaction.plan(barely, budget: budget), [.dropToolResult(index: 3), .dropToolResult(index: 5)], "stops as soon as it is under the target")

    let alreadyDone = [system, user, call, tool(90, compacted: true), call, tool(600), call, tool(300), call, tool(300)]
    expectEqual(AgentCompaction.plan(alreadyDone, budget: budget), [.dropToolResult(index: 5)], "a result that is already a stub is not dropped twice")

    let onlyRecent = [system, user, call, tool(900), call, tool(900)]
    expectEqual(AgentCompaction.plan(onlyRecent, budget: budget), [], "the newest results are never dropped, even over budget")

    var byteBudget = AgentCompaction.Budget()
    byteBudget.maxBytes = 1_000
    byteBudget.targetBytes = 500
    byteBudget.keepRecentToolResults = 1
    let pictureUser = E(kind: .user, cost: 6_050, bytes: 900, hasImages: true, isCompacted: false)
    let lastUser = E(kind: .user, cost: 6_050, bytes: 900, hasImages: true, isCompacted: false)
    expectEqual(AgentCompaction.plan([system, pictureUser, call, tool(60), lastUser], budget: byteBudget), [.stripImages(index: 1)], "when results are not enough, pictures leave older user messages; the newest keeps its picture")

    // Under budget, old screenshots still go: each step re-sends the whole job.
    let pictureTool = E(kind: .tool, cost: 6_100, bytes: 900, hasImages: true, isCompacted: false)
    expectEqual(
        AgentCompaction.plan([system, pictureUser, call, pictureTool, call, pictureTool], budget: AgentCompaction.Budget()),
        [.stripImages(index: 1), .stripImages(index: 3)],
        "only the newest screenshot is sent again, even well under budget"
    )
}

section("compaction: applied to a real conversation")
do {
    var budget = AgentCompaction.Budget()
    budget.maxCost = 2_000
    budget.targetCost = 1_000
    budget.keepRecentToolResults = 1
    let big = String(repeating: "result text ", count: 60)
    var messages: [[String: Any]] = [
        ["role": "system", "content": "You are Teachy."],
        ["role": "user", "content": "Compare three laptops and never suggest refurbished ones."],
        toolCallMessage(id: "c1", name: "web_search", arguments: #"{"query":"best laptops 2026"}"#),
        ["role": "tool", "tool_call_id": "c1", "content": "First result: Framework 16 review. " + big],
        toolCallMessage(id: "c2", name: "web_fetch", arguments: #"{"url":"https://example.com/a"}"#),
        ["role": "tool", "tool_call_id": "c2", "content": [["type": "text", "text": "Page says MacBook Air is lightest. " + big], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]]]],
        toolCallMessage(id: "c3", name: "web_fetch", arguments: #"{"url":"https://example.com/b"}"#),
        ["role": "tool", "tool_call_id": "c3", "content": "Newest page. " + big]
    ]
    let before = messages.count
    let outcome = AgentCompaction.compact(&messages, budget: budget)
    expect(outcome.didCompact, "over budget: compaction ran")
    expectEqual(messages.count, before, "no message is removed, so every tool call keeps its result")
    expectEqual(outcome.summaries.count, 2, "two results summarised")
    expect(outcome.summaries[0].hasPrefix("web_search {\"query\":\"best laptops 2026\"} → First result: Framework 16 review."), "summary names the tool, its arguments and the start of the result: \(outcome.summaries[0])")
    expect(outcome.summaries[1].contains("MacBook Air is lightest"), "summary of a result with a picture uses its text")
    expect(((messages[3]["content"] as? String) ?? "").hasPrefix(AgentCompaction.droppedPrefix), "dropped result is now a stub")
    expectEqual(messages[3]["tool_call_id"] as? String, "c1", "the stub keeps its tool_call_id")
    expect((messages[5]["content"] as? String) != nil, "the picture went with the dropped result")
    expect(((messages[7]["content"] as? String) ?? "").hasPrefix("Newest page."), "the newest result is untouched")
    expectEqual((messages[1]["content"] as? String), "Compare three laptops and never suggest refurbished ones.", "the request is untouched")

    let again = AgentCompaction.compact(&messages, budget: budget)
    expect(!again.didCompact, "a second pass right after does nothing")

    var notes = AgentJobNotes.initial(request: "Compare three laptops and never suggest refurbished ones.", title: "Laptop Hunt")
    notes = AgentJobNotes.addingRule("Only new machines, no refurbished.", to: notes)
    notes = AgentJobNotes.addingRule("only new machines, no refurbished", to: notes)
    notes = AgentJobNotes.addingDone(outcome.summaries, to: notes)
    expectEqual(AgentMarkdown.bullets(inSection: AgentJobNotes.rulesSection, of: notes).count, 1, "the same rule is written once")
    expectEqual(AgentMarkdown.bullets(inSection: AgentJobNotes.doneSection, of: notes).count, 2, "dropped results are listed under Done so far")
    expect(notes.contains("## Goal\nCompare three laptops"), "the goal is in the notes")

    AgentCompaction.readNotesBackIn(notes, messages: &messages)
    AgentCompaction.readNotesBackIn(notes + "\n- one more", messages: &messages)
    let noteMessages = messages.filter { (($0["content"] as? String) ?? "").hasPrefix(AgentCompaction.notesPrefix) }
    expectEqual(noteMessages.count, 1, "only one copy of the notes is ever in context")
    expect(((messages.last?["content"] as? String) ?? "").contains("one more"), "and it is the newest copy, at the end")
    expect(((messages.last?["content"] as? String) ?? "").contains("never suggest refurbished"), "the re-read notes carry the goal and rules")
    expect(AgentCompaction.entry(for: messages.last!).isCompacted, "the notes message is never itself compacted")

    var manyDone = AgentJobNotes.initial(request: "x y z", title: "T")
    manyDone = AgentJobNotes.addingDone((1...60).map { "step \($0) → ok" }, to: manyDone)
    let kept = AgentMarkdown.bullets(inSection: AgentJobNotes.doneSection, of: manyDone)
    expectEqual(kept.count, AgentJobNotes.maxDoneLines, "Done so far is capped")
    expectEqual(kept.last, "step 60 → ok", "the newest lines are the ones kept")
    expectEqual(kept.first, "step 21 → ok", "the oldest are dropped")

    let handEdited = "# My notes\n\nSome prose I wrote.\n\n## Rules from the person\n- Be brief\n\n## Other\nkeep me\n"
    let edited = AgentMarkdown.appendingBullet("Use metric units", toSection: "Rules from the person", in: handEdited)
    expectEqual(edited, "# My notes\n\nSome prose I wrote.\n\n## Rules from the person\n- Be brief\n- Use metric units\n\n## Other\nkeep me\n", "a bullet is added without disturbing the rest of the file")
    expect(AgentMarkdown.appendingBullet("New thing", toSection: "Brand new", in: handEdited).contains("## Brand new\n- New thing"), "a missing section is created")
    expectEqual(AgentMarkdown.appendingBullet("   ", toSection: "Other", in: handEdited), handEdited, "an empty note changes nothing")
}

// MARK: - Roster

section("named agents: folders in a temp directory")
do {
    let root = scratch.appendingPathComponent("agents", isDirectory: true)
    let trashDirectory = scratch.appendingPathComponent("trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
    var trashed: [String] = []
    let roster = AgentRoster(root: root, trash: { url in
        trashed.append(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: trashDirectory.appendingPathComponent(url.lastPathComponent))
    })

    let first = roster.reload()
    expectEqual(first.map(\.name), ["Builder", "Research buddy"], "two starter agents on first use")
    for slug in ["builder", "research-buddy"] {
        expect(FileManager.default.fileExists(atPath: roster.agentFileURL(for: slug).path), "\(slug) has AGENT.md")
        expect(FileManager.default.fileExists(atPath: roster.memoryURL(for: slug).path), "\(slug) has MEMORY.md")
        var isDirectory: ObjCBool = false
        expect(FileManager.default.fileExists(atPath: roster.filesDirectory(for: slug).path, isDirectory: &isDirectory) && isDirectory.boolValue, "\(slug) has files/")
    }
    expect(!(roster.agent(slug: "research-buddy")?.role.isEmpty ?? true), "starter agents have a role")
    expect(roster.agent(slug: "builder")?.preferredTools.contains("bash") == true, "preferred tools are read back from AGENT.md")

    // Folders that are not agents are ignored.
    try FileManager.default.createDirectory(at: root.appendingPathComponent("history"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("random-folder"), withIntermediateDirectories: true)
    try "{}".write(to: root.appendingPathComponent("routines.json"), atomically: true, encoding: .utf8)
    expectEqual(roster.reload().count, 2, "history/, stray folders and routines.json are not agents")

    let made = try roster.create(name: "Inbox Helper", role: "Sorts my mail.", instructions: "Be brief.", preferredTools: ["web_search"], preferredConnectors: ["gmail"])
    expectEqual(made.slug, "inbox-helper", "slug from the name")
    let reread = roster.agent(slug: "inbox-helper")
    expectEqual(reread?.name, "Inbox Helper", "name round-trips through AGENT.md")
    expectEqual(reread?.role, "Sorts my mail.", "role round-trips")
    expectEqual(reread?.instructions, "Be brief.", "instructions round-trip")
    expectEqual(reread?.preferredConnectors ?? [], ["gmail"], "connectors round-trip")

    do {
        _ = try roster.create(name: "inbox helper")
        expect(false, "a second agent with the same name should be refused")
    } catch {
        expect(error.localizedDescription.contains("already"), "duplicate name is explained: \(error.localizedDescription)")
    }
    do {
        _ = try roster.create(name: "!!!")
        expect(false, "a name with no letters should be refused")
    } catch {
        expect(true, "")
    }
    expectEqual(try roster.create(name: "History").slug, "history-agent", "a reserved folder name is never used as a slug")
    expectEqual(AgentRoster.slug(for: "  Café  Über-Bot 2! "), "cafe-uber-bot-2", "slug folds accents and punctuation")

    // Memory and files move with a rename.
    let savedFirst = try roster.remember("Prefers answers in bullet points.", slug: "inbox-helper", now: Date(timeIntervalSince1970: 1_794_614_400), timeZone: TimeZone(identifier: "UTC")!)
    expect(savedFirst, "a note is saved")
    let savedAgain = try roster.remember("prefers answers in bullet points", slug: "inbox-helper")
    expect(!savedAgain, "the same note is not saved twice")
    try "draft".write(to: roster.filesDirectory(for: "inbox-helper").appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
    expect(roster.memoryText(for: "inbox-helper").contains("- 2026-11-14: Prefers answers in bullet points."), "the note is a dated bullet: \(roster.memoryText(for: "inbox-helper"))")

    let renamed = try roster.rename(slug: "inbox-helper", to: "Mail Sorter")
    expectEqual(renamed.slug, "mail-sorter", "the folder follows the new name")
    expectEqual(renamed.name, "Mail Sorter", "the new name is in AGENT.md")
    expectEqual(renamed.role, "Sorts my mail.", "everything else in AGENT.md is kept")
    expect(!FileManager.default.fileExists(atPath: roster.folder(for: "inbox-helper").path), "the old folder is gone")
    expect(roster.memoryText(for: "mail-sorter").contains("bullet points"), "memory moved with it")
    expect(FileManager.default.fileExists(atPath: roster.filesDirectory(for: "mail-sorter").appendingPathComponent("draft.txt").path), "files moved with it")
    do {
        _ = try roster.rename(slug: "mail-sorter", to: "builder")
        expect(false, "renaming onto an existing agent should be refused")
    } catch {
        expect(true, "")
    }
    expectEqual(try roster.rename(slug: "mail-sorter", to: "Mail sorter").slug, "mail-sorter", "changing only the capitals keeps the folder")

    // A hand-edited AGENT.md keeps its extra content through a rename.
    let handWritten = "<!-- mine -->\n# Mail sorter\n\nRole: Sorts my mail.\nSome extra prose.\n\n## Instructions\nBe brief.\n\n## My own section\n- keep this\n"
    try handWritten.write(to: roster.agentFileURL(for: "mail-sorter"), atomically: true, encoding: .utf8)
    _ = try roster.rename(slug: "mail-sorter", to: "Post Office")
    let afterRename = try String(contentsOf: roster.agentFileURL(for: "post-office"), encoding: .utf8)
    expectEqual(afterRename, handWritten.replacingOccurrences(of: "# Mail sorter", with: "# Post Office"), "rename changes only the name line")

    try roster.delete(slug: "post-office")
    expectEqual(trashed, ["post-office"], "delete hands the folder to the Trash")
    expect(FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent("post-office/AGENT.md").path), "the whole folder went, not just a file")
    expect(roster.agent(slug: "post-office") == nil, "and it is off the list")
    for bad in ["history", "", "../trash", ".hidden", "no-such-agent"] {
        do {
            try roster.delete(slug: bad)
            expect(false, "delete(\(bad)) should be refused")
        } catch {
            expect(true, "")
        }
    }
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("history").path), "history/ cannot be deleted as an agent")

    try roster.delete(slug: "builder")
    try roster.delete(slug: "research-buddy")
    let fresh = AgentRoster(root: root, trash: { _ in })
    expect(!fresh.reload().contains { $0.slug == "builder" }, "deleted starter agents are not made again")

    let agents = [AgentProfile(slug: "research-buddy", name: "Research buddy"), AgentProfile(slug: "builder", name: "Builder"), AgentProfile(slug: "research-buddy-two", name: "Research buddy two")]
    expectEqual(AgentRoster.bestMatch(for: "Ask research buddy to find flights", among: agents)?.slug, "research-buddy", "explicit name wins")
    expectEqual(AgentRoster.bestMatch(for: "have RESEARCH BUDDY TWO look into it", among: agents)?.slug, "research-buddy-two", "the longer name wins over the one inside it")
    expectEqual(AgentRoster.bestMatch(for: "builder, make me a todo app", among: agents)?.slug, "builder", "one-word names match")
    expect(AgentRoster.bestMatch(for: "I am rebuilding my site", among: agents) == nil, "a name inside another word is not a mention")
    expect(AgentRoster.bestMatch(for: "find me flights to Goa", among: agents) == nil, "no name: no agent (a plain job)")

    let prompt = AgentRoster.promptSection(agent: AgentProfile(slug: "x", name: "Scout", role: "Finds things.", instructions: "Be quick."), memory: "- 2026-11-01: Likes tables.", filesPath: "/tmp/x/files")
    for needle in ["Scout", "Finds things.", "Be quick.", "/tmp/x/files", "Likes tables.", "remember"] {
        expect(prompt.contains(needle), "agent prompt mentions \(needle)")
    }

    expect(AgentRoster.looksLikeSecret("the wifi password is hunter2"), "a stated password is a secret")
    expect(AgentRoster.looksLikeSecret("API key: sk-abcdefghijklmnopqrstuvwx"), "a key is a secret")
    expect(!AgentRoster.looksLikeSecret("Keeps passwords in 1Password, never ask for them"), "talking about passwords is not a secret")
    expect(!AgentRoster.looksLikeSecret("Prefers dark mode."), "a preference is not a secret")
}

// MARK: - Policy for an agent's files/

section("policy: an agent's own files folder")
do {
    let home = "/Users/tester"
    let files = "/Users/tester/.teachy/agents/builder/files"
    let agentSettings = ToolPolicySettings(allowBrowserCookies: false, homeDirectory: home, ownBundleIdentifier: "so.teachy.app", agentFilesDirectory: files)
    let plainSettings = ToolPolicySettings(allowBrowserCookies: false, homeDirectory: home, ownBundleIdentifier: "so.teachy.app")
    func write(_ path: String, _ settings: ToolPolicySettings) -> ToolRisk { ToolPolicy.classify(toolName: "write_file", arguments: ["path": path, "content": "x"], settings: settings).risk }
    func read(_ path: String, _ settings: ToolPolicySettings) -> ToolRisk { ToolPolicy.classify(toolName: "read_file", arguments: ["path": path], settings: settings).risk }

    expectEqual(write("\(files)/app/index.html", agentSettings), .safe, "writing inside files/ is safe")
    expectEqual(write("\(files)/notes.md", agentSettings), .safe, "a file right in files/ is safe")
    expectEqual(write("\(files)/app/index.html", plainSettings), .needsConsent, "the same path in a job that is not that agent still asks")
    expectEqual(write("/Users/tester/Desktop/out.txt", agentSettings), .needsConsent, "writing elsewhere keeps the usual rule")
    expectEqual(write("\(files)/../AGENT.md", agentSettings), .needsConsent, "climbing out with .. is not inside")
    expectEqual(write("\(files)/../../research-buddy/files/x.txt", agentSettings), .needsConsent, "another agent's folder is not this agent's")
    expectEqual(write("\(files)-evil/x.txt", agentSettings), .needsConsent, "a sibling folder with the same prefix is not inside")
    expectEqual(write(files, agentSettings), .needsConsent, "the folder itself is not a file inside it")
    expectEqual(write("\(files)/.env", agentSettings), .alwaysAsk, "a secrets-looking file still asks every time, even inside")
    expectEqual(write("\(files)/site/.zshrc", agentSettings), .alwaysAsk, "so does a shell start-up file")
    expectEqual(write("/Users/tester/.ssh/authorized_keys", agentSettings), .alwaysAsk, "credential paths elsewhere are unchanged")
    expectEqual(write("/etc/hosts", agentSettings), .alwaysAsk, "system paths are unchanged")
    expectEqual(write("~/.teachy/agents/builder/files/a.txt", agentSettings), .safe, "~ is expanded before the check")

    expectEqual(read("\(files)/notes.md", agentSettings), .safe, "reading its own files is safe (the folder is under a hidden one)")
    expectEqual(read("\(files)/notes.md", plainSettings), .needsConsent, "for any other job that hidden path asks")
    expectEqual(read("\(files)/id_rsa", agentSettings), .alwaysAsk, "a key file is never read silently")
    expectEqual(read("/Users/tester/Documents/a.txt", agentSettings), .safe, "ordinary reads are unchanged")

    expectEqual(PathPolicy.absolute("report.md", workingDirectory: files, home: home), "\(files)/report.md", "a relative path starts in the agent's folder")
    expectEqual(PathPolicy.absolute("sub/../report.md", workingDirectory: files, home: home), "\(files)/report.md", "and is tidied")
    expectEqual(PathPolicy.absolute("../../../../.ssh/id_rsa", workingDirectory: files, home: home), "/Users/tester/.ssh/id_rsa", "a relative path that climbs out is judged where it lands")
    expectEqual(PathPolicy.absolute("report.md", workingDirectory: nil, home: home), "/Users/tester/report.md", "no agent: relative paths start at home")
    expectEqual(PathPolicy.absolute("~/x.txt", workingDirectory: files, home: home), "/Users/tester/x.txt", "~ wins over the working folder")
    expectEqual(PathPolicy.absolute("/tmp/x.txt", workingDirectory: files, home: home), "/tmp/x.txt", "absolute paths are left alone")
    // The gate feeds the resolved path to the policy: a relative write lands safe, an escape does not.
    expectEqual(write(PathPolicy.absolute("report.md", workingDirectory: files, home: home), agentSettings), .safe, "relative write in the agent's folder is safe end to end")
    expectEqual(write(PathPolicy.absolute("../../../../Desktop/x", workingDirectory: files, home: home), agentSettings), .needsConsent, "relative escape asks end to end")

    func risk(_ name: String, _ arguments: [String: Any] = [:]) -> ToolRisk { ToolPolicy.classify(toolName: name, arguments: arguments, settings: plainSettings).risk }
    expectEqual(risk("remember", ["note": "x"]), .safe, "remember is safe")
    expectEqual(risk("list_routines"), .safe, "listing routines is safe")
    expectEqual(risk("create_routine", ["task": "check mail", "schedule": ["kind": "daily", "time": "09:00"]]), .needsConsent, "creating a routine asks")
    expectEqual(risk("pause_routine", ["id": "abcd1234"]), .safe, "pausing is safe")
    expectEqual(risk("pause_routine", ["id": "abcd1234", "resume": true]), .needsConsent, "resuming asks")
    expectEqual(risk("delete_routine", ["id": "abcd1234"]), .alwaysAsk, "deleting a routine asks every time")
    let createDecision = ToolPolicy.classify(toolName: "create_routine", arguments: ["task": "check mail", "schedule": ["kind": "daily", "time": "09:00"]], settings: plainSettings)
    expect(createDecision.detail.contains("09:00") && createDecision.detail.contains("check mail"), "the consent card shows the schedule and the task: \(createDecision.detail)")
}

// MARK: - Schedules

func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

func date(_ text: String, _ calendar: Calendar) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

func show(_ date: Date, _ calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
    return formatter.string(from: date)
}

section("schedules: next run")
do {
    let india = calendar("Asia/Kolkata")
    expectEqual(RoutineSchedule.every(minutes: 30).nextFire(after: date("2026-11-14 10:10", india), calendar: india), date("2026-11-14 10:40", india), "every 30 minutes")
    expectEqual(RoutineSchedule.every(minutes: 120).nextFire(after: date("2026-11-14 23:30", india), calendar: india), date("2026-11-15 01:30", india), "every 2 hours crosses midnight")

    let daily = RoutineSchedule.daily(hour: 9, minute: 0)
    expectEqual(daily.nextFire(after: date("2026-11-14 08:59", india), calendar: india), date("2026-11-14 09:00", india), "daily: later today")
    expectEqual(daily.nextFire(after: date("2026-11-14 09:00", india), calendar: india), date("2026-11-15 09:00", india), "daily: exactly on the slot means tomorrow (strictly after)")
    expectEqual(daily.nextFire(after: date("2026-11-14 21:00", india), calendar: india), date("2026-11-15 09:00", india), "daily: tomorrow")
    expectEqual(RoutineSchedule.daily(hour: 0, minute: 0).nextFire(after: date("2026-12-31 23:59", india), calendar: india), date("2027-01-01 00:00", india), "daily at midnight crosses the year")

    // 13 Nov 2026 is a Friday, 14 a Saturday.
    let weekdays = RoutineSchedule.weekdays(hour: 9, minute: 0)
    expectEqual(weekdays.nextFire(after: date("2026-11-13 08:00", india), calendar: india), date("2026-11-13 09:00", india), "weekdays: Friday morning runs Friday")
    expectEqual(weekdays.nextFire(after: date("2026-11-13 10:00", india), calendar: india), date("2026-11-16 09:00", india), "weekdays: Friday after the slot skips to Monday")
    expectEqual(weekdays.nextFire(after: date("2026-11-14 08:00", india), calendar: india), date("2026-11-16 09:00", india), "weekdays: Saturday skips to Monday")
    expectEqual(weekdays.nextFire(after: date("2026-11-15 23:00", india), calendar: india), date("2026-11-16 09:00", india), "weekdays: Sunday night runs Monday")
    expectEqual(weekdays.nextFire(after: date("2026-11-16 09:00", india), calendar: india), date("2026-11-17 09:00", india), "weekdays: Monday's slot then Tuesday")

    let weekly = RoutineSchedule.weekly(weekday: 2, hour: 17, minute: 30)
    expectEqual(weekly.nextFire(after: date("2026-11-14 12:00", india), calendar: india), date("2026-11-16 17:30", india), "weekly on Monday")
    expectEqual(weekly.nextFire(after: date("2026-11-16 17:30", india), calendar: india), date("2026-11-23 17:30", india), "weekly: a week later")
    expectEqual(weekly.nextFire(after: date("2026-11-16 17:29", india), calendar: india), date("2026-11-16 17:30", india), "weekly: a minute before")
}

section("schedules: clock changes")
do {
    let newYork = calendar("America/New_York")
    // Clocks go forward 8 Mar 2026: 02:00 → 03:00, so 02:30 does not exist that day.
    let early = RoutineSchedule.daily(hour: 2, minute: 30)
    let springRun = early.nextFire(after: date("2026-03-07 12:00", newYork), calendar: newYork)
    expectEqual(show(springRun, newYork), "2026-03-08 03:00 EDT", "a skipped time runs at the next time that exists")
    expectEqual(show(early.nextFire(after: springRun, calendar: newYork), newYork), "2026-03-09 02:30 EDT", "and is back to normal the day after")
    expectEqual(early.missedSlots(anchor: date("2026-03-07 12:00", newYork), now: date("2026-03-10 12:00", newYork), calendar: newYork), 3, "exactly one run per day across the change")

    let nine = RoutineSchedule.daily(hour: 9, minute: 0)
    let before = nine.nextFire(after: date("2026-03-07 10:00", newYork), calendar: newYork)
    expectEqual(show(before, newYork), "2026-03-08 09:00 EDT", "9 am stays 9 am on the wall clock")
    expectEqual(before.timeIntervalSince(date("2026-03-07 09:00", newYork)), 23 * 3_600, "which is 23 real hours after the day before")

    // Clocks go back 1 Nov 2026: 01:30 happens twice.
    let repeated = RoutineSchedule.daily(hour: 1, minute: 30)
    let fallRun = repeated.nextFire(after: date("2026-10-31 12:00", newYork), calendar: newYork)
    expectEqual(show(fallRun, newYork), "2026-11-01 01:30 EDT", "a repeated time runs at its first occurrence")
    let afterFall = repeated.nextFire(after: fallRun, calendar: newYork)
    expectEqual(show(afterFall, newYork), "2026-11-02 01:30 EST", "and not again an hour later")
    expectEqual(repeated.nextFire(after: fallRun.addingTimeInterval(20), calendar: newYork), afterFall, "even when the last run was a few seconds past the slot")
    expectEqual(repeated.missedSlots(anchor: date("2026-10-31 12:00", newYork), now: date("2026-11-02 12:00", newYork), calendar: newYork), 2, "two days, two runs")
    expectEqual(show(nine.nextFire(after: date("2026-10-31 10:00", newYork), calendar: newYork), newYork), "2026-11-01 09:00 EST", "9 am on the fall-back day")

    let weekdayRun = RoutineSchedule.weekdays(hour: 2, minute: 30).nextFire(after: date("2026-03-06 12:00", newYork), calendar: newYork)
    expectEqual(show(weekdayRun, newYork), "2026-03-09 02:30 EDT", "weekdays skip the changeover Sunday as any weekend day")

    let interval = RoutineSchedule.every(minutes: 60)
    expectEqual(interval.nextFire(after: date("2026-03-08 01:30", newYork), calendar: newYork).timeIntervalSince(date("2026-03-08 01:30", newYork)), 3_600, "intervals are real time, whatever the clocks do")
}

section("schedules: one catch-up after sleep")
do {
    let india = calendar("Asia/Kolkata")
    let daily = RoutineSchedule.daily(hour: 9, minute: 0)
    let lastRun = date("2026-11-10 09:00", india)
    let wake = date("2026-11-14 15:20", india)
    expect(daily.isDue(anchor: lastRun, now: wake, calendar: india), "four missed mornings: a run is owed")
    expectEqual(daily.missedSlots(anchor: lastRun, now: wake, calendar: india), 4, "four slots were missed")
    expect(!daily.isDue(anchor: wake, now: wake.addingTimeInterval(60), calendar: india), "after that one run nothing more is owed")
    expectEqual(daily.nextFire(after: wake, calendar: india), date("2026-11-15 09:00", india), "the next run is the next normal slot")
    expect(!daily.isDue(anchor: date("2026-11-14 09:00", india), now: date("2026-11-14 18:00", india), calendar: india), "ran this morning: not due again today")
    expect(daily.isDue(anchor: date("2026-11-14 08:00", india), now: date("2026-11-14 09:00", india), calendar: india), "due exactly on the slot")

    let every = RoutineSchedule.every(minutes: 15)
    expect(every.isDue(anchor: lastRun, now: wake, calendar: india), "an interval routine is owed a run after a long sleep")
    expectEqual(every.missedSlots(anchor: lastRun, now: wake, calendar: india, cap: 50), 50, "missed slots are counted up to a cap")
    expect(!every.isDue(anchor: wake, now: wake.addingTimeInterval(14 * 60), calendar: india), "then it waits a full interval")
}

section("schedules: reading the JSON form")
do {
    func parse(_ json: [String: Any]) -> RoutineSchedule? { try? RoutineSchedule.parse(json) }
    func error(_ json: [String: Any]) -> String {
        do { _ = try RoutineSchedule.parse(json); return "" } catch { return error.localizedDescription }
    }
    expectEqual(parse(["kind": "every", "every": 30, "unit": "minutes"]), .every(minutes: 30), "every 30 minutes")
    expectEqual(parse(["kind": "every", "every": 2, "unit": "hours"]), .every(minutes: 120), "every 2 hours")
    expectEqual(parse(["kind": "every", "every": "45", "unit": "mins"]), .every(minutes: 45), "numbers as text and short units")
    expectEqual(parse(["kind": "daily", "time": "09:00"]), .daily(hour: 9, minute: 0), "daily")
    expectEqual(parse(["kind": "weekdays", "time": "9"]), .weekdays(hour: 9, minute: 0), "a bare hour")
    expectEqual(parse(["kind": "daily", "time": "9:30 pm"]), .daily(hour: 21, minute: 30), "12-hour time")
    expectEqual(parse(["kind": "daily", "time": "12am"]), .daily(hour: 0, minute: 0), "12 am is midnight")
    expectEqual(parse(["kind": "daily", "time": "12pm"]), .daily(hour: 12, minute: 0), "12 pm is noon")
    expectEqual(parse(["kind": "daily", "hour": 7, "minute": 5]), .daily(hour: 7, minute: 5), "separate hour and minute")
    expectEqual(parse(["kind": "weekly", "day": "Monday", "time": "17:30"]), .weekly(weekday: 2, hour: 17, minute: 30), "weekly by name")
    expectEqual(parse(["kind": "weekly", "day": "sun", "time": "08:00"]), .weekly(weekday: 1, hour: 8, minute: 0), "weekly by short name")
    expectEqual(parse(["kind": "WEEKLY", "weekday": 7, "time": "08:00"]), .weekly(weekday: 7, hour: 8, minute: 0), "weekly by number")

    expect(error(["kind": "every", "every": 1, "unit": "minutes"]).contains("5 minutes"), "too often is refused with the limit")
    expect(!error(["kind": "every", "every": 0, "unit": "minutes"]).isEmpty, "zero is refused")
    expect(!error(["kind": "every", "every": -5, "unit": "hours"]).isEmpty, "negative is refused")
    expect(!error(["kind": "every", "every": 2.5, "unit": "hours"]).isEmpty, "a fraction is refused")
    expect(!error(["kind": "every", "every": 3, "unit": "fortnights"]).isEmpty, "an unknown unit is refused")
    expect(!error(["kind": "every", "every": 30, "unit": "days"]).isEmpty, "longer than a week is refused")
    expect(!error(["kind": "daily", "time": "25:00"]).isEmpty, "hour 25 is refused")
    expect(!error(["kind": "daily", "time": "09:75"]).isEmpty, "minute 75 is refused")
    expect(!error(["kind": "daily", "time": "13pm"]).isEmpty, "13 pm is refused")
    expect(!error(["kind": "daily", "time": "soon"]).isEmpty, "words are not a time")
    expect(!error(["kind": "daily"]).isEmpty, "a missing time is refused")
    expect(!error(["kind": "weekly", "time": "09:00"]).isEmpty, "weekly with no day is refused")
    expect(!error(["kind": "weekly", "day": "someday", "time": "09:00"]).isEmpty, "an unknown day is refused")
    expect(!error(["kind": "monthly", "time": "09:00"]).isEmpty, "an unknown kind is refused")
    expect(!error([:]).isEmpty, "an empty object is refused")

    for schedule in [RoutineSchedule.every(minutes: 30), .every(minutes: 180), .daily(hour: 9, minute: 5), .weekdays(hour: 23, minute: 59), .weekly(weekday: 6, hour: 0, minute: 0)] {
        expectEqual(parse(schedule.json), schedule, "json form round-trips for \(schedule.summary)")
        let data = try JSONEncoder().encode(schedule)
        expectEqual(try JSONDecoder().decode(RoutineSchedule.self, from: data), schedule, "Codable round-trips for \(schedule.summary)")
    }
    expect((try? JSONDecoder().decode(RoutineSchedule.self, from: Data(#"{"kind":"daily","time":"99:00"}"#.utf8))) == nil, "a bad schedule in the file does not decode")

    expectEqual(RoutineSchedule.every(minutes: 30).summary, "Every 30 minutes", "summary: minutes")
    expectEqual(RoutineSchedule.every(minutes: 60).summary, "Every hour", "summary: hour")
    expectEqual(RoutineSchedule.every(minutes: 180).summary, "Every 3 hours", "summary: hours")
    expectEqual(RoutineSchedule.daily(hour: 9, minute: 0).summary, "Every day at 9 am", "summary: daily")
    expectEqual(RoutineSchedule.weekdays(hour: 17, minute: 30).summary, "Weekdays at 5:30 pm", "summary: weekdays")
    expectEqual(RoutineSchedule.weekly(weekday: 2, hour: 0, minute: 5).summary, "Mondays at 12:05 am", "summary: weekly")
}

section("schedules: the model's reply, checked")
do {
    let good = try RoutineDraft.parse(modelReply: #"{"task": "Check my GitHub notifications and list the ones that need me.", "schedule": {"kind":"weekdays","time":"09:00"}, "agent": null}"#)
    expectEqual(good.schedule, .weekdays(hour: 9, minute: 0), "schedule read from the reply")
    expectEqual(good.task, "Check my GitHub notifications and list the ones that need me.", "task read from the reply")
    expect(good.agentName == nil, "null agent is no agent")

    let fenced = try RoutineDraft.parse(modelReply: "Here you go:\n```json\n{\"task\":\"Summarise the news\",\"schedule\":{\"kind\":\"every\",\"every\":2,\"unit\":\"hours\"},\"agent\":\"Research buddy\"}\n```")
    expectEqual(fenced.schedule, .every(minutes: 120), "a fenced reply is read")
    expectEqual(fenced.agentName, "Research buddy", "the named agent is passed on")

    func failure(_ reply: String) -> String {
        do { _ = try RoutineDraft.parse(modelReply: reply); return "" } catch { return error.localizedDescription }
    }
    expectEqual(failure(#"{"error": "Tell me when it should run."}"#), "Tell me when it should run.", "the model's own refusal is passed on")
    expect(!failure("I think every morning works!").isEmpty, "prose is not a routine")
    expect(!failure(#"{"task":"x","schedule":{"kind":"daily","time":"09:00"}}"#).isEmpty, "a task that says nothing is refused")
    expect(!failure(#"{"task":"Check mail","schedule":{"kind":"every","every":1,"unit":"minutes"}}"#).isEmpty, "an invalid schedule from the model is refused")
    expect(!failure(#"{"task":"Check mail"}"#).isEmpty, "a missing schedule is refused")
    expect(!failure(#"{"task":"Check mail","schedule":"daily at 9"}"#).isEmpty, "a schedule that is not an object is refused")
    expect(!failure("").isEmpty, "an empty reply is refused")
}

section("routines: what happens after each run")
do {
    let india = calendar("Asia/Kolkata")
    let created = date("2026-11-10 08:00", india)
    var book = RoutineBook(routines: [
        Routine(id: "daily", task: "Check GitHub", schedule: .daily(hour: 9, minute: 0), createdAt: created),
        Routine(id: "often", agentSlug: "research-buddy", task: "Check prices", schedule: .every(minutes: 30), createdAt: created),
        Routine(id: "off", task: "Paused one", schedule: .every(minutes: 5), enabled: false, createdAt: created)
    ])

    expectEqual(book.due(now: date("2026-11-10 08:10", india), calendar: india).map(\.id), [], "nothing is due right after creation")
    expectEqual(book.due(now: date("2026-11-10 08:31", india), calendar: india).map(\.id), ["often"], "the interval routine comes due first")

    // The Mac sleeps for four days.
    let wake = date("2026-11-14 15:00", india)
    expectEqual(book.due(now: wake, calendar: india).map(\.id), ["daily", "often"], "after a long sleep each routine is due ONCE; the paused one never")
    expectEqual(book.due(now: wake, calendar: india, running: ["daily"]).map(\.id), ["often"], "a routine already running is not started again")

    book.markStarted(id: "daily", now: wake)
    book.markStarted(id: "often", now: wake)
    expectEqual(book.due(now: wake.addingTimeInterval(60), calendar: india).map(\.id), [], "once started, the missed slots are spent: no second catch-up")
    book.record(.succeeded(result: "3 notifications need you."), id: "daily", now: wake.addingTimeInterval(40))
    let daily = book.routines[0]
    expectEqual(daily.lastResult, "3 notifications need you.", "the result is kept")
    expectEqual(daily.lastStatus, "ok", "status ok")
    expect(daily.hasUnreadResult, "a new result is unread")
    expectEqual(daily.nextRun(calendar: india), date("2026-11-15 09:00", india), "next run is tomorrow's slot")
    expectEqual(book.unreadCount, 1, "one unread")
    book.markRead(id: "daily")
    expectEqual(book.unreadCount, 0, "read clears the dot")

    // Three failures in a row pause it; a success in between resets the count.
    book.record(.failed(reason: "No internet."), id: "often", now: wake)
    book.record(.failed(reason: "No internet."), id: "often", now: wake)
    expect(book.routines[1].enabled, "two failures: still on")
    book.record(.succeeded(result: "ok"), id: "often", now: wake)
    expectEqual(book.routines[1].consecutiveFailures, 0, "a success resets the count")
    book.record(.failed(reason: "a"), id: "often", now: wake)
    book.record(.needsPerson(result: "Could not send: needs your yes."), id: "often", now: wake)
    expectEqual(book.routines[1].consecutiveFailures, 0, "a run that was refused something is not a failure")
    expectEqual(book.routines[1].lastStatus, "needs you", "it is marked as needing the person")
    for _ in 0..<3 { book.record(.failed(reason: "Timed out."), id: "often", now: wake) }
    expect(!book.routines[1].enabled, "three failures in a row pause it")
    expect((book.routines[1].pausedReason ?? "").contains("3 failed runs"), "and it says why")
    expectEqual(book.routines[1].lastResult, "Timed out.", "the last failure is the result shown")
    expectEqual(book.due(now: wake.addingTimeInterval(86_400), calendar: india).map(\.id), ["daily"], "a paused routine is never due")

    let resumeAt = wake.addingTimeInterval(10 * 86_400)
    book.setEnabled(true, id: "often", now: resumeAt)
    expect(book.routines[1].enabled && book.routines[1].pausedReason == nil && book.routines[1].consecutiveFailures == 0, "resume clears the pause and the count")
    expect(!book.due(now: resumeAt.addingTimeInterval(60), calendar: india).contains { $0.id == "often" }, "resuming does not fire it at once")
    expect(book.due(now: resumeAt.addingTimeInterval(31 * 60), calendar: india).contains { $0.id == "often" }, "it runs after one interval")
    book.setEnabled(false, id: "daily", now: resumeAt)
    expect(book.routines[0].pausedReason == nil, "a pause by hand has no reason text")

    let file = scratch.appendingPathComponent("routines/routines.json")
    let store = RoutineStore(fileURL: file)
    expectEqual(store.load().book.routines.count, 0, "no file yet: no routines, no problem")
    expect(store.load().problem == nil, "a missing file is not a problem")
    try store.save(book)
    let loaded = store.load()
    expect(loaded.problem == nil, "saved file reads back")
    expectEqual(loaded.book.routines.map(\.id), ["daily", "often", "off"], "all routines are back, in order")
    expectEqual(loaded.book.routines[1].schedule, .every(minutes: 30), "schedules survive the file")
    expectEqual(loaded.book.routines[1].agentSlug, "research-buddy", "the agent survives the file")
    expectEqual(loaded.book.routines[0].lastResult, "3 notifications need you.", "results survive the file")
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)
    expect(store.load().problem != nil, "an unreadable file is reported, not treated as empty-and-fine")

    book.remove(id: "off")
    expectEqual(book.routines.count, 2, "remove")
}

// MARK: - Unattended consent

section("a routine cannot give itself consent")
do {
    let memory = InMemoryConsentStore()
    let ledger = ConsentLedger(store: memory)
    func decision(_ tool: String, _ risk: ToolRisk, app: String = "", detail: String = "") -> ToolPolicyDecision {
        ToolPolicyDecision(toolName: tool, risk: risk, reason: "test", summary: "use \(tool)", detail: detail, appScope: app)
    }
    func isAllowed(_ resolution: ConsentLedger.Resolution) -> Bool {
        if case .allowed = resolution { return true }
        return false
    }

    expect(isAllowed(ledger.resolveUnattended(decision("web_search", .safe))), "safe calls run")
    let write = decision("write_file", .needsConsent)
    expect(!isAllowed(ledger.resolveUnattended(write)), "a call that needs a yes is refused")
    expect(ledger.resolveUnattended(write) != .ask, "and never turned into a question")

    // A yes given inside a job (even this job's id) does not count for an unattended run.
    expect(ledger.record(.allowForJob, for: write, jobID: "routine-job"), "an attended job gets its yes")
    expect(isAllowed(ledger.resolve(write, jobID: "routine-job")), "which covers that attended job")
    expect(!isAllowed(ledger.resolveUnattended(write)), "but not an unattended run")
    expect(ledger.record(.allowOnce, for: write, jobID: "other"), "allow once elsewhere")
    expect(!isAllowed(ledger.resolveUnattended(write)), "allow once elsewhere changes nothing")

    // "Always allow" for that exact tool + app does.
    let driveNotes = decision("drive", .needsConsent, app: "Notes")
    let driveMail = decision("drive", .needsConsent, app: "Mail")
    expect(!isAllowed(ledger.resolveUnattended(driveNotes)), "driving Notes is refused at first")
    ledger.record(.alwaysAllow, for: driveNotes, jobID: "an-earlier-attended-job")
    expect(isAllowed(ledger.resolveUnattended(driveNotes)), "after Always allow for drive + Notes, a routine may drive Notes")
    expect(isAllowed(ledger.resolveUnattended(decision("drive", .needsConsent, app: "notes"))), "app names match without case")
    expect(!isAllowed(ledger.resolveUnattended(driveMail)), "but not Mail: the yes was for Notes only")
    expect(!isAllowed(ledger.resolveUnattended(decision("bash", .needsConsent, app: "Notes"))), "nor another tool in Notes")

    // Deletes, sends and payments are never covered by any earlier yes.
    let send = decision("drive", .alwaysAsk, app: "Notes", detail: "Send")
    ledger.record(.alwaysAllow, for: send, jobID: "earlier")
    expect(!isAllowed(ledger.resolveUnattended(send)), "an always-ask call is refused even where the tool + app is always allowed")
    expect(!isAllowed(ledger.resolveUnattended(decision("delete_routine", .alwaysAsk))), "deleting is refused")
    expect(!isAllowed(ledger.resolveUnattended(decision("authenticated_fetch", .blocked))), "blocked stays blocked")

    ledger.revokeAlwaysAllow(driveNotes.grantKey)
    expect(!isAllowed(ledger.resolveUnattended(driveNotes)), "revoking Always allow takes it away from routines too")

    let note = ConsentLedger.unattendedRefusalNote(for: decision("write_file", .needsConsent, app: "Notes"))
    expect(note.contains("use write_file") && note.contains("Notes") && note.contains("Always allow"), "the refusal is reported in plain words: \(note)")

    // And the policy puts the things a routine might try in the classes that are refused.
    let settings = ToolPolicySettings(allowBrowserCookies: false, homeDirectory: "/Users/tester", ownBundleIdentifier: "so.teachy.app")
    for (tool, arguments) in [("create_routine", ["task": "x"] as [String: Any]), ("delete_routine", ["id": "x"]), ("write_file", ["path": "/Users/tester/a.txt"]), ("bash", ["command": "rm -rf ~/Documents"]), ("pause_routine", ["id": "x", "resume": true])] {
        let classified = ToolPolicy.classify(toolName: tool, arguments: arguments, settings: settings)
        expect(!isAllowed(ConsentLedger(store: InMemoryConsentStore()).resolveUnattended(classified)), "\(tool) is refused in an unattended run")
    }
}

// MARK: - Catalog

section("connector catalog")
do {
    let entries = ConnectorCatalog.entries
    expect(entries.count >= 15, "the catalog decodes and has entries (\(entries.count))")
    expectEqual((try? ConnectorCatalog.decode(ConnectorCatalog.json))?.count, entries.count, "the embedded JSON passes its own checks")
    expectEqual(Set(entries.map(\.id)).count, entries.count, "ids are unique")
    for entry in entries {
        expect(URL(string: entry.url)?.scheme == "https", "\(entry.id) is https")
        expect(!entry.name.isEmpty && !entry.summary.isEmpty && entry.summary.count <= 40, "\(entry.id) has a name and a short summary")
    }
    expect(entries.contains { $0.id == "linear" && $0.auth == .oauth && $0.url == "https://mcp.linear.app/mcp" }, "Linear is there, by sign-in")
    expect(entries.contains { $0.id == "github" && $0.auth == .apiKey && $0.keyHint != nil }, "GitHub is there, by key, with a hint")
    expect(entries.contains { $0.auth == ConnectorCatalogEntry.Auth.none }, "some need no sign-in")

    func rejects(_ json: String) -> Bool { (try? ConnectorCatalog.decode(json)) == nil }
    expect(rejects(#"[{"id":"a","name":"A","summary":"s","url":"http://mcp.example.com/mcp","auth":"oauth"}]"#), "http is refused")
    expect(rejects(#"[{"id":"a","name":"A","summary":"s","url":"https://mcp.example.com/mcp","auth":"magic"}]"#), "an unknown auth kind is refused")
    expect(rejects(#"[{"id":"a","name":"A","summary":"s","url":"https://mcp.example.com/mcp","auth":"api_key"}]"#), "a key entry without a hint is refused")
    expect(rejects(#"[{"id":"a","name":"A","summary":"s","url":"https://a.example.com","auth":"none"},{"id":"a","name":"B","summary":"s","url":"https://b.example.com","auth":"none"}]"#), "a repeated id is refused")
    expect(rejects(#"[{"id":"a","name":"A","summary":"s","url":"https://a.example.com/mcp/","auth":"none"},{"id":"b","name":"B","summary":"s","url":"https://A.example.com/mcp","auth":"none"}]"#), "a repeated URL is refused")
    expect(rejects(#"[{"id":"a","name":"A","summary":"s","url":"https://user:pw@a.example.com","auth":"none"}]"#), "a URL with a login in it is refused")
    expect(rejects(#"[{"id":"A b","name":"A","summary":"s","url":"https://a.example.com","auth":"none"}]"#), "a bad id is refused")
    expect(rejects(#"[{"id":"a","name":"","summary":"s","url":"https://a.example.com","auth":"none"}]"#), "an empty name is refused")
    expect(rejects("{}"), "not a list is refused")
    expectEqual((try? ConnectorCatalog.decode("[]"))?.count, 0, "an empty list is fine")

    let linear = entries.first { $0.id == "linear" }!
    let draft = ConnectorCatalog.draft(for: linear, apiKey: "should-be-ignored")
    expectEqual(draft.serverURL, "https://mcp.linear.app/mcp", "the draft carries the URL")
    expectEqual(draft.label, "Linear", "and the name")
    expectEqual(draft.apiKey, "", "a sign-in entry never gets a key")
    let github = entries.first { $0.id == "github" }!
    expectEqual(ConnectorCatalog.draft(for: github, apiKey: "tok").apiKey, "tok", "a key entry carries the key")
    let built = try ConnectorCatalog.draft(for: linear).build(existingIDs: [])
    expectEqual(built.config.id, "linear", "the draft builds the same connector the Add form would")
    expect(built.config.isRemote, "as a remote connector")

    expect(ConnectorCatalog.isAdded(github, serverURLs: ["https://API.githubcopilot.com/mcp"]), "already added, ignoring case and a trailing slash")
    expect(!ConnectorCatalog.isAdded(github, serverURLs: ["https://mcp.linear.app/mcp"]), "a different server is not this one")
}

// MARK: - The loop

section("reading a streamed reply")
do {
    var accumulator = AgentStreamAccumulator()
    let lines = [
        ": keep-alive",
        #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"update_plan","arguments":""}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"steps\":[\"Look\"],"}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"current_step\":1}"}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"web_search","arguments":"{\"query\":"}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"swift\"}"}}]}}]}"#
    ]
    for line in lines { expect(!accumulator.ingest(line: line), "tool-call lines do not grow the text") }
    expect(!accumulator.isComplete, "not complete until the server says so")
    accumulator.ingest(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
    expect(accumulator.isComplete, "finish_reason ends the reply")
    expectEqual(accumulator.turn.toolCalls, [
        AgentToolCall(id: "call_a", name: "update_plan", arguments: #"{"steps":["Look"],"current_step":1}"#),
        AgentToolCall(id: "call_b", name: "web_search", arguments: #"{"query":"swift"}"#)
    ], "two tool calls are put back together from their pieces")

    var text = AgentStreamAccumulator()
    expect(text.ingest(line: #"data: {"choices":[{"delta":{"content":"All "}}]}"#), "a text delta grows the text")
    expect(text.ingest(line: #"data: {"choices":[{"delta":{"content":"done."}}]}"#), "and again")
    expectEqual(text.content, "All done.", "text deltas join up")
    expect(!text.isComplete, "still open")
    text.ingest(line: "data: [DONE]")
    expect(text.isComplete, "[DONE] ends the reply")
    expect(text.turn.toolCalls.isEmpty, "no tool calls in a plain answer")

    var failed = AgentStreamAccumulator()
    failed.ingest(line: #"data: {"error":{"message":"overloaded"}}"#)
    expectEqual(failed.errorMessage, "overloaded", "an error chunk is caught")
    expect(failed.isComplete, "and ends the reply")

    var whole = AgentStreamAccumulator()
    whole.ingest(line: #"data: {"choices":[{"message":{"content":"Hi","tool_calls":[{"id":"x","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":"stop"}]}"#)
    expectEqual(whole.turn, AgentAssistantTurn(content: "Hi", toolCalls: [AgentToolCall(id: "x", name: "bash", arguments: "{}")]), "a reply sent whole in one chunk is read too")

    var garbage = AgentStreamAccumulator()
    garbage.ingest(line: "data: {not json")
    garbage.ingest(line: "event: ping")
    expect(garbage.content.isEmpty && !garbage.isComplete, "junk lines are ignored")

    expect(AgentStreamAccumulator.lineStartsReply(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0}]}}]}"#), "a tool call counts as the reply starting")
    expect(AgentStreamAccumulator.lineStartsReply(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), "so does text")
    expect(!AgentStreamAccumulator.lineStartsReply(#"data: {"choices":[{"delta":{"content":""}}]}"#), "an empty delta does not")
    expect(!AgentStreamAccumulator.lineStartsReply(": keep-alive"), "nor a keep-alive")
}

section("one tool per turn")
do {
    typealias D = AgentTurnPolicy.Disposition
    expectEqual(AgentTurnPolicy.dispositions(for: ["web_search"], inlinePlan: true), [D.run], "one tool runs")
    expectEqual(AgentTurnPolicy.dispositions(for: ["web_search", "web_fetch"], inlinePlan: true), [D.run, .deferred], "a second real tool waits for the next turn")
    expectEqual(AgentTurnPolicy.dispositions(for: ["update_plan", "web_search", "web_fetch", "update_plan"], inlinePlan: true), [D.plan, .run, .deferred, .plan], "an update_plan call is taken without running anything")
    expectEqual(AgentTurnPolicy.dispositions(for: ["bash", "bash"], inlinePlan: false), [D.run, .run], "the old loop runs what it is given")
    expectEqual(AgentTurnPolicy.dispositions(for: [], inlinePlan: true), [], "no calls, nothing to do")
}

section("the plan as a line of text")
do {
    typealias U = AgentPlanText.Update
    expectEqual(AgentPlanText.parse("PLAN: Umbrella Check | Find the forecast; Read the calendar; Compare"), U(title: "Umbrella Check", steps: ["Find the forecast", "Read the calendar", "Compare"], currentStep: nil), "title and steps")
    expectEqual(AgentPlanText.parse("  PLAN: Search; Read ;  Answer  "), U(title: nil, steps: ["Search", "Read", "Answer"], currentStep: nil), "steps without a title")
    expectEqual(AgentPlanText.parse("STEP: 2"), U(title: nil, steps: nil, currentStep: 2), "a step number")
    expectEqual(AgentPlanText.parse("STEP: step 3 now"), U(title: nil, steps: nil, currentStep: 3), "a step number among words")
    expectEqual(AgentPlanText.parse("PLAN: Fix | A; B\nSTEP: 2"), U(title: "Fix", steps: ["A", "B"], currentStep: 2), "a plan and a step together")
    expectEqual(AgentPlanText.parse("STEP: 2\nPLAN: New | X; Y"), U(title: "New", steps: ["X", "Y"], currentStep: nil), "a new plan starts again at its first step")
    expect(AgentPlanText.parse("I plan to search first.") == nil, "ordinary prose is not a plan")
    expect(AgentPlanText.parse("The PLAN: is simple") == nil, "the marker must start the line")
    expect(AgentPlanText.parse("PLAN:") == nil, "an empty plan line is nothing")
    expect(AgentPlanText.parse("STEP: soon") == nil, "a step line with no number is nothing")
    expect(AgentPlanText.parse("") == nil, "empty text is nothing")

    expectEqual(AgentPlanText.withoutPlanLines("PLAN: A | x; y\nHere is the answer.\nSTEP: 3\nAll good.", isComplete: true), "Here is the answer.\nAll good.", "plan lines are taken out of what is said and shown")
    expectEqual(AgentPlanText.withoutPlanLines("No markers here. Plain text.", isComplete: true), "No markers here. Plain text.", "other text is untouched")
    expectEqual(AgentPlanText.withoutPlanLines("STEP: 4", isComplete: true), "", "a turn that is only a plan line says nothing")

    // While streaming, what may be spoken only ever grows and never shows part of a marker.
    for full in ["PLAN: A | x; y\nSo the answer is yes. Plenty of time.", "Sure thing.\nSTEP: 2\nPlease wait.", "Plain answer. Simple as that.", "S", "PLAN"] {
        var previous = ""
        var broke = false
        for end in full.indices {
            let partial = String(full[...end])
            let speakable = AgentPlanText.withoutPlanLines(partial, isComplete: false)
            if !speakable.hasPrefix(previous) { broke = true }
            if speakable.contains("PLAN") || speakable.contains("STEP") || speakable.contains("PL\n") { broke = true }
            previous = speakable
        }
        expect(!broke, "streaming \(full.debugDescription) never un-says anything or leaks a marker")
        let finished = AgentPlanText.withoutPlanLines(full, isComplete: true)
        expect(finished.hasPrefix(previous.trimmingCharacters(in: .newlines)) || finished == previous, "and ends as the finished text for \(full.debugDescription)")
    }
    expectEqual(AgentPlanText.withoutPlanLines("Sure.\nS", isComplete: false), "Sure.\n", "a letter that might start STEP: is held back")
    expectEqual(AgentPlanText.withoutPlanLines("Sure.\nSo", isComplete: false), "Sure.\nSo", "and released once it cannot be one")
    expectEqual(AgentPlanText.withoutPlanLines("Sure.\nS", isComplete: true), "Sure.\nS", "at the end nothing is held back")
}

/// A scripted model and stub tools around the real loop.
@MainActor
final class LoopHarness {
    var script: [AgentAssistantTurn]
    var requests: [AgentModelRequest] = []
    var tools: [String: ([String: Any]) -> AgentLoopToolOutcome] = [:]
    var toolCalls: [String] = []
    var plans: [(title: String?, plan: AgentPlan)] = []
    var sentences: [String] = []
    var retractions = 0
    var steps: [String] = []
    var followUpsToDeliver: [Int: [String]] = [:]
    var noteSummaries: [[String]] = []
    var budget: AgentJobBudget
    var messages: [[String: Any]]
    var config = AgentLoopConfig()
    /// Deliver the text in pieces, the way a stream does.
    var streamsText = true
    private var followUpPolls = 0

    init(script: [AgentAssistantTurn], maxIterations: Int = 25) {
        self.script = script
        self.budget = AgentJobBudget(maxIterations: maxIterations, maxWallTime: 600, startedAt: Date())
        self.messages = [["role": "system", "content": "You are a test."], ["role": "user", "content": "Do the thing."]]
        config.usesPlan = true
    }

    func run() async throws -> String {
        var hooks = AgentLoopHooks(
            model: { [self] request in
                requests.append(request)
                guard !script.isEmpty else { throw AgentLoopError(message: "script ran out") }
                let turn = script.removeFirst()
                if streamsText, !turn.content.isEmpty, let onContent = request.onContent {
                    var soFar = ""
                    for word in turn.content.split(separator: " ", omittingEmptySubsequences: false) {
                        soFar += (soFar.isEmpty ? "" : " ") + word
                        onContent(soFar)
                    }
                }
                return turn
            },
            checkBudget: { [self] in budget.check(now: Date()) },
            recordIteration: { [self] in budget.recordIteration() },
            runTool: { [self] call, arguments in
                toolCalls.append(call.name)
                return tools[call.name]?(arguments) ?? .result(text: "ok from \(call.name)", content: "ok from \(call.name)")
            }
        )
        hooks.planChanged = { [self] title, plan in plans.append((title, plan)) }
        hooks.stepFinished = { [self] call, text, _ in steps.append("\(call.name): \(text)") }
        hooks.takeFollowUps = { [self] in
            followUpPolls += 1
            return followUpsToDeliver.removeValue(forKey: followUpPolls) ?? []
        }
        hooks.compacted = { [self] summaries in
            noteSummaries.append(summaries)
            return "## Goal\nDo the thing.\n\n## Done so far\n" + summaries.map { "- \($0)" }.joined(separator: "\n")
        }
        hooks.answerSentence = { [self] sentence in sentences.append(sentence) }
        hooks.answerRetracted = { [self] in retractions += 1 }
        var working = messages
        defer { messages = working }
        return try await AgentLoop.run(messages: &working, config: config, hooks: hooks)
    }
}

func call(_ id: String, _ name: String, _ arguments: String = "{}") -> AgentToolCall { AgentToolCall(id: id, name: name, arguments: arguments) }
let planArguments = #"{"title":"Price Check","steps":["Search","Read","Answer"],"current_step":1}"#

section("loop: the plan costs no round trip")
do {
    let inline = LoopHarness(script: [
        AgentAssistantTurn(content: "PLAN: Price Check | Search; Read; Answer\n", toolCalls: [call("t1", "web_search", #"{"query":"a"}"#)]),
        AgentAssistantTurn(content: "STEP: 2", toolCalls: [call("t2", "web_fetch", #"{"url":"https://example.com"}"#)]),
        AgentAssistantTurn(content: "It costs twelve dollars. That is the cheapest I found.", toolCalls: [])
    ])
    let answer = try await inline.run()
    expectEqual(answer, "It costs twelve dollars. That is the cheapest I found.", "the loop returns the model's answer")
    expectEqual(inline.requests.count, 3, "two tool steps + the answer = three round trips with the plan riding along")
    expectEqual(inline.budget.iterationsUsed, 3, "and three steps of budget")
    expectEqual(inline.toolCalls, ["web_search", "web_fetch"], "both real tools ran, in order")
    expectEqual(inline.plans.count, 3, "the plan was stated, moved on, and finished")
    expectEqual(inline.plans.first?.title, "Price Check", "the job got its name from the plan line")
    expectEqual(inline.plans.first?.plan.currentStep?.text, "Search", "a new plan starts on its first step")
    expectEqual(inline.plans[1].plan.currentStep?.text, "Read", "STEP: 2 moved it on without repeating the steps")
    expect(inline.plans.last?.plan.steps.allSatisfy { $0.state == .done } == true, "when the answer comes, every step is ticked")
    expectEqual(inline.requests[0].parallelToolCalls, false, "parallel tool calls stay off")
    expect(!inline.requests[0].tools.contains { (($0["function"] as? [String: Any])?["name"] as? String) == "update_plan" }, "update_plan is not offered: the plan needs no call")
    expect(!inline.sentences.contains { $0.contains("PLAN") || $0.contains("STEP") || $0.contains("Price Check") }, "plan lines are never spoken")
    expectEqual(inline.retractions, 0, "and a turn with only a plan line retracts nothing, because nothing was said")
    expectEqual(inline.requests[2].messages.filter { ($0["role"] as? String) == "tool" }.count, 2, "one tool result per step")

    // The plan is on the card while the model is still writing the tool call.
    let streaming = LoopHarness(script: [])
    var planCountWhenCallArrived = -1
    var hooks = AgentLoopHooks(
        model: { request in
            if request.messages.contains(where: { ($0["role"] as? String) == "tool" }) {
                return AgentAssistantTurn(content: "All done here.", toolCalls: [])
            }
            request.onContent?("PLAN: Crop Photo | Open the photo; Crop")
            request.onContent?("PLAN: Crop Photo | Open the photo; Crop it\n")
            planCountWhenCallArrived = streaming.plans.count
            return AgentAssistantTurn(content: "PLAN: Crop Photo | Open the photo; Crop it\n", toolCalls: [call("t1", "drive_snapshot")])
        },
        checkBudget: { .proceed },
        recordIteration: {},
        runTool: { _, _ in .result(text: "ok", content: "ok") }
    )
    hooks.planChanged = { title, plan in streaming.plans.append((title, plan)) }
    var streamingMessages = streaming.messages
    _ = try await AgentLoop.run(messages: &streamingMessages, config: streaming.config, hooks: hooks)
    expectEqual(planCountWhenCallArrived, 1, "the plan was shown as soon as its line was complete, before the turn ended")
    expectEqual(streaming.plans.first?.plan.steps.map(\.text) ?? [], ["Open the photo", "Crop it"], "with the whole line, not a half-written one")
    expectEqual(streaming.plans.count, 2, "it is not applied a second time when the turn ends (then once more when the job finishes)")

    // The same job the old way: the plan takes a turn of its own.
    let legacy = LoopHarness(script: [
        AgentAssistantTurn(content: "", toolCalls: [call("p1", "update_plan", planArguments)]),
        AgentAssistantTurn(content: "", toolCalls: [call("t1", "web_search", #"{"query":"a"}"#)]),
        AgentAssistantTurn(content: "", toolCalls: [call("p2", "update_plan", #"{"steps":["Search","Read","Answer"],"current_step":2}"#)]),
        AgentAssistantTurn(content: "", toolCalls: [call("t2", "web_fetch", #"{"url":"https://example.com"}"#)]),
        AgentAssistantTurn(content: "It costs twelve dollars.", toolCalls: [])
    ])
    legacy.config.inlinePlan = false
    legacy.config.streams = false
    _ = try await legacy.run()
    expectEqual(legacy.requests.count, 5, "the old loop needs five round trips for the same work")
    expect((legacy.requests[0].tools.first?["function"] as? [String: Any])?["name"] as? String == "update_plan", "the old loop offers update_plan, first")
    expectEqual(legacy.plans.first?.title, "Price Check", "and reads the plan from the call")

    // A model that sends update_plan anyway is still understood (and told the cheaper way).
    let habit = LoopHarness(script: [
        AgentAssistantTurn(content: "", toolCalls: [call("p1", "update_plan", planArguments)]),
        AgentAssistantTurn(content: "", toolCalls: [call("p2", "update_plan", #"{"current_step":2}"#), call("t1", "web_search")]),
        AgentAssistantTurn(content: "Done with it.", toolCalls: [])
    ])
    _ = try await habit.run()
    expectEqual(habit.plans.first?.title, "Price Check", "an update_plan call still sets the plan")
    expectEqual(habit.plans[1].plan.currentStep?.text, "Read", "a later call may send just the step number")
    expectEqual(habit.toolCalls, ["web_search"], "and the real tool beside it runs")

    let quiet = LoopHarness(script: [AgentAssistantTurn(content: "", toolCalls: [call("t1", "capture_screen")]), AgentAssistantTurn(content: "PLAN: not a plan here\nDone.", toolCalls: [])])
    quiet.config.usesPlan = false
    let quietAnswer = try await quiet.run()
    expectEqual(quiet.requests[0].parallelToolCalls, false, "a turn without a plan keeps parallel tool calls off")
    expect(quiet.plans.isEmpty, "and reads no plan lines")
    expectEqual(quietAnswer, "PLAN: not a plan here\nDone.", "its text is left exactly as written")
}

section("loop: still one real tool per turn")
do {
    let greedy = LoopHarness(script: [
        AgentAssistantTurn(content: "PLAN: Tidy Up | Search; Clean\n", toolCalls: [call("t1", "web_search"), call("t2", "bash", #"{"command":"rm -rf x"}"#)]),
        AgentAssistantTurn(content: "Done.", toolCalls: [])
    ])
    _ = try await greedy.run()
    expectEqual(greedy.toolCalls, ["web_search"], "the second real tool in a turn is not run")
    let replies = greedy.requests[1].messages.filter { ($0["role"] as? String) == "tool" }
    expectEqual(replies.count, 2, "but it still gets a reply")
    expectEqual(replies.last?["content"] as? String, AgentTurnPolicy.deferredReply, "telling the model to send it again")
    expectEqual(replies.last?["tool_call_id"] as? String, "t2", "against the right call")
}

section("loop: the answer is spoken as it arrives")
do {
    let spoken = LoopHarness(script: [
        AgentAssistantTurn(content: "", toolCalls: [call("t1", "web_search")]),
        AgentAssistantTurn(content: "I found **three** flights under your budget. The cheapest leaves at six in the morning. Want me to hold it?", toolCalls: [])
    ])
    let answer = try await spoken.run()
    expectEqual(spoken.sentences, ["I found three flights under your budget.", "The cheapest leaves at six in the morning.", "Want me to hold it?"], "each sentence is handed over, cleaned for speech")
    expectEqual(spoken.retractions, 0, "nothing retracted")
    expect(answer.contains("**three**"), "the written answer is returned as the model wrote it")

    // Sentences arrive before the answer is complete.
    let early = LoopHarness(script: [AgentAssistantTurn(content: "First sentence is long enough to speak. Second sentence comes later on.", toolCalls: [])])
    var heardBeforeEnd = 0
    let earlyAnswer = try await { () async throws -> String in
        var hooks = AgentLoopHooks(
            model: { request in
                request.onContent?("First sentence is long enough to speak. Sec")
                heardBeforeEnd = early.sentences.count
                request.onContent?("First sentence is long enough to speak. Second sentence comes later on.")
                return early.script[0]
            },
            checkBudget: { .proceed },
            recordIteration: {},
            runTool: { _, _ in .failed("unused") }
        )
        hooks.answerSentence = { early.sentences.append($0) }
        var working = early.messages
        return try await AgentLoop.run(messages: &working, config: early.config, hooks: hooks)
    }()
    expectEqual(heardBeforeEnd, 1, "the first sentence was out while the model was still writing the second")
    expectEqual(early.sentences.count, 2, "and the rest followed at the end")
    expect(!earlyAnswer.isEmpty, "answer returned")

    let preamble = LoopHarness(script: [
        AgentAssistantTurn(content: "Let me look that up for you right now. It will only take a moment.", toolCalls: [call("t1", "web_search")]),
        AgentAssistantTurn(content: "It is sunny today.", toolCalls: [])
    ])
    _ = try await preamble.run()
    expectEqual(preamble.retractions, 1, "text before a tool call was not the answer: it is retracted")
    expectEqual(preamble.sentences.last, "It is sunny today.", "and the real answer still comes through")

    let unstreamed = LoopHarness(script: [AgentAssistantTurn(content: "This answer is short and sweet. Nothing was streamed here.", toolCalls: [])])
    unstreamed.streamsText = false
    _ = try await unstreamed.run()
    expectEqual(unstreamed.sentences, ["This answer is short and sweet.", "Nothing was streamed here."], "an answer that did not stream is still delivered sentence by sentence")

    let empty = LoopHarness(script: [AgentAssistantTurn(content: "  ", toolCalls: [])])
    expectEqual(try await empty.run(), "Done.", "an empty answer becomes Done.")
    expectEqual(empty.sentences, ["Done."], "and that is what is said")
}

section("loop: follow-ups join the job's own conversation")
do {
    let chatty = LoopHarness(script: [
        AgentAssistantTurn(content: "", toolCalls: [call("t1", "web_search")]),
        AgentAssistantTurn(content: "", toolCalls: [call("t2", "web_fetch")]),
        AgentAssistantTurn(content: "Here are only the direct flights.", toolCalls: [])
    ])
    chatty.followUpsToDeliver[2] = ["only direct flights please"]
    _ = try await chatty.run()
    let secondRequest = chatty.requests[1].messages
    expect(secondRequest.contains { ($0["role"] as? String) == "user" && (($0["content"] as? String) ?? "").contains("only direct flights please") }, "a follow-up is in front of the model before its next step")
    expect(!chatty.requests[0].messages.contains { (($0["content"] as? String) ?? "").contains("only direct flights") }, "and was not there before it was said")

    // Said while the model was writing its final answer: the job carries on instead of ending.
    let late = LoopHarness(script: [
        AgentAssistantTurn(content: "All finished with the first part. Nothing else is left to do.", toolCalls: []),
        AgentAssistantTurn(content: "And now the second part is done too.", toolCalls: [])
    ])
    late.followUpsToDeliver[2] = ["also do the second part"]
    let lateAnswer = try await late.run()
    expectEqual(lateAnswer, "And now the second part is done too.", "a follow-up that lands at the last moment is not lost")
    expectEqual(late.requests.count, 2, "the job went round once more")
    expectEqual(late.retractions, 1, "the first answer was withdrawn from speech")

    // A finished job's messages are a valid conversation to resume from.
    var resumed = chatty.messages
    expectEqual(resumed.last?["role"] as? String, "assistant", "the conversation ends with the answer")
    resumed.append(["role": "user", "content": "and what about Tuesday?"])
    let second = LoopHarness(script: [AgentAssistantTurn(content: "Tuesday has two.", toolCalls: [])])
    second.messages = resumed
    expectEqual(try await second.run(), "Tuesday has two.", "a later follow-up resumes with everything the job already knew")
    expect(second.requests[0].messages.contains { (($0["content"] as? String) ?? "") == "Here are only the direct flights." }, "including its earlier answer")
}

section("loop: long jobs compact and re-read their notes")
do {
    let long = LoopHarness(script: (1...6).map { AgentAssistantTurn(content: "", toolCalls: [call("t\($0)", "web_fetch", "{\"url\":\"https://example.com/\($0)\"}")]) } + [AgentAssistantTurn(content: "Summary done.", toolCalls: [])])
    long.config.compaction.maxCost = 3_000
    long.config.compaction.targetCost = 1_500
    long.config.compaction.keepRecentToolResults = 2
    long.tools["web_fetch"] = { arguments in
        let text = "Page \(arguments["url"] ?? "") says: " + String(repeating: "lorem ipsum ", count: 80)
        return .result(text: text, content: text)
    }
    _ = try await long.run()
    expect(!long.noteSummaries.isEmpty, "the conversation outgrew its budget and was compacted")
    expect(long.noteSummaries[0][0].hasPrefix("web_fetch {\"url\":\"https://example.com/1\"} → Page https://example.com/1 says:"), "the oldest result was summarised into the notes: \(long.noteSummaries[0][0])")
    let lastRequest = long.requests.last!.messages
    let sizes = AgentCompaction.total(lastRequest.map { AgentCompaction.entry(for: $0, budget: long.config.compaction) })
    expect(sizes.cost <= long.config.compaction.maxCost + 1_200, "what is sent stays near the budget (\(sizes.cost))")
    expectEqual(lastRequest.filter { (($0["content"] as? String) ?? "").hasPrefix(AgentCompaction.notesPrefix) }.count, 1, "the notes are in context exactly once")
    expect(lastRequest.contains { (($0["content"] as? String) ?? "").contains("## Goal\nDo the thing.") }, "the goal is re-read from the notes")
    expectEqual(lastRequest.first?["role"] as? String, "system", "the system prompt is never dropped")
    expectEqual(lastRequest[1]["content"] as? String, "Do the thing.", "nor the request")
    let calls = lastRequest.flatMap { ($0["tool_calls"] as? [[String: Any]]) ?? [] }.compactMap { $0["id"] as? String }
    let answered = Set(lastRequest.compactMap { $0["tool_call_id"] as? String })
    expectEqual(Set(calls), answered, "every tool call still has its result message")
}

section("loop: budget, failures, hand-back")
do {
    let endless = LoopHarness(script: (1...10).map { AgentAssistantTurn(content: "", toolCalls: [call("t\($0)", "web_search", "{\"query\":\"\($0)\"}")]) }, maxIterations: 3)
    endless.script[2] = AgentAssistantTurn(content: "I got two searches done; the rest is left.", toolCalls: [])
    let wrapped = try await endless.run()
    expectEqual(endless.requests.count, 3, "the loop stops at its step limit")
    expect(endless.requests[2].tools.isEmpty, "the last turn is offered no tools")
    expectEqual(wrapped, "I got two searches done; the rest is left.", "and the model's wrap-up is the answer")

    let stubborn = LoopHarness(script: (1...8).map { _ in AgentAssistantTurn(content: "", toolCalls: [call("same", "bash", #"{"command":"false"}"#)]) })
    stubborn.tools["bash"] = { _ in .failed("exit 1") }
    do {
        _ = try await stubborn.run()
        expect(false, "a job that keeps repeating a dead call should give up")
    } catch {
        expect(error.localizedDescription.contains("same wall"), "it stops with a plain reason: \(error.localizedDescription)")
    }
    expectEqual(stubborn.toolCalls.count, 2, "the failing call really ran only twice")

    let secret = LoopHarness(script: [AgentAssistantTurn(content: "", toolCalls: [call("t1", "drive_set_text")])])
    secret.tools["drive_set_text"] = { _ in .handBack("That is a password field, so it's yours to type.") }
    do {
        _ = try await secret.run()
        expect(false, "a hand-back should end the loop")
    } catch let handBack as AgentLoopHandBack {
        expectEqual(handBack.spokenLine, "That is a password field, so it's yours to type.", "the hand-back line is carried out")
    }

    let refused = LoopHarness(script: [AgentAssistantTurn(content: "", toolCalls: [call("t1", "write_file")]), AgentAssistantTurn(content: "I could not save it; that needs your yes.", toolCalls: [])])
    refused.tools["write_file"] = { _ in .refused("Not run: this needs the person's yes.") }
    expectEqual(try await refused.run(), "I could not save it; that needs your yes.", "a refusal goes back to the model, which reports it")
    expect(refused.steps[0].contains("Not run"), "and is in the step log")

    let badJSON = LoopHarness(script: [AgentAssistantTurn(content: "", toolCalls: [call("t1", "bash", "{not json")]), AgentAssistantTurn(content: "Okay.", toolCalls: [])])
    _ = try await badJSON.run()
    expectEqual(badJSON.toolCalls, [], "a call with broken arguments is not run")
}

print("")
if failures == 0 {
    print("agents2 tests: \(checks) checks, 0 failed")
} else {
    print("agents2 tests: \(checks) checks, \(failures) FAILED")
    exit(1)
}
