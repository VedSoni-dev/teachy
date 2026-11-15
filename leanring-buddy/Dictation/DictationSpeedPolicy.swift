//
//  DictationSpeedPolicy.swift
//  leanring-buddy
//
//  Pure rules that make dictation feel instant. Foundation only, no AppKit, so
//  scripts/tests/dictspeed/main.swift compiles this file on its own.
//
//  SETTINGS (UserDefaults; the settings screen writes them, dictation reads them
//  at the start of every dictation):
//
//    "teachyDictationSpeedMode"            String  "speed" (default) or "accuracy"
//        speed     On-device text is typed into the field while the person speaks
//                  and completed the moment they let go. publik's transcript then
//                  replaces it in place, only if it is better and the typed text is
//                  still exactly where Teachy put it.
//        accuracy  Nothing is typed until publik's transcript and the cleanup pass
//                  are back (the behaviour before 14 Nov 2026).
//
//    "teachyDictationLiveInsertionEnabled" Bool    default true
//        Only read in speed mode. false keeps the live words in the pill and puts
//        the text in the field once, when the person lets go.
//
//  Measured 14 Nov 2026 on six spoken clips (1.6 s to 17.6 s): the on-device
//  recognizer's final text arrives 33 to 160 ms after the audio ends; publik's
//  transcript takes 1.5 to 2.4 s whatever the clip length; cleanup adds 1.1 to
//  1.5 s and returned the transcript unchanged for four of the six. publik's
//  transcription endpoint does not stream (asked with stream=true, it answers
//  with one JSON body), so the live words can only come from the device.
//

import Foundation

// MARK: - Setting

nonisolated enum DictationSpeedMode: String {
    case speedFirst = "speed"
    case accuracyFirst = "accuracy"

    static let defaultsKey = "teachyDictationSpeedMode"
    static let liveInsertionDefaultsKey = "teachyDictationLiveInsertionEnabled"
    static let defaultMode: DictationSpeedMode = .speedFirst

    static func current(_ defaults: UserDefaults = .standard) -> DictationSpeedMode {
        defaults.string(forKey: defaultsKey).flatMap(DictationSpeedMode.init(rawValue:)) ?? defaultMode
    }

    static func save(_ mode: DictationSpeedMode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }

    static func liveInsertionEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: liveInsertionDefaultsKey) == nil ? true : defaults.bool(forKey: liveInsertionDefaultsKey)
    }
}

// MARK: - A text field Teachy can read and edit

/// The few things dictation needs from the focused text field. The app backs it
/// with Accessibility; tests back it with an in-memory field. Ranges are UTF-16.
nonisolated protocol DictationEditableField: AnyObject {
    func value() -> String?
    func characterCount() -> Int?
    func selectedRange() -> NSRange?
    func setSelectedRange(_ range: NSRange) -> Bool
    /// Replaces the selection (or inserts at the caret).
    func setSelectedText(_ text: String) -> DictationFieldSetResult
}

nonisolated enum DictationFieldSetResult: Equatable {
    case accepted
    /// The app did not answer in time. It may still apply the change later.
    case timedOut
    /// The app refused; nothing will change.
    case refused
}

// MARK: - Stable prefix of the live text

