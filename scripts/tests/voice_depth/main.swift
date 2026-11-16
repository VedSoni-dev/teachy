// Tests for VoiceTurnDepth and [OPEN:] link parsing. Run with scripts/tests/run_voice_depth_tests.sh.
import Foundation

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL (line \(line)): \(message)") }
}

print("— depth")
for deep in ["explain this diagram", "teach me how compound interest works", "why is this failing?", "How does a transformer work",
             "what's the difference between let and var", "help me understand this error", "can you break down this chart for me",
             "should I use postgres or sqlite for this", "what am I looking at here"] {
    expect(VoiceTurnDepth.classify(deep) == .deep, "\(deep) should be deep")
}
for quick in ["open Spotify", "close this tab", "where's the export button", "what time is it in Tokyo", "play some music",
              "switch to Safari", "make the font bigger"] {
    expect(VoiceTurnDepth.classify(quick) == .quick, "\(quick) should be quick")
}
expect(VoiceTurnDepth.deep.reasoningEffort == "low" && VoiceTurnDepth.quick.reasoningEffort == nil, "effort per depth")
expect(VoiceTurnDepth.deep.maxTokens > VoiceTurnDepth.quick.maxTokens, "deep gets more room")

print("— open links")
let reply = "Here's the docs. [OPEN: https://developer.apple.com/documentation/swiftui] And a video. [OPEN: https://www.youtube.com/results?search_query=swiftui+layout] [OPEN: https://example.com/third]"
let (text, urls) = VoiceOpenLinks.extract(from: reply)
expect(urls.count == 2, "at most two links: \(urls)")
expect(urls.first?.host == "developer.apple.com", "first link kept in order")
expect(!text.contains("[OPEN"), "every OPEN tag is stripped, even past the limit: \(text)")
expect(VoiceOpenLinks.safeURL("javascript:alert(1)") == nil, "no javascript urls")
expect(VoiceOpenLinks.safeURL("file:///etc/passwd") == nil, "no file urls")
expect(VoiceOpenLinks.safeURL("teachy://install") == nil, "no custom schemes")
expect(VoiceOpenLinks.safeURL("wikipedia.org/wiki/Moon")?.absoluteString == "https://wikipedia.org/wiki/Moon", "bare domains get https")
expect(VoiceOpenLinks.safeURL("not a url") == nil, "spaces are not urls")
expect(VoiceOpenLinks.safeURL("http://localhost") == nil, "needs a real host")
expect(VoiceOpenLinks.extract(from: "No links here.").urls.isEmpty, "no tags, no links")

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASSED")
