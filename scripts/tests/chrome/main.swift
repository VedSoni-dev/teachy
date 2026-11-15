// Tests for the app side of the browser bridge. Run with scripts/tests/run_chrome_tests.sh.
//
// Pure parts (framing, request/response pairing and timeouts, risk classes, the
// native-messaging manifest) are tested directly. The socket server and the
// link are tested for real: against the built helper binary, with this test
// playing Chrome on the helper's stdin/stdout. Everything lives in a temp
// folder; the real ~/Library/Application Support is never touched.

import Darwin
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

let environment = ProcessInfo.processInfo.environment
let repoRoot = environment["TEACHY_REPO_ROOT"] ?? FileManager.default.currentDirectoryPath
let helperBinary = environment["TEACHY_HOST_BINARY"] ?? ""
let scratch = URL(fileURLWithPath: environment["TEACHY_TEST_SCRATCH"] ?? NSTemporaryDirectory()).appendingPathComponent("chrome-swift-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func sleepMilliseconds(_ milliseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

/// Polls until `condition` holds or the time is up.
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await sleepMilliseconds(20)
    }
    return condition()
}

// MARK: - Framing

section("framing: round trip, byte layout, chunks")
do {
    let message: [String: Any] = ["type": "request", "id": "1", "method": "type", "params": ["text": "héllo ☕", "n": 3]]
    let frame = try BrowserFraming.encode(message)
    let body = frame.dropFirst(4)
    expect(Array(frame.prefix(4)) == [UInt8(body.count & 0xff), UInt8((body.count >> 8) & 0xff), 0, 0], "length prefix is little-endian and counts UTF-8 bytes")

    var decoder = BrowserFrameDecoder()
    let frames = try decoder.push(frame)
    expect(frames.count == 1, "one frame in, one message out")
    if case .message(let object)? = frames.first {
        expect(object["method"] as? String == "type", "method survives")
        expect((object["params"] as? [String: Any])?["text"] as? String == "héllo ☕", "unicode survives")
    } else {
        expect(false, "expected a message")
    }
    expect(decoder.bufferedByteCount == 0, "nothing left over")

    // Three messages, delivered 5 bytes at a time.
    var all = Data()
    for n in 1...3 { all.append(try BrowserFraming.encode(["n": n, "pad": String(repeating: "x", count: n * 700)])) }
    var chunked = BrowserFrameDecoder()
    var seen: [Int] = []
    var offset = 0
    while offset < all.count {
        let end = min(all.count, offset + 5)
        for frame in try chunked.push(all.subdata(in: offset..<end)) {
            if case .message(let object) = frame { seen.append(object["n"] as? Int ?? -1) }
        }
        offset = end
    }
    expect(seen == [1, 2, 3], "messages split across reads arrive whole and in order, got \(seen)")

    var together = BrowserFrameDecoder()
    expect(try together.push(all).count == 3, "several messages in one read")
}

section("framing: malformed and oversize")
do {
    var decoder = BrowserFrameDecoder()
    var data = BrowserFraming.frame(Data("this is not json".utf8))
    data.append(BrowserFraming.frame(Data("[1,2,3]".utf8)))
    data.append(BrowserFraming.frame(Data()))
    data.append(try BrowserFraming.encode(["ok": true]))
    let frames = try decoder.push(data)
    var kinds: [String] = []
    for frame in frames {
        switch frame {
        case .message: kinds.append("message")
        case .malformed: kinds.append("malformed")
        }
    }
    expect(kinds == ["malformed", "malformed", "malformed", "message"], "bad frames are reported and the stream carries on, got \(kinds)")

    var small = BrowserFrameDecoder(maxFrameBytes: 100)
    var threw = false
    do { _ = try small.push(BrowserFraming.frame(Data(repeating: 0x20, count: 101))) } catch let error as BrowserWireError {
        threw = error == .frameTooLarge(101)
    }
    expect(threw, "a length over the limit throws frameTooLarge")

    var huge = BrowserFrameDecoder()
    var header = Data([0xf0, 0xff, 0xff, 0x7f])
    header.append(Data("x".utf8))
    var threwHuge = false
    do { _ = try huge.push(header) } catch { threwHuge = true }
    expect(threwHuge, "an absurd length prefix throws instead of waiting for 2 GB")
}