/// The on-device recognizer revises its newest words as it hears more. Only the
/// words that two hypotheses in a row agree on, minus the newest `holdBackWords`,
/// are typed into the field.
nonisolated struct DictationStablePrefix {
    var holdBackWords = 1
    private var previousWords: [String] = []

    init(holdBackWords: Int = 1) {
        self.holdBackWords = holdBackWords
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Feed every hypothesis in order. Returns the text that is safe to type now.
    mutating func feed(_ hypothesis: String) -> String {
        let words = Self.words(in: hypothesis)
        var agreed = 0
        while agreed < words.count, agreed < previousWords.count, words[agreed] == previousWords[agreed] { agreed += 1 }
        previousWords = words
        let stableCount = max(0, min(agreed, words.count - holdBackWords))
        return words.prefix(stableCount).joined(separator: " ")
    }

    mutating func reset() {
        previousWords = []
    }
}

// MARK: - Finding and editing what Teachy typed

nonisolated enum DictationRangeLocator {
    /// Where `inserted` sits in `value` now. It is trusted at `expectedLocation`
    /// first; if the text before it changed, the one and only other occurrence is
    /// used. nil means the text was edited (or appears twice) and must be left alone.
    static func locate(value: String, expectedLocation: Int, inserted: String) -> NSRange? {
        let source = value as NSString
        let length = (inserted as NSString).length
        guard length > 0 else {
            return expectedLocation >= 0 && expectedLocation <= source.length ? NSRange(location: expectedLocation, length: 0) : nil
        }
        if expectedLocation >= 0, expectedLocation + length <= source.length,
           source.substring(with: NSRange(location: expectedLocation, length: length)) == inserted {
            return NSRange(location: expectedLocation, length: length)
        }
        let first = source.range(of: inserted, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: source.length - first.location - 1)
        if source.range(of: inserted, options: .literal, range: rest).location != NSNotFound { return nil }
        return first
    }

    /// `value` with `range` replaced by `text`, or nil if the range does not fit.
    static func replacing(_ range: NSRange, in value: String, with text: String) -> String? {
        let source = value as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= source.length else { return nil }
        return source.replacingCharacters(in: range, with: text)
    }
}

nonisolated enum DictationLiveEdit {
    struct Plan: Equatable {
        /// UTF-16 length of the start of the typed text that stays.
        let keepLength: Int
        /// UTF-16 length removed after that.
        let deleteLength: Int
        let insert: String
    }

    /// The smallest change at the end of `current` that turns it into `target`.
    /// Never cuts a character (an emoji, an accented letter) in half.
    static func plan(from current: String, to target: String) -> Plan {
        var keptLength = 0
        var currentIndex = current.startIndex
        var targetIndex = target.startIndex
        while currentIndex < current.endIndex, targetIndex < target.endIndex, current[currentIndex] == target[targetIndex] {
            keptLength += current[currentIndex].utf16.count
            currentIndex = current.index(after: currentIndex)
            targetIndex = target.index(after: targetIndex)
        }
        return Plan(
            keepLength: keptLength,
            deleteLength: (current as NSString).length - keptLength,
            insert: String(target[targetIndex...])
        )
    }
}

// MARK: - Did the insertion happen?

/// Decides, from what the field looked like before and after an insertion was
/// asked for, whether the text is in it. This is what stops text landing twice:
/// Teachy pastes only when the field shows no change at all.
nonisolated enum DictationInsertEvidence: Equatable {
    /// The text is there. `range` is where, when the field's value could be read.
    case verified(value: String?, range: NSRange?)
    /// The field changed but not in a way that proves the text is there.
    case changedUnverified
    case noChange

    struct Snapshot: Equatable {
        var value: String?
        var characterCount: Int?
        var selection: NSRange?

        init(value: String? = nil, characterCount: Int? = nil, selection: NSRange? = nil) {
            self.value = value
            self.characterCount = characterCount
            self.selection = selection
        }

        /// False when nothing about the field can be read, so nothing can be checked.
        var isReadable: Bool { value != nil || characterCount != nil }
    }

    static func classify(before: Snapshot, after: Snapshot, inserted text: String) -> DictationInsertEvidence {
        let insertedLength = (text as NSString).length
        let replacedLength = before.selection?.length ?? 0
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let valueBefore = before.value, let valueAfter = after.value {
            if valueAfter != valueBefore {
                let afterString = valueAfter as NSString
                if let selection = before.selection,
                   DictationRangeLocator.replacing(selection, in: valueBefore, with: text) == valueAfter {
                    return .verified(value: valueAfter, range: NSRange(location: selection.location, length: insertedLength))
                }
                // Some fields trim the trailing space or reformat around the text.
                if !needle.isEmpty {
                    if let selection = before.selection {
                        let window = NSRange(location: min(selection.location, afterString.length),
                                             length: afterString.length - min(selection.location, afterString.length))
                        let found = afterString.range(of: needle, options: .literal, range: window)
                        if found.location == selection.location { return .verified(value: valueAfter, range: found) }
                    }
                    let occurrencesBefore = occurrences(of: needle, in: valueBefore)
                    let occurrencesAfter = occurrences(of: needle, in: valueAfter)
                    if occurrencesAfter > occurrencesBefore {
                        let found = afterString.range(of: needle, options: [.literal, .backwards])
                        return .verified(value: valueAfter, range: occurrencesAfter == 1 ? found : nil)
                    }
                }
                return .changedUnverified
            }
        } else if let countBefore = before.characterCount, let countAfter = after.characterCount, countAfter != countBefore {
            let delta = countAfter - countBefore
            let trimmedLength = (needle as NSString).length
            if delta == insertedLength - replacedLength || delta == trimmedLength - replacedLength {
                return .verified(value: nil, range: nil)
            }
            return .changedUnverified
        }

        // The value (or count) reads the same. A caret that moved still means the
        // app did something with the request.
        if let selectionBefore = before.selection, let selectionAfter = after.selection, selectionAfter != selectionBefore {
            return .changedUnverified
        }
        return .noChange
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        let source = haystack as NSString
        var count = 0
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: needle, options: .literal, range: searchRange)
            if found.location == NSNotFound { break }
            count += 1
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return count
    }
}

