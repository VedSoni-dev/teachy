// Unit tests for the pure dictation-speed and writing logic.
// Run: scripts/tests/run_dictspeed_tests.sh

import Foundation

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL line \(line): \(message)\n   got:      \(actual)\n   expected: \(expected)")
    }
}

func expectAsync(_ condition: @autoclosure () async -> Bool, _ message: String, line: Int = #line) async {
    let result = await condition()
    expect(result, message, line: line)
}
func expectEqualAsync<T: Equatable>(_ actual: @autoclosure () async -> T, _ expected: T, _ message: String, line: Int = #line) async {
    let result = await actual()
    expectEqual(result, expected, message, line: line)
}

/// An in-memory text field with the ways real fields misbehave.
final class FakeField: DictationEditableField {
    enum Behaviour {
        case normal
        /// Accepts every edit and changes nothing (Chromium, Electron).
        case ignores
        /// Answers "timed out" and applies the edit after this many later reads.
        case timesOutThenAppliesAfter(reads: Int)
        /// Accepts, then inserts something other than what was asked.
        case mangles
        /// Nothing can be read.
        case unreadable
        /// Only the character count can be read.
        case countOnly
        /// Drops a trailing space from what is inserted.
        case trimsTrailingSpace
    }

    var text: String
    var selection: NSRange
    var behaviour: Behaviour
    var setTextCalls = 0
    private var pending: (text: String, readsLeft: Int)?

    init(_ text: String = "", caret: Int? = nil, behaviour: Behaviour = .normal) {
        self.text = text
        self.selection = NSRange(location: caret ?? (text as NSString).length, length: 0)
        self.behaviour = behaviour
    }

    private func tick() {
        guard var waiting = pending else { return }
        waiting.readsLeft -= 1
        if waiting.readsLeft <= 0 {
            pending = nil
            apply(waiting.text)
        } else {
            pending = waiting
        }
    }

    private func apply(_ inserted: String) {
        text = (text as NSString).replacingCharacters(in: selection, with: inserted)
        selection = NSRange(location: selection.location + (inserted as NSString).length, length: 0)
    }

    func value() -> String? {
        tick()
        switch behaviour {
        case .unreadable, .countOnly: return nil
        default: return text
        }
    }

    func characterCount() -> Int? {
        if case .unreadable = behaviour { return nil }
        return (text as NSString).length
    }

    func selectedRange() -> NSRange? {
        if case .unreadable = behaviour { return nil }
        return selection
    }

    func setSelectedRange(_ range: NSRange) -> Bool {
        guard range.location + range.length <= (text as NSString).length else { return false }
        selection = range
        return true
    }

    func setSelectedText(_ inserted: String) -> DictationFieldSetResult {
        setTextCalls += 1
        switch behaviour {
        case .normal, .countOnly:
            apply(inserted)
            return .accepted
        case .ignores, .unreadable:
            return .accepted
        case .timesOutThenAppliesAfter(let reads):
            pending = (inserted, reads)
            return .timedOut
        case .mangles:
            apply("???")
            return .accepted
        case .trimsTrailingSpace:
            apply(inserted.hasSuffix(" ") ? String(inserted.dropLast()) : inserted)
            return .accepted
        }
    }

    /// The person types at the caret.
    func userTypes(_ typed: String) {
        apply(typed)
    }
}

func noWait(_ milliseconds: Int) async {}

// MARK: - Setting

do {
    let suite = "dictspeed-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    expectEqual(DictationSpeedMode.current(defaults), .speedFirst, "speed first is the default")
    expect(DictationSpeedMode.liveInsertionEnabled(defaults), "live insertion is on by default")
    defaults.set("accuracy", forKey: "teachyDictationSpeedMode")
    expectEqual(DictationSpeedMode.current(defaults), .accuracyFirst, "accuracy read from defaults")
    defaults.set("nonsense", forKey: "teachyDictationSpeedMode")
    expectEqual(DictationSpeedMode.current(defaults), .speedFirst, "unknown value falls back to the default")
    defaults.set(false, forKey: "teachyDictationLiveInsertionEnabled")
    expect(!DictationSpeedMode.liveInsertionEnabled(defaults), "live insertion can be turned off")
    DictationSpeedMode.save(.accuracyFirst, defaults)
    expectEqual(defaults.string(forKey: DictationSpeedMode.defaultsKey), "accuracy", "save writes the raw value")
}

// MARK: - Stable prefix