section("messages: parsing what the extension and the helper send")
do {
    if case .response(let id, let result) = BrowserMessage.parse(["type": "response", "id": "t4", "ok": true, "result": ["tab": 7]]),
       case .success(let object) = result {
        expect(id == "t4" && object["tab"] as? Int == 7, "ok response")
    } else { expect(false, "ok response did not parse") }

    if case .response(_, let result) = BrowserMessage.parse(["type": "response", "id": 9, "ok": false, "error": ["code": "no_such_element", "message": "gone"]]),
       case .failure(let error) = result {
        expect(error == .remote(code: "no_such_element", message: "gone") && error.code == "no_such_element", "error response keeps its code")
        expect(error.errorDescription == "gone", "error text is the extension's message")
    } else { expect(false, "error response did not parse") }

    if case .event(let name, let fields) = BrowserMessage.parse(["type": "event", "event": "user_stopped", "job": "J", "reason": "escape"]) {
        expect(name == "user_stopped" && fields["job"] as? String == "J", "event")
    } else { expect(false, "event did not parse") }

    if case .host(let event, let fields) = BrowserMessage.parse(["type": "host", "event": "hello", "browser": "Arc"]) {
        expect(event == "hello" && fields["browser"] as? String == "Arc", "helper hello")
    } else { expect(false, "helper hello did not parse") }

    if case .unknown = BrowserMessage.parse(["type": "response", "ok": true]) {} else { expect(false, "a response without an id is unknown") }
    if case .unknown = BrowserMessage.parse(["hello": "there"]) {} else { expect(false, "junk is unknown") }
}

// MARK: - Request / response pairing

section("correlator: answers, errors, timeouts, late replies")
do {
    let correlator = BrowserRequestCorrelator()

    // The answer arrives from another thread while the caller waits.
    let answered = try await correlator.perform(method: "ping", timeout: 2) { id in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            correlator.resolve(id: id, with: .success(["echo": id]))
        }
    }
    expect((answered["echo"] as? String)?.hasPrefix("t") == true, "the caller gets its own answer")
    expect(correlator.pendingCount == 0, "nothing left pending after an answer")

    // An error answer is thrown.
    do {
        _ = try await correlator.perform(method: "click", timeout: 2) { id in
            correlator.resolve(id: id, with: .failure(.remote(code: "no_such_element", message: "gone")))
        }
        expect(false, "an error answer should throw")
    } catch let error as BrowserWireError {
        expect(error == .remote(code: "no_such_element", message: "gone"), "the extension's error is thrown as is")
    }

    // No answer: it gives up on time, and a late answer is ignored.
    final class Box: @unchecked Sendable { var id = "" }
    let lateBox = Box()
    let started = Date()
    do {
        _ = try await correlator.perform(method: "read_page", timeout: 0.25) { id in lateBox.id = id }
        expect(false, "should have timed out")
    } catch let error as BrowserWireError {
        let elapsed = Date().timeIntervalSince(started)
        expect(error == .timedOut(method: "read_page", seconds: 0.25), "timeout names the method, got \(error)")
        expect(elapsed >= 0.2 && elapsed < 1.5, "timed out on time (\(elapsed) s)")
    }
    expect(correlator.resolve(id: lateBox.id, with: .success([:])) == false, "an answer after the timeout is dropped")
    expect(correlator.resolve(id: "t999", with: .success([:])) == false, "an answer nobody asked for is dropped")
    expect(correlator.pendingCount == 0, "nothing left pending after a timeout")

    // The send itself fails.
    do {
        _ = try await correlator.perform(method: "ping", timeout: 2) { _ in throw BrowserWireError.connectionLost }
        expect(false, "a failed send should throw")
    } catch let error as BrowserWireError {
        expect(error == .connectionLost, "a failed send is reported at once")
    }

    // Many at once: each caller gets its own answer.
    let total = 60
    let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
        for n in 0..<total {
            group.addTask {
                let reply = try? await correlator.perform(method: "m\(n)", timeout: 3) { id in
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double((n * 7) % 30) / 1000) {
                        correlator.resolve(id: id, with: .success(["n": n]))
                    }
                }
                return reply?["n"] as? Int == n
            }
        }
        var collected: [Bool] = []
        for await ok in group { collected.append(ok) }
        return collected
    }
    expect(results.count == total && !results.contains(false), "\(total) overlapping requests each get their own answer")
}

section("correlator: lost connections and cancellation")
do {
    let correlator = BrowserRequestCorrelator()

    // Two browsers; one goes away. Only its requests fail.
    async let onChrome: [String: Any] = correlator.perform(method: "a", owner: "chrome", timeout: 3) { _ in }
    async let onArc: [String: Any] = correlator.perform(method: "b", owner: "arc", timeout: 3) { id in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { correlator.resolve(id: id, with: .success(["from": "arc"])) }
    }
    _ = await eventually { correlator.pendingCount == 2 }
    correlator.failAll(owner: "chrome")
    var chromeError: BrowserWireError?
    do { _ = try await onChrome } catch let error as BrowserWireError { chromeError = error }
    expect(chromeError == .connectionLost, "requests to the browser that left fail with connectionLost")
    let arcReply = try? await onArc
    expect(arcReply?["from"] as? String == "arc", "requests to the other browser still finish")

    // Cancelling the caller releases it straight away.
    let task = Task { try await correlator.perform(method: "wait_for", timeout: 30) { _ in } }
    _ = await eventually { correlator.pendingCount == 1 }
    let cancelledAt = Date()
    task.cancel()
    var cancelError: BrowserWireError?
    do { _ = try await task.value } catch let error as BrowserWireError { cancelError = error } catch {}
    expect(cancelError == .cancelled && Date().timeIntervalSince(cancelledAt) < 1, "a cancelled caller stops waiting")
    expect(correlator.pendingCount == 0, "nothing left pending after cancel")
}

