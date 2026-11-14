//
//  Tests for MCP connectors (leanring-buddy/Connectors).
//  Run with scripts/tests/run_connectors_tests.sh.
//
//  Pure logic first (JSON-RPC, SSE, config import, names, results, risk), then
//  end-to-end runs against two fake servers started here on this machine.
//  Nothing touches the real ~/.teachy or the real Keychain.
//

import Foundation

// MARK: - Tiny harness

nonisolated final class TestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var passCount = 0

    func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        lock.lock(); defer { lock.unlock() }
        if condition {
            passCount += 1
        } else {
            let extra = detail()
            failures.append(extra.isEmpty ? name : "\(name) — \(extra)")
            print("  FAIL: \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    func summary() -> (passed: Int, failures: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (passCount, failures)
    }
}

let log = TestLog()

func section(_ title: String) { print("• \(title)") }

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    log.check(actual == expected, name, "got \(actual), wanted \(expected)")
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// Collects what a peer sent, and session events.
nonisolated final class Collector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func add(_ item: Element) { lock.lock(); items.append(item); lock.unlock() }
    var all: [Element] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { all.count }
}

func frames(_ collector: Collector<Data>) -> [JSONValue] {
    collector.all.compactMap { try? JSONValue.parse($0) }
}

let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("teachy-connectors-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }

let inheritedPATH = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
let testPathProvider: @Sendable () async -> String = {
    McpShellEnvironment.mergedPATH(shellPATH: inheritedPATH, inheritedPATH: nil, homeDirectory: NSHomeDirectory())
}

// MARK: - JSON

func testJSON() throws {
    section("JSON values")
    let parsed = try JSONValue.parse(#"{"a":1,"b":true,"c":1.5,"d":null,"e":["x",2],"f":{"g":"h"},"zero":0,"one":1}"#)
    expectEqual(parsed["a"], .int(1), "integers stay integers")
    expectEqual(parsed["b"], .bool(true), "booleans stay booleans")
    expectEqual(parsed["zero"], .int(0), "0 is a number, not false")
    expectEqual(parsed["one"], .int(1), "1 is a number, not true")
    expectEqual(parsed["c"], .double(1.5), "doubles stay doubles")
    expectEqual(parsed["d"], .null, "null survives")
    expectEqual(parsed["e"]?.arrayValue?.count, 2, "arrays")
    expectEqual(parsed["f"]?["g"]?.stringValue, "h", "nested objects")

    let roundTripped = try JSONValue.parse(try parsed.serialized())
    expectEqual(roundTripped, parsed, "round trip keeps every type")

    let withNewline = JSONValue.object(["text": .string("line one\nline two")])
    let serialized = String(decoding: try withNewline.serialized(), as: UTF8.self)
    log.check(!serialized.contains("\n"), "serialised JSON is one line even when a string holds a newline")
    expectEqual(JSONValue(any: ["k": [1, "two", true] as [Any]] as [String: Any])["k"]?.arrayValue?.count, 3, "builds from [String: Any]")
}

// MARK: - JSON-RPC framing

func testFraming() throws {
    section("JSON-RPC framing")
    let request = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"cursor":"x"}}"#.utf8))
    expectEqual(request, [.request(id: .int(7), method: "tools/list", params: .object(["cursor": .string("x")]))], "parses a request")

    let notification = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
    expectEqual(notification, [.notification(method: "notifications/tools/list_changed", params: nil)], "parses a notification")

    let response = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"abc","result":{"ok":true}}"#.utf8))
    expectEqual(response, [.response(id: .string("abc"), result: .object(["ok": .bool(true)]))], "parses a response with a string id")

    let failure = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"nope","data":{"x":1}}}"#.utf8))
    expectEqual(failure, [.error(id: .int(3), error: JSONRPCErrorObject(code: -32601, message: "nope", data: .object(["x": .int(1)])))], "parses an error")

    let batch = try JSONRPCMessage.parse(Data(#"[{"jsonrpc":"2.0","id":1,"result":{}},{"not":"rpc"},{"jsonrpc":"2.0","method":"m"}]"#.utf8))
    expectEqual(batch.count, 2, "a batch keeps the valid entries and drops the rest")

    log.check((try? JSONRPCMessage.parse(Data(#"{"hello":"world"}"#.utf8))) == nil, "rejects JSON that isn't JSON-RPC")
    log.check((try? JSONRPCMessage.parse(Data("not json".utf8))) == nil, "rejects non-JSON")
    log.check((try? JSONRPCMessage.parse(Data(#"{"jsonrpc":"1.0","id":1,"result":{}}"#.utf8))) == nil, "rejects the wrong jsonrpc version")

    let encoded = try JSONRPCMessage.request(id: .int(1), method: "ping", params: nil).encoded()
    let encodedJSON = try JSONValue.parse(encoded)
    expectEqual(encodedJSON["jsonrpc"]?.stringValue, "2.0", "encodes jsonrpc 2.0")
    expectEqual(encodedJSON["id"], .int(1), "encodes the id as a number")
    log.check(encodedJSON["params"] == nil, "omits params when there are none")
    log.check(!encoded.contains(0x0A), "an encoded frame has no newline")
    let encodedError = try JSONValue.parse(try JSONRPCMessage.error(id: nil, error: JSONRPCErrorObject(code: -32700, message: "bad", data: nil)).encoded())
    expectEqual(encodedError["id"], .null, "an error without an id encodes id null")
}

// MARK: - JSON-RPC peer

func testPeer() async throws {
    section("JSON-RPC peer: id matching, timeouts, cancellation")

    // Responses arriving out of order go to the right callers.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        async let first = peer.request("first", params: .object(["n": .int(1)]))
        async let second = peer.request("second")
        _ = await waitUntil { sent.count == 2 }
        let sentFrames = frames(sent)
        let firstID = sentFrames.first { $0["method"]?.stringValue == "first" }?["id"]?.intValue ?? -1
        let secondID = sentFrames.first { $0["method"]?.stringValue == "second" }?["id"]?.intValue ?? -1
        log.check(firstID != secondID && firstID > 0 && secondID > 0, "each request gets its own id")
        await peer.receive(Data(#"{"jsonrpc":"2.0","id":\#(secondID),"result":{"who":"second"}}"#.utf8))
        await peer.receive(Data(#"{"jsonrpc":"2.0","id":\#(firstID),"result":{"who":"first"}}"#.utf8))
        let (firstResult, secondResult) = try await (first, second)
        expectEqual(firstResult["who"]?.stringValue, "first", "out-of-order response reaches the first caller")
        expectEqual(secondResult["who"]?.stringValue, "second", "out-of-order response reaches the second caller")
        expectEqual(await peer.pendingRequestCount, 0, "nothing left pending")
    }

    // An error response throws the server's error.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        async let failing = peer.request("fails")
        _ = await waitUntil { sent.count == 1 }
        await peer.receive(Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad params"}}"#.utf8))
        do {
            _ = try await failing
            log.check(false, "error response throws")
        } catch let error as JSONRPCErrorObject {
            expectEqual(error.code, -32602, "error response throws the server's code")
        }
    }

    // Timeout: throws, tells the server, ignores the late answer.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        let started = Date()
        do {
            _ = try await peer.request("slow", timeout: 0.15)
            log.check(false, "a request with no answer times out")
        } catch let error as JSONRPCPeerError {
            expectEqual(error, .timedOut(method: "slow", seconds: 0.15), "a request with no answer times out")
        }
        log.check(Date().timeIntervalSince(started) < 2, "the timeout fires promptly")
        _ = await waitUntil { sent.count == 2 }
        let cancelNotice = frames(sent).first { $0["method"]?.stringValue == "notifications/cancelled" }
        expectEqual(cancelNotice?["params"]?["requestId"], .int(1), "a timed-out request is cancelled on the server by id")
        await peer.receive(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        expectEqual(await peer.pendingRequestCount, 0, "a late answer to a timed-out request is ignored")
    }

    // `initialize` must never be cancelled.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        _ = try? await peer.request("initialize", timeout: 0.05)
        try? await Task.sleep(nanoseconds: 100_000_000)
        log.check(!frames(sent).contains { $0["method"]?.stringValue == "notifications/cancelled" }, "a timed-out initialize sends no cancellation")
    }

    // Cancelling the calling task.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        let task = Task { try await peer.request("long", timeout: 30) }
        _ = await waitUntil { sent.count == 1 }
        task.cancel()
        do {
            _ = try await task.value
            log.check(false, "cancelling the caller cancels the request")
        } catch {
            log.check(error is CancellationError, "cancelling the caller throws CancellationError", "\(error)")
        }
        _ = await waitUntil { sent.count == 2 }
        log.check(frames(sent).contains { $0["method"]?.stringValue == "notifications/cancelled" && $0["params"]?["requestId"] == .int(1) }, "the server is told about the cancellation")
        expectEqual(await peer.pendingRequestCount, 0, "a cancelled request is no longer pending")
    }

    // A send that fails surfaces to the caller instead of hanging.
    do {
        let peer = JSONRPCPeer(sender: { _ in throw McpError.notConnected })
        do {
            _ = try await peer.request("x", timeout: 5)
            log.check(false, "a failed send fails the request")
        } catch {
            expectEqual(error as? McpError, .notConnected, "a failed send fails the request")
        }
    }

    // Requests from the server: ping is answered, everything else declined.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        await peer.receive(Data(#"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#.utf8))
        await peer.receive(Data(#"{"jsonrpc":"2.0","id":99,"method":"sampling/createMessage","params":{}}"#.utf8))
        let replies = frames(sent)
        expectEqual(replies.first { $0["id"] == .string("p1") }?["result"], .object([:]), "a server ping gets an empty result")
        expectEqual(replies.first { $0["id"] == .int(99) }?["error"]?["code"], .int(-32601), "sampling is declined with method-not-found")
    }

    // Notifications reach the handler; junk is counted, not fatal.
    do {
        let seen = Collector<String>()
        let peer = JSONRPCPeer(sender: { _ in })
        await peer.setNotificationHandler { method, _ in seen.add(method) }
        await peer.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
        await peer.receive(Data("Server listening on stdio".utf8))
        _ = await waitUntil { seen.count == 1 }
        expectEqual(seen.all, ["notifications/tools/list_changed"], "notifications reach the handler")
        expectEqual(await peer.unparseableFrameCount, 1, "a non-JSON frame is counted and skipped")
    }

    // Closing fails what's in flight and everything after.
    do {
        let sent = Collector<Data>()
        let peer = JSONRPCPeer(sender: { sent.add($0) })
        async let pending = peer.request("never", timeout: 30)
        _ = await waitUntil { sent.count == 1 }
        await peer.close(error: McpError.processExited(code: 1, stderrTail: "bye"))
        do {
            _ = try await pending
            log.check(false, "closing fails pending requests")
        } catch {
            expectEqual(error as? McpError, .processExited(code: 1, stderrTail: "bye"), "closing fails pending requests with the reason")
        }
        do {
            _ = try await peer.request("after")
            log.check(false, "requests after close fail")
        } catch {
            log.check(true, "requests after close fail")
        }
    }
}

// MARK: - SSE

func testSSE() {
    section("SSE parsing")
    var parser = SSEParser()
    var events = parser.feed("data: first line\ndata: second line\n\n")
    expectEqual(events, [SSEEvent(event: "message", data: "first line\nsecond line", id: nil, retryMilliseconds: nil)], "multi-line data joins with newlines")

    parser = SSEParser()
    events = parser.feed(": this is a comment\n\n:another\ndata: real\n\n")
    expectEqual(events.map(\.data), ["real"], "comments are ignored and don't make events")

    parser = SSEParser()
    events = parser.feed("event: endpoint\ndata: /messages?session=1\nid: 42\nretry: 1500\n\n")
    expectEqual(events, [SSEEvent(event: "endpoint", data: "/messages?session=1", id: "42", retryMilliseconds: 1500)], "event name, id and retry are read")
    events = parser.feed("data: next\n\n")
    expectEqual(events.first?.event, "message", "the event name resets after each event")
    expectEqual(events.first?.id, "42", "the last event id sticks")
    expectEqual(parser.lastEventID, "42", "lastEventID is exposed for reconnects")

    // Any chunking gives the same events as one big chunk.
    let stream = ": hello\r\nevent: message\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\ndata:no-space\n\ndata: caf\u{00E9} \u{1F600}\rid: 7\r\rdata\n\n"
    var wholeParser = SSEParser()
    let expected = wholeParser.feed(stream)
    expectEqual(expected.map(\.data), ["{\"a\":\n1}", "no-space", "caf\u{00E9} \u{1F600}", ""], "CRLF, CR and LF endings, missing space, and a bare `data` line")
    let streamBytes = Data(stream.utf8)
    var allSplitsMatch = true
    for chunkSize in [1, 2, 3, 5, 7, 11] {
        var chunkedParser = SSEParser()
        var collected: [SSEEvent] = []
        var offset = 0
        while offset < streamBytes.count {
            let end = min(offset + chunkSize, streamBytes.count)
            collected.append(contentsOf: chunkedParser.feed(streamBytes.subdata(in: offset..<end)))
            offset = end
        }
        if collected != expected { allSplitsMatch = false }
    }
    log.check(allSplitsMatch, "split chunks (even mid-character and mid-CRLF) give the same events")

    parser = SSEParser()
    expectEqual(parser.feed("data: unfinished\n").count, 0, "no event until the blank line arrives")
    expectEqual(parser.feed("\n").map(\.data), ["unfinished"], "the blank line completes it")

    parser = SSEParser()
    expectEqual(parser.feed("event: ping\n\n").count, 0, "a block with no data makes no event")
    expectEqual(parser.feed("data: after\n\n").first?.event, "message", "and its event name doesn't leak into the next one")

    parser = SSEParser()
    expectEqual(parser.feed("\u{FEFF}data: bom\n\n").map(\.data), ["bom"], "a leading byte-order mark is dropped")
    parser = SSEParser()
    expectEqual(parser.feed("data:  two spaces\n\n").map(\.data), [" two spaces"], "only one leading space is stripped")
    parser = SSEParser()
    expectEqual(parser.feed("unknown: x\ndata: ok\n\n").map(\.data), ["ok"], "unknown fields are ignored")
}

// MARK: - Config: import, store, drafts

func testConfig() throws {
    section("Config import and the store")

    let claudeDesktopStyle = #"""
    {
      "mcpServers": {
        "GitHub": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-github", "--api-key", "arg-secret-999", "--token=inline-secret-555"],
          "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_supersecret123", "LOG_LEVEL": "debug", "PLAIN": "sk-looks-like-a-key"}
        },
        "linear": {
          "url": "https://mcp.linear.app/mcp",
          "headers": {"Authorization": "Bearer lin_api_secret456", "X-Workspace-Key": "workspace-secret-789", "Accept": "application/json"}
        },
        "off": {"command": "uvx", "args": ["some-server"], "disabled": true}
      }
    }
    """#
    let imported = try McpConfigImporter.parse(claudeDesktopStyle)
    expectEqual(imported.map(\.config.id), ["github", "linear", "off"], "one connector per server, ids from names")

    let github = imported[0]
    guard case .stdio(let command, let arguments, let environment, let secretEnvironment, _) = github.config.transport else {
        log.check(false, "GitHub imports as a local command"); return
    }
    expectEqual(command, "npx", "command is kept")
    expectEqual(arguments, ["-y", "@modelcontextprotocol/server-github", "--api-key", "${TEACHY_SECRET_1}", "--token=${TEACHY_SECRET_2}"], "secrets in arguments become placeholders")
    expectEqual(environment, ["LOG_LEVEL": "debug"], "harmless env stays in the file")
    expectEqual(secretEnvironment["GITHUB_PERSONAL_ACCESS_TOKEN"], "github.env.GITHUB_PERSONAL_ACCESS_TOKEN", "secret env is a Keychain reference")
    expectEqual(github.secrets["github.env.GITHUB_PERSONAL_ACCESS_TOKEN"], "ghp_supersecret123", "the env secret goes to the Keychain")
    expectEqual(github.secrets["github.env.PLAIN"], "sk-looks-like-a-key", "a secret-looking value is caught even under a plain name")
    expectEqual(github.secrets["github.env.TEACHY_SECRET_1"], "arg-secret-999", "the --api-key argument goes to the Keychain")
    expectEqual(github.secrets["github.env.TEACHY_SECRET_2"], "inline-secret-555", "the --token=… argument goes to the Keychain")
    expectEqual(
        McpConfigImporter.expandArgumentSecrets(arguments, values: ["TEACHY_SECRET_1": "arg-secret-999", "TEACHY_SECRET_2": "inline-secret-555"]),
        ["-y", "@modelcontextprotocol/server-github", "--api-key", "arg-secret-999", "--token=inline-secret-555"],
        "placeholders expand back at launch"
    )

    let linear = imported[1]
    guard case .http(let url, let headers, let secretHeaders) = linear.config.transport else {
        log.check(false, "linear imports as a remote server"); return
    }
    expectEqual(url, "https://mcp.linear.app/mcp", "url is kept")
    expectEqual(linear.config.auth, .bearer(keychainRef: "linear.bearer", header: "Authorization", scheme: "Bearer"), "Authorization header becomes bearer auth")
    expectEqual(linear.secrets["linear.bearer"], "lin_api_secret456", "the bearer token goes to the Keychain without its scheme")
    expectEqual(headers, ["Accept": "application/json"], "harmless headers stay in the file")
    expectEqual(secretHeaders, ["X-Workspace-Key": "linear.header.X-Workspace-Key"], "other headers become Keychain references")
    expectEqual(linear.secrets["linear.header.X-Workspace-Key"], "workspace-secret-789", "and their values go to the Keychain")
    expectEqual(imported[2].config.enabled, false, "\"disabled\": true imports switched off")

    // Save it and make sure no secret reached the disk.
    let storeURL = temporaryRoot.appendingPathComponent("import/mcp.json")
    let store = McpConnectorStore(fileURL: storeURL)
    try store.save(imported.map(\.config))
    let savedText = try String(contentsOf: storeURL, encoding: .utf8)
    for secret in ["ghp_supersecret123", "lin_api_secret456", "workspace-secret-789", "arg-secret-999", "inline-secret-555", "sk-looks-like-a-key"] {
        log.check(!savedText.contains(secret), "mcp.json doesn't contain the secret \(secret.prefix(8))…")
    }
    log.check(savedText.contains("keychainRef"), "mcp.json holds references instead")
    let reloaded = store.load()
    expectEqual(reloaded.connectors, imported.map(\.config), "the store round-trips every field")
    log.check(reloaded.problem == nil, "a good file loads without complaint")
    let permissions = (try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber)?.intValue
    expectEqual(permissions, 0o600, "mcp.json is readable only by the owner")

    // Teachy's own format imports too, and ids never collide with what's there.
    let reimported = try McpConfigImporter.parse(savedText, existingIDs: ["github"])
    expectEqual(reimported.map(\.config.id), ["github_2", "linear", "off"], "importing Teachy's own file renames clashing ids")
    log.check(reimported.allSatisfy { $0.secrets.isEmpty }, "Teachy's own file carries no secrets to import")
    expectEqual(try McpConfigImporter.parse(claudeDesktopStyle, existingIDs: ["github", "linear"]).map(\.config.id), ["github_2", "linear_2", "off"], "pasted configs avoid existing ids")

    // Other shapes people paste.
    let fragment = try McpConfigImporter.parse(#""weather": {"command": "uvx", "args": ["weather-mcp"]}"#)
    expectEqual(fragment.map(\.config.id), ["weather"], "a fragment without outer braces works")
    let bareMap = try McpConfigImporter.parse(#"{"notes": {"url": "http://localhost:8080/mcp"}}"#)
    expectEqual(bareMap.first?.config.targetSummary, "http://localhost:8080/mcp", "a bare name → server map works")
    let single = try McpConfigImporter.parse(#"{"url": "https://mcp.example.com/sse"}"#)
    expectEqual(single.first?.config.label, "mcp.example.com", "a single remote entry is named after its host")
    let vscodeStyle = try McpConfigImporter.parse(#"{"servers": {"fs": {"type": "stdio", "command": "node", "args": ["server.js"]}}}"#)
    expectEqual(vscodeStyle.first?.config.id, "fs", "a \"servers\" block works")

    expectEqual((try? McpConfigImporter.parse("definitely not json")) == nil, true, "garbage is refused")
    do { _ = try McpConfigImporter.parse("{}"); log.check(false, "an empty config is refused") }
    catch { expectEqual(error as? McpConfigImportError, .noServers, "an empty config is refused") }
    do { _ = try McpConfigImporter.parse(#"{"mcpServers": {"bad": {"args": []}}}"#); log.check(false, "an entry with neither command nor url is refused") }
    catch { log.check(error is McpConfigImportError, "an entry with neither command nor url is refused") }
    do {
        _ = try McpConfigImporter.parse(#"{"mcpServers": {"leaky": {"url": "http://example.com/mcp", "headers": {"Authorization": "Bearer abc"}}}}"#)
        log.check(false, "a token over plain http to another machine is refused")
    } catch { log.check(error is McpConfigImportError, "a token over plain http to another machine is refused") }

    // An unreadable file is set aside, never overwritten.
    let brokenURL = temporaryRoot.appendingPathComponent("broken/mcp.json")
    try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ this is not json".write(to: brokenURL, atomically: true, encoding: .utf8)
    let brokenLoad = McpConnectorStore(fileURL: brokenURL).load()
    log.check(brokenLoad.connectors.isEmpty && brokenLoad.problem != nil, "an unreadable mcp.json is reported")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: brokenURL.deletingLastPathComponent().path)
    log.check(leftovers.contains { $0.hasPrefix("mcp.unreadable-") } && !leftovers.contains("mcp.json"), "and set aside rather than overwritten")
    expectEqual(McpConnectorStore(fileURL: temporaryRoot.appendingPathComponent("nowhere/mcp.json")).load().connectors.count, 0, "a missing file is an empty list")

    section("Add-connector form")
    let remoteDraft = try McpConnectorDraft(label: "Linear", serverURL: " https://mcp.linear.app/mcp ", apiKey: "Bearer abc123", accountLabel: "Work").build(existingIDs: [])
    expectEqual(remoteDraft.config.id, "linear_work", "the id combines label and account")
    expectEqual(remoteDraft.config.displayName, "Linear · Work", "the display name shows the account")
    expectEqual(remoteDraft.config.auth, .bearer(keychainRef: "linear_work.bearer", header: "Authorization", scheme: "Bearer"), "an API key becomes bearer auth")
    expectEqual(remoteDraft.secrets, ["linear_work.bearer": "abc123"], "a pasted \"Bearer \" prefix is stripped")

    let secondAccount = try McpConnectorDraft(label: "Linear", serverURL: "https://mcp.linear.app/mcp", accountLabel: "Personal").build(existingIDs: ["linear_work"])
    expectEqual(secondAccount.config.id, "linear_personal", "a second account on the same server gets its own id")
    expectEqual(secondAccount.config.auth, McpConnectorConfig.Auth.none, "no key means no auth (sign-in comes later if needed)")

    let customHeader = try McpConnectorDraft(label: "Search", serverURL: "https://api.example.com/mcp", apiKey: "X-API-Key: k-42").build(existingIDs: [])
    expectEqual(customHeader.config.auth, .bearer(keychainRef: "search.bearer", header: "X-API-Key", scheme: ""), "\"Header: value\" sets a custom key header")
    expectEqual(customHeader.secrets["search.bearer"], "k-42", "with the bare value as the secret")

    let localDraft = try McpConnectorDraft(label: "Files", commandLine: "API_KEY=abc DEBUG=1 npx -y \"@scope/server name\" --root '/Users/me/My Docs'").build(existingIDs: [])
    guard case .stdio(let draftCommand, let draftArguments, let draftEnvironment, let draftSecretEnvironment, _) = localDraft.config.transport else {
        log.check(false, "a command draft is a local connector"); return
    }
    expectEqual(draftCommand, "npx", "leading NAME=value words aren't the command")
    expectEqual(draftArguments, ["-y", "@scope/server name", "--root", "/Users/me/My Docs"], "quotes group arguments")
    expectEqual(draftEnvironment, ["DEBUG": "1"], "plain variables stay in the file")
    expectEqual(draftSecretEnvironment, ["API_KEY": "files.env.API_KEY"], "key-like variables go to the Keychain")
    expectEqual(localDraft.secrets, ["files.env.API_KEY": "abc"], "with their values")

    log.check((try? McpConnectorDraft(label: "", serverURL: "https://x.dev").build(existingIDs: [])) == nil, "a name is required")
    log.check((try? McpConnectorDraft(label: "X").build(existingIDs: [])) == nil, "a URL or a command is required")
    log.check((try? McpConnectorDraft(label: "X", serverURL: "https://x.dev", commandLine: "npx y").build(existingIDs: [])) == nil, "not both")
    log.check((try? McpConnectorDraft(label: "X", serverURL: "not a url").build(existingIDs: [])) == nil, "a malformed URL is refused")
    log.check((try? McpConnectorDraft(label: "X", serverURL: "http://example.com/mcp", apiKey: "k").build(existingIDs: [])) == nil, "a key over plain http to another machine is refused")
    log.check((try? McpConnectorDraft(label: "X", serverURL: "http://localhost:3000/mcp", apiKey: "k").build(existingIDs: [])) != nil, "plain http to this Mac is fine")
    expectEqual(McpCommandLine.split(#"a "b c" 'd e' f\ g "" "h\"i""#), ["a", "b c", "d e", "f g", "", "h\"i"], "command-line splitting")
    log.check(McpCommandLine.environmentAssignment("9X=1") == nil && McpCommandLine.environmentAssignment("--flag=1") == nil, "only real variable names count as assignments")
}

// MARK: - Names, results, risk, states

func testToolModel() throws {
    section("Tool names")
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    expectEqual(McpToolNaming.sanitise("delete everything!"), "delete_everything_", "spaces and punctuation become underscores")
    expectEqual(McpToolNaming.sanitise("créer.issue/v2"), "cr_er_issue_v2", "non-ASCII and separators become underscores")
    expectEqual(McpToolNaming.sanitiseConnectorID("My  Linear (Work)!"), "my_linear_work", "connector ids are tidy lowercase")
    log.check(!McpToolNaming.sanitiseConnectorID("a__b____c").contains("__"), "a connector id never contains the __ separator")
    expectEqual(McpToolNaming.sanitiseConnectorID("!!!"), "connector", "an id with nothing usable falls back")
    expectEqual(McpConnectorIdentity.makeID(label: "Linear", existing: ["linear", "linear_2"]), "linear_3", "ids are made unique")

    expectEqual(McpToolNaming.registeredNames(connectorID: "linear", toolNames: ["create_issue", "list-issues"]), ["mcp__linear__create_issue", "mcp__linear__list-issues"], "names are mcp__<connector>__<tool>")

    let collisions = McpToolNaming.registeredNames(connectorID: "srv", toolNames: ["a.b", "a/b", "a b", "a_b", "a.b"])
    expectEqual(Set(collisions).count, 5, "tools that sanitise alike still get distinct names")
    expectEqual(collisions[0], "mcp__srv__a_b", "the first keeps the plain name")
    expectEqual(collisions, McpToolNaming.registeredNames(connectorID: "srv", toolNames: ["a.b", "a/b", "a b", "a_b", "a.b"]), "naming is stable from run to run")

    let longName = String(repeating: "very_long_tool_name_", count: 6)
    let longNames = McpToolNaming.registeredNames(connectorID: "a_connector_with_a_long_id", toolNames: [longName, longName + "x", "", "ok"])
    log.check(longNames.allSatisfy { $0.count <= 64 }, "every name is at most 64 characters", "\(longNames.map(\.count))")
    expectEqual(Set(longNames).count, 4, "shortened names stay distinct")
    log.check((collisions + longNames).allSatisfy { $0.unicodeScalars.allSatisfy(allowed.contains) }, "every name uses only [a-zA-Z0-9_-]")
    log.check(longNames[2].hasSuffix("__tool"), "an empty tool name becomes \"tool\"")

    section("Tool results")
    func flatten(_ json: String, limit: Int = 20_000) throws -> String {
        McpContentFlattener.flatten(try JSONValue.parse(json), maximumCharacters: limit)
    }
    expectEqual(try flatten(#"{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}"#), "one\ntwo", "text blocks join with newlines")
    expectEqual(try flatten(#"{"content":[{"type":"text","text":"see"},{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"audio","data":"AAAA"}]}"#), "see\n[image]\n[audio]", "images and audio are noted, not dumped")
    expectEqual(try flatten(#"{"content":[{"type":"text","text":"no such issue"}],"isError":true}"#), "The tool reported an error: no such issue", "isError is surfaced")
    expectEqual(try flatten(#"{"content":[],"isError":true}"#), "The tool reported an error.", "isError with no text still says so")
    expectEqual(try flatten(#"{"content":[]}"#), "(the tool returned nothing)", "an empty result says so")
    expectEqual(try flatten(#"{"content":[],"structuredContent":{"b":2,"a":1}}"#), #"{"a":1,"b":2}"#, "structured-only results become JSON")
    expectEqual(try flatten(#"{"content":[{"type":"text","text":"shown"}],"structuredContent":{"a":1}}"#), "shown", "text wins over structured content")
    expectEqual(try flatten(#"{"content":[{"type":"resource","resource":{"uri":"file:///a.txt","text":"file body"}},{"type":"resource","resource":{"uri":"file:///b.bin","blob":"AAAA"}},{"type":"resource_link","uri":"file:///c","name":"c.txt"}]}"#), "file body\n[resource file:///b.bin]\n[link: c.txt file:///c]", "embedded resources and links")
    expectEqual(try flatten(#"{"content":[{"type":"hologram"}]}"#), "[unsupported content]", "unknown content types don't crash")
    let truncated = try flatten(#"{"content":[{"type":"text","text":"\#(String(repeating: "x", count: 500))"}]}"#, limit: 100)
    log.check(truncated.hasPrefix(String(repeating: "x", count: 100)) && truncated.contains("cut 400 more characters") && truncated.count < 140, "long results are cut with a note")

    section("Risk from annotations")
    func risk(_ json: String?) throws -> McpToolRisk { McpToolRisk.from(annotations: try json.map { try JSONValue.parse($0) }) }
    expectEqual(try risk(nil), .unknown, "no annotations → unknown")
    expectEqual(try risk("{}"), .unknown, "empty annotations → unknown")
    expectEqual(try risk(#"{"title":"Nice name","openWorldHint":true}"#), .unknown, "annotations without the two hints → unknown")
    expectEqual(try risk(#"{"readOnlyHint":true}"#), .readOnly, "readOnlyHint true → read-only")
    expectEqual(try risk(#"{"readOnlyHint":false,"destructiveHint":false}"#), .writes, "not read-only, not destructive → writes")
    expectEqual(try risk(#"{"destructiveHint":false}"#), .writes, "destructiveHint false alone → writes")
    expectEqual(try risk(#"{"readOnlyHint":false,"destructiveHint":true}"#), .destructive, "destructiveHint true → destructive")
    expectEqual(try risk(#"{"readOnlyHint":false}"#), .destructive, "not read-only and silent on destructive → destructive (the spec's default)")
    expectEqual(try risk(#"{"readOnlyHint":true,"destructiveHint":true}"#), .destructive, "contradictory hints → the scarier one")
    expectEqual(try risk(#"{"readOnlyHint":"yes"}"#), .unknown, "a hint of the wrong type is ignored")
    expectEqual(McpToolRisk.unknown.effective, .writes, "unknown is treated as writes")
    expectEqual(McpToolRisk.readOnly.effective, .readOnly, "known risks are unchanged")

    let descriptor = McpToolDescriptor(json: try JSONValue.parse(#"{"name":"search","annotations":{"title":"Search the web","readOnlyHint":true,"openWorldHint":true}}"#))
    expectEqual(descriptor?.openWorld, true, "openWorldHint is exposed")
    expectEqual(descriptor?.title, "Search the web", "the annotation title is the fallback title")
    expectEqual(descriptor?.inputSchema, McpToolDescriptor.emptySchema, "a missing schema becomes an empty object schema")
    log.check(McpToolDescriptor(json: try JSONValue.parse(#"{"description":"nameless"}"#)) == nil, "a tool without a name is dropped")
    expectEqual(McpToolDescriptor(json: try JSONValue.parse(#"{"name":"t","inputSchema":{"properties":{"q":{"type":"string"}}}}"#))?.inputSchema["type"], .string("object"), "a schema missing its type is repaired")

    section("Connector states")
    let bearer = McpConnectorConfig.Auth.bearer(keychainRef: "x", header: "Authorization", scheme: "Bearer")
    expectEqual(McpConnectorState.describing(McpError.unauthorized(hadCredentials: true, wwwAuthenticate: nil), auth: bearer), .tokenRejected, "401 with an API key → token rejected")
    expectEqual(McpConnectorState.describing(McpError.unauthorized(hadCredentials: false, wwwAuthenticate: nil), auth: .none), .needsSignIn, "401 with nothing → needs sign-in")
    expectEqual(McpConnectorState.describing(McpError.unauthorized(hadCredentials: true, wwwAuthenticate: nil), auth: .oauth), .needsSignIn, "401 after sign-in → needs sign-in again")
    expectEqual(McpConnectorState.describing(McpError.needsSignIn, auth: .oauth), .needsSignIn, "no token yet → needs sign-in")
    expectEqual(McpConnectorState.describing(McpError.commandNotFound("npx"), auth: .none), .failed("Couldn't find \"npx\" on this Mac. Check it is installed and on your PATH."), "other errors show their sentence")
    expectEqual(McpConnectorState.connected(toolCount: 1).summary, "Connected · 1 tool", "singular tool count")
    expectEqual(McpConnectorState.connected(toolCount: 12).summary, "Connected · 12 tools", "plural tool count")
    expectEqual(McpConnectorState.checking.summary, "Checking…", "checking label")
    expectEqual(McpConnectorState.tokenRejected.summary, "Token rejected", "token rejected label")
}

// MARK: - Shell PATH, OAuth helpers

func testEnvironmentAndOAuthHelpers() async throws {
    section("Login-shell PATH")
    expectEqual(McpShellEnvironment.parsePATH(fromShellOutput: "Welcome back!\n__TEACHY_PATH_START__/opt/homebrew/bin:/usr/bin__TEACHY_PATH_END__\nbye"), "/opt/homebrew/bin:/usr/bin", "the PATH is found between the markers, banners ignored")
    log.check(McpShellEnvironment.parsePATH(fromShellOutput: "no markers here") == nil, "no markers → nil")
    expectEqual(McpShellEnvironment.mergedPATH(shellPATH: "/a:/b", inheritedPATH: "/b:/c", homeDirectory: "/Users/x").components(separatedBy: ":").prefix(3).joined(separator: ":"), "/a:/b:/c", "shell PATH first, then inherited, without repeats")
    log.check(McpShellEnvironment.mergedPATH(shellPATH: nil, inheritedPATH: nil, homeDirectory: "/Users/x").contains("/opt/homebrew/bin"), "the usual install folders are always included")
    expectEqual(McpShellEnvironment.resolveExecutable("sh", searchPATH: "/nonexistent:/bin"), "/bin/sh", "bare commands are found on the PATH")
    expectEqual(McpShellEnvironment.resolveExecutable("/bin/sh", searchPATH: ""), "/bin/sh", "absolute paths are used as they are")
    log.check(McpShellEnvironment.resolveExecutable("definitely-not-a-command-xyz", searchPATH: "/bin:/usr/bin") == nil, "a missing command is nil")
    log.check(McpShellEnvironment.resolveExecutable("/bin", searchPATH: "") == nil, "a folder is not a command")
    let shellPATH = await McpShellEnvironment.askLoginShellForPATH(shell: "/bin/sh", timeout: 10)
    log.check(shellPATH?.contains("/bin") == true, "asking a real shell for its PATH works", "\(shellPATH ?? "nil")")
    log.check(await McpShellEnvironment.askLoginShellForPATH(shell: "/nonexistent/shell", timeout: 1) == nil, "a missing shell gives nil instead of hanging")

    section("OAuth helpers")
    let challenge = McpOAuthDiscovery.parseChallenge(#"Bearer realm="mcp", resource_metadata="https://api.example.com/.well-known/oauth-protected-resource/mcp", scope="read write", error=invalid_token"#)
    expectEqual(challenge["resource_metadata"], "https://api.example.com/.well-known/oauth-protected-resource/mcp", "resource_metadata is read from WWW-Authenticate")
    expectEqual(challenge["scope"], "read write", "a quoted scope with a space is read whole")
    expectEqual(challenge["error"], "invalid_token", "unquoted values are read")
    expectEqual(McpOAuthDiscovery.parseChallenge(nil), [:], "no header → nothing")
    expectEqual(
        McpOAuthDiscovery.protectedResourceMetadataURLs(for: URL(string: "https://api.example.com/v1/mcp/")!).map(\.absoluteString),
        ["https://api.example.com/.well-known/oauth-protected-resource/v1/mcp", "https://api.example.com/.well-known/oauth-protected-resource"],
        "protected-resource metadata: path-specific first, then root"
    )
    expectEqual(
        McpOAuthDiscovery.authorizationServerMetadataURLs(forIssuer: URL(string: "https://auth.example.com/tenant1")!).map(\.absoluteString),
        ["https://auth.example.com/.well-known/oauth-authorization-server/tenant1", "https://auth.example.com/.well-known/openid-configuration/tenant1", "https://auth.example.com/tenant1/.well-known/openid-configuration"],
        "authorization-server metadata for an issuer with a path"
    )
    expectEqual(
        McpOAuthDiscovery.authorizationServerMetadataURLs(forIssuer: URL(string: "https://auth.example.com")!).map(\.absoluteString),
        ["https://auth.example.com/.well-known/oauth-authorization-server", "https://auth.example.com/.well-known/openid-configuration"],
        "authorization-server metadata for a bare issuer"
    )
    expectEqual(McpOAuthDiscovery.canonicalResource(for: URL(string: "HTTPS://API.Example.com/mcp?x=1#frag")!), "https://api.example.com/mcp", "the resource is the server URL without query or fragment")
    // Expected value computed independently (Python hashlib + urlsafe base64, padding removed).
    expectEqual(McpPKCE.challenge(forVerifier: "teachy-test-verifier-0123456789-abcdefghijklmnop"), "p8WJDSWfO41H5RWUQyb-weP41qwZtGnDkN5cl7Y4i5A", "the S256 challenge matches an independent SHA-256")
    let verifier = McpPKCE.randomURLSafeString(byteCount: 48)
    log.check(verifier.count >= 43 && !verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"), "verifiers are long and URL-safe")
    log.check(McpPKCE.randomURLSafeString() != McpPKCE.randomURLSafeString(), "verifiers are random")
    log.check(McpOAuthDiscovery.isAcceptableEndpoint(URL(string: "https://auth.example.com/token")!), "https endpoints are fine")
    log.check(!McpOAuthDiscovery.isAcceptableEndpoint(URL(string: "http://auth.example.com/token")!), "plain-http endpoints on other machines are refused")
    expectEqual(String(decoding: McpOAuthDiscovery.formEncode([("a b", "c&d=e"), ("redirect_uri", "http://127.0.0.1:1/callback")]), as: UTF8.self), "a%20b=c%26d%3De&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback", "form encoding escapes everything risky")
    let now = Date(timeIntervalSince1970: 1_000)
    let firstTokens = McpOAuthDiscovery.tokens(fromTokenResponse: try JSONValue.parse(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#), previous: nil, now: now)
    expectEqual(firstTokens, McpOAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date(timeIntervalSince1970: 4_600), scope: nil), "a token response is read")
    expectEqual(McpOAuthDiscovery.tokens(fromTokenResponse: try JSONValue.parse(#"{"access_token":"a2"}"#), previous: firstTokens, now: now)?.refreshToken, "r1", "a refresh that returns no refresh token keeps the old one")
    log.check(McpOAuthDiscovery.tokens(fromTokenResponse: try JSONValue.parse(#"{"error":"invalid_grant"}"#), previous: nil) == nil, "an error response yields no tokens")
}

// MARK: - End to end: stdio

func writeScript(_ source: String, named name: String) throws -> String {
    let url = temporaryRoot.appendingPathComponent(name)
    try source.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

func processIsAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

func testStdioEndToEnd() async throws {
    section("End to end: a fake stdio MCP server")
    let scriptPath = try writeScript(FakeServers.stdioServerSource, named: "fake_stdio_server.py")
    let events = Collector<McpSessionEvent>()
    let transports = Collector<McpStdioTransport>()

    var options = McpSessionOptions()
    options.restartBackoffBase = 0.1
    options.requestTimeout = 10
    let session = McpSession(
        options: options,
        makeTransport: {
            let transport = McpStdioTransport(
                command: "python3",
                arguments: [scriptPath, "--flag", "value with spaces"],
                environment: ["FAKE_SECRET": "hunter2-secret", "FAKE_PLAIN": "visible"],
                redactions: ["hunter2-secret"],
                pathProvider: testPathProvider
            )
            transports.add(transport)
            return transport
        },
        onEvent: { events.add($0) }
    )

    let tools = try await session.connect()
    expectEqual(tools.map(\.name), ["echo", "add", "delete everything!", "boom", "crash", "grow", "getenv", "argv", "ask_client", "client_answers", "picture"], "tools/list follows the cursor across every page")
    let info = await session.serverInfo
    expectEqual(info?.name, "fake-stdio", "initialize returns the server's name")
    expectEqual(info?.protocolVersion, McpSessionOptions.supportedProtocolVersions[0], "the protocol version is negotiated")
    expectEqual(tools[0].risk, .readOnly, "echo is tagged read-only from its annotations")
    expectEqual(tools[0].openWorld, false, "echo's openWorldHint is read")
    expectEqual(tools[1].risk, .unknown, "add has no annotations → unknown")
    expectEqual(tools[2].risk, .destructive, "the delete tool is tagged destructive")
    expectEqual(tools[3].risk, .writes, "boom is tagged writes")

    let echo = try await session.callTool(name: "echo", arguments: .object(["text": .string("héllo wörld")]))
    expectEqual(McpContentFlattener.flatten(echo), "héllo wörld", "echo round-trips text, accents included")
    let sum = try await session.callTool(name: "add", arguments: .object(["a": .int(2), "b": .int(40)]))
    expectEqual(McpContentFlattener.flatten(sum), "42", "add adds")
    let big = String(repeating: "A long line of text. ", count: 20_000) // ~420 KB, well past a pipe buffer
    let bigEcho = try await session.callTool(name: "echo", arguments: .object(["text": .string(big)]))
    expectEqual(bigEcho["content"]?.arrayValue?.first?["text"]?.stringValue?.count, big.count, "a message far bigger than the pipe buffer survives both ways")
    let boom = try await session.callTool(name: "boom", arguments: .object([:]))
    expectEqual(McpContentFlattener.flatten(boom), "The tool reported an error: it broke", "a tool-level error comes back as text")
    let picture = try await session.callTool(name: "picture", arguments: .object([:]))
    expectEqual(McpContentFlattener.flatten(picture), "here you go\n[image]", "images are noted")

    do {
        _ = try await session.callTool(name: "no_such_tool", arguments: .object([:]))
        log.check(false, "an unknown tool throws")
    } catch let error as JSONRPCErrorObject {
        expectEqual(error.code, -32602, "an unknown tool throws the server's JSON-RPC error")
    }

    let plainEnv = try await session.callTool(name: "getenv", arguments: .object(["name": .string("FAKE_PLAIN")]))
    expectEqual(McpContentFlattener.flatten(plainEnv), "visible", "configured environment reaches the server")
    let pathEnv = try await session.callTool(name: "getenv", arguments: .object(["name": .string("PATH")]))
    log.check(McpContentFlattener.flatten(pathEnv).contains("/usr/bin"), "the server gets a real PATH")
    let argv = try await session.callTool(name: "argv", arguments: .object([:]))
    expectEqual(McpContentFlattener.flatten(argv), #"["--flag", "value with spaces"]"#, "arguments arrive unsplit")

    try await session.ping()
    log.check(true, "ping is answered")

    // The server asks the client things.
    _ = try await session.callTool(name: "ask_client", arguments: .object([:]))
    var clientAnswers: [JSONValue] = []
    _ = await waitUntil {
        guard let result = try? await session.callTool(name: "client_answers", arguments: .object([:])),
              let parsed = try? JSONValue.parse(McpContentFlattener.flatten(result)), let list = parsed.arrayValue else { return false }
        clientAnswers = list
        return list.count >= 3
    }
    expectEqual(clientAnswers.first { $0["id"] == .string("srv-ping") }?["result"], .object([:]), "the client answers the server's ping")
    expectEqual(clientAnswers.first { $0["id"] == .string("srv-sampling") }?["error"]?["code"], .int(-32601), "the client declines sampling")
    expectEqual(clientAnswers.first { $0["id"] == .string("srv-roots") }?["error"]?["code"], .int(-32601), "the client declines roots")

    // stderr is captured, the stdout banner didn't break anything, and our secret is hidden.
    let diagnostics = await session.diagnostics()
    log.check(diagnostics.contains("fake server ready"), "stderr is captured for diagnostics")
    log.check(diagnostics.contains("fake server starting up"), "a non-JSON stdout line lands in diagnostics instead of breaking the stream")
    log.check(diagnostics.contains(#""name": "Teachy""#), "the client introduces itself as Teachy", diagnostics)
    log.check(diagnostics.contains("caps {}"), "the client declares no capabilities")
    log.check(!diagnostics.contains("hunter2-secret") && diagnostics.contains("[hidden]"), "a secret the server prints is hidden in diagnostics")

    // tools/list_changed.
    _ = try await session.callTool(name: "grow", arguments: .object([:]))
    let sawChange = await waitUntil {
        events.all.contains { if case .toolsChanged(let changed) = $0 { return changed.count == 12 } else { return false } }
    }
    log.check(sawChange, "notifications/tools/list_changed reloads the tool list")
    expectEqual(await session.tools.count, 12, "the session's tool list grew")

    // Crash → restart with backoff → usable again.
    let firstPID = transports.all.first?.processIdentifier ?? 0
    do {
        _ = try await session.callTool(name: "crash", arguments: .object([:]))
        log.check(false, "a call in flight when the server dies fails")
    } catch {
        if case McpError.processExited(let code, let stderrTail) = error {
            expectEqual(code, 3, "the crash reports the exit code")
            log.check(stderrTail.contains("crashing on request"), "the crash carries the server's last words")
        } else {
            log.check(false, "a call in flight when the server dies fails with processExited", "\(error)")
        }
    }
    let restarted = await waitUntil(timeout: 10) {
        events.all.contains { if case .restarted = $0 { return true } else { return false } }
    }
    log.check(restarted, "a crashed server is restarted")
    log.check(events.all.contains { if case .restarting(let attempt, let delay, _) = $0 { return attempt == 1 && delay == 0.1 } else { return false } }, "the restart waits for the backoff first")
    let afterRestart = try await session.callTool(name: "echo", arguments: .object(["text": .string("back")]))
    expectEqual(McpContentFlattener.flatten(afterRestart), "back", "tools work again after the restart")
    let secondPID = transports.all.last?.processIdentifier ?? 0
    log.check(firstPID > 0 && secondPID > 0 && firstPID != secondPID, "the restart is a new process")

    // Clean shutdown.
    await session.close()
    let gone = await waitUntil { !processIsAlive(secondPID) }
    log.check(gone, "closing the session stops the server process")
    log.check(!(await session.isConnected), "a closed session isn't connected")
    do { _ = try await session.callTool(name: "echo", arguments: .object([:])); log.check(false, "calls after close fail") }
    catch { expectEqual(error as? McpError, .notConnected, "calls after close fail with notConnected") }
    try? await Task.sleep(nanoseconds: 400_000_000)
    log.check(!events.all.contains { if case .restarting(let attempt, _, _) = $0 { return attempt > 1 } else { return false } }, "closing on purpose doesn't trigger a restart")

    section("Backoff and stdio failures")
    var backoff = McpSessionOptions()
    backoff.restartBackoffBase = 1
    backoff.restartBackoffCap = 30
    expectEqual((1...7).map { backoff.restartDelay(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30], "restart delays double up to the cap")

    let missing = McpSession(makeTransport: { McpStdioTransport(command: "definitely-not-a-command-xyz", pathProvider: testPathProvider) })
    do { try await missing.connect(); log.check(false, "a missing command fails") }
    catch { expectEqual(error as? McpError, .commandNotFound("definitely-not-a-command-xyz"), "a missing command says so") }

    let dying = McpSession(makeTransport: { McpStdioTransport(command: "python3", arguments: [scriptPath, "--exit-immediately"], pathProvider: testPathProvider) })
    do { try await dying.connect(); log.check(false, "a server that quits at startup fails") }
    catch {
        if case McpError.processExited(let code, let stderrTail) = error {
            log.check(code == 7 && stderrTail.contains("missing configuration"), "a server that quits at startup reports its exit code and stderr", "\(code) \(stderrTail)")
        } else {
            log.check(false, "a server that quits at startup reports processExited", "\(error)")
        }
    }

    let wrongVersion = McpSession(makeTransport: { McpStdioTransport(command: "python3", arguments: [scriptPath, "--bad-version"], pathProvider: testPathProvider) })
    do { try await wrongVersion.connect(); log.check(false, "an unsupported protocol version fails") }
    catch { expectEqual(error as? McpError, .unsupportedProtocolVersion("1999-01-01"), "an unsupported protocol version is refused") }
    await wrongVersion.close()

    // A server that never answers: the handshake times out and the process is cleaned up.
    let silentTransports = Collector<McpStdioTransport>()
    var impatient = McpSessionOptions()
    impatient.requestTimeout = 0.4
    impatient.handshakeTimeout = 0.4
    let silent = McpSession(options: impatient, makeTransport: {
        let transport = McpStdioTransport(command: "/bin/cat", pathProvider: testPathProvider)
        silentTransports.add(transport)
        return transport
    })
    do { try await silent.connect(); log.check(false, "a silent server times out") }
    catch { log.check(error is JSONRPCPeerError || error is JSONRPCErrorObject || error is McpError, "a server that never answers the handshake times out", "\(error)") }
    let silentPID = silentTransports.all.first?.processIdentifier ?? 0
    let silentGone = await waitUntil { silentPID > 0 && !processIsAlive(silentPID) }
    log.check(silentGone, "and its process is not left running")

    let ring = McpRingBuffer(capacity: 10)
    ring.append(Data("0123456789abcdef".utf8))
    expectEqual(ring.text(), "6789abcdef", "the stderr ring buffer keeps only the newest bytes")
}

// MARK: - End to end: HTTP

nonisolated final class FakeHTTPServer: @unchecked Sendable {
    let process = Process()
    let stdinPipe = Pipe()
    private(set) var port = 0

    var base: String { "http://127.0.0.1:\(port)" }

    func start(scriptPath: String, python: String) throws {
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", scriptPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var announced = Data()
        while !announced.contains(0x0A) {
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            announced.append(chunk)
        }
        let line = String(decoding: announced, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        port = Int(line.replacingOccurrences(of: "PORT ", with: "")) ?? 0
    }

    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func post(_ path: String) async {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    func getJSON(_ path: String) async -> JSONValue? {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: base + path)!) else { return nil }
        return try? JSONValue.parse(data)
    }
}

func testHTTPEndToEnd(server: FakeHTTPServer) async throws {
    section("End to end: streamable HTTP against a local fake")

    // No auth, with the optional GET stream.
    do {
        let events = Collector<McpSessionEvent>()
        let transports = Collector<McpHTTPTransport>()
        let session = McpSession(
            makeTransport: {
                let transport = McpHTTPTransport(url: URL(string: server.base + "/open/mcp")!)
                transports.add(transport)
                return transport
            },
            onEvent: { events.add($0) }
        )
        let tools = try await session.connect()
        expectEqual(tools.map(\.name), ["echo", "whoami", "grow"], "tools arrive over an SSE-framed response (multi-line data, a comment and a notification in front)")
        expectEqual(await transports.all.first?.negotiatedTransportName, "streamable-http", "the server is recognised as streamable HTTP")
        let echo = try await session.callTool(name: "echo", arguments: .object(["text": .string("over http")]))
        expectEqual(McpContentFlattener.flatten(echo), "over http", "a tool call gets its plain-JSON response")
        let who = try await session.callTool(name: "whoami", arguments: .object([:]))
        log.check(McpContentFlattener.flatten(who).hasPrefix("sess-"), "the Mcp-Session-Id from initialize is sent back", McpContentFlattener.flatten(who))
        try await session.ping()

        _ = try await session.callTool(name: "grow", arguments: .object([:]))
        let pushed = await waitUntil(timeout: 5) {
            events.all.contains { if case .toolsChanged(let changed) = $0 { return changed.count == 4 } else { return false } }
        }
        log.check(pushed, "a list_changed pushed on the GET stream reloads the tools")

        // The server forgets the session: the next call starts a new one and still succeeds.
        let sessionBefore = McpContentFlattener.flatten(who)
        await server.post("/test/expire-session")
        let afterExpiry = try await session.callTool(name: "whoami", arguments: .object([:]))
        let sessionAfter = McpContentFlattener.flatten(afterExpiry)
        log.check(sessionAfter.hasPrefix("sess-") && sessionAfter != sessionBefore, "an expired session (404) is replaced and the call retried", "\(sessionBefore) → \(sessionAfter)")
        await session.close()
    }

    // Bearer token.
    do {
        let good = McpSession(makeTransport: {
            McpHTTPTransport(url: URL(string: server.base + "/token/mcp")!, auth: McpStaticHeaderAuth(headers: ["Authorization": "Bearer good-token"]))
        })
        expectEqual(try await good.connect().count >= 3, true, "the right bearer token connects")
        await good.close()

        let bad = McpSession(makeTransport: {
            McpHTTPTransport(url: URL(string: server.base + "/token/mcp")!, auth: McpStaticHeaderAuth(headers: ["Authorization": "Bearer wrong"]))
        })
        do { try await bad.connect(); log.check(false, "a wrong token is refused") }
        catch {
            if case McpError.unauthorized(let hadCredentials, let challenge) = error {
                log.check(hadCredentials && challenge?.contains("Bearer") == true, "a wrong token → unauthorized, with credentials, challenge kept")
            } else { log.check(false, "a wrong token → unauthorized", "\(error)") }
        }

        let none = McpSession(makeTransport: { McpHTTPTransport(url: URL(string: server.base + "/token/mcp")!) })
        do { try await none.connect(); log.check(false, "no token is refused") }
        catch { expectEqual(error as? McpError, .unauthorized(hadCredentials: false, wwwAuthenticate: "Bearer realm=\"fake\""), "no token → unauthorized, without credentials") }

        let apiKey = McpSession(makeTransport: {
            McpHTTPTransport(url: URL(string: server.base + "/key/mcp")!, auth: McpStaticHeaderAuth(headers: ["X-API-Key": "key-123"]))
        })
        expectEqual(try await apiKey.connect().count >= 3, true, "an API-key header connects")
        await apiKey.close()

        let notFound = McpSession(makeTransport: { McpHTTPTransport(url: URL(string: server.base + "/nothing/here")!) })
        do { try await notFound.connect(); log.check(false, "a URL that isn't an MCP server fails") }
        catch { if case McpError.httpStatus(let code, _) = error { expectEqual(code, 404, "a URL that isn't an MCP server reports the HTTP status") } else { log.check(false, "a wrong URL reports httpStatus", "\(error)") } }

        let refused = McpSession(makeTransport: { McpHTTPTransport(url: URL(string: "http://127.0.0.1:1/mcp")!) })
        do { try await refused.connect(); log.check(false, "nothing listening fails") }
        catch { log.check(error is URLError, "nothing listening fails with a network error", "\(error)") }
    }

    section("End to end: the older HTTP+SSE transport")
    do {
        let transports = Collector<McpHTTPTransport>()
        let session = McpSession(makeTransport: {
            let transport = McpHTTPTransport(url: URL(string: server.base + "/legacy/sse")!)
            transports.add(transport)
            return transport
        })
        let tools = try await session.connect()
        log.check(tools.count >= 3, "a 405 on POST falls back to GET /sse + endpoint event, and tools load")
        expectEqual(await transports.all.first?.negotiatedTransportName, "sse", "the server is recognised as HTTP+SSE")
        let echo = try await session.callTool(name: "echo", arguments: .object(["text": .string("legacy")]))
        expectEqual(McpContentFlattener.flatten(echo), "legacy", "tool calls work over HTTP+SSE")
        await session.close()
    }

    log.check(McpSameOriginRedirectGuard.isSameOrigin(URL(string: "https://a.example.com/x"), URL(string: "https://a.example.com:443/y")), "same origin: default port equals explicit port")
    log.check(!McpSameOriginRedirectGuard.isSameOrigin(URL(string: "https://a.example.com/x"), URL(string: "https://evil.example.net/x")), "a redirect to another host is not same-origin")
    log.check(!McpSameOriginRedirectGuard.isSameOrigin(URL(string: "https://a.example.com/x"), URL(string: "http://a.example.com/x")), "a downgrade to http is not same-origin")
}

func testOAuthEndToEnd(server: FakeHTTPServer) async throws {
    section("End to end: OAuth sign-in against a local fake")
    let secrets = InMemoryMcpSecretStore()
    let serverURL = URL(string: server.base + "/oauth/mcp")!
    let opened = Collector<URL>()
    // Stands in for the browser: follow the authorization URL; the fake redirects to our loopback listener.
    let pretendBrowser: @Sendable (URL) -> Void = { url in
        opened.add(url)
        Task.detached { _ = try? await URLSession.shared.data(from: url) }
    }
    let manager = McpOAuthManager(serverURL: serverURL, secretReference: "oauthy.oauth", secrets: secrets, signInTimeout: 15, openURL: pretendBrowser)

    // Before signing in: the connector reports that it needs it.
    let session = McpSession(makeTransport: { McpHTTPTransport(url: serverURL, auth: manager) })
    do { try await session.connect(); log.check(false, "OAuth without a token needs sign-in") }
    catch { expectEqual(McpConnectorState.describing(error, auth: .oauth), .needsSignIn, "OAuth without a token → needs sign-in") }

    try await manager.signIn()
    let authorizeURL = opened.all.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    func query(_ name: String) -> String? { authorizeURL?.queryItems?.first { $0.name == name }?.value }
    expectEqual(authorizeURL?.path, "/as/authorize", "discovery found the authorization endpoint (401 → resource metadata → server metadata)")
    expectEqual(query("code_challenge_method"), "S256", "PKCE S256 is used")
    expectEqual(query("resource"), server.base + "/oauth/mcp", "the resource parameter names the MCP server")
    expectEqual(query("scope"), "tools.read tools.write", "scopes come from the resource metadata")
    log.check(query("redirect_uri")?.hasPrefix("http://127.0.0.1:") == true && query("redirect_uri")?.hasSuffix("/callback") == true, "the redirect is a loopback address", query("redirect_uri") ?? "nil")
    expectEqual(query("client_id"), "client-1", "the client id came from dynamic registration")
    log.check((query("state") ?? "").count >= 16, "a state value is sent")

    let stored = secrets.secret(for: "oauthy.oauth") ?? ""
    log.check(stored.contains("access-1") && stored.contains("refresh-1"), "tokens are stored in the secret store (the fake checked the PKCE verifier)")
    expectEqual(try await manager.authorizationHeaders(), ["Authorization": "Bearer access-1"], "the access token is sent as a bearer header")

    let tools = try await session.connect()
    log.check(tools.count >= 3, "after signing in, the connector connects")

    // The access token stops working: the 401 triggers a refresh and the call succeeds.
    await server.post("/test/revoke-access-tokens")
    let echo = try await session.callTool(name: "echo", arguments: .object(["text": .string("refreshed")]))
    expectEqual(McpContentFlattener.flatten(echo), "refreshed", "a 401 triggers a token refresh and the call is retried")
    let oauthLog = await server.getJSON("/test/oauth-log")
    expectEqual(oauthLog?["refreshes"], .int(1), "exactly one refresh happened")
    log.check((secrets.secret(for: "oauthy.oauth") ?? "").contains("access-2"), "the refreshed token replaced the old one")
    log.check((secrets.secret(for: "oauthy.oauth") ?? "").contains("refresh-1"), "the refresh token was kept")
    let registeredRedirects = oauthLog?["clients"]?["client-1"]?["redirect_uris"]?.arrayValue?.compactMap(\.stringValue) ?? []
    expectEqual(registeredRedirects.first, query("redirect_uri"), "the registered redirect URI is the one used")
    expectEqual(oauthLog?["clients"]?["client-1"]?["client_name"]?.stringValue, "Teachy", "Teachy registers under its own name")
    await session.close()

    // Signing in again reuses the registration (same port) instead of registering a new client.
    try await manager.signIn()
    let secondLog = await server.getJSON("/test/oauth-log")
    expectEqual(secondLog?["clients"]?.objectValue?.count, 1, "a second sign-in reuses the registered client")

    // The listener itself: wrong paths are ignored, a mismatched state is refused.
    let listener = try McpLoopbackRedirectListener()
    log.check(listener.port > 1024, "the listener binds a random high port")
    async let callback = listener.waitForCallback(timeout: 5)
    _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port)/favicon.ico")!)
    let (pageData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port)/callback?code=abc&state=xyz%20z")!)
    expectEqual(try await callback, ["code": "abc", "state": "xyz z"], "the listener returns the callback's query, ignoring other paths")
    log.check(String(decoding: pageData, as: UTF8.self).contains("You're signed in"), "the browser sees a friendly page")

    let timeoutListener = try McpLoopbackRedirectListener()
    do { _ = try await timeoutListener.waitForCallback(timeout: 0.3); log.check(false, "the listener times out") }
    catch { log.check(error is McpError, "a sign-in nobody finishes times out") }

    await manager.signOut()
    log.check(secrets.secret(for: "oauthy.oauth") == nil, "signing out removes the stored tokens")
}

// MARK: - End to end: ConnectorCenter

@MainActor
func testConnectorCenter(server: FakeHTTPServer) async throws {
    section("ConnectorCenter: add, connect, tools, persistence")
    let scriptPath = try writeScript(FakeServers.stdioServerSource, named: "fake_stdio_server_center.py")
    let storeURL = temporaryRoot.appendingPathComponent("center/mcp.json")
    let secrets = InMemoryMcpSecretStore()
    var options = McpSessionOptions()
    options.restartBackoffBase = 0.1
    // Stands in for the browser during sign-in: follow the URL, the fake redirects back to the loopback listener.
    let pretendBrowser: @Sendable (URL) -> Void = { url in
        Task.detached { _ = try? await URLSession.shared.data(from: url) }
    }
    func makeCenter() -> ConnectorCenter {
        ConnectorCenter(store: McpConnectorStore(fileURL: storeURL), secrets: secrets, sessionOptions: options, pathProvider: testPathProvider, openURL: pretendBrowser)
    }

    let center = makeCenter()
    center.start()
    expectEqual(center.connectors.count, 0, "a fresh store starts empty")
    expectEqual(await center.toolsForAgent(waitingUpTo: 1).count, 0, "no connectors, no tools")

    let localID = try center.add(McpConnectorDraft(label: "Fake Local", commandLine: "FAKE_SECRET=s3cr3t-value python3 '\(scriptPath)'"))
    expectEqual(localID, "fake_local", "add returns the new id")
    expectEqual(center.state(for: localID), .checking, "a new connector shows Checking… straight away")
    await center.waitUntilSettled(timeout: 10)
    expectEqual(center.state(for: localID), .connected(toolCount: 11), "then Connected with its tool count")

    let tools = center.tools
    expectEqual(tools.count, 11, "its tools are exposed to the agent")
    log.check(tools.allSatisfy { $0.name.hasPrefix("mcp__fake_local__") && $0.name.count <= 64 }, "tool names are mcp__<connectorid>__<toolname>")
    log.check(tools.contains { $0.name == "mcp__fake_local__delete_everything_" }, "a tool name with spaces and punctuation is sanitised")
    guard let echoTool = tools.first(where: { $0.name == "mcp__fake_local__echo" }) as? McpConnectorTool,
          let addTool = tools.first(where: { $0.name == "mcp__fake_local__add" }) as? McpConnectorTool,
          let deleteTool = tools.first(where: { $0.name == "mcp__fake_local__delete_everything_" }) as? McpConnectorTool,
          let boomTool = tools.first(where: { $0.name == "mcp__fake_local__boom" }) as? McpConnectorTool,
          let envTool = tools.first(where: { $0.name == "mcp__fake_local__getenv" }) as? McpConnectorTool else {
        log.check(false, "the expected tool adapters exist"); return
    }
    expectEqual(try await echoTool.execute(arguments: ["text": "through the adapter"]), "through the adapter", "an adapter runs tools/call and returns the text")
    expectEqual(try await addTool.execute(arguments: ["a": 20, "b": 22]), "42", "arguments pass through as JSON")
    expectEqual(try await boomTool.execute(arguments: [:]), "The tool reported an error: it broke", "isError reaches the agent as text")
    expectEqual(try await envTool.execute(arguments: ["name": "FAKE_SECRET"]), "s3cr3t-value", "a secret from the Keychain reaches the local server's environment")
    expectEqual(echoTool.description, "[Fake Local] Says the text back.", "the description is the server's, tagged with the connector")
    expectEqual((echoTool.jsonSchema["properties"] as? [String: Any])?.keys.sorted(), ["text"], "the JSON schema passes through")
    expectEqual(echoTool.jsonSchema["type"] as? String, "object", "the schema is an object schema")
    expectEqual(echoTool.remoteToolName, "echo", "the adapter remembers the server's tool name")
    expectEqual(deleteTool.remoteToolName, "delete everything!", "even when the registered name was sanitised")
    expectEqual([echoTool.mcpRisk, addTool.mcpRisk, deleteTool.mcpRisk, boomTool.mcpRisk], [.readOnly, .unknown, .destructive, .writes], "each adapter carries its mcpRisk")
    expectEqual(echoTool.mcpOpenWorld, false, "and its open-world hint")
    log.check(center.promptSection().contains("Fake Local: 11 tools"), "the prompt note lists the connector")

    let savedText = try String(contentsOf: storeURL, encoding: .utf8)
    log.check(!savedText.contains("s3cr3t-value"), "the secret typed into the command never reaches mcp.json")
    expectEqual(secrets.secret(for: "fake_local.env.FAKE_SECRET"), "s3cr3t-value", "it is in the secret store instead")

    // list_changed reaches the published tools.
    _ = try await (tools.first { $0.name == "mcp__fake_local__grow" })?.execute(arguments: [:])
    let grew = await waitUntil { center.tools.count == 12 }
    log.check(grew && center.state(for: localID) == .connected(toolCount: 12), "a tool the server adds later shows up")

    // A crash is recovered without anyone asking.
    _ = try? await (tools.first { $0.name == "mcp__fake_local__crash" })?.execute(arguments: [:])
    let recovered = await waitUntil(timeout: 10) { center.state(for: localID).isConnected && center.tools.count == 11 }
    log.check(recovered, "a crashed local server comes back by itself", "\(center.state(for: localID))")
    let freshEcho = center.tools.first { $0.name == "mcp__fake_local__echo" }
    expectEqual(try await freshEcho?.execute(arguments: ["text": "again"]), "again", "and its tools work again")

    // Off and on.
    center.setEnabled(id: localID, false)
    expectEqual(center.tools.count, 0, "switching a connector off removes its tools")
    expectEqual(center.state(for: localID), .idle, "and it goes idle")
    center.setEnabled(id: localID, true)
    await center.waitUntilSettled(timeout: 10)
    expectEqual(center.state(for: localID).isConnected, true, "switching it on reconnects")
    expectEqual(await center.test(id: localID).isConnected, true, "test pings a connected connector")

    section("ConnectorCenter: remote servers, tokens, accounts")
    let wrongID = try center.add(McpConnectorDraft(label: "Remote", serverURL: server.base + "/token/mcp", apiKey: "wrong-token", accountLabel: "work"))
    await center.waitUntilSettled(timeout: 10)
    expectEqual(center.state(for: wrongID), .tokenRejected, "a wrong API key shows Token rejected")
    await center.updateToken(id: wrongID, apiKey: "good-token")
    expectEqual(center.state(for: wrongID), .connected(toolCount: 4), "editing the token fixes it")

    let secondID = try center.add(McpConnectorDraft(label: "Remote", serverURL: server.base + "/token/mcp", apiKey: "good-token", accountLabel: "personal"))
    await center.waitUntilSettled(timeout: 10)
    expectEqual([wrongID, secondID], ["remote_work", "remote_personal"], "two accounts on one server are two connectors")
    expectEqual(center.state(for: secondID).isConnected, true, "the second account connects too")
    log.check(center.tools.contains { $0.name == "mcp__remote_work__echo" } && center.tools.contains { $0.name == "mcp__remote_personal__echo" }, "each account has its own tool names")
    let personalEcho = center.tools.first { $0.name == "mcp__remote_personal__echo" }
    expectEqual(personalEcho?.description, "[Remote · personal] Says the text back.", "descriptions say which account")
    expectEqual(try await personalEcho?.execute(arguments: ["text": "remote"]), "remote", "remote tools run through the adapter")

    let signInID = try center.add(McpConnectorDraft(label: "Needs Login", serverURL: server.base + "/oauth/mcp"))
    await center.waitUntilSettled(timeout: 10)
    expectEqual(center.state(for: signInID), .needsSignIn, "a server that wants OAuth shows Needs sign-in")
    await center.signIn(id: signInID)
    expectEqual(center.state(for: signInID).isConnected, true, "signing in through the browser connects it")
    expectEqual(center.connectors.first { $0.id == signInID }?.auth, .oauth, "and the connector is saved as an OAuth one")
    log.check((secrets.secret(for: "needs_login.oauth") ?? "").contains("access-"), "with its tokens in the secret store")
    let savedAfterSignIn = try String(contentsOf: storeURL, encoding: .utf8)
    log.check(!savedAfterSignIn.contains("access-") && !savedAfterSignIn.contains("refresh-"), "and no token in mcp.json")

    let deadID = try center.add(McpConnectorDraft(label: "Dead", commandLine: "definitely-not-a-command-xyz --serve"))
    await center.waitUntilSettled(timeout: 10)
    expectEqual(center.state(for: deadID), .failed("Couldn't find \"definitely-not-a-command-xyz\" on this Mac. Check it is installed and on your PATH."), "a bad command shows its error")
    log.check((try? center.add(McpConnectorDraft(label: "", serverURL: "https://x.dev"))) == nil, "an invalid draft is refused and nothing is saved")

    // Paste-config import.
    let importedIDs = try center.importConfig(#"{"mcpServers": {"pasted": {"url": "\#(server.base)/key/mcp", "headers": {"X-API-Key": "key-123"}}}}"#)
    await center.waitUntilSettled(timeout: 10)
    expectEqual(importedIDs, ["pasted"], "a pasted config adds its servers")
    expectEqual(center.state(for: "pasted").isConnected, true, "and the imported header (now in the secret store) authenticates")
    expectEqual(secrets.secret(for: "pasted.header.X-API-Key"), "key-123", "the pasted key moved to the secret store")
    log.check(!((try? String(contentsOf: storeURL, encoding: .utf8)) ?? "key-123").contains("key-123"), "and is not in mcp.json")

    // A second center on the same file sees everything (and reconnects on its own).
    let relaunched = makeCenter()
    let relaunchedTools = await relaunched.toolsForAgent(waitingUpTo: 10)
    expectEqual(relaunched.connectors.map(\.id), center.connectors.map(\.id), "connectors persist across launches")
    log.check(relaunched.state(for: localID).isConnected && relaunched.state(for: "remote_work").isConnected, "enabled connectors reconnect on launch")
    log.check(relaunchedTools.contains { $0.name == "mcp__fake_local__echo" }, "toolsForAgent returns tools once connectors settle")
    await relaunched.shutdown()

    // Remove cleans up the file and the secrets.
    center.remove(id: wrongID)
    log.check(!center.tools.contains { $0.name.hasPrefix("mcp__remote_work__") }, "removing a connector removes its tools")
    log.check(secrets.secret(for: "remote_work.bearer") == nil, "and its secret")
    log.check(!(try String(contentsOf: storeURL, encoding: .utf8)).contains("remote_work"), "and its entry in mcp.json")
    for connector in center.connectors { center.remove(id: connector.id) }
    expectEqual(secrets.allReferences, [], "removing every connector leaves no secrets behind")
    expectEqual(McpConnectorStore(fileURL: storeURL).load().connectors.count, 0, "and an empty mcp.json")
    await center.shutdown()
}

// MARK: - Run

do {
    try testJSON()
    try testFraming()
    try await testPeer()
    testSSE()
    try testConfig()
    try testToolModel()
    try await testEnvironmentAndOAuthHelpers()
    try await testStdioEndToEnd()

    let python = McpShellEnvironment.resolveExecutable("python3", searchPATH: await testPathProvider()) ?? "/usr/bin/python3"
    let httpServer = FakeHTTPServer()
    try httpServer.start(scriptPath: try writeScript(FakeServers.httpServerSource, named: "fake_http_server.py"), python: python)
    defer { httpServer.stop() }
    log.check(httpServer.port > 0, "the fake HTTP server started")
    if httpServer.port > 0 {
        try await testHTTPEndToEnd(server: httpServer)
        try await testOAuthEndToEnd(server: httpServer)
        try await testConnectorCenter(server: httpServer)
    }
} catch {
    log.check(false, "the test run threw", "\(error)")
}

let outcome = log.summary()
print("")
if outcome.failures.isEmpty {
    print("Connectors tests: \(outcome.passed) passed, 0 failed")
} else {
    print("Connectors tests: \(outcome.passed) passed, \(outcome.failures.count) FAILED")
    for failure in outcome.failures { print("  - \(failure)") }
    exit(1)
}
