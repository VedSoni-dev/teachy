// Run: scripts/tests/run_dictation_shortcut_tests.sh
import Foundation

var failures = 0
func expect(_ name: String, _ condition: Bool) { if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") } }
typealias S = DictationShortcut
let fn = S.functionKey, control = S.controlKey, option = S.optionKey, shift = S.shiftKey, command = S.commandKey
let keyD: UInt16 = 2, keyF5: UInt16 = 96, rightOption: UInt16 = 61
let talk: [UInt16] = [control, option]

// What may be a shortcut
expect("default fn + control is fine", S.validationProblem([fn, control], pushToTalk: talk) == nil)
expect("two modifiers are fine", S.validationProblem([option, command], pushToTalk: talk) == nil)
expect("three modifiers are fine", S.validationProblem([control, option, shift], pushToTalk: talk) == nil)
expect("modifier + letter is fine", S.validationProblem([control, keyD], pushToTalk: talk) == nil)
expect("a function key alone is fine", S.validationProblem([keyF5], pushToTalk: talk) == nil)
expect("nothing pressed is refused", S.validationProblem([], pushToTalk: talk) != nil)
expect("one modifier alone is refused", S.validationProblem([option], pushToTalk: talk) != nil)
expect("a letter alone is refused", S.validationProblem([keyD], pushToTalk: talk) != nil)
expect("two letters are refused", S.validationProblem([keyD, 3], pushToTalk: talk) != nil)
expect("escape is refused", S.validationProblem([control, S.escapeKey], pushToTalk: talk) != nil)
expect("the talk keys are refused", S.validationProblem([option, control], pushToTalk: talk) != nil)
expect("right-side talk keys are refused too", S.validationProblem([62, rightOption], pushToTalk: talk) != nil)
expect("four keys are refused", S.validationProblem([control, option, shift, command], pushToTalk: talk) != nil)

// Holding it
expect("held: exact modifiers", S.isHeld(shortcut: [fn, control], heldModifiers: [fn, control], heldOtherKeys: []))
expect("not held: one missing", !S.isHeld(shortcut: [fn, control], heldModifiers: [control], heldOtherKeys: []))
expect("not held: extra modifier (another shortcut)", !S.isHeld(shortcut: [fn, control], heldModifiers: [fn, control, option], heldOtherKeys: []))
expect("held: modifier + key", S.isHeld(shortcut: [control, keyD], heldModifiers: [control], heldOtherKeys: [keyD]))
expect("not held: modifier without its key", !S.isHeld(shortcut: [control, keyD], heldModifiers: [control], heldOtherKeys: []))
expect("held: lone function key", S.isHeld(shortcut: [keyF5], heldModifiers: [], heldOtherKeys: [keyF5]))
expect("not held: function key with a modifier down", !S.isHeld(shortcut: [keyF5], heldModifiers: [shift], heldOtherKeys: [keyF5]))
expect("talk keys never count as fn + control", !S.isHeld(shortcut: [fn, control], heldModifiers: [control, option], heldOtherKeys: []))

// Keys and flags
expect("right option is option", S.normalized(rightOption) == option)
expect("flags → modifiers", S.heldModifiers(flagsRawValue: DictationChord.controlMask | DictationChord.functionMask) == [fn, control])
expect("no flags → none", S.heldModifiers(flagsRawValue: 0).isEmpty)
expect("display order puts modifiers first", S.orderedForDisplay([keyD, control, fn]) == [fn, control, keyD])
expect("display order drops duplicates", S.orderedForDisplay([control, control, option]) == [control, option])
expect("the other key of control + D is D", S.otherKey(of: [control, keyD]) == keyD)
expect("modifier-only shortcuts have no other key", S.otherKey(of: [fn, control]) == nil)

// Saving
let suite = "teachy-dictation-shortcut-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
expect("nothing saved → default", S.current(defaults) == S.defaultKeyCodes)
S.save([keyD, 62], defaults)
expect("saved keys come back normalized and ordered", S.current(defaults) == [control, keyD])
defaults.set([Int(keyD)], forKey: S.defaultsKey)
expect("a broken saved value falls back to the default", S.current(defaults) == S.defaultKeyCodes)
S.reset(defaults)
expect("reset restores the default", S.current(defaults) == S.defaultKeyCodes)
defaults.removePersistentDomain(forName: suite)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