/// One checked insertion through `DictationEditableField`.
nonisolated enum DictationVerifiedInsert {
    enum Outcome: Equatable {
        /// In the field. Do not paste.
        case inserted(value: String?, range: NSRange?)
        /// The field changed; the text is probably in it. Do not paste.
        case changedUnverified
        /// The field never changed. Pasting cannot double the text.
        case noEffect
        /// Nothing about the field can be read, so no insertion was tried.
        case cannotCheck
    }

    /// Waits between re-reads, in milliseconds. An app that accepted the request
    /// applies it at once or within a few frames; an app that timed out may be busy
    /// for much longer, so it gets the long schedule before anyone pastes.
    static let acceptedWaits = [0, 30, 60, 120, 180, 210]
    static let timedOutWaits = [0, 60, 120, 240, 480, 600, 500]
    static let refusedWaits = [0, 40]

    static func snapshot(of field: DictationEditableField) -> DictationInsertEvidence.Snapshot {
        DictationInsertEvidence.Snapshot(
            value: field.value(), characterCount: field.characterCount(), selection: field.selectedRange()
        )
    }

    static func insert(
        _ text: String,
        into field: DictationEditableField,
        wait: (_ milliseconds: Int) async -> Void
    ) async -> Outcome {
        let before = snapshot(of: field)
        guard before.isReadable else { return .cannotCheck }

        let waits: [Int]
        switch field.setSelectedText(text) {
        case .accepted: waits = acceptedWaits
        case .timedOut: waits = timedOutWaits
        case .refused: waits = refusedWaits
        }

        var sawChange = false
        // A field that stops answering can't be shown to be unchanged.
        var lastReadFailed = false
        for milliseconds in waits {
            if milliseconds > 0 { await wait(milliseconds) }
            let after = snapshot(of: field)
            lastReadFailed = !after.isReadable || (before.value != nil && after.value == nil)
            if lastReadFailed { continue }
            switch DictationInsertEvidence.classify(before: before, after: after, inserted: text) {
            case .verified(let value, let range): return .inserted(value: value, range: range)
            case .changedUnverified: sawChange = true
            case .noChange: break
            }
        }
        return sawChange || lastReadFailed ? .changedUnverified : .noEffect
    }
}

// MARK: - The region Teachy is typing live