do {
    var stable = DictationStablePrefix()
    expectEqual(stable.feed("Let's"), "", "one hypothesis: nothing is stable yet")
    expectEqual(stable.feed("Let's meet"), "Let's", "agreed word, newest held back")
    expectEqual(stable.feed("Let's meet at"), "Let's meet", "grows a word at a time")
    expectEqual(stable.feed("Let's meet at tree"), "Let's meet at", "the newest word is held back")
    expectEqual(stable.feed("Let's meet at three tomorrow"), "Let's meet at", "a revised word is not stable until seen twice")
    expectEqual(stable.feed("Let's meet at three tomorrow"), "Let's meet at three", "same hypothesis twice: all but the last word")
    expectEqual(stable.feed("Lets meet at three tomorrow"), "", "a revised first word takes the prefix back")
    var eager = DictationStablePrefix(holdBackWords: 0)
    _ = eager.feed("a b")
    expectEqual(eager.feed("a b c"), "a b", "no hold-back: everything both agree on")
    var unspaced = DictationStablePrefix()
    _ = unspaced.feed("今日は")
    expectEqual(unspaced.feed("今日はいい天気"), "", "text without spaces is never typed early")
}

// MARK: - Locating typed text

do {
    typealias Locator = DictationRangeLocator
    expectEqual(Locator.locate(value: "Hi there friend", expectedLocation: 3, inserted: "there"), NSRange(location: 3, length: 5), "found where expected")
    expectEqual(Locator.locate(value: "Oh. Hi there friend", expectedLocation: 3, inserted: "there"), NSRange(location: 7, length: 5), "text added before it: found by its one occurrence")
    expect(Locator.locate(value: "Hi their friend", expectedLocation: 3, inserted: "there") == nil, "edited text is not found")
    expect(Locator.locate(value: "x the the", expectedLocation: 0, inserted: "the") == nil, "two occurrences elsewhere: ambiguous, so nil")
    expectEqual(Locator.locate(value: "the the", expectedLocation: 4, inserted: "the"), NSRange(location: 4, length: 3), "the expected spot wins over ambiguity")
    expectEqual(Locator.locate(value: "abc", expectedLocation: 3, inserted: ""), NSRange(location: 3, length: 0), "empty text sits at the caret")
    expect(Locator.locate(value: "abc", expectedLocation: 9, inserted: "") == nil, "caret outside the field")
    expectEqual(Locator.replacing(NSRange(location: 1, length: 1), in: "abc", with: "XY"), "aXYc", "replace in range")
    expect(Locator.replacing(NSRange(location: 2, length: 5), in: "abc", with: "x") == nil, "range that does not fit")
}

do {
    typealias Edit = DictationLiveEdit
    expectEqual(Edit.plan(from: "Let's meet", to: "Let's meet at"), Edit.Plan(keepLength: 10, deleteLength: 0, insert: " at"), "append only")
    expectEqual(Edit.plan(from: "meet at tree", to: "meet at three tomorrow"), Edit.Plan(keepLength: 9, deleteLength: 3, insert: "hree tomorrow"), "replace the changed end")
    expectEqual(Edit.plan(from: "abc", to: ""), Edit.Plan(keepLength: 0, deleteLength: 3, insert: ""), "take everything back")
    expectEqual(Edit.plan(from: "ok 👍🏽", to: "ok 👍"), Edit.Plan(keepLength: 3, deleteLength: 4, insert: "👍"), "an emoji is never cut in half")
    expectEqual(Edit.plan(from: "same", to: "same"), Edit.Plan(keepLength: 4, deleteLength: 0, insert: ""), "no change")
}

// MARK: - Did the insertion happen?

