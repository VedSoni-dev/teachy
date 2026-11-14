//
//  dictation_tests.swift
//
//  Standalone tests for the pure dictation logic. Run with:
//      scripts/tests/run_dictation_tests.sh
//
//  Compiled together with (and only with):
//      leanring-buddy/Dictation/DictationHotkeyStateMachine.swift
//      leanring-buddy/Dictation/DictationTextRules.swift
//      leanring-buddy/Dictation/DictationDictionary.swift
//
//  Exits non-zero if any check fails.
//

import Foundation

nonisolated(unsafe) var failureCount = 0
nonisolated(unsafe) var checkCount = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("FAIL line \(line): \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("FAIL line \(line): \(message)\n   expected: \(expected)\n   actual:   \(actual)")
    }
}

typealias Machine = DictationHotkeyStateMachine

/// Feeds (event, time) pairs and returns every action produced, in order.
func run(_ events: [(Machine.Event, TimeInterval)], machine: inout Machine) -> [Machine.Action] {
    events.flatMap { machine.handle($0.0, at: $0.1) }
}

/// 16-bit mono sine wave (or silence when amplitude is 0).
func tone(seconds: Double, amplitude: Double, sampleRate: Int = 16_000) -> Data {
    var data = Data()
    for index in 0..<Int(seconds * Double(sampleRate)) {
        let value = sin(Double(index) * 2 * .pi * 220 / Double(sampleRate)) * amplitude
        var sample = Int16(max(-1, min(1, value)) * 32767).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}

func range(of needle: String, in text: String) -> NSRange {
    (text as NSString).range(of: needle)
}

// MARK: - Hotkey

func testChord() {
    let fn = DictationChord.functionMask, control = DictationChord.controlMask
    check(DictationChord.isHeld(flagsRawValue: fn | control), "fn+control is the chord")
    check(DictationChord.isHeld(flagsRawValue: fn | control | 0x100), "device-dependent low bits are ignored")
    check(!DictationChord.isHeld(flagsRawValue: control), "control alone is not the chord")
    check(!DictationChord.isHeld(flagsRawValue: fn), "fn alone is not the chord")
    check(!DictationChord.isHeld(flagsRawValue: control | DictationChord.optionMask),
          "control+option (push-to-talk) is not the chord")
    check(!DictationChord.isHeld(flagsRawValue: fn | control | DictationChord.optionMask),
          "fn+control+option is left to push-to-talk")
    check(!DictationChord.isHeld(flagsRawValue: fn | control | DictationChord.commandMask), "command breaks the chord")
    check(!DictationChord.isHeld(flagsRawValue: fn | control | DictationChord.shiftMask), "shift breaks the chord")
}

func testHoldToDictate() {
    var machine = Machine()
    checkEqual(machine.handle(.chordDown, at: 10.0), [.startRecording], "press starts recording at once")
    check(machine.isRecording, "recording while held")
    checkEqual(machine.handle(.tick, at: 10.5), [], "ticks do nothing during a hold")
    checkEqual(machine.handle(.chordUp, at: 12.0), [.finish], "release after a hold finishes")
    checkEqual(machine.state, .idle, "idle after finishing")
    checkEqual(machine.deadline, nil, "no deadline when idle")
}

func testSingleQuickTapEndsAfterTheWindow() {
    var machine = Machine()
    checkEqual(run([(.chordDown, 1.0), (.chordUp, 1.2)], machine: &machine), [.startRecording],
               "a quick tap keeps recording while a second tap is possible")
    checkEqual(machine.deadline, 1.2 + machine.configuration.doubleTapGap, "deadline is the end of the double-tap window")
    checkEqual(machine.handle(.tick, at: 1.4), [], "no action before the window ends")
    checkEqual(machine.handle(.tick, at: 1.7), [.finish], "window over: the tap ends (the silence gate drops it)")
    checkEqual(machine.state, .idle, "idle after the lone tap")
}

func testDoubleTapHandsFree() {
    var machine = Machine()
    let start = run([(.chordDown, 1.0), (.chordUp, 1.15), (.chordDown, 1.35)], machine: &machine)
    checkEqual(start, [.startRecording, .enterHandsFree], "double-tap enters hands-free without restarting the recording")
    checkEqual(machine.handle(.chordUp, at: 1.5), [], "releasing the second tap keeps listening")
    checkEqual(machine.state, .handsFree(.listening), "listening hands-free")
    checkEqual(machine.handle(.otherKeyDown, at: 3.0), [], "typing while hands-free does not cancel")
    checkEqual(machine.handle(.tick, at: 30.0), [], "hands-free does not time out in the state machine")

    // A single tap, or a long press, does not stop it.
    checkEqual(run([(.chordDown, 40.0), (.chordUp, 40.1), (.tick, 41.0)], machine: &machine), [], "one tap does not stop hands-free")
    checkEqual(machine.state, .handsFree(.listening), "still listening after one tap")
    checkEqual(run([(.chordDown, 50.0), (.chordUp, 52.0)], machine: &machine), [], "a long press does not stop hands-free")

    // Two taps too far apart do not stop it either.
    checkEqual(run([(.chordDown, 60.0), (.chordUp, 60.1), (.chordDown, 61.0), (.chordUp, 61.1), (.tick, 62.0)], machine: &machine),
               [], "slow taps are not a double-tap")

    let stop = run([(.chordDown, 70.0), (.chordUp, 70.1), (.chordDown, 70.3)], machine: &machine)
    checkEqual(stop, [.finish], "double-tap again finishes")
    checkEqual(machine.state, .idle, "idle after stopping")
    checkEqual(machine.handle(.chordUp, at: 70.4), [], "the release of the stopping tap is ignored")
}

func testSlowSecondPressIsANewHold() {
    var machine = Machine()
    let actions = run([(.chordDown, 1.0), (.chordUp, 1.1), (.chordDown, 2.0)], machine: &machine)
    checkEqual(actions, [.startRecording, .finish, .startRecording],
               "a second press after the window ends the tap and starts a fresh hold")
    checkEqual(machine.state, .holding(since: 2.0), "holding the new press")
}

func testCancel() {
    var machine = Machine()
    checkEqual(run([(.chordDown, 1.0), (.escape, 1.5)], machine: &machine), [.startRecording, .cancel], "escape cancels a hold")
    checkEqual(machine.handle(.chordUp, at: 2.0), [], "release after cancel does nothing")

    checkEqual(run([(.chordDown, 3.0), (.otherKeyDown, 3.2)], machine: &machine), [.startRecording, .cancel],
               "another key during a hold means a keyboard shortcut, so cancel")

    checkEqual(run([(.chordDown, 5.0), (.chordUp, 5.1), (.escape, 5.2)], machine: &machine), [.startRecording, .cancel],
               "escape cancels a pending tap")

    _ = run([(.chordDown, 7.0), (.chordUp, 7.1), (.chordDown, 7.2), (.chordUp, 7.3)], machine: &machine)
    checkEqual(machine.handle(.escape, at: 9.0), [.cancel], "escape cancels hands-free")
    checkEqual(machine.state, .idle, "idle after cancelling hands-free")

    checkEqual(machine.handle(.escape, at: 10.0), [], "escape when idle does nothing")
    checkEqual(machine.handle(.otherKeyDown, at: 10.0), [], "typing when idle does nothing")
    checkEqual(machine.handle(.chordUp, at: 10.0), [], "a stray release when idle does nothing")
}

// MARK: - Silence gate and chunking

func testSilenceGate() {
    let gate = DictationSilenceGate()
    let rate = 16_000
    check(gate.shouldDiscard(pcm16: tone(seconds: 0.15, amplitude: 0.5), sampleRate: rate, liveText: "hello"),
          "very short audio is dropped even if loud")
    check(gate.shouldDiscard(pcm16: tone(seconds: 2, amplitude: 0), sampleRate: rate, liveText: ""), "silence is dropped")
    check(gate.shouldDiscard(pcm16: tone(seconds: 2, amplitude: 0.002), sampleRate: rate, liveText: ""), "room noise is dropped")
    check(!gate.shouldDiscard(pcm16: tone(seconds: 2, amplitude: 0.2), sampleRate: rate, liveText: ""), "speech-level audio is kept")
    check(!gate.shouldDiscard(pcm16: tone(seconds: 2, amplitude: 0.002), sampleRate: rate, liveText: "send it"),
          "quiet audio is kept when the on-device recognizer heard words")
    check(gate.shouldDiscard(pcm16: tone(seconds: 2, amplitude: 0.002), sampleRate: rate, liveText: " ... "),
          "punctuation-only live text does not count as words")

    var mostlySilent = tone(seconds: 3, amplitude: 0)
    mostlySilent.append(tone(seconds: 0.5, amplitude: 0.2))
    check(!gate.shouldDiscard(pcm16: mostlySilent, sampleRate: rate, liveText: ""), "a short phrase after a long pause is kept")

    checkEqual(DictationSilenceGate.rms(pcm16: Data()), 0, "rms of nothing is zero")
    let level = DictationSilenceGate.rms(pcm16: tone(seconds: 1, amplitude: 0.5))
    check(abs(level - 0.5 / 2.0.squareRoot()) < 0.01, "rms of a sine is amplitude / sqrt(2)")
    checkEqual(DictationSilenceGate.seconds(pcm16ByteCount: 32_000, sampleRate: rate), 1.0, "32,000 bytes at 16 kHz is one second")

    check(DictationSilenceGate.isEmptyTranscript("", dictionaryPrompt: nil), "empty transcript")
    check(DictationSilenceGate.isEmptyTranscript(" . ", dictionaryPrompt: nil), "punctuation-only transcript")
    check(DictationSilenceGate.isEmptyTranscript("Publik, Teachy.", dictionaryPrompt: "Publik, Teachy"),
          "a transcript that only echoes the dictionary prompt is empty")
    check(!DictationSilenceGate.isEmptyTranscript("Publik is great", dictionaryPrompt: "Publik, Teachy"), "real words are kept")
    check(!DictationSilenceGate.isEmptyTranscript("好", dictionaryPrompt: nil), "one CJK character is a transcript")
}

func testChunking() {
    let rate = 16_000
    let short = tone(seconds: 5, amplitude: 0.2)
    checkEqual(DictationAudioChunker.split(pcm16: short, sampleRate: rate, maximumSeconds: 10).count, 1, "short audio is one chunk")

    // 8 s speech, 0.5 s pause, 8 s speech; limit 10 s, so the cut should land in the pause.
    var audio = tone(seconds: 8, amplitude: 0.3)
    audio.append(tone(seconds: 0.5, amplitude: 0))
    audio.append(tone(seconds: 8, amplitude: 0.3))
    let chunks = DictationAudioChunker.split(pcm16: audio, sampleRate: rate, maximumSeconds: 10, searchSeconds: 4)
    checkEqual(chunks.count, 2, "split into two chunks")
    checkEqual(chunks.reduce(0) { $0 + $1.count }, audio.count, "no audio lost or repeated")
    check(chunks.allSatisfy { $0.count % 2 == 0 }, "chunks hold whole samples")
    check(chunks.allSatisfy { $0.count <= 10 * rate * 2 }, "no chunk is over the limit")
    let cutSeconds = Double(chunks[0].count) / Double(rate * 2)
    check(cutSeconds >= 8.0 && cutSeconds <= 8.5, "the cut is inside the pause (was \(cutSeconds) s)")

    let long = tone(seconds: 35, amplitude: 0.3)
    let longChunks = DictationAudioChunker.split(pcm16: long, sampleRate: rate, maximumSeconds: 10)
    check(longChunks.count >= 4, "continuous audio still splits")
    checkEqual(longChunks.reduce(0) { $0 + $1.count }, long.count, "continuous audio is all kept")
    check(longChunks.allSatisfy { $0.count <= 10 * rate * 2 && $0.count % 2 == 0 }, "every chunk fits")

    // A slice with a non-zero start index must not crash or shift.
    let slice = audio.subdata(in: 1000..<audio.count)[...]
    checkEqual(DictationAudioChunker.split(pcm16: Data(slice), sampleRate: rate, maximumSeconds: 10).reduce(0) { $0 + $1.count },
               slice.count, "sliced input is handled")
}

// MARK: - Cleanup guardrails

func testCleanupGuards() {
    check(DictationCleanup.shouldSkip(raw: "sounds good thanks"), "three words skip cleanup")
    check(!DictationCleanup.shouldSkip(raw: "sounds good to me"), "four words get cleanup")
    check(DictationCleanup.shouldSkip(raw: "好的"), "two CJK characters skip cleanup")
    check(!DictationCleanup.shouldSkip(raw: "今天天气很好"), "a CJK sentence gets cleanup")

    let body = DictationCleanup.requestBody(raw: "um so hello there")
    check(body["model"] == nil, "the body has no model key (the router sets it)")
    let messages = body["messages"] as? [[String: String]] ?? []
    checkEqual(messages.count, 2, "system + user message")
    checkEqual(messages.last?["content"], "<transcript>\num so hello there\n</transcript>", "input is wrapped in transcript tags")
    check(messages.first?["content"]?.contains("Never answer") == true, "the prompt forbids answering")
    check(messages.first?["content"]?.contains("em dashes") == true, "the prompt forbids em dashes")
    check(!DictationCleanup.systemPrompt.contains("\u{2014}"), "the prompt itself has no em dash")
    check(JSONSerialization.isValidJSONObject(body), "the body is valid JSON")

    let raw = "um so i think we should uh ship the dictation feature on friday"
    let good = "So I think we should ship the dictation feature on Friday."
    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: good).text, good, "a faithful cleanup is used")
    check(DictationCleanup.finalText(raw: raw, modelOutput: good).usedCleanup, "and reported as used")

    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: "<transcript>\n\(good)\n</transcript>").text, good,
               "a copied transcript wrapper is stripped")
    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: "<cleaned>\(good)</cleaned>").text, good, "other wrapper tags are stripped")
    checkEqual(DictationCleanup.stripTags("use the <div> tag", raw: "use the <div> tag"), "use the <div> tag",
               "a tag the speaker dictated is kept")
    checkEqual(DictationCleanup.stripTags("<transcript>hi</transcript>", raw: "say <transcript> hi"), "hi",
               "the transcript wrapper is always removed")
    checkEqual(DictationCleanup.stripTags("a < b and c > d", raw: "x"), "a < b and c > d", "comparisons are not tags")

    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: nil).text, raw, "no model output: raw transcript")
    check(!DictationCleanup.finalText(raw: raw, modelOutput: nil).usedCleanup, "raw is reported as not cleaned")
    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: "").text, raw, "empty model output: raw transcript")
    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: "Ship it.").text, raw, "a cleanup under half the length is rejected")
    let padded = good + " Also, we should think carefully about the rollout plan and tell the whole team about it."
    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: padded).text, raw, "a cleanup over 150% of the length is rejected")

    let question = "what is the capital of france and how many people live there"
    let answer = "The capital of France is Paris, home to roughly two million residents."
    checkEqual(DictationCleanup.finalText(raw: question, modelOutput: answer).text, question,
               "an answer of similar length is rejected because the words differ")
    checkEqual(DictationCleanup.finalText(raw: question, modelOutput: "What is the capital of France, and how many people live there?").text,
               "What is the capital of France, and how many people live there?", "a dictated question is cleaned, not answered")

    checkEqual(DictationCleanup.finalText(raw: raw, modelOutput: "So I think we should ship the dictation feature \u{2014} on Friday.").text,
               "So I think we should ship the dictation feature, on Friday.", "em dashes from the model become commas")
    checkEqual(DictationCleanup.removeEmDashes("wait\u{2014}what"), "wait, what", "unspaced em dash")
    checkEqual(DictationCleanup.removeEmDashes("\u{2014} hello"), "hello", "leading em dash is dropped")
    checkEqual(DictationCleanup.removeEmDashes("pages 3\u{2013}5"), "pages 3\u{2013}5", "en dashes in ranges are left alone")
    checkEqual(DictationCleanup.finalText(raw: "ok \u{2014} sure", modelOutput: nil).text, "ok, sure", "em dashes are removed from raw text too")

    let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": "Hello."]]]])
    checkEqual(DictationCleanup.content(fromResponse: response), "Hello.", "content is read from a chat-completions response")
    let parts = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": [["type": "text", "text": "Hi."]]]]]])
    checkEqual(DictationCleanup.content(fromResponse: parts), "Hi.", "content parts are joined")
    checkEqual(DictationCleanup.content(fromResponse: Data("nope".utf8)), nil, "garbage has no content")

    let chinese = "嗯今天我们去公园玩吧"
    checkEqual(DictationCleanup.finalText(raw: chinese, modelOutput: "今天我们去公园玩吧。").text, "今天我们去公园玩吧。", "CJK cleanup is accepted")
    checkEqual(DictationCleanup.finalText(raw: chinese, modelOutput: "Let's go to the park today.").text, chinese, "a translation is rejected")
}