/// The stretch of a field that one dictation has typed. Every edit first proves
/// the stretch still holds exactly what Teachy put there; if it does not, the
/// region freezes and nothing in the field is touched again.
nonisolated final class DictationLiveRegion {
    enum State: Equatable {
        /// Nothing typed yet.
        case empty
        case active
        /// The typed text was edited or can't be found. Leave the field alone.
        case frozen
        /// The first insertion changed nothing: this field ignores Accessibility edits.
        case unsupported
        /// The field changed in a way that can't be checked. Assume text is in it.
        case unverified
    }

    let field: DictationEditableField
    private(set) var location: Int
    /// What Teachy believes sits at `location` (exact, including a trailing space).
    private(set) var text = ""
    private(set) var state: State = .empty
    /// The field's value right after the last edit Teachy verified.
    private(set) var lastVerifiedValue: String?

    static let verifyWaits = [0, 25, 50, 100]

    /// nil when the field can't be read back well enough to type into it safely.
    init?(field: DictationEditableField) {
        guard field.value() != nil, let selection = field.selectedRange() else { return nil }
        self.field = field
        self.location = selection.location
    }

    /// A region for text that is already in the field (a checked one-shot insertion).
    init(field: DictationEditableField, location: Int, text: String, value: String?) {
        self.field = field
        self.location = location
        self.text = text
        self.state = .active
        self.lastVerifiedValue = value
    }

    var canEdit: Bool { state == .empty || state == .active }
    /// True when some of Teachy's text is (or may be) in the field, whatever the state.
    var hasTypedText: Bool { !text.isEmpty || state == .unverified }

    /// Where the typed text is now, or nil if it is no longer intact.
    func currentRange() -> NSRange? {
        guard state == .active, let value = field.value() else { return nil }
        return DictationRangeLocator.locate(value: value, expectedLocation: location, inserted: text)
    }

    var isIntact: Bool { currentRange() != nil }

    /// Another region earlier in the same field grew or shrank.
    func shift(by delta: Int) {
        location = max(0, location + delta)
    }

    /// Makes the typed text equal `target` by changing only its end. Returns true
    /// when the field now holds `target`; `lastDelta` is then the change in length.
    @discardableResult
    func update(to target: String, wait: (_ milliseconds: Int) async -> Void) async -> Bool {
        lastDelta = 0
        guard canEdit else { return false }
        if target == text { return true }
        guard let valueBefore = field.value() else {
            state = text.isEmpty ? .unsupported : .frozen
            return false
        }

        let source = valueBefore as NSString
        let editRange: NSRange
        let replacement: String
        if state == .empty {
            // First words: they go where the caret (or selection) was when the
            // dictation started, provided the caret has not moved since.
            guard let selection = field.selectedRange(), selection.location == location,
                  selection.location + selection.length <= source.length
            else {
                state = .frozen
                return false
            }
            editRange = selection
            replacement = target
        } else {
            guard let range = DictationRangeLocator.locate(value: valueBefore, expectedLocation: location, inserted: text) else {
                state = .frozen
                return false
            }
            location = range.location
            let plan = DictationLiveEdit.plan(from: text, to: target)
            editRange = NSRange(location: range.location + plan.keepLength, length: plan.deleteLength)
            replacement = plan.insert
        }
        guard let expected = DictationRangeLocator.replacing(editRange, in: valueBefore, with: replacement) else {
            state = .frozen
            return false
        }

        // Put the selection on the stretch to change, unless it is already there
        // (the usual case: the caret sits at the end of what was typed).
        let caretBefore = field.selectedRange()
        if caretBefore != editRange {
            guard field.setSelectedRange(editRange), field.selectedRange() == editRange else {
                if let caretBefore { _ = field.setSelectedRange(caretBefore) }
                state = state == .empty ? .unsupported : .frozen
                return false
            }
        }

        let setResult = field.setSelectedText(replacement)
        var sawChange = false
        var verified = false
        for milliseconds in (setResult == .timedOut ? DictationVerifiedInsert.timedOutWaits : Self.verifyWaits) {
            if milliseconds > 0 { await wait(milliseconds) }
            guard let valueAfter = field.value() else { continue }
            if valueAfter == expected {
                verified = true
                break
            }
            if valueAfter != valueBefore { sawChange = true }
        }

        guard verified else {
            if sawChange {
                state = .unverified
            } else {
                // Nothing happened. What was typed before is still exactly there.
                if let caretBefore, caretBefore != editRange { _ = field.setSelectedRange(caretBefore) }
                state = state == .empty ? .unsupported : .frozen
            }
            return false
        }

        let delta = (replacement as NSString).length - editRange.length
        text = target
        state = .active
        lastVerifiedValue = expected
        lastDelta = delta

        // Leave the caret where the person had it: after the edit it moves with
        // the text; before the edit it stays put.
        if let caretBefore, caretBefore != editRange {
            let editEnd = editRange.location + editRange.length
            if caretBefore.location >= editEnd {
                _ = field.setSelectedRange(NSRange(location: caretBefore.location + delta, length: caretBefore.length))
            } else if caretBefore.location + caretBefore.length <= editRange.location {
                _ = field.setSelectedRange(caretBefore)
            }
        }
        return true
    }

    /// Length change of the last successful `update` (UTF-16), for shifting later regions.
    private(set) var lastDelta = 0
}

