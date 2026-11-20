// Run: scripts/tests/render_docs2_shots.sh
// Renders the chat window (in a real, never-shown NSWindow, title bar included)
// and the attachment views to PNG files with sample conversations, and checks a
// few things that need AppKit: the composer's Return handling, the window's
// style, and that the hotkey registers. Nothing is put on screen.
// Output: $TMPDIR/teachy-docs2/shots/
import AppKit
import Carbon.HIToolbox
import SwiftUI

setvbuf(stdout, nil, _IOLBF, 0)
// Makes the top level of this file run on the main actor.
await Task.yield()
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-docs2", isDirectory: true)
let outputDirectory = root.appendingPathComponent("shots", isDirectory: true)
let dataDirectory = root.appendingPathComponent("shots-data-\(UUID().uuidString.prefix(6))", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dataDirectory) }

func settle(_ seconds: TimeInterval = 0.35) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func writePNG(_ view: NSView, name: String) {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("FAIL no bitmap for \(name)"); failures += 1; return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { print("FAIL no PNG for \(name)"); failures += 1; return }
    let url = outputDirectory.appendingPathComponent(name + ".png")
    try? data.write(to: url)
    print("wrote \(url.path) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
}

/// A SwiftUI view at a fixed width, in a borderless window that is never shown.
func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String) {
    let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
    let size = NSSize(width: width, height: height ?? hosting.fittingSize.height)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    settle()
    writePNG(hosting, name: name)
}

// MARK: - Sample data

let calendar = Calendar.current
let now = Date()
let todayNoon = calendar.date(bySettingHour: 14, minute: 2, second: 0, of: now) ?? now
func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: todayNoon) ?? todayNoon
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
}

let longAnswer = """
The report says revenue was **84.6 million euros**, up 11 percent on the year before (page 5). Three things drove it:

- **More turbines.** The fleet grew to 38, each rated at 2.5 megawatts (page 3).
- **Better uptime.** Availability averaged 94.3 percent against a 92 percent target (page 17).
- **Long contracts.** The average contracted price was 178 euros per megawatt hour under fifteen-year agreements (page 19).

Costs were 51.2 million euros, with vessel hire the biggest single item (page 6). The main thing to watch is gearbox seal failure: it caused 61 percent of unplanned downtime (page 23), and the digital twin on page 26 exists mostly to catch it early.
"""

let codeAnswer = """
Your loop reads the whole file before it filters. Read it line by line instead, and stop when you have enough:

```swift
func firstMatches(in url: URL, containing word: String, limit: Int) async throws -> [String] {
    var matches: [String] = []
    for try await line in url.lines where line.localizedCaseInsensitiveContains(word) {
        matches.append(line)
        if matches.count == limit { break }
    }
    return matches
}
```

`url.lines` never holds more than one line in memory, so a 2 GB log is fine.
"""

let messages: [ChatMessage] = [
    ChatMessage(isFromUser: true, text: "why does my log search use 4 gigs of memory", date: at(daysAgo: 1, hour: 16, minute: 40)),
    ChatMessage(isFromUser: false, text: codeAnswer, date: at(daysAgo: 1, hour: 16, minute: 40)),
    ChatMessage(isFromUser: true, text: "Show me how a tidal turbine makes power", date: at(daysAgo: 0, hour: 13, minute: 41)),
    ChatMessage(isFromUser: false, text: "The tide pushes water past the blades, the blades turn a shaft, and a generator in the nacelle turns that into electricity. I drew it for you. [SHOW: tidal turbine cutaway]", date: at(daysAgo: 0, hour: 13, minute: 41)),
    ChatMessage(isFromUser: true, text: "What does the annual report say about revenue, and what should I worry about?", date: at(daysAgo: 0, hour: 13, minute: 58)),
    ChatMessage(isFromUser: false, text: longAnswer, date: at(daysAgo: 0, hour: 13, minute: 58)),
    ChatMessage(isFromUser: true, text: "Find the three emails from the insurer about the Stroma cable claim", date: at(daysAgo: 0, hour: 14, minute: 0))
]