// MARK: - Insertion rules

func testInsertionRules() {
    for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                   "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty"] {
        check(DictationInsertionRules.isTerminal(bundleIdentifier: bundle), "\(bundle) is a terminal")
    }
    for bundle in ["com.apple.Notes", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "com.apple.TextEdit"] {
        check(!DictationInsertionRules.isTerminal(bundleIdentifier: bundle), "\(bundle) is not a terminal")
    }
    check(!DictationInsertionRules.isTerminal(bundleIdentifier: nil), "no app is not a terminal")

    checkEqual(DictationInsertionRules.textToInsert("git status\n\nthen push\r\n", bundleIdentifier: "com.apple.Terminal"),
               "git status then push ", "newlines collapse to spaces in a terminal")
    checkEqual(DictationInsertionRules.textToInsert("Line one.\nLine two.", bundleIdentifier: "com.apple.Notes"),
               "Line one.\nLine two. ", "newlines are kept elsewhere")
    checkEqual(DictationInsertionRules.textToInsert("  Hello there.  ", bundleIdentifier: nil), "Hello there. ",
               "trimmed, with one trailing space")
    checkEqual(DictationInsertionRules.textToInsert("你好世界", bundleIdentifier: nil), "你好世界", "no trailing space after Chinese")
    checkEqual(DictationInsertionRules.textToInsert("你好。", bundleIdentifier: nil), "你好。", "no trailing space after CJK punctuation")
    checkEqual(DictationInsertionRules.textToInsert("こんにちは", bundleIdentifier: nil), "こんにちは", "no trailing space after Japanese")
    checkEqual(DictationInsertionRules.textToInsert("สวัสดี", bundleIdentifier: nil), "สวัสดี", "no trailing space after Thai")
    checkEqual(DictationInsertionRules.textToInsert("안녕하세요", bundleIdentifier: nil), "안녕하세요 ", "Korean uses spaces, so it gets one")
    checkEqual(DictationInsertionRules.textToInsert("我用 Teachy", bundleIdentifier: nil), "我用 Teachy ", "mixed text ending in Latin gets a space")
    checkEqual(DictationInsertionRules.textToInsert(" \n ", bundleIdentifier: nil), "", "whitespace-only text inserts nothing")
}