// MARK: - Tidying the on-device text

nonisolated enum DictationOnDevicePolish {
    static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ":", ";", ","]
    static let minimumWordsForPeriod = 3

    /// Capital first letter, and a full stop when the recognizer left the sentence
    /// open. `addPeriod` is false for terminals, where a stray dot breaks a command.
    static func polish(_ text: String, addPeriod: Bool = true) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = result.first else { return "" }
        if first.isLowercase { result = first.uppercased() + result.dropFirst() }
        guard addPeriod, let last = result.last, let lastScalar = result.unicodeScalars.last else { return result }
        if !sentenceEnders.contains(last), last.isLetter || last.isNumber,
           !DictationScript.isUnspacedScript(lastScalar),
           DictationStablePrefix.words(in: result).count >= minimumWordsForPeriod {
            result += "."
        }
        return result
    }
}

// MARK: - Is the transcript already clean?

nonisolated enum DictationCleanupSkip {
    static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mhm", "mm"]
    static let fillerPhrases = ["you know", "i mean"]
    static let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    /// publik's transcript already has punctuation and capitals. When it also has
    /// no filler sounds, no stutter and ends a sentence, the cleanup call would
    /// hand it back unchanged a second later, so it is skipped (speed mode only).
    static func looksAlreadyClean(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, let last = text.last else { return false }
        if first.isLowercase { return false }
        if text.contains("\u{2014}") || text.contains("\u{2015}") || text.contains("<") { return false }
        let units = DictationScript.units(in: text)
        guard !units.isEmpty else { return false }
        let endsSentence = terminalPunctuation.contains(last)
            || (text.unicodeScalars.last.map(DictationScript.isUnspacedScript) ?? false)
        if !endsSentence { return false }
        if units.contains(where: fillerWords.contains) { return false }
        for index in units.indices.dropFirst() where units[index] == units[index - 1] && units[index].count > 1 { return false }
        let joined = " " + units.joined(separator: " ") + " "
        if fillerPhrases.contains(where: { joined.contains(" \($0) ") }) { return false }
        // Long text with no punctuation inside it was not punctuated by the transcriber.
        if units.count >= 18, !text.dropLast().contains(where: { ",.;:!?，。".contains($0) }) { return false }
        return true
    }
}

// MARK: - What to do when the person lets go

