// Next-step chips: reading [NEXT:] tags, which chips show, finding the typed text again.
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let reply = "Friday works. [NEXT: Find a table for six] [next: \"Add it to my calendar\"] [NEXT: find a TABLE for six] [NEXT: Show me on a map] [NEXT: One too many]"
let (text, labels) = NextStepRules.extract(from: reply)
check(text == "Friday works.", "tags are removed from the reply")
check(labels == ["Find a table for six", "Add it to my calendar", "Show me on a map"], "labels cleaned, de-duplicated, capped at three")
check(NextStepRules.extract(from: "No tags here.").labels.isEmpty, "no tags → no labels")
let long = NextStepRules.extract(from: "[NEXT: " + String(repeating: "word ", count: 20) + "]").labels.first ?? ""
check(long.count <= NextStepRules.maximumLabelLength + 1 && long.hasSuffix("…"), "long labels are shortened")

let afterWriting = NextStepRules.chips(modelLabels: ["Make it shorter", "Book it"], typedTextJustNow: true)
check(afterWriting.map(\.label) == ["Make it shorter", "Make it warmer", "Book it"], "rewrite chips first, no duplicates")
check(afterWriting[0].kind == .rewriteLastWriting(change: "make it shorter") && afterWriting[2].kind == .askTeachy, "chip kinds")
check(NextStepRules.chips(modelLabels: [], typedTextJustNow: false).isEmpty, "nothing to offer → no row")

let field = "Hi Maya,\nFriday works great! See you then.\n\nSent from my Mac"
let range = NextStepRules.rangeOfLastWriting("Friday works great! See you then.", in: field)
check(range == NSRange(location: 9, length: 33), "finds the typed text in the field")
check(NextStepRules.rangeOfLastWriting("Something else", in: field) == nil, "edited away → not found")
check(NextStepRules.rangeOfLastWriting("ok", in: "ok then ok") == NSRange(location: 8, length: 2), "uses the last occurrence")
check(NextStepRules.rewriteInstruction(originalText: "Hello there", change: "make it shorter").contains("make it shorter"), "rewrite instruction names the change")

print(failures == 0 ? "All next-step checks passed." : "\(failures) next-step check(s) failed.")
exit(failures == 0 ? 0 : 1)