func testFocusAndPasteKey() {
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: "AXTextArea", isSelectedTextSettable: true), .textField,
               "a settable text area is a text field")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: "AXGroup", isSelectedTextSettable: true), .textField,
               "anything with settable selected text is a text field")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: "AXTextField", isSelectedTextSettable: false), .textField,
               "a text role without settable selection still gets a paste")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: nil, isSelectedTextSettable: false), .unknown,
               "no focused element (Electron, some terminals) means paste")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: "AXWebArea", isSelectedTextSettable: false), .unknown,
               "a web area is unknown")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: "AXButton", isSelectedTextSettable: false), .notText,
               "a button is not a text field")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: true, role: "AXOutline", isSelectedTextSettable: false), .notText,
               "a Finder list is not a text field")
    checkEqual(DictationFocusKind.classify(hasFrontmostApp: false, role: "AXTextArea", isSelectedTextSettable: true), .notText,
               "no frontmost app means clipboard")

    typealias Key = DictationPasteKey.Candidate
    let qwerty = [Key(keyCode: 9, plain: "v", withCommand: "v"), Key(keyCode: 47, plain: ".", withCommand: ".")]
    let dvorak = [Key(keyCode: 9, plain: "k", withCommand: "k"), Key(keyCode: 47, plain: "v", withCommand: "v")]
    let colemak = [Key(keyCode: 9, plain: "v", withCommand: "v"), Key(keyCode: 15, plain: "p", withCommand: "p")]
    let dvorakQwertyCommand = [Key(keyCode: 9, plain: "k", withCommand: "v"), Key(keyCode: 47, plain: "v", withCommand: ".")]
    let russian = [Key(keyCode: 9, plain: "м", withCommand: "м")]
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: [qwerty]), 9, "QWERTY: v is key 9")
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: [dvorak]), 47, "Dvorak: v is the QWERTY period key")
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: [colemak]), 9, "Colemak: v stays on key 9")
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: [dvorakQwertyCommand]), 9, "Dvorak-QWERTY-Command: the Command mapping wins")
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: [russian, dvorak]), 47, "no v in the layout: use the ASCII-capable layout")
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: [russian]), 9, "no v anywhere: ANSI position")
    checkEqual(DictationPasteKey.keyCodeForV(inLayouts: []), 9, "no layouts: ANSI position")
}