nonisolated enum DictationReleasePolicy {
    struct OnDevice: Equatable {
        var text: String
        /// Mean and lowest per-word confidence from the recognizer's final result, 0...1.
        var meanConfidence: Double
        var minimumConfidence: Double

        init(text: String, confidences: [Double]) {
            self.text = text
            self.meanConfidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
            self.minimumConfidence = confidences.min() ?? 0
        }

        init(text: String, meanConfidence: Double, minimumConfidence: Double) {
            self.text = text
            self.meanConfidence = meanConfidence
            self.minimumConfidence = minimumConfidence
        }
    }

    /// Measured: correct clips scored a mean of 0.91 to 0.99; a clip with two
    /// misheard names 0.80 (lowest word 0.50); Spanish heard as English 0.001.
    static let trustedMeanConfidence = 0.90
    static let trustedMinimumConfidence = 0.60
    static let trustedMaximumWords = 25
    /// From this many words on, on-device text without a single comma or full
    /// stop inside it is a run-on that needs the accurate pass.
    static let wordsThatNeedInnerPunctuation = 12

    /// "Confident and short": the on-device text can stand as the final text when
    /// there will be no chance to correct it afterwards.
    static func isTrustworthy(_ onDevice: OnDevice) -> Bool {
        let words = DictationStablePrefix.words(in: onDevice.text)
        guard !DictationScript.units(in: onDevice.text).isEmpty, words.count <= trustedMaximumWords else { return false }
        guard onDevice.meanConfidence >= trustedMeanConfidence, onDevice.minimumConfidence >= trustedMinimumConfidence else { return false }
        if words.count >= wordsThatNeedInnerPunctuation,
           !onDevice.text.dropLast().contains(where: { ",.;:!?".contains($0) }) {
            return false
        }
        return true
    }

    /// Same words, same punctuation inside: a different capital on the first
    /// letter, spacing, or the closing full stop is not worth touching the field for.
    static func differsMeaningfully(_ first: String, _ second: String) -> Bool {
        func normalized(_ text: String) -> String {
            var result = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            while let last = result.last, DictationCleanupSkip.terminalPunctuation.contains(last) { result.removeLast() }
            if let firstCharacter = result.first { result = firstCharacter.lowercased() + result.dropFirst() }
            return result
        }
        return normalized(first) != normalized(second)
    }

    enum Action: Equatable {
        /// Leave the field as it is.
        case keep
        /// Replace the text Teachy typed with this, in place.
        case replace(String)
        /// Nothing is in the field yet: insert this.
        case insert(String)
        /// Nothing to insert at all.
        case nothing
    }

    /// The whole decision once the accurate pass is back.
    /// - insertedText: what Teachy already put in the field (nil = nothing yet).
    /// - onDevice: the on-device recognizer's final text and confidence.
    /// - publikText: publik's transcript (nil = it failed or timed out).
    /// - cleanedText: the text after cleanup and the per-app insertion rules
    ///   (nil = no accurate text at all).
    /// - rangeIntact: the inserted text is still exactly where Teachy put it, in
    ///   the same field, unedited.
    static func decide(
        insertedText: String?,
        onDevice: OnDevice?,
        publikText: String?,
        cleanedText: String?,
        rangeIntact: Bool
    ) -> Action {
        let accurate = (cleanedText ?? publikText).flatMap { text -> String? in
            DictationScript.units(in: text).isEmpty ? nil : text
        }
        guard let insertedText, !insertedText.isEmpty else {
            if let accurate { return .insert(accurate) }
            if let onDevice, !DictationScript.units(in: onDevice.text).isEmpty { return .insert(onDevice.text) }
            return .nothing
        }
        guard let accurate else { return .keep }
        guard rangeIntact else { return .keep }
        guard differsMeaningfully(insertedText, accurate) else { return .keep }

        // A transcript of a very different length from text the recognizer was
        // sure of is more likely an invented or cut-off transcript than a fix.
        if let onDevice, onDevice.meanConfidence >= trustedMeanConfidence {
            let onDeviceCount = DictationScript.units(in: onDevice.text).count
            let accurateCount = DictationScript.units(in: accurate).count
            if onDeviceCount >= 4, accurateCount > onDeviceCount * 2 || accurateCount * 2 < onDeviceCount {
                return .keep
            }
        }
        return .replace(accurate)
    }
}

// MARK: - Pauses: when to start transcribing early

