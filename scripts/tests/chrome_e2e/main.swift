// End to end from the app's side. Run with scripts/tests/run_chrome_e2e_tests.sh.
//
//   the real agent tools (browser_open, browser_click, …)
//     -> the real BrowserBridge / BrowserLink / socket, in a temp folder
//       -> the real helper binary
//         -> the real extension in a headless Chromium with a brand-new temp profile
//           -> HTML fixtures on a local temp web server
//
// Only the agent job types are stand-ins (stubs.swift). Nothing touches the real
// ~/Library/Application Support or anybody's real browser. Skipped (exit 0, saying so)
// when no Chromium that can load an unpacked extension is installed.

import AppKit
import Foundation

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func section(_ name: String) { print("— \(name)") }

func sleepMilliseconds(_ milliseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

@MainActor
func eventually(_ seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await sleepMilliseconds(40)
    }
    return condition()
}

/// The Node script that runs Chromium and the fixture server (chrome-extension/tests/support/launch-for-app.js).
nonisolated final class BrowserLauncher: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = Data()

    init(repoRoot: String, socketPath: String, helper: String, workDir: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", repoRoot + "/chrome-extension/tests/support/launch-for-app.js", socketPath, helper, workDir]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handle = output.fileHandleForReading
        Thread { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                self?.absorb(chunk)
            }
        }.start()
    }

    private func absorb(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        partial.append(chunk)
        while let newline = partial.firstIndex(of: 0x0a) {
            let line = partial.subdata(in: partial.startIndex..<newline)
            partial.removeSubrange(partial.startIndex...newline)
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
    }

    private func takeLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    func nextJSON(_ seconds: Double = 30) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let line = takeLine() {
                return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            if !process.isRunning { return nil }
            await sleepMilliseconds(30)
        }
        return nil
    }

    func command(_ name: String) async -> [String: Any]? {
        try? input.fileHandleForWriting.write(contentsOf: Data((name + "\n").utf8))
        return await nextJSON(15)
    }

    func quit() {
        try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
    }
}

struct ToolFailure: Error { let text: String }

/// Runs a browser tool the way the agent loop does: inside a job, through its rich-result entry point.
@MainActor
func run(_ tool: BrowserAgentTool, _ arguments: [String: Any], in job: AgentJob) async -> Result<AgentToolResult, ToolFailure> {
    do {
        let result = try await AgentJobContext.$current.withValue(job) {
            try await tool.executeReturningRichResult(arguments: arguments)
        }
        return .success(result)
    } catch {
        return .failure(ToolFailure(text: error.localizedDescription))
    }
}

func text(_ result: Result<AgentToolResult, ToolFailure>) -> String {
    switch result {
    case .success(let value): return value.text
    case .failure(let failure): return "ERROR: " + failure.text
    }
}

func index(in outline: String, of needle: String) -> Int {
    for line in outline.split(separator: "\n") where line.contains(needle) {
        if let close = line.firstIndex(of: "]"), line.hasPrefix("[") {
            return Int(line[line.index(after: line.startIndex)..<close]) ?? -1
        }
    }
    return -1
}