// MARK: - Risk classes

section("risk: what each tool is by default")
do {
    let safe: Set<String> = ["browser_read", "browser_screenshot", "browser_wait", "browser_scroll", "browser_close_job"]
    for name in BrowserRiskClassifier.toolNames {
        let expected: BrowserRisk = safe.contains(name) ? .safe : name == "browser_upload" ? .alwaysAsk : .needsConsent
        expect(BrowserRiskClassifier.baseRisk(forTool: name) == expected, "\(name) base risk")
    }
    expect(BrowserRiskClassifier.toolNames.count == 12, "twelve browser tools")
    expect(BrowserRisk.safe.rawValue == 0 && BrowserRisk.needsConsent.rawValue == 1 && BrowserRisk.alwaysAsk.rawValue == 2, "raw values line up with ToolRisk")
}

func risk(_ tool: String, _ arguments: [String: Any] = [:], site: String = "shop.example.com", label: String = "", submit: String = "", isSubmit: Bool = false) -> BrowserRiskDecision {
    BrowserRiskClassifier.classify(toolName: tool, arguments: arguments, context: BrowserRiskContext(siteHost: site, elementLabel: label, submitLabel: submit, isSubmit: isSubmit))
}

section("risk: reading is safe, acting on a site asks once per site")
do {
    expect(risk("browser_read").risk == .safe, "read")
    expect(risk("browser_screenshot").risk == .safe, "screenshot")
    expect(risk("browser_wait", ["text": "Done"]).risk == .safe, "wait")
    expect(risk("browser_scroll", ["direction": "down"]).risk == .safe, "scroll")
    expect(risk("browser_close_job").risk == .safe, "close job")

    let open = risk("browser_open", ["url": "https://news.example.org/a?b=1"], site: "")
    expect(open.risk == .needsConsent && open.siteScope == "news.example.org", "open asks, scoped to the site it opens (\(open.siteScope))")
    expect(open.summary == "work on news.example.org in your browser", "open summary reads as a question: \(open.summary)")

    let navigate = risk("browser_navigate", ["url": "https://other.example.net/"], site: "shop.example.com")
    expect(navigate.risk == .needsConsent && navigate.siteScope == "other.example.net", "navigate is scoped to where it goes, not where it is")

    let click = risk("browser_click", ["index": 3], label: "button \"Add to cart\"")
    expect(click.risk == .needsConsent && click.siteScope == "shop.example.com", "an ordinary click asks once for the site")
    expect(click.detail == "click button \"Add to cart\"", "the click is named: \(click.detail)")

    // Same site, different tools: the same scope, so one yes covers them.
    let typed = risk("browser_type", ["index": 4, "text": "ada@example.com"], label: "textbox \"Email\"")
    let selected = risk("browser_select", ["index": 5, "option": "Two"], label: "combobox \"Quantity\"")
    let key = risk("browser_key", ["combo": "Tab"])
    for decision in [typed, selected, key] {
        expect(decision.risk == .needsConsent && decision.siteScope == click.siteScope && decision.summary == click.summary, "same site, same question: \(decision.summary)")
    }

    let current = risk("browser_open", ["current_tab": true], site: "")
    expect(current.risk == .needsConsent && current.summary.contains("the tab you have open"), "borrowing the current tab asks: \(current.summary)")
    let back = risk("browser_navigate", ["action": "back"])
    expect(back.risk == .needsConsent && back.siteScope == "shop.example.com" && back.detail == "go back", "going back is an action on the site the tab is on: \(back.detail)")
    let unknown = risk("browser_click", ["index": 1], site: "")
    expect(unknown.risk == .needsConsent && unknown.summary == "work in your browser", "no page known yet: still asks")
}