do {
    typealias Evidence = DictationInsertEvidence
    typealias Snapshot = DictationInsertEvidence.Snapshot
    let caret = NSRange(location: 6, length: 0)
    expectEqual(
        Evidence.classify(before: Snapshot(value: "Hello ", characterCount: 6, selection: caret),
                          after: Snapshot(value: "Hello world ", characterCount: 12, selection: NSRange(location: 12, length: 0)),
                          inserted: "world "),
        .verified(value: "Hello world ", range: NSRange(location: 6, length: 6)), "exact insertion at the caret")
    expectEqual(
        Evidence.classify(before: Snapshot(value: "Hello ", selection: caret),
                          after: Snapshot(value: "Hello world", selection: NSRange(location: 11, length: 0)),
                          inserted: "world "),
        .verified(value: "Hello world", range: NSRange(location: 6, length: 5)), "trailing space trimmed by the field")
    expectEqual(
        Evidence.classify(before: Snapshot(value: "Hello ", selection: caret), after: Snapshot(value: "Hello ", selection: caret), inserted: "world "),
        .noChange, "nothing changed")
    expectEqual(
        Evidence.classify(before: Snapshot(value: "Hello ", selection: caret), after: Snapshot(value: "Hello ???", selection: caret), inserted: "world "),
        .changedUnverified, "changed, but not to our text")
    expectEqual(
        Evidence.classify(before: Snapshot(value: "Hello ", selection: caret), after: Snapshot(value: "Hello ", selection: NSRange(location: 3, length: 0)), inserted: "world "),
        .changedUnverified, "only the caret moved: something happened, so no paste")
    expectEqual(
        Evidence.classify(before: Snapshot(characterCount: 10, selection: caret), after: Snapshot(characterCount: 16, selection: caret), inserted: "world "),
        .verified(value: nil, range: nil), "count grew by the inserted length")
    expectEqual(
        Evidence.classify(before: Snapshot(characterCount: 10, selection: caret), after: Snapshot(characterCount: 13, selection: caret), inserted: "world "),
        .changedUnverified, "count changed by some other amount: still no paste")
    expectEqual(
        Evidence.classify(before: Snapshot(characterCount: 10), after: Snapshot(characterCount: 10), inserted: "world "),
        .noChange, "count the same")
    expectEqual(
        Evidence.classify(before: Snapshot(value: "world ", selection: NSRange(location: 6, length: 0)),
                          after: Snapshot(value: "world world ", selection: NSRange(location: 12, length: 0)), inserted: "world "),
        .verified(value: "world world ", range: NSRange(location: 6, length: 6)), "same words already in the field")
    expectEqual(
        Evidence.classify(before: Snapshot(value: "abcdef", selection: NSRange(location: 2, length: 3)),
                          after: Snapshot(value: "abXf", selection: NSRange(location: 3, length: 0)), inserted: "X"),
        .verified(value: "abXf", range: NSRange(location: 2, length: 1)), "replacing a selection")
    expectEqual(Evidence.occurrences(of: "ab", in: "ab ab abab"), 4, "occurrence count")
}