// MARK: - Dictionary learning

func testEditDiff() {
    let inserted = "I talked to Vedant about public billing today. "
    let baseline = "Notes:\n" + inserted
    let insertedRange = range(of: inserted, in: baseline)

    func learned(_ current: String) -> DictationEditDiff.Correction? {
        DictationEditDiff.correction(baseline: baseline, current: current, insertedRange: insertedRange)
    }

    checkEqual(learned(baseline.replacingOccurrences(of: "public", with: "Publik")),
               DictationEditDiff.Correction(heard: "public", corrected: "Publik"), "one fixed word is learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "today.", with: "todya.")),
               DictationEditDiff.Correction(heard: "today", corrected: "todya"),
               "punctuation around the word is not part of the correction")
    checkEqual(learned(baseline), nil, "no edit, nothing learned")
    checkEqual(learned(baseline + "And then we shipped it."), nil, "typing more after the dictation is not a correction")
    checkEqual(learned(baseline.replacingOccurrences(of: "public", with: "Publik") + "More text typed afterwards."),
               DictationEditDiff.Correction(heard: "public", corrected: "Publik"), "a fix plus more typing still learns the fix")
    checkEqual(learned("Hello!\n" + baseline.replacingOccurrences(of: "public", with: "Publik")),
               DictationEditDiff.Correction(heard: "public", corrected: "Publik"), "text added before the dictation does not matter")
    checkEqual(learned(baseline.replacingOccurrences(of: "public billing", with: "Publik invoices")), nil, "two changed words: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "public", with: "the publik")), nil, "one word replaced by two: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "public ", with: "")), nil, "a deleted word: nothing learned")
    checkEqual(learned("Notes:\nWe had a completely different conversation."), nil, "a rewrite: nothing learned")
    checkEqual(learned(""), nil, "a cleared field: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "public", with: "extraordinarily")), nil, "a very different word: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "today.", with: "today!")), nil, "a punctuation-only edit: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "Notes:", with: "Notez:")), nil, "an edit outside the dictated text: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "about", with: "5")), nil, "a replacement with no letters: nothing learned")
    checkEqual(learned(baseline.replacingOccurrences(of: "Vedant", with: "vedant")),
               DictationEditDiff.Correction(heard: "Vedant", corrected: "vedant"), "a capitals-only fix is a correction")

    checkEqual(DictationEditDiff.correction(baseline: "ab", current: "cd", insertedRange: NSRange(location: 0, length: 0)), nil,
               "no inserted range, nothing learned")

    checkEqual(DictationEditDiff.editDistance("kitten", "sitting"), 3, "edit distance")
    checkEqual(DictationEditDiff.editDistance("", "abc"), 3, "edit distance from empty")
    checkEqual(DictationEditDiff.editDistance("same", "same"), 0, "edit distance of equal strings")

    let commonWords: Set<String> = ["there", "their", "today", "the", "paris"]
    let isKnown: (String) -> Bool = { commonWords.contains($0) }
    check(DictationEditDiff.isWorthLearning("Publik", isKnownWord: isKnown), "an unknown name is worth learning")
    check(DictationEditDiff.isWorthLearning("GitHub", isKnownWord: { _ in true }), "inner capitals are worth learning")
    check(DictationEditDiff.isWorthLearning("gpt4", isKnownWord: { _ in true }), "words with digits are worth learning")
    check(!DictationEditDiff.isWorthLearning("there", isKnownWord: isKnown), "an ordinary word is not learned")
    check(!DictationEditDiff.isWorthLearning("The", isKnownWord: isKnown), "a capitalized ordinary word is not learned")
}