@MainActor
func runEndToEnd() async {
    let environment = ProcessInfo.processInfo.environment
    let repoRoot = environment["TEACHY_REPO_ROOT"] ?? FileManager.default.currentDirectoryPath
    let helper = environment["TEACHY_HOST_BINARY"] ?? ""
    let base = URL(fileURLWithPath: environment["TEACHY_TEST_SCRATCH"] ?? NSTemporaryDirectory())
    // Short on purpose: Unix socket paths are limited to about 100 bytes.
    let root = base.appendingPathComponent("e\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    guard FileManager.default.isExecutableFile(atPath: helper) else {
        print("SKIPPED: no helper binary (run scripts/tests/run_chrome_e2e_tests.sh, which builds it)")
        return
    }

    section("bridge: not installed -> waiting -> connected")
    BrowserBridge.supportRootForTesting = root
    let bridge = BrowserBridge.shared
    expect(bridge.state == .notInstalled, "nothing installed in the temp root: \(bridge.state)")

    _ = try? BrowserHostManifest.install(helperBinary: URL(fileURLWithPath: helper), root: root)
    bridge.start()
    expect(bridge.state == .waitingForChrome, "helper installed, no browser yet: \(bridge.state)")
    expect(bridge.browsersWithHelper.count == 6, "six browsers have the manifest")
    expect(bridge.problem == nil, "the bridge is listening (\(bridge.problem ?? ""))")
    let socketPath = BrowserHostManifest.socketURL(root: root).path
    expect(FileManager.default.fileExists(atPath: socketPath), "socket at \(socketPath)")

    let job = AgentJob(id: "job-e2e-1", title: "Buy a kettle")
    AgentJobCenter.shared.add(job)
    let early = await run(BrowserAgentTools.open, ["url": "https://example.com"], in: job)
    expect(text(early).contains("extension is not connected"), "a tool before any browser explains itself: \(text(early))")

    let launcher: BrowserLauncher
    do {
        launcher = try BrowserLauncher(repoRoot: repoRoot, socketPath: socketPath, helper: BrowserHostManifest.helperURL(root: root).path, workDir: root.appendingPathComponent("w").path)
    } catch {
        print("SKIPPED: could not start node (\(error.localizedDescription))")
        return
    }
    defer { launcher.quit() }
    guard let ready = await launcher.nextJSON(40), ready["ready"] as? Bool == true, let origin = ready["origin"] as? String else {
        print("SKIPPED: no Chromium that can load an unpacked extension was found on this Mac")
        bridge.stop()
        return
    }

    expect(await eventually(30) { bridge.state.isConnected }, "the extension reaches the app through the helper: \(bridge.state)")
    expect(bridge.state == .connected(browserName: "Chrome for Testing"), "the browser is named: \(bridge.state)")

    // MARK: open + read

    section("browser_open / browser_read")
    let opened = text(await run(BrowserAgentTools.open, ["url": origin + "/shop.html"], in: job))
    expect(opened.hasPrefix("Opened in the \"Buy a kettle\" tab group."), "open says where it opened: \(opened.prefix(80))")
    expect(opened.contains("Fixture Shop") && opened.contains(origin + "/shop.html"), "title and address")
    expect(opened.contains("TEXT\n# Blue Kettle"), "main text")
    expect(opened.contains("CONTROLS\n[") && opened.contains("button \"Add to cart\""), "numbered controls")
    expect(opened.contains("textbox \"Password\" (password: the person types this)"), "private fields are marked")
    expect(!opened.contains("hunter2") && !opened.contains("4111") && !opened.contains("424242"), "no private values")
    let add = index(in: opened, of: "button \"Add to cart\"")
    let email = index(in: opened, of: "textbox \"Email\"")
    let password = index(in: opened, of: "textbox \"Password\"")
    let card = index(in: opened, of: "textbox \"Card number\"")
    let quantity = index(in: opened, of: "combobox \"Quantity\"")
    let order = index(in: opened, of: "button \"Place order\"")
    let photo = index(in: opened, of: "file input \"Photo\"")
    expect(add > 0 && email > 0 && password > 0 && card > 0 && quantity > 0 && order > 0 && photo > 0, "found the controls by number")

    let reread = text(await run(BrowserAgentTools.read, ["max_chars": 60], in: job))
    expect(reread.hasPrefix("Read the page.") && reread.contains("more characters"), "read honours max_chars: \(reread.prefix(160))")

    // MARK: what the permission gate would be told

    section("permission facts from the live page")
    let site = BrowserRiskClassifier.host(of: origin)
    func verdict(_ tool: String, _ arguments: [String: Any]) async -> BrowserRiskDecision {
        let context = await bridge.policyContext(toolName: tool, arguments: arguments, jobID: job.id)
        return BrowserRiskClassifier.classify(toolName: tool, arguments: arguments, context: context)
    }
    let addVerdict = await verdict("browser_click", ["index": add])
    expect(addVerdict.risk == .needsConsent && addVerdict.siteScope == site, "Add to cart: ask once for the site (\(addVerdict.risk), \(addVerdict.siteScope))")
    expect(addVerdict.detail == "click button \"Add to cart\"", "the question names the control: \(addVerdict.detail)")
    let orderVerdict = await verdict("browser_click", ["index": order])
    expect(orderVerdict.risk == .alwaysAsk && orderVerdict.reason == "the control says \"place order\"", "Place order: ask every time (\(orderVerdict.reason))")
    let submitVerdict = await verdict("browser_type", ["index": email, "text": "a@b.c", "submit": true])
    expect(submitVerdict.risk == .alwaysAsk && submitVerdict.reason.contains("Place order"), "typing + Return on the order form asks every time (\(submitVerdict.reason))")
    let typeVerdict = await verdict("browser_type", ["index": email, "text": "a@b.c"])
    expect(typeVerdict.risk == .needsConsent && typeVerdict.detail.hasPrefix("type into textbox \"Email\""), "plain typing: once per site (\(typeVerdict.detail))")
    let readVerdict = await verdict("browser_read", [:])
    expect(readVerdict.risk == .safe, "reading is safe")
    let uploadVerdict = await verdict("browser_upload", ["index": photo, "path": "/tmp/x.png"])
    expect(uploadVerdict.risk == .alwaysAsk && uploadVerdict.summary == "send x.png to \(site)", "upload: every time (\(uploadVerdict.summary))")

    // MARK: acting

    section("browser_click / browser_type / the secrets rule")
    let clicked = text(await run(BrowserAgentTools.click, ["index": add], in: job))
    expect(clicked.hasPrefix("Clicked [\(add)] button \"Add to cart\"."), "click names what it clicked: \(clicked.prefix(80))")
    expect(clicked.contains("Appeared:") && clicked.contains("button \"Go to checkout\""), "and what changed: \(clicked)")

    let typed = text(await run(BrowserAgentTools.type, ["index": email, "text": "ada@example.com"], in: job))
    expect(typed.hasPrefix("Typed 15 characters."), "type reports: \(typed.prefix(60))")
    expect(typed.contains("textbox \"Email\" value=\"ada@example.com\""), "the new value shows in the diff")

    let refused = text(await run(BrowserAgentTools.type, ["index": password, "text": "should-never-arrive"], in: job))
    expect(refused.hasPrefix("STOP: \"Password\" [\(password)] is a password field."), "a password field is handed back: \(refused)")
    expect(refused.contains("Ask the person to type it themselves") && refused.contains("nothing was typed"), "with instructions to stop and ask")
    let refusedCard = text(await run(BrowserAgentTools.type, ["index": card, "text": "4242424242424242"], in: job))
    expect(refusedCard.hasPrefix("STOP: \"Card number\" [\(card)] is a card or bank details field."), "a card field is handed back: \(refusedCard.prefix(90))")
    _ = await run(BrowserAgentTools.click, ["index": password], in: job)
    let keyed = text(await run(BrowserAgentTools.key, ["combo": "x"], in: job))
    expect(keyed.hasPrefix("STOP:"), "typing a password key by key is refused too: \(keyed.prefix(60))")

    let missing = text(await run(BrowserAgentTools.click, ["index": 9999], in: job))
    expect(missing.hasPrefix("ERROR: There is no control [9999]"), "a wrong number is a clear error: \(missing)")
    let noIndex = text(await run(BrowserAgentTools.click, [:], in: job))
    expect(noIndex.contains("Give index"), "a missing index is caught before the browser: \(noIndex)")

    section("browser_select / browser_key / browser_scroll / browser_wait")
    let selected = text(await run(BrowserAgentTools.select, ["index": quantity, "option": "Two"], in: job))
    expect(selected.hasPrefix("Chose \"Two\".") && selected.contains("combobox \"Quantity\" value=\"Two\""), "select: \(selected)")
    let tabbed = text(await run(BrowserAgentTools.key, ["combo": "Tab"], in: job))
    expect(tabbed.hasPrefix("Pressed Tab."), "key: \(tabbed.prefix(40))")
    let scrolled = text(await run(BrowserAgentTools.scroll, ["direction": "bottom"], in: job))
    expect(scrolled.hasPrefix("Scrolled"), "scroll: \(scrolled.prefix(40))")
    let waited = text(await run(BrowserAgentTools.wait, ["text": "Blue Kettle", "timeout_seconds": 3], in: job))
    expect(waited.hasPrefix("Ready after"), "wait finds text: \(waited)")
    let waitedLoad = text(await run(BrowserAgentTools.wait, [:], in: job))
    expect(waitedLoad.hasPrefix("Ready after"), "wait with nothing waits for loading: \(waitedLoad)")
    let never = text(await run(BrowserAgentTools.wait, ["text": "never appears", "timeout_seconds": 0.6], in: job))
    expect(never.hasPrefix("Still not there after"), "wait gives up politely: \(never)")

    section("browser_screenshot: a picture the model can see")
    switch await run(BrowserAgentTools.screenshot, [:], in: job) {
    case .success(let shot):
        let data = shot.visionImageJPEGData ?? Data()
        expect(data.count > 3000 && Array(data.prefix(3)) == [0xff, 0xd8, 0xff], "a JPEG comes back (\(data.count) bytes)")
        let image = NSBitmapImageRep(data: data)
        expect((image?.pixelsWide ?? 0) > 300 && (image?.pixelsWide ?? 9999) <= 1400, "it decodes, at most 1400 wide (\(image?.pixelsWide ?? 0))")
        expect(shot.visionImageLabel == "Browser tab: Fixture Shop", "labelled: \(shot.visionImageLabel ?? "")")
        expect(shot.text.contains("2 private fields are blurred"), "private fields are blurred: \(shot.text)")
        try? data.write(to: base.appendingPathComponent("last-e2e-screenshot.jpg"))
    case .failure(let failure):
        expect(false, "screenshot failed: \(failure.text)")
    }

    section("browser_upload: the consent token is minted for that one file")
    let file = root.appendingPathComponent("photo.txt")
    try? Data("not really a photo".utf8).write(to: file)
    let uploaded = text(await run(BrowserAgentTools.upload, ["index": photo, "path": file.path], in: job))
    expect(uploaded.hasPrefix("Attached photo.txt."), "upload: \(uploaded)")
    let afterUpload = text(await run(BrowserAgentTools.read, [:], in: job))
    expect(afterUpload.contains("Chosen: photo.txt"), "the page received the file")
    let noFile = text(await run(BrowserAgentTools.upload, ["index": photo, "path": root.appendingPathComponent("nope.png").path], in: job))
    expect(noFile.hasPrefix("ERROR: There is no file at"), "a missing file never reaches the browser: \(noFile)")

    section("browser_navigate")
    let moved = text(await run(BrowserAgentTools.navigate, ["url": origin + "/article.html"], in: job))
    expect(moved.hasPrefix("Went to \(origin)/article.html.") && moved.contains("A new page loaded: \"How kettles whistle - Fixture Journal\""), "navigate: \(moved.prefix(140))")
    let back = text(await run(BrowserAgentTools.navigate, ["action": "back"], in: job))
    expect(back.hasPrefix("Went back.") && back.contains("Fixture Shop"), "back: \(back.prefix(100))")
    let nowhere = text(await run(BrowserAgentTools.navigate, [:], in: job))
    expect(nowhere.contains("Give url, or action"), "navigate needs somewhere to go")
    let bad = text(await run(BrowserAgentTools.navigate, ["url": "chrome://settings"], in: job))
    expect(bad.contains("http://") || bad.contains("https://"), "a non-web address is refused by the extension: \(bad)")

    // MARK: endings

    section("the job ends: working tabs close, the last page stays for the person")
    _ = await run(BrowserAgentTools.open, ["url": origin + "/article.html"], in: job)
    _ = await run(BrowserAgentTools.open, ["url": origin + "/thanks.html"], in: job)
    var tabs = (await launcher.command("tabs"))?["tabs"] as? [[String: Any]] ?? []
    expect(tabs.filter { ($0["url"] as? String ?? "").hasPrefix(origin) && $0["grouped"] as? Bool == true }.count == 3, "three job tabs in the group: \(tabs)")
    expect(bridge.hasWorkingJobs, "the bridge knows a job is using the browser")
    bridge.jobEnded(jobID: job.id)
    var settled = false
    for _ in 0..<40 {
        tabs = (await launcher.command("tabs"))?["tabs"] as? [[String: Any]] ?? []
        if tabs.filter({ ($0["url"] as? String ?? "").hasPrefix(origin) }).count == 1 { settled = true; break }
        await sleepMilliseconds(100)
    }
    let left = tabs.filter { ($0["url"] as? String ?? "").hasPrefix(origin) }
    expect(settled && (left.first?["url"] as? String ?? "").hasSuffix("/thanks.html"), "only the page the job finished on is left: \(tabs)")
    expect(left.first?["grouped"] as? Bool == false, "and it is out of the job's group")
    expect(!bridge.hasWorkingJobs, "the bridge has forgotten the job")

    section("browser_close_job, and the person stopping a job from the browser")
    let second = AgentJob(id: "job-e2e-2", title: "Second job")
    AgentJobCenter.shared.add(second)
    _ = await run(BrowserAgentTools.open, ["url": origin + "/shop.html"], in: second)
    let closed = text(await run(BrowserAgentTools.closeJob, ["keep_current_tab": false], in: second))
    expect(closed == "Closed 1 tab.", "close_job closes what the job opened: \(closed)")

    let third = AgentJob(id: "job-e2e-3", title: "Third job")
    AgentJobCenter.shared.add(third)
    _ = await run(BrowserAgentTools.open, ["url": origin + "/shop.html"], in: third)
    expect((await launcher.command("stop"))?["ok"] as? Bool == true, "the toolbar button was pressed")
    expect(await eventually(6) { third.stopReason != nil }, "the agent job is stopped")
    expect(third.stopReason == .userTookOver("you clicked the Teachy button in the browser"), "with the reason: \(String(describing: third.stopReason))")
    let afterStop = text(await run(BrowserAgentTools.read, [:], in: third))
    expect(afterStop.contains("took the browser back"), "further browser tools say why they will not run: \(afterStop)")
    bridge.jobEnded(jobID: third.id)

    section("the browser goes away")
    launcher.quit()
    expect(await eventually(10) { bridge.state == .waitingForChrome }, "back to waiting when the browser quits: \(bridge.state)")
    bridge.stop()
    expect(!FileManager.default.fileExists(atPath: socketPath), "the socket is removed when the bridge stops")
}

await runEndToEnd()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print(checks == 0 ? "NOTHING RUN" : "ALL PASSED")