@MainActor func runAsyncTests() async {
    typealias Insert = DictationVerifiedInsert

    // The double-insertion cases: when is a paste allowed afterwards?
    do {
        let field = FakeField("Hello ")
        let outcome = await Insert.insert("world ", into: field, wait: noWait)
        expectEqual(outcome, .inserted(value: "Hello world ", range: NSRange(location: 6, length: 6)), "normal field: inserted and checked")
        expectEqual(field.text, "Hello world ", "the text is in once")
    }
    do {
        let field = FakeField("Hello ", behaviour: .ignores)
        await expectEqualAsync(await Insert.insert("world ", into: field, wait: noWait), .noEffect, "a field that ignores the edit: paste is safe")
    }
    do {
        // The known risk: a slow app times out, the caller pasted, then the app
        // applied the Accessibility edit too. Now the long wait sees it land.
        let field = FakeField("Hello ", behaviour: .timesOutThenAppliesAfter(reads: 5))
        var waited = 0
        let outcome = await Insert.insert("world ", into: field) { waited += $0 }
        expectEqual(outcome, .inserted(value: "Hello world ", range: NSRange(location: 6, length: 6)), "slow app: the late insertion is seen, so no paste")
        expect(waited >= 60 && waited <= 2_000, "the wait is bounded (waited \(waited) ms)")
        expectEqual(field.text, "Hello world ", "slow app: text in once")
    }
    do {
        let field = FakeField("Hello ", behaviour: .timesOutThenAppliesAfter(reads: 1_000))
        var waited = 0
        let outcome = await Insert.insert("world ", into: field) { waited += $0 }
        expectEqual(outcome, .noEffect, "an app that never applies it: paste after the full wait")
        expectEqual(waited, Insert.timedOutWaits.reduce(0, +), "timed-out apps get the long schedule")
        expect(Insert.timedOutWaits.reduce(0, +) <= 2_000, "long schedule stays under 2 s")
        expect(Insert.acceptedWaits.reduce(0, +) <= 600, "normal schedule stays under 0.6 s")
    }
    do {
        let field = FakeField("Hello ", behaviour: .mangles)
        await expectEqualAsync(await Insert.insert("world ", into: field, wait: noWait), .changedUnverified, "field changed to something else: never paste on top")
    }
    do {
        let field = FakeField("Hello ", behaviour: .unreadable)
        await expectEqualAsync(await Insert.insert("world ", into: field, wait: noWait), .cannotCheck, "unreadable field: no insertion is attempted")
        expectEqual(field.setTextCalls, 0, "unreadable field is not written to")
    }
    do {
        let field = FakeField("Hello ", behaviour: .countOnly)
        await expectEqualAsync(await Insert.insert("world ", into: field, wait: noWait), .inserted(value: nil, range: nil), "count-only field: checked by length")
    }
    do {
        let field = FakeField("Hello ", behaviour: .trimsTrailingSpace)
        await expectEqualAsync(await Insert.insert("world ", into: field, wait: noWait), .inserted(value: "Hello world", range: NSRange(location: 6, length: 5)), "trimmed trailing space still counts")
    }

    // Live region: typing while speaking.
    do {
        let field = FakeField("Note: ")
        let region = DictationLiveRegion(field: field)!
        var stable = DictationStablePrefix()
        for hypothesis in ["Let's", "Let's meet", "Let's meet at", "Let's meet at tree", "Let's meet at tree tomorrow"] {
            let target = stable.feed(hypothesis)
            if !target.isEmpty { _ = await region.update(to: target, wait: noWait) }
        }
        expectEqual(field.text, "Note: Let's meet at tree", "stable words are typed as they settle")
        await expectAsync(await region.update(to: "Let's meet at three tomorrow. ", wait: noWait), "final on-device text completes the region")
        expectEqual(field.text, "Note: Let's meet at three tomorrow. ", "the revised word was replaced in place")
        expectEqual(field.selection, NSRange(location: 36, length: 0), "caret ends after the text")
        expect(region.isIntact, "region is intact")
        await expectAsync(await region.update(to: "Let's meet at 3 tomorrow. ", wait: noWait), "accurate text replaces the region")
        expectEqual(field.text, "Note: Let's meet at 3 tomorrow. ", "replaced in place")
        expectEqual(region.lastDelta, -4, "length change is reported")
    }
    do {
        // The person keeps typing after the dictation; the correction must not
        // move their caret or touch their words.
        let field = FakeField("")
        let region = DictationLiveRegion(field: field)!
        _ = await region.update(to: "Send the teacher bill. ", wait: noWait)
        field.userTypes("Thanks!")
        await expectAsync(await region.update(to: "Send the Teachy build. ", wait: noWait), "replace while the caret is elsewhere")
        expectEqual(field.text, "Send the Teachy build. Thanks!", "only the dictated stretch changed")
        expectEqual(field.selection, NSRange(location: 30, length: 0), "caret is back after what the person typed")
    }
    do {
        // The person edited the dictated text: leave everything alone.
        let field = FakeField("")
        let region = DictationLiveRegion(field: field)!
        _ = await region.update(to: "Call Jon tomorrow. ", wait: noWait)
        field.text = "Call John tomorrow. "
        field.selection = NSRange(location: 20, length: 0)
        expect(!region.isIntact, "an edited region is not intact")
        await expectAsync(!(await region.update(to: "Call Jon tomorrow morning. ", wait: noWait)), "no replacement over an edit")
        expectEqual(field.text, "Call John tomorrow. ", "the person's edit is untouched")
        expectEqual(region.state, .frozen, "the region freezes")
        expect(region.hasTypedText, "a frozen region still counts as typed text (no second insertion)")
        await expectAsync(!(await region.update(to: "anything", wait: noWait)), "a frozen region never edits again")
    }
    do {
        // Text added before the region (another segment grew): found again.
        let field = FakeField("")
        let region = DictationLiveRegion(field: field)!
        _ = await region.update(to: "second sentence. ", wait: noWait)
        field.text = "First one. second sentence. "
        field.selection = NSRange(location: 28, length: 0)
        await expectAsync(await region.update(to: "Second sentence. ", wait: noWait), "region found after text was added before it")
        expectEqual(field.text, "First one. Second sentence. ", "replaced at its new place")
    }
    do {
        // Two segments in one field: correcting the first shifts the second.
        let field = FakeField("")
        let first = DictationLiveRegion(field: field)!
        _ = await first.update(to: "the the cat ", wait: noWait)
        let second = DictationLiveRegion(field: field)!
        _ = await second.update(to: "the the dog ", wait: noWait)
        await expectAsync(await first.update(to: "The cat. ", wait: noWait), "first segment corrected")
        second.shift(by: first.lastDelta)
        await expectAsync(await second.update(to: "The dog. ", wait: noWait), "second segment still found after the shift")
        expectEqual(field.text, "The cat. The dog. ", "both corrected in place")
    }
    do {
        let field = FakeField("", behaviour: .ignores)
        let region = DictationLiveRegion(field: field)!
        await expectAsync(!(await region.update(to: "hello", wait: noWait)), "a field that ignores edits")
        expectEqual(region.state, .unsupported, "is marked unsupported")
        expect(!region.hasTypedText, "and nothing was typed, so a later paste is safe")
    }
    do {
        let field = FakeField("", behaviour: .mangles)
        let region = DictationLiveRegion(field: field)!
        await expectAsync(!(await region.update(to: "hello", wait: noWait)), "a field that changes to something else")
        expectEqual(region.state, .unverified, "is marked unverified")
        expect(region.hasTypedText, "and counts as typed, so nothing is pasted on top")
    }
    do {
        let field = FakeField("abc")
        let region = DictationLiveRegion(field: field)!
        field.selection = NSRange(location: 1, length: 0)
        await expectAsync(!(await region.update(to: "hello", wait: noWait)), "caret moved before the first word")
        expectEqual(field.text, "abc", "nothing typed")
        expectEqual(region.state, .frozen, "frozen without typing")
    }
    do {
        let field = FakeField("keep ")
        let region = DictationLiveRegion(field: field)!
        _ = await region.update(to: "um hello", wait: noWait)
        await expectAsync(await region.update(to: "", wait: noWait), "cancel takes the words back")
        expectEqual(field.text, "keep ", "field as it was before the dictation")
    }
    do {
        let field = FakeField("x", behaviour: .unreadable)
        expect(DictationLiveRegion(field: field) == nil, "no live region for a field that can't be read")
    }
    do {
        let field = FakeField("abcdef")
        field.selection = NSRange(location: 2, length: 3)
        let region = DictationLiveRegion(field: field)!
        await expectAsync(await region.update(to: "X", wait: noWait), "first words replace the selection")
        expectEqual(field.text, "abXf", "selection replaced")
        await expectAsync(await region.update(to: "XY", wait: noWait), "then append")
        expectEqual(field.text, "abXYf", "appended inside the text")
    }
}