section("risk: buy / pay / send / post / delete ask every time")
do {
    for label in ["button \"Buy now\"", "button \"Pay $40.00\"", "button \"Place order\"", "button \"Complete purchase\"", "link \"Checkout\"",
                  "button \"Send\"", "button \"Post\"", "button \"Delete account\"", "button \"Confirm purchase\"", "button \"Subscribe\"",
                  "button \"Remove\"", "button \"Publish\"", "button \"Submit\"", "button \"Sign out\"", "button \"Transfer\"", "button \"Reply\""] {
        let decision = risk("browser_click", ["index": 1], label: label)
        expect(decision.risk == .alwaysAsk, "\(label) should ask every time (\(decision.reason))")
    }
    for label in ["button \"Add to cart\"", "link \"Payment methods help\"", "button \"Next\"", "textbox \"Search\"", "link \"Postcode finder\"",
                  "button \"Sender details\"", "link \"Buyer guide\"", "button \"Continue\"", "checkbox \"Remember me\"", "link \"Reorder list\""] {
        let decision = risk("browser_click", ["index": 1], label: label)
        expect(decision.risk == .needsConsent, "\(label) should be an ordinary click, got \(decision.risk) (\(decision.reason))")
    }

    // A submit button with an innocent face on a form whose submit says "Pay".
    expect(risk("browser_click", ["index": 1], label: "button \"Continue\"", submit: "Pay now", isSubmit: true).risk == .alwaysAsk, "a submit button inherits its form's words")
    expect(risk("browser_click", ["index": 1], label: "link \"Help\"", submit: "Pay now", isSubmit: false).risk == .needsConsent, "a link inside that form does not")

    // Return in a field submits the form.
    expect(risk("browser_key", ["combo": "Enter"], submit: "Place order").risk == .alwaysAsk, "Return on an order form asks every time")
    expect(risk("browser_key", ["combo": "Enter"], submit: "Search").risk == .needsConsent, "Return in a search box is ordinary")
    expect(risk("browser_key", ["combo": "cmd+Enter"]).risk == .alwaysAsk, "cmd+Return sends on most sites")
    expect(risk("browser_key", ["combo": "ctrl + return"]).risk == .alwaysAsk, "ctrl+Return too")
    expect(risk("browser_type", ["index": 2, "text": "hi", "submit": true], label: "textbox \"Message\"", submit: "Send").risk == .alwaysAsk, "type-and-submit on a send form asks every time")
    expect(risk("browser_type", ["index": 2, "text": "kettle", "submit": true], label: "searchbox \"Search\"", submit: "Search").risk == .needsConsent, "type-and-submit in a search box is ordinary")
    expect(risk("browser_type", ["index": 2, "text": "hi"], label: "textbox \"Message\"", submit: "Send").risk == .needsConsent, "typing without submitting is ordinary")

    expect(risk("browser_click", ["index": 1, "accept_dialogs": true], label: "button \"Next\"").risk == .alwaysAsk, "answering OK to a page's question asks every time")
}

section("risk: uploads and money sites always ask")
do {
    let upload = risk("browser_upload", ["index": 9, "path": "/Users/tester/Pictures/cat.jpg"])
    expect(upload.risk == .alwaysAsk && upload.detail == "/Users/tester/Pictures/cat.jpg", "an upload always asks and shows the file")
    expect(upload.summary == "send cat.jpg to shop.example.com", "upload question: \(upload.summary)")
    expect(risk("browser_upload", ["path": "/Users/tester/.ssh/id_ed25519"]).reason.contains("keys or passwords"), "a key file is called out")

    for host in ["www.paypal.com", "paypal.com", "secure.chase.com", "dashboard.stripe.com", "app.revolut.com", "www.coinbase.com", "netbanking.hdfcbank.com"] {
        expect(BrowserRiskClassifier.isFinancialHost(host), "\(host) is a money site")
        for tool in ["browser_click", "browser_type", "browser_select", "browser_key", "browser_read", "browser_screenshot"] {
            expect(risk(tool, ["index": 1, "combo": "Tab", "text": "x", "option": "y"], site: host, label: "button \"Next\"").risk == .alwaysAsk, "\(tool) on \(host) asks every time")
        }
        expect(risk("browser_open", ["url": "https://\(host)/login"], site: "").risk == .alwaysAsk, "opening \(host) asks every time")
        expect(risk("browser_scroll", ["direction": "down"], site: host).risk == .safe, "scrolling on \(host) is still safe")
        expect(risk("browser_wait", [:], site: host).risk == .safe, "waiting on \(host) is still safe")
    }
    for host in ["notpaypal.com", "paypal.com.evil.example", "example.com", "chaser.com", ""] {
        expect(!BrowserRiskClassifier.isFinancialHost(host), "\(host) is not on the list")
    }
    expect(risk("browser_navigate", ["url": "https://www.paypal.com/send"], site: "shop.example.com").risk == .alwaysAsk, "navigating to a money site asks every time")
    expect(risk("browser_open", ["url": "javascript:alert(1)"], site: "").risk == .alwaysAsk, "a non-web address is never waved through")
    expect(risk("browser_open", ["url": "file:///etc/passwd"], site: "").risk == .alwaysAsk, "a file address is never waved through")
}

// MARK: - Manifest