// A stand-in drawing thumbnail (a real one comes from the drawing engine).
let thumbnailURL = dataDirectory.appendingPathComponent("turbine.png")
do {
    let image = NSImage(size: NSSize(width: 312, height: 204), flipped: false) { rect in
        NSColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
        rect.fill()
        NSColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 0.25).setFill()
        NSRect(x: 0, y: 0, width: 312, height: 70).fill()
        let ink = NSColor(red: 0.16, green: 0.2, blue: 0.3, alpha: 1)
        ink.setStroke()
        let tower = NSBezierPath()
        tower.lineWidth = 4
        tower.move(to: NSPoint(x: 156, y: 18)); tower.line(to: NSPoint(x: 156, y: 112)); tower.stroke()
        let hub = NSBezierPath(ovalIn: NSRect(x: 146, y: 104, width: 20, height: 20)); hub.lineWidth = 3; hub.stroke()
        for angle in stride(from: 90.0, to: 450.0, by: 120.0) {
            let blade = NSBezierPath()
            blade.lineWidth = 5
            blade.lineCapStyle = .round
            blade.move(to: NSPoint(x: 156, y: 114))
            blade.line(to: NSPoint(x: 156 + 62 * cos(angle * .pi / 180), y: 114 + 62 * sin(angle * .pi / 180)))
            blade.stroke()
        }
        NSColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1).setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 3
        arrow.move(to: NSPoint(x: 28, y: 44)); arrow.line(to: NSPoint(x: 96, y: 44))
        arrow.move(to: NSPoint(x: 84, y: 54)); arrow.line(to: NSPoint(x: 96, y: 44)); arrow.line(to: NSPoint(x: 84, y: 34))
        arrow.stroke()
        return true
    }
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
        try? bitmap.representation(using: .png, properties: [:])?.write(to: thumbnailURL)
    }
}

func makeTimeline(_ messages: [ChatMessage], name: String, withRows: Bool) -> ChatTimeline {
    let store = ChatTimelineStore(fileURL: dataDirectory.appendingPathComponent("\(name)-timeline.jsonl"))
    if withRows {
        store.post(.drawing(title: "How a tidal turbine makes power", thumbnailURL: thumbnailURL, id: "scene-1"), date: at(daysAgo: 0, hour: 13, minute: 42))
        store.post(.note("Attached Northwind Tidal Annual Report 2025.pdf"), date: at(daysAgo: 0, hour: 13, minute: 57))
        store.post(.job(
            title: "Inbox Hunter", status: .done,
            answer: "Found three emails from Harbour Mutual about the Stroma cable claim:\n- **12 Nov**, \"Claim 4471 received\": they have the survey report.\n- **13 Nov**, \"Loss adjuster visit\": proposed for 20 November, needs a yes from you.\n- **14 Nov**, \"Premium notice\": the 18 percent rise applies from January.",
            id: "job-1"), date: at(daysAgo: 0, hour: 14, minute: 1))
    }
    return ChatTimeline(loadMessages: { messages }, conversationFileURL: nil, store: store)
}

func makeShelf() -> AttachmentShelf {
    let shelf = AttachmentShelf(reader: { _ in throw DocumentReadError.unreadable("unused") })
    shelf.add(document: ReadDocument(
        title: "Northwind Tidal Annual Report 2025.pdf", kind: .pdf,
        sourceURL: URL(fileURLWithPath: "/Users/sample/Documents/Northwind Tidal Annual Report 2025.pdf"),
        sections: (1...30).map { DocumentSection(number: $0, text: "Page \($0)") }))
    shelf.add(document: ReadDocument(
        title: "turbine-output.csv", kind: .csv,
        sourceURL: URL(fileURLWithPath: "/Users/sample/Documents/turbine-output.csv"),
        sections: (1...4).map { DocumentSection(number: $0, text: "rows") }))
    return shelf
}

