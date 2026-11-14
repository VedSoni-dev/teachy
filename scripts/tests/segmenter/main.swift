// Run: scripts/tests/run_segmenter_tests.sh
import Foundation

var failures = 0
func expect(_ name: String, _ got: [String], _ want: [String]) {
    if got != want { failures += 1; print("FAIL \(name)\n  got:  \(got)\n  want: \(want)") } else { print("ok   \(name)") }
}
/// Feeds the text one character at a time, like a stream, and collects every sentence.
func stream(_ full: String) -> [String] {
    var seg = StreamingSpeechSegmenter(); var out: [String] = []; var acc = ""
    for ch in full { acc.append(ch); out += seg.feed(accumulated: acc) }
    out += seg.finish(accumulated: acc)
    return out
}

expect("two sentences", stream("Click the red button to save. Then close the window when it finishes."),
       ["Click the red button to save.", "Then close the window when it finishes."])
expect("short opener merges", stream("Okay. Tap the big blue export button up top."),
       ["Okay. Tap the big blue export button up top."])
expect("point tag stripped", stream("It's this one right here. [POINT:ax:12]"),
       ["It's this one right here."])
expect("tag mid sentence", stream("Open the File menu [POINT:M3:File] and choose Export from the list."),
       ["Open the File menu and choose Export from the list."])
expect("clipboard payload never spoken or split", stream("Your prompt is on the clipboard, ready to paste. [CLIPBOARD: Write a bio. Keep it short! Use a warm tone?] Paste it into the chat box now."),
       ["Your prompt is on the clipboard, ready to paste.", "Paste it into the chat box now."])
expect("unclosed tag at end dropped", stream("Opening Spotify for you now. [DO: open app Spo"),
       ["Opening Spotify for you now."])
expect("decimal not a boundary", stream("Version 3.5 is the one you want to install today."),
       ["Version 3.5 is the one you want to install today."])
expect("newline is a boundary", stream("First do the thing on the left\nThen do the thing on the right"),
       ["First do the thing on the left", "Then do the thing on the right"])
expect("info/todo markers stripped, content kept", stream("[INFO]This is where your site lives.[/INFO] [TODO]Click the Deploy button now.[/TODO]"),
       ["This is where your site lives. Click the Deploy button now."])
expect("empty", stream(""), [])
expect("only a tag", stream("[POINT:none]"), [])
expect("markdown stripped", stream("**Great**, now press `Run` to start the build process."),
       ["Great, now press Run to start the build process."])

// The first sentence must be available before the reply is finished.
var seg = StreamingSpeechSegmenter()
let early = seg.feed(accumulated: "Click the red button to save. Then clo")
expect("first sentence available mid-stream", early, ["Click the red button to save."])

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