section("manifest: the extension id comes from the committed public key")
do {
    let manifestURL = URL(fileURLWithPath: repoRoot).appendingPathComponent("chrome-extension/manifest.json")
    if let data = try? Data(contentsOf: manifestURL), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        let key = object["key"] as? String ?? ""
        expect(BrowserHostManifest.extensionID(publicKeyBase64: key) == BrowserHostManifest.developmentExtensionID,
               "manifest key gives \(BrowserHostManifest.extensionID(publicKeyBase64: key) ?? "nil"), the app allows \(BrowserHostManifest.developmentExtensionID)")
        expect(object["incognito"] as? String == "not_allowed", "the extension never runs in Incognito")
        expect((object["permissions"] as? [String] ?? []).sorted() == ["debugger", "nativeMessaging", "tabGroups", "tabs"], "permissions stay minimal: \(object["permissions"] ?? "")")
        expect(object["host_permissions"] == nil && object["optional_host_permissions"] == nil, "no host permissions")
        expect(object["manifest_version"] as? Int == 3, "Manifest V3")
        let committed = String(data: data, encoding: .utf8) ?? ""
        expect(!committed.contains("PRIVATE KEY"), "no private key in the manifest")
    } else {
        expect(false, "could not read chrome-extension/manifest.json at \(manifestURL.path)")
    }
    expect(BrowserHostManifest.isValidExtensionID(BrowserHostManifest.developmentExtensionID), "the id is 32 letters a-p")
    expect(!BrowserHostManifest.isValidExtensionID("okfgkjagfedglgjgnfbcffnmopbgige"), "31 letters is not an id")
    expect(!BrowserHostManifest.isValidExtensionID("okfgkjagfedglgjgnfbcffnmopbgigez"), "z is not in an id")
    expect(BrowserHostManifest.extensionID(publicKeyBase64: "not base64 !!") == nil, "a bad key gives no id")
}

section("manifest: text, paths, install and uninstall into a temp folder")
do {
    let root = scratch.appendingPathComponent("support root", isDirectory: true)
    let helperPath = BrowserHostManifest.helperURL(root: root).path
    let text = BrowserHostManifest.manifestJSON(helperPath: helperPath)
    let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    expect(parsed?["name"] as? String == "com.teachy.browser", "host name")
    expect(parsed?["type"] as? String == "stdio", "stdio host")
    expect(parsed?["path"] as? String == helperPath, "absolute helper path, spaces and all")
    expect(parsed?["allowed_origins"] as? [String] == ["chrome-extension://okfgkjagfedglgjgnfbcffnmopbgigem/"], "only the Teachy extension may start it")

    let two = BrowserHostManifest.manifestJSON(helperPath: "/x/\"odd\"\\path", extensionIDs: ["okfgkjagfedglgjgnfbcffnmopbgigem", "abcdefghijklmnopabcdefghijklmnop", "bad id", "*"])
    let parsedTwo = (try? JSONSerialization.jsonObject(with: Data(two.utf8))) as? [String: Any]
    expect(parsedTwo?["path"] as? String == "/x/\"odd\"\\path", "quotes and backslashes in the path are escaped")
    expect((parsedTwo?["allowed_origins"] as? [String])?.count == 2, "invalid ids (and wildcards) are left out")

    expect(BrowserHostManifest.socketURL(root: root).path.hasSuffix("/Teachy/browser.sock"), "socket path")
    let expectedFolders = ["Google/Chrome", "Google/Chrome Beta", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Vivaldi"]
    expect(BrowserHostManifest.browsers.map(\.supportFolder) == expectedFolders, "Chrome, Chrome Beta, Edge, Brave, Arc, Vivaldi")

    expect(BrowserHostManifest.installation(root: root) == .init(helperPresent: false, browsersWithManifest: []), "nothing installed yet")
    expect(!BrowserHostManifest.installation(root: root).isInstalled, "not installed")

    let fakeHelper = scratch.appendingPathComponent("fake-helper")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeHelper)
    let written = try BrowserHostManifest.install(helperBinary: fakeHelper, root: root)
    expect(written.count == 6, "six manifests written")
    for (index, folder) in expectedFolders.enumerated() {
        let expected = root.appendingPathComponent(folder).appendingPathComponent("NativeMessagingHosts/com.teachy.browser.json").path
        expect(written[index].path == expected, "manifest for \(folder) at \(written[index].path)")
        expect((try? String(contentsOfFile: expected, encoding: .utf8)) == text, "manifest content for \(folder)")
    }
    expect(FileManager.default.isExecutableFile(atPath: helperPath), "the helper is copied in and executable")
    let installed = BrowserHostManifest.installation(root: root)
    expect(installed.isInstalled && installed.browsersWithManifest == ["Chrome", "Chrome Beta", "Edge", "Brave", "Arc", "Vivaldi"], "installation is detected: \(installed)")

    // Installing again over a live copy works (an update).
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fakeHelper)
    _ = try BrowserHostManifest.install(helperBinary: fakeHelper, root: root)
    expect((try? String(contentsOfFile: helperPath, encoding: .utf8))?.contains("exit 1") == true, "reinstall replaces the helper")

    // A manifest that points at a missing helper does not count.
    try FileManager.default.removeItem(atPath: helperPath)
    expect(!BrowserHostManifest.installation(root: root).isInstalled, "manifests without the helper are not an installation")

    BrowserHostManifest.uninstall(root: root)
    expect(BrowserHostManifest.installation(root: root).browsersWithManifest.isEmpty, "uninstall removes the manifests")
}