// MARK: - The window, at three sizes

/// Builds the real window (same style as the app's), never shows it, and captures its whole frame.
func renderWindow(size: NSSize, name: String, timeline: ChatTimeline, shelf: AttachmentShelf, search: String = "", draft: String = "", keys: [String] = ["control", "option"]) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.contentView = ChatWindowController.contentView(for: ChatWindowView(
        timeline: timeline, shelf: shelf, talkKeyLabels: { keys },
        initialSearchText: search, initialDraft: draft, onSubmit: { _ in }
    ))
    ChatWindowController.style(window)
    window.setContentSize(size)
    settle(0.6)
    if let frameView = window.contentView?.superview {
        writePNG(frameView, name: name)
    }
    return window
}

let fullTimeline = makeTimeline(messages, name: "full", withRows: true)
let fullShelf = makeShelf()

let largeWindow = renderWindow(size: NSSize(width: 980, height: 1180), name: "01-chat-large", timeline: fullTimeline, shelf: fullShelf)
_ = renderWindow(size: NSSize(width: 780, height: 760), name: "02-chat-default", timeline: fullTimeline, shelf: fullShelf, draft: "And what was the dividend?")
_ = renderWindow(size: NSSize(width: 440, height: 620), name: "03-chat-small", timeline: fullTimeline, shelf: fullShelf, keys: ["fn", "space"])

// Search, live reply, empty and failed-attachment states.
_ = renderWindow(size: NSSize(width: 780, height: 560), name: "04-chat-search", timeline: fullTimeline, shelf: AttachmentShelf(), search: "insurer")
_ = renderWindow(size: NSSize(width: 780, height: 420), name: "05-chat-search-none", timeline: fullTimeline, shelf: AttachmentShelf(), search: "kubernetes")

let liveTimeline = makeTimeline(Array(messages.prefix(4)), name: "live", withRows: false)
liveTimeline.userAsked("What is the dividend this year?")
liveTimeline.streamingReply(text: "The board proposes **0.42 euros per share**, payable on 19 June (page 21). That is covered about three times by", isFinal: false)
_ = renderWindow(size: NSSize(width: 780, height: 620), name: "06-chat-streaming", timeline: liveTimeline, shelf: AttachmentShelf())

let thinkingTimeline = makeTimeline(Array(messages.prefix(2)), name: "thinking", withRows: false)
thinkingTimeline.userAsked("Summarize this PDF")
_ = renderWindow(size: NSSize(width: 780, height: 620), name: "07-chat-thinking", timeline: thinkingTimeline, shelf: AttachmentShelf())

let emptyTimeline = makeTimeline([], name: "empty", withRows: false)
_ = renderWindow(size: NSSize(width: 780, height: 560), name: "08-chat-empty", timeline: emptyTimeline, shelf: AttachmentShelf())

let jobsTimeline: ChatTimeline = {
    let store = ChatTimelineStore(fileURL: dataDirectory.appendingPathComponent("jobs-timeline.jsonl"))
    store.post(.job(title: "Flight Scout", status: .running, answer: nil, id: "a"), date: at(daysAgo: 0, hour: 9, minute: 5))
    store.post(.job(title: "Receipt Keeper", status: .waitingForYou, answer: "I need you to sign in to the expenses site before I can upload these.", id: "b"), date: at(daysAgo: 0, hour: 9, minute: 20))
    store.post(.job(title: "Deck Polisher", status: .failed, answer: "Keynote stopped answering after slide 14, so I left the file as it was.", id: "c"), date: at(daysAgo: 0, hour: 9, minute: 31))
    store.post(.drawing(title: "Why the sky is blue", thumbnailURL: nil, id: "no-thumb"), date: at(daysAgo: 0, hour: 9, minute: 40))
    return ChatTimeline(loadMessages: { [ChatMessage(isFromUser: true, text: "Book me the cheapest direct flight to Bergen on the 3rd, file last week's receipts, and tidy the board deck", date: at(daysAgo: 0, hour: 9, minute: 4))] }, conversationFileURL: nil, store: store)
}()
_ = renderWindow(size: NSSize(width: 780, height: 700), name: "09-chat-job-states", timeline: jobsTimeline, shelf: AttachmentShelf())