// MARK: - Polish and cleanup skip

do {
    typealias Polish = DictationOnDevicePolish
    expectEqual(Polish.polish("let's meet at three tomorrow"), "Let's meet at three tomorrow.", "capital and full stop")
    expectEqual(Polish.polish("Thanks for the reply. See you then."), "Thanks for the reply. See you then.", "already fine")
    expectEqual(Polish.polish("ok sure"), "Ok sure", "two words: no full stop")
    expectEqual(Polish.polish("git status now please", addPeriod: false), "Git status now please", "terminal: no full stop")
    expectEqual(Polish.polish("is that right?"), "Is that right?", "question kept")
    expectEqual(Polish.polish("今日はいい天気です"), "今日はいい天気です", "no Latin full stop after Japanese")
    expectEqual(Polish.polish("   "), "", "empty")
}

do {
    typealias Skip = DictationCleanupSkip
    expect(Skip.looksAlreadyClean("Let's meet at three tomorrow."), "clean short sentence")
    expect(Skip.looksAlreadyClean("Hola Marta, gracias por tu mensaje. Podemos hablar mañana a las diez."), "clean Spanish")
    expect(!Skip.looksAlreadyClean("Um, so I was thinking, uh, we could move the launch."), "filler sounds need cleanup")
    expect(!Skip.looksAlreadyClean("We could, you know, move the launch."), "filler phrase needs cleanup")
    expect(!Skip.looksAlreadyClean("I think the the launch is fine."), "stutter needs cleanup")
    expect(!Skip.looksAlreadyClean("let's meet at three tomorrow."), "no capital needs cleanup")
    expect(!Skip.looksAlreadyClean("Let's meet at three tomorrow"), "no full stop needs cleanup")
    expect(!Skip.looksAlreadyClean("Let's meet \u{2014} at three."), "em dash needs cleanup")
    expect(!Skip.looksAlreadyClean("I looked at the request this morning and I think the approach is right but the retry logic needs a second look."), "long run-on needs cleanup")
    expect(!Skip.looksAlreadyClean("That that is fine."), "a repeated word needs cleanup")
    expect(Skip.looksAlreadyClean("I think a a is fine."), "single-letter repeats don't count")
    expect(!Skip.looksAlreadyClean(""), "empty")
}

// MARK: - Release policy