/// Runs a command and returns (exit code, stdout).
func run(_ launchPath: String, _ arguments: [String], environment extra: [String: String] = [:]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    var merged = ProcessInfo.processInfo.environment
    for (key, value) in extra { merged[key] = value }
    process.environment = merged
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch { return (-1, "") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

section("manifest: scripts/install-chrome-host.sh writes exactly the same thing")
do {
    let script = URL(fileURLWithPath: repoRoot).appendingPathComponent("scripts/install-chrome-host.sh").path
    let root = scratch.appendingPathComponent("script root", isDirectory: true)
    let fakeHelper = scratch.appendingPathComponent("fake-helper-2")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeHelper)
    let settings = ["TEACHY_INSTALL_ROOT": root.path, "TEACHY_HOST_BINARY": fakeHelper.path]

    expect(run("/bin/sh", ["-n", script]).0 == 0, "the install script passes sh -n")

    // --print changes nothing.
    let printed = run("/bin/sh", [script, "--print"], environment: settings)
    expect(printed.0 == 0 && !FileManager.default.fileExists(atPath: root.path), "--print writes nothing")
    let expectedText = BrowserHostManifest.manifestJSON(helperPath: BrowserHostManifest.helperURL(root: root).path)
    expect(printed.1.hasPrefix(expectedText), "--print shows the manifest the app would write:\n\(printed.1)")
    expect(printed.1.components(separatedBy: "would write: ").count - 1 == 6, "--print lists six destinations")

    let installed = run("/bin/sh", [script], environment: settings)
    expect(installed.0 == 0, "the script installs into the temp root (exit \(installed.0))")
    for browser in BrowserHostManifest.browsers {
        let url = BrowserHostManifest.manifestURL(for: browser, root: root)
        expect((try? String(contentsOf: url, encoding: .utf8)) == expectedText, "script and app agree on the \(browser.name) manifest")
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expect(mode == 0o644, "\(browser.name) manifest is 0644, got \(String(mode, radix: 8))")
    }
    expect(BrowserHostManifest.installation(root: root).isInstalled, "the app sees what the script installed")
    let entries = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
    let files = entries.filter { !((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent($0).path)[.type] as? FileAttributeType) == .typeDirectory) }
    expect(files.count == 7, "exactly the helper and six manifests, nothing else: \(files)")

    // Extra ids (the Web Store id, later) are added; junk ids are refused.
    let withStore = run("/bin/sh", [script, "--print"], environment: settings.merging(["TEACHY_EXTENSION_IDS": "okfgkjagfedglgjgnfbcffnmopbgigem abcdefghijklmnopabcdefghijklmnop"]) { $1 })
    expect(withStore.1.contains("\"chrome-extension://okfgkjagfedglgjgnfbcffnmopbgigem/\", \"chrome-extension://abcdefghijklmnopabcdefghijklmnop/\""), "two allowed origins")
    expect(run("/bin/sh", [script, "--print"], environment: settings.merging(["TEACHY_EXTENSION_IDS": "*"]) { $1 }).0 != 0, "a wildcard id is refused")
    expect(run("/bin/sh", [script, "--print"], environment: settings.merging(["TEACHY_EXTENSION_IDS": "short"]) { $1 }).0 != 0, "a short id is refused")
    expect(run("/bin/sh", [script, "--bogus"], environment: settings).0 != 0, "an unknown option is refused")

    let removed = run("/bin/sh", [script, "--uninstall"], environment: settings)
    expect(removed.0 == 0 && !BrowserHostManifest.installation(root: root).helperPresent && BrowserHostManifest.installation(root: root).browsersWithManifest.isEmpty, "--uninstall removes them again")
}

// MARK: - The link, against the real helper