// MARK: - Attachment views on their own

let chipShelf = makeShelf()
if let png = try? Data(contentsOf: thumbnailURL) {
    chipShelf.add(document: ReadDocument(title: "whiteboard photo.png", kind: .image, sections: [], pageCount: 1, imageData: png))
}
let readingURL = dataDirectory.appendingPathComponent("lease-agreement-final-v3.docx")
try? Data("x".utf8).write(to: readingURL)
let slowShelf = AttachmentShelf(reader: { _ in try await Task.sleep(nanoseconds: 60_000_000_000); throw DocumentReadError.unreadable("x") })
slowShelf.add(url: readingURL)
let failedURL = dataDirectory.appendingPathComponent("budget.numbers")
try? FileManager.default.createDirectory(at: failedURL, withIntermediateDirectories: true)
let failingShelf = AttachmentShelf()
failingShelf.add(url: failedURL)
await failingShelf.waitUntilRead()
for number in 1...5 { failingShelf.add(document: ReadDocument(title: "notes-\(number).md", kind: .markdown, sourceURL: URL(fileURLWithPath: "/tmp/x/notes-\(number).md"), sections: [DocumentSection(number: 1, text: "x")])) }
settle(0.8)

render(
    VStack(alignment: .leading, spacing: 18) {
        Text("Chat window size").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
        AttachmentChipsView(shelf: chipShelf)
        AttachmentChipsView(shelf: slowShelf)
        AttachmentChipsView(shelf: failingShelf)
        Text("Notch size (compact)").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
        AttachmentChipsView(shelf: chipShelf, compact: true)
        AttachmentChipsView(shelf: failingShelf, compact: true)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black),
    width: 760, name: "10-attachment-chips")

// The notch panel is 640 wide and black; this is how the chips and the drop highlight sit in it.
render(
    VStack(alignment: .leading, spacing: 10) {
        AttachmentChipsView(shelf: chipShelf, compact: true)
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)).frame(height: 150)
    }
    .padding(12)
    .background(Color.black),
    width: 640, name: "11-notch-with-chips")
render(
    VStack(alignment: .leading, spacing: 10) {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)).frame(height: 190)
    }
    .padding(12)
    .background(Color.black)
    .overlay(AttachmentDropHighlight(cornerRadius: 18)),
    width: 640, name: "12-notch-drop-highlight")
render(
    ZStack {
        ChatStyle.windowBackground
        AttachmentDropHighlight(cornerRadius: 12)
    },
    width: 780, height: 420, name: "13-chat-drop-highlight")

// MARK: - Checks that need AppKit

check("window: standard title bar buttons", largeWindow.standardWindowButton(.closeButton) != nil && largeWindow.standardWindowButton(.miniaturizeButton) != nil && largeWindow.standardWindowButton(.zoomButton) != nil)
check("window: resizable, closable, minimisable", largeWindow.styleMask.contains([.resizable, .closable, .miniaturizable, .titled]))
check("window: a resize below the minimum is held at the minimum", ChatWindowController.clamped(NSSize(width: 200, height: 900)) == NSSize(width: 440, height: 900) && ChatWindowController.clamped(NSSize(width: 900, height: 100)).height == 420)
if let close = largeWindow.standardWindowButton(.closeButton), let frameView = largeWindow.contentView?.superview {
    let inFrame = close.convert(close.bounds, to: frameView)
    let fromTop = frameView.bounds.height - inFrame.midY
    check("window: title bar buttons sit in the header band (centre \(Int(fromTop)) pt from the top)", fromTop > 14 && fromTop < ChatStyle.headerHeight - 8)
    check("window: header leaves room for them (buttons end at \(Int(inFrame.maxX + 40)) pt)", inFrame.maxX + 40 <= 84)
}