do {
    typealias Policy = DictationReleasePolicy
    typealias OnDevice = DictationReleasePolicy.OnDevice
    // The six measured clips.
    let medium = OnDevice(text: "Thanks for the quick reply. I will send the updated numbers by end of day and we can go through them on the call.", meanConfidence: 0.987, minimumConfidence: 0.96)
    let short = OnDevice(text: "Let's meet at three tomorrow", meanConfidence: 0.65, minimumConfidence: 0.32)
    let name = OnDevice(text: "Please send the teacher bill to vet Sony and ask Publik support about the Conditor fellowship invoice", meanConfidence: 0.80, minimumConfidence: 0.504)
    let filler = OnDevice(text: "So I was thinking we could you know move the launch to Thursday I mean Friday if that works for everyone", meanConfidence: 0.946, minimumConfidence: 0.84)
    let spanishAsEnglish = OnDevice(text: "Hola Gracias mañana", meanConfidence: 0.001, minimumConfidence: 0.001)
    let long = OnDevice(text: String(repeating: "word ", count: 60), meanConfidence: 0.95, minimumConfidence: 0.9)
    expect(Policy.isTrustworthy(medium), "confident, punctuated, 23 words: trusted")
    expect(!Policy.isTrustworthy(short), "low confidence: not trusted")
    expect(!Policy.isTrustworthy(name), "misheard names score low: not trusted")
    expect(!Policy.isTrustworthy(filler), "confident but a run-on with no punctuation: not trusted")
    expect(!Policy.isTrustworthy(spanishAsEnglish), "wrong language: not trusted")
    expect(!Policy.isTrustworthy(long), "long: not trusted")
    expect(!Policy.isTrustworthy(OnDevice(text: "", confidences: [])), "empty: not trusted")
    expect(Policy.isTrustworthy(OnDevice(text: "Sounds good, see you then.", confidences: [0.95, 0.97, 0.93, 0.99, 0.96])), "short and confident: trusted")
    expectEqual(OnDevice(text: "a b", confidences: [0.5, 1.0]).meanConfidence, 0.75, "mean confidence")
    expectEqual(OnDevice(text: "a b", confidences: [0.5, 1.0]).minimumConfidence, 0.5, "lowest confidence")

    expect(!Policy.differsMeaningfully("Let's meet at three tomorrow. ", "let's meet at three tomorrow"), "capital, space and full stop don't matter")
    expect(Policy.differsMeaningfully("Let's meet at tree tomorrow.", "Let's meet at three tomorrow."), "a different word matters")
    expect(Policy.differsMeaningfully("So I was thinking we could move it", "So, I was thinking we could move it."), "punctuation inside matters")

    let inserted = "Please send the teacher bill to vet Sony. "
    let accurate = "Please send the Teachy build to Vedant Soni. "
    expectEqual(Policy.decide(insertedText: inserted, onDevice: name, publikText: accurate, cleanedText: accurate, rangeIntact: true),
                .replace(accurate), "better transcript and intact range: replace in place")
    expectEqual(Policy.decide(insertedText: inserted, onDevice: name, publikText: accurate, cleanedText: accurate, rangeIntact: false),
                .keep, "range not intact: leave what is there")
    expectEqual(Policy.decide(insertedText: "Let's meet at three tomorrow. ", onDevice: short, publikText: "Let's meet at three tomorrow.", cleanedText: "Let's meet at three tomorrow. ", rangeIntact: true),
                .keep, "same text: nothing to do")
    expectEqual(Policy.decide(insertedText: inserted, onDevice: name, publikText: nil, cleanedText: nil, rangeIntact: true),
                .keep, "publik failed: keep the on-device text")
    expectEqual(Policy.decide(insertedText: nil, onDevice: name, publikText: accurate, cleanedText: accurate, rangeIntact: false),
                .insert(accurate), "nothing typed yet: insert the accurate text")
    expectEqual(Policy.decide(insertedText: nil, onDevice: nil, publikText: accurate, cleanedText: accurate, rangeIntact: false),
                .insert(accurate), "accuracy mode: insert once")
    expectEqual(Policy.decide(insertedText: nil, onDevice: name, publikText: nil, cleanedText: nil, rangeIntact: false),
                .insert(name.text), "publik failed and nothing typed: the on-device text is better than nothing")
    expectEqual(Policy.decide(insertedText: nil, onDevice: OnDevice(text: "", confidences: []), publikText: nil, cleanedText: nil, rangeIntact: false),
                .nothing, "nothing heard at all")
    expectEqual(Policy.decide(insertedText: nil, onDevice: nil, publikText: "...", cleanedText: "...", rangeIntact: false),
                .nothing, "a transcript with no words is nothing")
    expectEqual(Policy.decide(insertedText: medium.text + " ", onDevice: medium, publikText: "Thanks.", cleanedText: "Thanks. ", rangeIntact: true),
                .keep, "a far shorter transcript against confident on-device text: keep")
    expectEqual(Policy.decide(insertedText: "Sounds good, see you then. ", onDevice: OnDevice(text: "Sounds good, see you then.", meanConfidence: 0.96, minimumConfidence: 0.9),
                              publikText: String(repeating: "Thank you for watching. ", count: 5), cleanedText: String(repeating: "Thank you for watching. ", count: 5), rangeIntact: true),
                .keep, "a far longer (invented) transcript against confident on-device text: keep")
    expectEqual(Policy.decide(insertedText: "Hola Gracias mañana. ", onDevice: spanishAsEnglish, publikText: "Hola Marta, gracias por tu mensaje. Podemos hablar mañana.", cleanedText: "Hola Marta, gracias por tu mensaje. Podemos hablar mañana. ", rangeIntact: true),
                .replace("Hola Marta, gracias por tu mensaje. Podemos hablar mañana. "), "unsure on-device text is replaced whatever the length")
    expectEqual(Policy.decide(insertedText: filler.text + ". ", onDevice: filler, publikText: "Um, so I was thinking...", cleanedText: "So I was thinking we could move the launch to Thursday. I mean Friday, if that works for everyone. ", rangeIntact: true),
                .replace("So I was thinking we could move the launch to Thursday. I mean Friday, if that works for everyone. "), "the cleaned text is what goes in, not the raw transcript")
}