/// Plays Chrome: starts the helper and speaks native messaging on its stdin/stdout.
nonisolated final class FakeChrome: @unchecked Sendable {
    let process = Process()
    private let toHelper = Pipe()
    private let fromHelper = Pipe()
    private let lock = NSLock()
    private var inbox: [[String: Any]] = []

    init(helper: String, socketPath: String, extensionID: String = BrowserHostManifest.developmentExtensionID) throws {
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["chrome-extension://\(extensionID)/"]
        var settings = ProcessInfo.processInfo.environment
        settings["TEACHY_BROWSER_SOCKET"] = socketPath
        process.environment = settings
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        try process.run()

        let handle = fromHelper.fileHandleForReading
        let thread = Thread { [weak self] in
            var decoder = BrowserFrameDecoder()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                guard let frames = try? decoder.push(chunk) else { return }
                for frame in frames {
                    if case .message(let object) = frame {
                        self?.lock.lock()
                        self?.inbox.append(object)
                        self?.lock.unlock()
                    }
                }
            }
        }
        thread.start()
    }

    func send(_ object: [String: Any]) {
        guard let data = try? BrowserFraming.encode(object) else { return }
        try? toHelper.fileHandleForWriting.write(contentsOf: data)
    }

    /// Removes and returns the first message that matches.
    func take(_ seconds: Double = 5, where matches: ([String: Any]) -> Bool) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            if let index = inbox.firstIndex(where: matches) {
                let found = inbox.remove(at: index)
                lock.unlock()
                return found
            }
            lock.unlock()
            await sleepMilliseconds(15)
        }
        return nil
    }

    func quit() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

nonisolated final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String, [String: Any])] = []
    private var changeCount = 0
    func add(_ peer: String, _ name: String, _ fields: [String: Any]) { lock.lock(); entries.append((peer, name, fields)); lock.unlock() }
    func changed() { lock.lock(); changeCount += 1; lock.unlock() }
    var changes: Int { lock.lock(); defer { lock.unlock() }; return changeCount }
    func first(named name: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return entries.first { $0.1 == name }?.2 }
}