// Composer keys, driven through the real text view.
var submitted: [String] = []
let composer = ChatComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
composer.onSubmit = { submitted.append(composer.string) }
func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "\r") -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}
composer.string = "hello"
composer.keyDown(with: key(36))
check("composer: Return sends", submitted == ["hello"])
composer.keyDown(with: key(36, .shift))
check("composer: Shift+Return adds a line and does not send", submitted.count == 1 && composer.string.contains("\n"))
composer.string = "two"
composer.keyDown(with: key(36, .option))
check("composer: Option+Return adds a line and does not send", submitted.count == 1 && composer.string.contains("\n"))
composer.string = "pad"
composer.keyDown(with: key(76))
check("composer: keypad Enter sends", submitted.last == "pad")

// The hotkey registers without any permission, and unregisters.
let hotkey = ChatWindowHotkey()
let registered = hotkey.register { }
check("hotkey: Control+Command+A registers (status \(hotkey.status))", registered && hotkey.isRegistered)
hotkey.unregister()
check("hotkey: unregisters", !hotkey.isRegistered)

// Live updates: a file change is picked up by the poll.
do {
    let conversationURL = dataDirectory.appendingPathComponent("conversation.jsonl")
    var saved: [ChatMessage] = []
    let timeline = ChatTimeline(loadMessages: { saved }, conversationFileURL: conversationURL, store: ChatTimelineStore(fileURL: dataDirectory.appendingPathComponent("poll-timeline.jsonl")))
    timeline.startWatching()
    timeline.userAsked("Is it live?")
    check("live: the question shows before it is saved", timeline.items.last?.content == .userMessage("Is it live?") && timeline.isWaitingForReply)
    timeline.streamingReply(text: "Yes, [POINT:1", isFinal: false)
    check("live: the reply shows as it streams, without tags", timeline.items.last?.content == .streamingReply("Yes,") && !timeline.isWaitingForReply)
    timeline.streamingReply(text: "Yes, it is.", isFinal: true)
    saved = [ChatMessage(isFromUser: true, text: "Is it live?", date: Date()), ChatMessage(isFromUser: false, text: "Yes, it is.", date: Date())]
    try? "changed".write(to: conversationURL, atomically: true, encoding: .utf8)
    settle(1.3)
    check("live: after the file changes, the saved messages replace the live ones", timeline.items.map(\.content) == [.userMessage("Is it live?"), .assistantMessage("Yes, it is.")])
    timeline.post(.note("A note"))
    check("live: a posted row appears at once", timeline.items.last?.plainText == "A note")

    // Saved dates are whole seconds, so a short reply saved in the second it started
    // streaming reads as slightly older than the live copy. It must still replace it.
    timeline.userAsked("Quick one?")
    timeline.streamingReply(text: "Sure.", isFinal: true)
    let wholeSecondNow = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    saved += [ChatMessage(isFromUser: true, text: "Quick one?", date: wholeSecondNow), ChatMessage(isFromUser: false, text: "Sure.", date: wholeSecondNow)]
    try? "changed again".write(to: conversationURL, atomically: true, encoding: .utf8)
    settle(1.3)
    let sureCount = timeline.items.filter { $0.plainText == "Sure." }.count
    check("live: a reply saved within its first second shows once, not twice (\(sureCount))", sureCount == 1)
    timeline.stopWatching()
}

print(failures == 0 ? "\nALL CHECKS PASSED; PNGs in \(outputDirectory.path)" : "\n\(failures) CHECKS FAILED")
exit(failures == 0 ? 0 : 1)