/// Watches the loudness of the recording as it comes in. A pause is the cue to
/// send what was said so far (so the answer is already on its way when the person
/// lets go) and, in a long hands-free session, to close a sentence-sized segment
/// and type it while the person carries on.
nonisolated struct DictationPauseDetector {
    enum Event: Equatable {
        /// The person stopped speaking for a moment.
        case pause
        /// Enough has been said, and there is a pause: close this segment.
        case segmentBoundary
    }

    var voicedRMS = 0.008
    var pauseSeconds = 0.45
    var minimumVoicedBeforePause = 0.6
    var boundaryPauseSeconds = 0.7
    var minimumSegmentSeconds = 6.0
    var minimumVoicedInSegment = 1.5
    /// A segment this long is closed at the next short gap, pause or not.
    var longSegmentSeconds = 40.0
    var longSegmentPauseSeconds = 0.25
    /// Hard limit, safely under publik's clip size limit.
    var maximumSegmentSeconds = 75.0

    private(set) var segmentSeconds = 0.0
    private(set) var voicedInSegment = 0.0
    private(set) var silenceRun = 0.0
    /// Speech heard since `markSpeculation()` was last called.
    private(set) var voicedSinceMark = 0.0
    private var voicedSincePause = 0.0
    private var pauseReported = false

    init() {}

    mutating func feed(rms: Double, seconds: Double) -> [Event] {
        guard seconds > 0 else { return [] }
        var events: [Event] = []
        segmentSeconds += seconds
        if rms >= voicedRMS {
            voicedInSegment += seconds
            voicedSinceMark += seconds
            voicedSincePause += seconds
            silenceRun = 0
            pauseReported = false
        } else {
            silenceRun += seconds
            if !pauseReported, silenceRun >= pauseSeconds, voicedSincePause >= minimumVoicedBeforePause {
                pauseReported = true
                voicedSincePause = 0
                events.append(.pause)
            }
        }

        let hasEnoughSpeech = voicedInSegment >= minimumVoicedInSegment
        let naturalBoundary = segmentSeconds >= minimumSegmentSeconds && silenceRun >= boundaryPauseSeconds
        let longBoundary = segmentSeconds >= longSegmentSeconds && silenceRun >= longSegmentPauseSeconds
        let hardBoundary = segmentSeconds >= maximumSegmentSeconds
        if hardBoundary || (hasEnoughSpeech && (naturalBoundary || longBoundary)) {
            events.append(.segmentBoundary)
            startNewSegment()
        }
        return events
    }

    mutating func startNewSegment() {
        segmentSeconds = 0
        voicedInSegment = 0
        voicedSinceMark = 0
        voicedSincePause = 0
        // The silence run carries on; the pause was already reported.
        pauseReported = true
    }

    /// Call when a speculative transcription of "everything so far" is started.
    mutating func markSpeculation() {
        voicedSinceMark = 0
    }

    /// True when nothing worth transcribing was said since the speculation started.
    func speculationCoversEverything(tolerance: Double = 0.12) -> Bool {
        voicedSinceMark <= tolerance
    }
}

// MARK: - Apps that ignore Accessibility edits

/// Many Chromium and Electron fields accept an Accessibility insertion and change
/// nothing. Checking that costs a wait before the paste, so the answer is
/// remembered per app for a week.
nonisolated struct DictationInsertRouteMemory {
    static let defaultsKey = "teachyDictationAppsThatIgnoreAccessibilityInsert"
    static let lifetime: TimeInterval = 7 * 24 * 3600

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var stored: [String: Double] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double]) ?? [:]
    }

    func ignoresAccessibilityInsert(bundleIdentifier: String?, now: Date = Date()) -> Bool {
        guard let bundleIdentifier, let markedAt = stored[bundleIdentifier] else { return false }
        return now.timeIntervalSince1970 - markedAt < Self.lifetime
    }

    func markIgnoresAccessibilityInsert(bundleIdentifier: String?, now: Date = Date()) {
        guard let bundleIdentifier else { return }
        var all = stored.filter { now.timeIntervalSince1970 - $0.value < Self.lifetime }
        all[bundleIdentifier] = now.timeIntervalSince1970
        defaults.set(all, forKey: Self.defaultsKey)
    }

    func clear(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        var all = stored
        all.removeValue(forKey: bundleIdentifier)
        defaults.set(all, forKey: Self.defaultsKey)
    }
}