// MARK: - Pauses

do {
    typealias Detector = DictationPauseDetector
    func feed(_ detector: inout Detector, voiced: Bool, seconds: Double) -> [Detector.Event] {
        var events: [Detector.Event] = []
        var remaining = seconds
        while remaining > 0.0001 {
            events += detector.feed(rms: voiced ? 0.05 : 0.001, seconds: 0.02)
            remaining -= 0.02
        }
        return events
    }
    var detector = Detector()
    expectEqual(feed(&detector, voiced: true, seconds: 2.0), [], "speaking: no events")
    expectEqual(feed(&detector, voiced: false, seconds: 0.3), [], "a short gap is not a pause")
    expectEqual(feed(&detector, voiced: false, seconds: 0.3), [.pause], "0.45 s of silence after speech is a pause")
    expectEqual(feed(&detector, voiced: false, seconds: 2.0), [], "one pause is reported once")
    detector.markSpeculation()
    expect(detector.speculationCoversEverything(), "nothing said since the speculation")
    _ = feed(&detector, voiced: true, seconds: 0.5)
    expect(!detector.speculationCoversEverything(), "more speech after the speculation")
    expectEqual(feed(&detector, voiced: false, seconds: 0.5), [], "too little speech since the last pause to report another")
    _ = feed(&detector, voiced: true, seconds: 2.0)
    // 7.6 s in, 4.5 s voiced: the next 0.7 s pause closes the segment.
    let events = feed(&detector, voiced: false, seconds: 0.8)
    expectEqual(events, [.pause, .segmentBoundary], "a longer pause after enough speech closes the segment")
    expectEqual(detector.segmentSeconds < 0.2, true, "a new segment starts")
    expectEqual(feed(&detector, voiced: false, seconds: 10), [], "silence alone never makes a segment")

    var tapping = Detector()
    expectEqual(feed(&tapping, voiced: true, seconds: 0.2) + feed(&tapping, voiced: false, seconds: 1.0), [], "a blip of sound is not speech")

    var nonstop = Detector()
    let longEvents = feed(&nonstop, voiced: true, seconds: 76)
    expectEqual(longEvents, [.segmentBoundary], "talking without a break is cut at the hard limit")

    var longWithGap = Detector()
    _ = feed(&longWithGap, voiced: true, seconds: 41)
    expectEqual(feed(&longWithGap, voiced: false, seconds: 0.3), [.segmentBoundary], "a long segment is cut at the first short gap")
}

// MARK: - Apps that ignore Accessibility edits

do {
    let suite = "dictspeed-route-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = DictationInsertRouteMemory(defaults: defaults)
    let now = Date()
    expect(!memory.ignoresAccessibilityInsert(bundleIdentifier: "com.tinyspeck.slackmacgap", now: now), "unknown app")
    memory.markIgnoresAccessibilityInsert(bundleIdentifier: "com.tinyspeck.slackmacgap", now: now)
    expect(memory.ignoresAccessibilityInsert(bundleIdentifier: "com.tinyspeck.slackmacgap", now: now), "remembered")
    expect(!memory.ignoresAccessibilityInsert(bundleIdentifier: "com.apple.Notes", now: now), "other apps unaffected")
    expect(!memory.ignoresAccessibilityInsert(bundleIdentifier: "com.tinyspeck.slackmacgap", now: now.addingTimeInterval(8 * 24 * 3600)), "forgotten after a week")
    expect(!memory.ignoresAccessibilityInsert(bundleIdentifier: nil, now: now), "no app")
    memory.clear(bundleIdentifier: "com.tinyspeck.slackmacgap")
    expect(!memory.ignoresAccessibilityInsert(bundleIdentifier: "com.tinyspeck.slackmacgap", now: now), "cleared")
}

// MARK: - Writing