// MARK: - Dictionary and history files

func testDictionaryAndHistory() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("nested/dictionary.json")

    let dictionary = DictationDictionary(fileURL: fileURL)
    checkEqual(dictionary.words, [], "a missing file is an empty dictionary")
    checkEqual(dictionary.transcriptionPrompt, nil, "no words, no prompt")
    check(dictionary.add("Publik"), "add a word")
    check(dictionary.add("  Vedant   Soni \n"), "add a phrase")
    check(!dictionary.add("publik") || dictionary.words.contains("publik"), "re-adding with new capitals replaces the spelling")
    check(!dictionary.add("   "), "blank words are refused")
    check(!dictionary.add("Vedant Soni"), "an exact duplicate is refused")
    checkEqual(dictionary.words, ["Vedant Soni", "publik"], "words are stored once, whitespace collapsed")
    checkEqual(dictionary.transcriptionPrompt, "publik, Vedant Soni", "the prompt lists newest first")

    let onDisk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))) as? [String]
    checkEqual(onDisk, ["Vedant Soni", "publik"], "the file is a plain JSON list (and the folder was created)")
    checkEqual(DictationDictionary(fileURL: fileURL).words, ["Vedant Soni", "publik"], "a new instance reads the file")

    check(dictionary.remove("PUBLIK"), "remove ignores case")
    check(!dictionary.remove("nothing"), "removing a missing word reports false")
    checkEqual(dictionary.words, ["Vedant Soni"], "the word is gone")

    // A hand edit of the file is picked up.
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: fileURL.path)
    _ = dictionary.words
    try? Data("[\"Teachy\", \"teachy\", 7, \"Kubernetes\"]".utf8).write(to: fileURL)
    checkEqual(dictionary.words, ["Teachy", "Kubernetes"], "hand edits are re-read; duplicates and non-strings are dropped")

    let many = (0..<400).map { "word\($0)" }
    let prompt = DictationDictionary.prompt(from: many) ?? ""
    check(prompt.count <= DictationDictionary.maximumPromptCharacters, "the prompt is capped")
    check(prompt.hasPrefix("word399, word398"), "the cap keeps the newest words")

    let historyURL = directory.appendingPathComponent("more/history.jsonl")
    let history = DictationHistoryLog(fileURL: historyURL)
    check(history.append(.init(appBundleIdentifier: "com.apple.Notes", raw: "um hello\nthere", cleaned: "Hello there.",
                               transcriber: "publik", insertion: "accessibility")), "first entry is written")
    check(history.append(.init(appBundleIdentifier: nil, raw: "second \"quoted\"", cleaned: "Second.",
                               transcriber: "apple", insertion: "paste")), "second entry is appended")
    let lines = ((try? String(contentsOf: historyURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    func parse(_ line: String?) -> [String: String]? {
        guard let line else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
    }
    checkEqual(lines.count, 2, "one line per dictation")
    let first = parse(lines.first)
    checkEqual(first?["raw"], "um hello\nthere", "raw text survives, newlines escaped inside the line")
    checkEqual(first?["cleaned"], "Hello there.", "cleaned text is saved")
    checkEqual(first?["app"], "com.apple.Notes", "the app bundle id is saved")
    check(first?["timestamp"]?.hasSuffix("Z") == true, "the timestamp is ISO 8601")
    let second = parse(lines.last)
    checkEqual(second?["raw"], "second \"quoted\"", "the second line parses on its own")
}

@main
enum DictationTests {
    static func main() {
        testChord()
        testHoldToDictate()
        testSingleQuickTapEndsAfterTheWindow()
        testDoubleTapHandsFree()
        testSlowSecondPressIsANewHold()
        testCancel()
        testSilenceGate()
        testChunking()
        testCleanupGuards()
        testInsertionRules()
        testFocusAndPasteKey()
        testEditDiff()
        testDictionaryAndHistory()

        if failureCount > 0 {
            print("dictation tests: \(failureCount) of \(checkCount) checks FAILED")
            exit(1)
        }
        print("dictation tests: all \(checkCount) checks passed")
    }
}