if helperBinary.isEmpty || !FileManager.default.isExecutableFile(atPath: helperBinary) {
    print("— link: SKIPPED (no helper binary; run scripts/tests/run_chrome_tests.sh, which builds it)")
} else {
    section("link + socket + real helper: connect, request, answer")
    // Unix socket paths are limited to about 100 bytes, so keep this one short.
    var socketFolder = scratch.deletingLastPathComponent().appendingPathComponent("k\(getpid())", isDirectory: true)
    if socketFolder.path.utf8.count > 90 { socketFolder = URL(fileURLWithPath: "/tmp/teachy-chrome-k\(getpid())", isDirectory: true) }
    let socketPath = socketFolder.appendingPathComponent("b.sock").path

    // A leftover socket file from a crashed run is replaced, not an error.
    try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))

    let log = EventLog()
    let link = BrowserLink(
        socketPath: socketPath,
        onChange: { log.changed() },
        onEvent: { peer, name, fields in log.add(peer, name, fields.object) }
    )
    do {
        try link.start()
        expect(link.isListening, "the link is listening")
    } catch {
        expect(false, "the link could not start: \(error)")
    }

    let socketMode = (try? FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    let folderMode = (try? FileManager.default.attributesOfItem(atPath: socketFolder.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect(socketMode == 0o600, "the socket is 0600, got \(String(socketMode, radix: 8))")
    expect(folderMode == 0o700, "its folder is 0700, got \(String(folderMode, radix: 8))")

    // A second Teachy must not steal the socket.
    var secondError: BrowserSocketError?
    do { try BrowserLink(socketPath: socketPath).start() } catch let error as BrowserSocketError { secondError = error } catch {}
    expect(secondError == .alreadyInUse, "a second listener on the same socket is refused")

    do {
        _ = try await link.request(method: "ping", params: [:], timeout: 1)
        expect(false, "a request with no browser should fail")
    } catch let error as BrowserWireError {
        expect(error == .notConnected, "no browser yet: notConnected")
    }

    let chrome = try FakeChrome(helper: helperBinary, socketPath: socketPath)
    expect(await chrome.take { $0["type"] as? String == "host" && $0["event"] as? String == "app_connected" } != nil, "the helper tells Chrome the app is there")
    expect(link.readyPeers.isEmpty, "not 'connected' until the extension itself says hello")
    chrome.send(["type": "event", "event": "hello", "protocol": 1, "browser": "Chrome", "extensionId": BrowserHostManifest.developmentExtensionID])
    expect(await eventually { link.readyPeers.count == 1 }, "the extension's hello makes it a ready browser")
    expect(log.changes >= 1, "the link reported a change")
    expect(log.first(named: "hello")?["protocol"] as? Int == 1, "the hello event is passed on")
    let peer = link.readyPeers.first
    expect(peer?.origin == "chrome-extension://okfgkjagfedglgjgnfbcffnmopbgigem/", "the helper passed on who started it")
    expect(peer?.browser.isEmpty == false, "the browser has a name (\(peer?.browser ?? ""))")

    // Request -> Chrome -> answer.
    async let reply = link.request(method: "read_page", params: ["tab": 7, "job": "J1"], timeout: 5)
    let seen = await chrome.take { $0["type"] as? String == "request" }
    expect(seen?["method"] as? String == "read_page" && (seen?["params"] as? [String: Any])?["tab"] as? Int == 7, "Chrome receives the request")
    chrome.send(["type": "response", "id": seen?["id"] ?? "", "ok": true, "result": ["title": "Fixture Shop", "text": String(repeating: "é", count: 200_000)]])
    do {
        let answer = try await reply
        expect(answer.result["title"] as? String == "Fixture Shop", "the answer reaches the caller")
        expect((answer.result["text"] as? String)?.count == 200_000, "a 400 KB answer arrives whole")
        expect(answer.peer == peer?.id, "the answer says which browser it came from")
    } catch {
        expect(false, "request failed: \(error)")
    }

    section("link + real helper: errors, size limit, timeout, events")
    async let failing = link.request(method: "click", params: ["tab": 7, "index": 99], timeout: 5)
    let clickRequest = await chrome.take { $0["method"] as? String == "click" }
    chrome.send(["type": "response", "id": clickRequest?["id"] ?? "", "ok": false, "error": ["code": "no_such_element", "message": "There is no control [99]."]])
    do {
        _ = try await failing
        expect(false, "an error answer should throw")
    } catch let error as BrowserWireError {
        expect(error.code == "no_such_element" && error.errorDescription == "There is no control [99].", "the extension's error comes through")
    }

    do {
        _ = try await link.request(method: "type", params: ["text": String(repeating: "a", count: 1_100_000)], timeout: 5)
        expect(false, "an oversize request should throw")
    } catch let error as BrowserWireError {
        expect(error.code == "message_too_large", "more than Chrome's 1 MB is refused before sending (\(error))")
    }
    expect(await chrome.take(0.3) { $0["method"] as? String == "type" } == nil, "and never reaches Chrome")

    let slowStart = Date()
    do {
        _ = try await link.request(method: "wait_for", params: [:], timeout: 0.3)
        expect(false, "should time out")
    } catch let error as BrowserWireError {
        expect(error.code == "timeout" && Date().timeIntervalSince(slowStart) < 2, "no answer: timeout on time")
    }
    let slowRequest = await chrome.take { $0["method"] as? String == "wait_for" }
    chrome.send(["type": "response", "id": slowRequest?["id"] ?? "", "ok": true, "result": [:]])
    await sleepMilliseconds(100)
    expect(link.correlator.pendingCount == 0, "the late answer is dropped quietly")

    chrome.send(["type": "event", "event": "user_stopped", "job": "J1", "reason": "escape"])
    expect(await eventually { log.first(named: "user_stopped") != nil }, "events from the browser are passed on")
    expect(log.first(named: "user_stopped")?["job"] as? String == "J1", "with their fields")

    section("link + real helper: an impostor, and the browser going away")
    let impostor = try FakeChrome(helper: helperBinary, socketPath: socketPath, extensionID: "abcdefghijklmnopabcdefghijklmnop")
    _ = await impostor.take { $0["event"] as? String == "app_connected" }
    impostor.send(["type": "event", "event": "hello", "protocol": 1])
    await sleepMilliseconds(300)
    expect(link.readyPeers.count == 1, "a helper started by another extension is not accepted")
    expect(await impostor.take(3) { $0["event"] as? String == "app_not_running" } != nil, "and its connection is dropped")
    impostor.quit()

    async let orphaned = link.request(method: "screenshot", params: ["tab": 7], timeout: 10)
    _ = await chrome.take { $0["method"] as? String == "screenshot" }
    let quitAt = Date()
    chrome.quit()
    do {
        _ = try await orphaned
        expect(false, "a request to a browser that quit should fail")
    } catch let error as BrowserWireError {
        expect(error == .connectionLost && Date().timeIntervalSince(quitAt) < 3, "the browser quit mid-request: connectionLost at once, not a 10 s wait")
    }
    expect(await eventually { link.readyPeers.isEmpty }, "the browser is no longer listed")
    expect(await eventually { log.first(named: "peer_closed") != nil }, "the app is told the browser left")

    // The app quits: the helper notices and says so to its browser.
    let second = try FakeChrome(helper: helperBinary, socketPath: socketPath)
    _ = await second.take { $0["event"] as? String == "app_connected" }
    link.stop()
    expect(await second.take { $0["event"] as? String == "app_not_running" } != nil, "when the app stops, the helper tells Chrome")
    expect(!FileManager.default.fileExists(atPath: socketPath), "the socket file is removed on stop")
    second.quit()
    try? FileManager.default.removeItem(at: socketFolder)
}

try? FileManager.default.removeItem(at: scratch)

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASSED")