do {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    expectEqual(WritingPrompt.mediaType(for: png), "image/png", "PNG detected")
    expectEqual(WritingPrompt.mediaType(for: jpeg), "image/jpeg", "JPEG otherwise")

    let body = WritingPrompt.requestBody(
        instruction: " say thanks and ask about his use cases ",
        screenshots: [(data: png, label: "primary focus (1512x982)"), (data: jpeg, label: "second screen"), (data: jpeg, label: "third screen")],
        frontmostApp: "Mail",
        focusedFieldContext: "text area, empty",
        memory: "## About me\n- Name: Sam"
    )
    expect(body["model"] == nil, "no model key: the router picks the tier")
    let messages = body["messages"] as? [[String: Any]] ?? []
    expectEqual(messages.count, 2, "system and user message")
    let system = messages.first?["content"] as? String ?? ""
    expect(system.contains("Output ONLY the text to insert"), "system prompt has the output rule")
    expect(system.contains("- Name: Sam"), "memory is in the system prompt")
    let content = messages.last?["content"] as? [[String: Any]] ?? []
    expectEqual(content.filter { $0["type"] as? String == "image_url" }.count, 2, "at most two screenshots are sent")
    let text = content.last?["text"] as? String ?? ""
    expect(text.contains("App in front: Mail"), "app name is in the user text")
    expect(text.contains("Focused field: text area, empty"), "field context is in the user text")
    expect(text.contains("What they asked for: say thanks and ask about his use cases"), "instruction is trimmed and included")
    expect(text.contains("Screenshot 1: primary focus (1512x982)"), "screenshot labels are included")
    expect(WritingPrompt.systemPrompt(memory: "  ").contains("You know nothing about this person yet"), "empty memory is said plainly")

    let big = Data(count: 2_000_000)
    expectEqual(WritingPrompt.screenshotsThatFit([(data: big, label: "a"), (data: big, label: "b")]).count, 1, "screenshots over the size budget are dropped")
    expectEqual(WritingPrompt.screenshotsThatFit([(data: Data(count: 5_000_000), label: "a")]).count, 1, "the first screenshot is always kept")

    typealias W = WritingPrompt
    expectEqual(W.textToInsert(fromModelOutput: "  Thanks, Ravi!  \n", isTerminal: false), "Thanks, Ravi!", "trimmed")
    expectEqual(W.textToInsert(fromModelOutput: "\"Thanks, Ravi!\"", isTerminal: false), "Thanks, Ravi!", "wrapping quotes removed")
    expectEqual(W.textToInsert(fromModelOutput: "“Thanks, Ravi!”", isTerminal: false), "Thanks, Ravi!", "curly wrapping quotes removed")
    expectEqual(W.textToInsert(fromModelOutput: "\"Yes\" is my answer, not \"no\"", isTerminal: false), "\"Yes\" is my answer, not \"no\"", "quotes that are part of the text stay")
    expectEqual(W.textToInsert(fromModelOutput: "Here's your reply:\n\nThanks, Ravi!", isTerminal: false), "Thanks, Ravi!", "preamble line removed")
    expectEqual(W.textToInsert(fromModelOutput: "Sure! Here is a reply you can send:\nThanks, Ravi!", isTerminal: false), "Thanks, Ravi!", "chatty preamble removed")
    expectEqual(W.textToInsert(fromModelOutput: "Here is the report you asked for, Ravi.", isTerminal: false), "Here is the report you asked for, Ravi.", "a sentence that starts with 'Here is' stays")
    expectEqual(W.textToInsert(fromModelOutput: "```\nfix: retry on 429\n```", isTerminal: false), "fix: retry on 429", "code fence around the whole answer removed")
    expectEqual(W.textToInsert(fromModelOutput: "```bash\ngit status\n```", isTerminal: true), "git status", "fence with a language removed")
    expectEqual(W.textToInsert(fromModelOutput: "fix: retry on 429\n\nBack off for 2 s.\n", isTerminal: true), "fix: retry on 429 Back off for 2 s.", "terminal: one line, no newline")
    expectEqual(W.textToInsert(fromModelOutput: "Hi Ana,\n\nThanks!\n\nSam", isTerminal: false), "Hi Ana,\n\nThanks!\n\nSam", "line breaks kept outside terminals")
    expectEqual(W.textToInsert(fromModelOutput: "Thanks \u{2014} talk soon", isTerminal: false), "Thanks, talk soon", "no em dashes")
    expectEqual(W.textToInsert(fromModelOutput: "", isTerminal: false), "", "empty stays empty")

    let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": "Thanks!"]]]])
    expectEqual(W.content(fromResponse: response), "Thanks!", "content read from the response")
    expect(W.content(fromResponse: Data("nope".utf8)) == nil, "bad response gives nil")

    // The voice hook: the tag the rule asks for is what VoiceTag reads.
    expect(W.voicePromptRule.contains("[WRITE:"), "the rule names the tag")
    let extracted = VoiceTag.extract("WRITE", from: "Writing it now. [WRITE: reply to Ravi saying thanks and ask about his use cases]")
    expectEqual(extracted.text, "Writing it now.", "spoken text without the tag")
    expectEqual(extracted.payload, "reply to Ravi saying thanks and ask about his use cases", "instruction from the tag")
    expect(VoiceTag.extract("WRITE", from: "Nothing to write here.").payload == nil, "no tag, no instruction")
}

await runAsyncTests()

print(failures == 0 ? "dictspeed tests: all \(checks) checks passed" : "dictspeed tests: \(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
