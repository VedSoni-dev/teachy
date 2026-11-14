// Run: scripts/tests/run_uiextras_tests.sh
// Pure logic behind settings, captions, the text box shortcut and the paint trail.
import CoreGraphics
import Foundation

var failures = 0
var passes = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1 } else { failures += 1; print("FAIL \(name) \(detail())") }
}
func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "\n  got:  \(got)\n  want: \(want)")
}
func near(_ name: String, _ got: Double, _ want: Double, tolerance: Double = 0.0001) {
    check(name, abs(got - want) <= tolerance, "\n  got:  \(got)\n  want: \(want)")
}

// MARK: - Double-tap Control

typealias Tap = DoubleTapControlStateMachine
let none: UInt64 = 0
let ctrl = Tap.controlMask
let opt = Tap.optionMask
let fn = Tap.functionMask
let shift = Tap.shiftMask
let cmd = Tap.commandMask
let capsLock: UInt64 = 0x0001_0000
/// Bits real events carry besides the modifiers (device-dependent low bits).
let noise: UInt64 = 0x100

enum Step { case flags(UInt64, Double), key(Double) }
/// Runs the steps and returns the times at which the double-tap fired.
func run(_ steps: [Step]) -> [Double] {
    var machine = Tap()
    var fired: [Double] = []
    for step in steps {
        switch step {
        case .flags(let flags, let time):
            if machine.handle(.modifiersChanged(flagsRawValue: flags | noise), at: time) { fired.append(time) }
        case .key(let time):
            if machine.handle(.otherInput, at: time) { fired.append(time) }
        }
    }
    return fired
}

equal("double tap fires on the second release",
      run([.flags(ctrl, 0), .flags(none, 0.08), .flags(ctrl, 0.20), .flags(none, 0.28)]), [0.28])
equal("single tap does nothing", run([.flags(ctrl, 0), .flags(none, 0.08)]), [])
equal("second tap too late does nothing",
      run([.flags(ctrl, 0), .flags(none, 0.08), .flags(ctrl, 0.50), .flags(none, 0.58)]), [])
equal("gap exactly at the limit still counts",
      run([.flags(ctrl, 0), .flags(none, 0.10), .flags(ctrl, 0.45), .flags(none, 0.50)]), [0.50])
equal("late second tap becomes a new first tap",
      run([.flags(ctrl, 0), .flags(none, 0.08), .flags(ctrl, 0.60), .flags(none, 0.68), .flags(ctrl, 0.80), .flags(none, 0.88)]), [0.88])
equal("held Control is not a tap",
      run([.flags(ctrl, 0), .flags(none, 0.9), .flags(ctrl, 1.0), .flags(none, 1.05)]), [])
equal("second press held too long does nothing",
      run([.flags(ctrl, 0), .flags(none, 0.08), .flags(ctrl, 0.20), .flags(none, 1.4)]), [])
equal("Control+C never fires",
      run([.flags(ctrl, 0), .key(0.05), .flags(none, 0.10), .flags(ctrl, 0.20), .key(0.24), .flags(none, 0.28)]), [])
equal("tap then Control+C does not fire",
      run([.flags(ctrl, 0), .flags(none, 0.08), .flags(ctrl, 0.20), .key(0.24), .flags(none, 0.28)]), [])
equal("a key between the taps cancels",
      run([.flags(ctrl, 0), .flags(none, 0.08), .key(0.12), .flags(ctrl, 0.20), .flags(none, 0.28)]), [])
equal("after a cancel, a fresh double tap works",
      run([.flags(ctrl, 0), .key(0.05), .flags(none, 0.10),
           .flags(ctrl, 1.0), .flags(none, 1.08), .flags(ctrl, 1.2), .flags(none, 1.28)]), [1.28])
equal("Control+Option push-to-talk never fires",
      run([.flags(ctrl, 0), .flags(ctrl | opt, 0.03), .flags(ctrl, 0.10), .flags(none, 0.14),
           .flags(ctrl, 0.20), .flags(ctrl | opt, 0.22), .flags(opt, 0.27), .flags(none, 0.30)]), [])
equal("Option first, then Control, never fires",
      run([.flags(opt, 0), .flags(ctrl | opt, 0.03), .flags(ctrl, 0.06), .flags(none, 0.09),
           .flags(opt, 0.15), .flags(ctrl | opt, 0.18), .flags(ctrl, 0.21), .flags(none, 0.24)]), [])
equal("releasing Option while Control stays down is not a tap start",
      run([.flags(ctrl | opt, 0), .flags(ctrl, 0.05), .flags(none, 0.10), .flags(ctrl, 0.20), .flags(none, 0.28)]), [])
equal("Fn+Control dictation double-tap never fires",
      run([.flags(fn, 0), .flags(fn | ctrl, 0.02), .flags(fn, 0.08), .flags(none, 0.10),
           .flags(fn, 0.20), .flags(fn | ctrl, 0.22), .flags(fn, 0.28), .flags(none, 0.30)]), [])
equal("Control then Fn never fires",
      run([.flags(ctrl, 0), .flags(ctrl | fn, 0.02), .flags(none, 0.08),
           .flags(ctrl, 0.2), .flags(ctrl | fn, 0.22), .flags(none, 0.28)]), [])
equal("Shift+Control and Command+Control never fire",
      run([.flags(ctrl | shift, 0), .flags(none, 0.05), .flags(ctrl | cmd, 0.15), .flags(none, 0.2)]), [])
equal("Caps Lock being on does not block it",
      run([.flags(ctrl | capsLock, 0), .flags(capsLock, 0.08), .flags(ctrl | capsLock, 0.20), .flags(capsLock, 0.28)]), [0.28])
equal("both Control keys in one tap count as one tap",
      run([.flags(ctrl, 0), .flags(ctrl, 0.02), .flags(none, 0.08)]), [])
equal("triple tap fires once, the third starts over",
      run([.flags(ctrl, 0), .flags(none, 0.06), .flags(ctrl, 0.15), .flags(none, 0.21), .flags(ctrl, 0.30), .flags(none, 0.36)]), [0.21])
equal("four taps fire twice",
      run([.flags(ctrl, 0), .flags(none, 0.06), .flags(ctrl, 0.15), .flags(none, 0.21),
           .flags(ctrl, 0.30), .flags(none, 0.36), .flags(ctrl, 0.45), .flags(none, 0.51)]), [0.21, 0.51])
equal("typing with no modifiers is ignored", run([.key(0), .key(0.1), .key(0.2)]), [])
do {
    var machine = Tap()
    _ = machine.handle(.modifiersChanged(flagsRawValue: ctrl), at: 0)
    machine.reset()
    equal("reset returns to idle", machine.state, .idle)
    var custom = Tap(configuration: .init(tapMaximumDuration: 0.1, doubleTapGap: 0.1))
    _ = custom.handle(.modifiersChanged(flagsRawValue: ctrl), at: 0)
    _ = custom.handle(.modifiersChanged(flagsRawValue: 0), at: 0.05)
    _ = custom.handle(.modifiersChanged(flagsRawValue: ctrl), at: 0.25)
    check("custom gap is respected", !custom.handle(.modifiersChanged(flagsRawValue: 0), at: 0.3))
}

// MARK: - Text box placement

let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
let box = CGSize(width: 420, height: 56)
equal("box sits below and right of the pointer",
      TextBoxPlacement.origin(cursor: CGPoint(x: 400, y: 500), panelSize: box, visibleFrame: screen),
      CGPoint(x: 414, y: 500 - 18 - 56))
do {
    let nearBottom = TextBoxPlacement.origin(cursor: CGPoint(x: 400, y: 30), panelSize: box, visibleFrame: screen)
    check("near the bottom it goes above the pointer", nearBottom.y >= 30, "\(nearBottom)")
    let nearRight = TextBoxPlacement.origin(cursor: CGPoint(x: 1430, y: 500), panelSize: box, visibleFrame: screen)
    check("near the right edge it stays on screen", nearRight.x + box.width <= 1440 - 10, "\(nearRight)")
    let second = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
    let onSecond = TextBoxPlacement.origin(cursor: CGPoint(x: -1900, y: 210), panelSize: box, visibleFrame: second)
    check("stays inside a display with a negative origin",
          second.contains(CGRect(origin: onSecond, size: box)), "\(onSecond)")
    let corner = TextBoxPlacement.origin(cursor: CGPoint(x: 1439, y: 1), panelSize: box, visibleFrame: screen)
    check("bottom-right corner stays on screen", screen.contains(CGRect(origin: corner, size: box)), "\(corner)")
}

// MARK: - Caption line fitting

equal("short sentence is one line", CaptionLineFitter.wrap("Click the red button.", maxWidth: 40), ["Click the red button."])
equal("wraps at word boundaries",
      CaptionLineFitter.wrap("Click the red button to save your work", maxWidth: 16),
      ["Click the red", "button to save", "your work"])
equal("whitespace and newlines collapse",
      CaptionLineFitter.wrap("  Open   the\nFile menu \t now ", maxWidth: 40), ["Open the File menu now"])
equal("a word longer than the line is broken",
      CaptionLineFitter.wrap("see supercalifragilistic now", maxWidth: 10),
      ["see", "supercalif", "ragilistic", "now"])
equal("empty text has no lines", CaptionLineFitter.wrap("   ", maxWidth: 10), [])
equal("zero width has no lines", CaptionLineFitter.wrap("hello", maxWidth: 0), [])
check("no line is wider than the limit",
      CaptionLineFitter.wrap("The quick brown fox jumps over the lazy dog near the riverbank at dawn", maxWidth: 12).allSatisfy { $0.count <= 12 })
equal("words are never lost or reordered",
      CaptionLineFitter.wrap("The quick brown fox jumps over the lazy dog", maxWidth: 9).joined(separator: " "),
      "The quick brown fox jumps over the lazy dog")
equal("pages hold two lines each",
      CaptionLineFitter.pages("one two three four five six seven", maxWidth: 9),
      [["one two", "three"], ["four five", "six seven"]])
equal("an odd last line gets its own page",
      CaptionLineFitter.pages("aaaa bbbb cccc", maxWidth: 4), [["aaaa", "bbbb"], ["cccc"]])
equal("empty text has no pages", CaptionLineFitter.pages("", maxWidth: 20), [])
equal("custom measure is used",
      CaptionLineFitter.wrap("ab cd ef", maxWidth: 10, measure: { Double($0.count) * 2.5 }), ["ab", "cd", "ef"])
near("speech time grows with length", CaptionLineFitter.estimatedSpeechSeconds(for: String(repeating: "a", count: 30)), 2.0)
near("slower speed takes longer", CaptionLineFitter.estimatedSpeechSeconds(for: String(repeating: "a", count: 30), speed: 0.5), 4.0)
near("a tiny caption still stays up", CaptionLineFitter.estimatedSpeechSeconds(for: "Ok."), 0.6)
equal("one duration per page",
      CaptionLineFitter.pageDurations(CaptionLineFitter.pages("one two three four five six seven", maxWidth: 9)).count, 2)

// MARK: - Paint trail

typealias Trail = PaintTrailMath
let trailConfig = PaintTrailConfiguration()
do {
    var points: [PaintTrailPoint] = []
    check("first point is kept", Trail.append(PaintTrailPoint(x: 0, y: 0, time: 0), to: &points))
    check("a jittery sample is dropped", !Trail.append(PaintTrailPoint(x: 1, y: 1, time: 0.01), to: &points))
    check("a moved sample is kept", Trail.append(PaintTrailPoint(x: 3, y: 4, time: 0.02), to: &points))
    equal("two points kept", points.count, 2)
    near("length is the path length", Trail.length(of: points), 5)

    var capped = PaintTrailConfiguration()
    capped.maximumPointCount = 10
    var many: [PaintTrailPoint] = []
    for i in 0..<50 { Trail.append(PaintTrailPoint(x: Double(i) * 10, y: 0, time: Double(i) * 0.01), to: &many, configuration: capped) }
    equal("point count is capped", many.count, 10)
    near("the newest points survive the cap", many.last!.x, 490)
}
near("opacity is full while held", Trail.releaseOpacity(now: 5, releasedAt: nil), 1)
near("opacity is full at release", Trail.releaseOpacity(now: 5, releasedAt: 5), 1)
near("opacity is zero after the fade", Trail.releaseOpacity(now: 6.2, releasedAt: 5), 0)
near("opacity stays zero later", Trail.releaseOpacity(now: 60, releasedAt: 5), 0)
do {
    let samples = stride(from: 0.0, through: 1.2, by: 0.1).map { Trail.releaseOpacity(now: 5 + $0, releasedAt: 5) }
    check("fade only ever goes down", zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    check("fade is mostly gone at the halfway point", Trail.releaseOpacity(now: 5.6, releasedAt: 5) < 0.3)
}
check("not finished while held", !Trail.isFinished(now: 100, releasedAt: nil))
check("not finished mid-fade", !Trail.isFinished(now: 5.5, releasedAt: 5))
check("finished after the fade", Trail.isFinished(now: 6.2, releasedAt: 5))
near("fresh paint is full width", Trail.ageFactor(pointTime: 0, now: 3, releasedAt: nil), 1)
near("old paint thins while held", Trail.ageFactor(pointTime: 0, now: 7, releasedAt: nil), 0.5)
near("very old paint is gone", Trail.ageFactor(pointTime: 0, now: 9, releasedAt: nil), 0)
near("age freezes at release", Trail.ageFactor(pointTime: 0, now: 30, releasedAt: 3), 1)
do {
    let old = [PaintTrailPoint(x: 0, y: 0, time: 0), PaintTrailPoint(x: 10, y: 0, time: 5), PaintTrailPoint(x: 20, y: 0, time: 9)]
    equal("fully thinned points are pruned while held", Trail.pruned(old, now: 10, releasedAt: nil).count, 2)
    equal("nothing is pruned after release", Trail.pruned(old, now: 10, releasedAt: 9.5).count, 3)
    equal("everything prunes eventually", Trail.pruned(old, now: 100, releasedAt: nil).count, 0)
}
do {
    let wobbles = (0..<500).map(Trail.wobble(index:))
    check("wobble stays within -1...1", wobbles.allSatisfy { $0 >= -1 && $0 <= 1 })
    check("wobble actually varies", (wobbles.max()! - wobbles.min()!) > 0.8)
    near("wobble is steady for an index", Trail.wobble(index: 42), Trail.wobble(index: 42))
    check("fast strokes are thinner than slow ones",
          Trail.width(index: 5, speed: 3000) < Trail.width(index: 5, speed: 50))
    let extremes = (0..<300).flatMap { [Trail.width(index: $0, speed: 0), Trail.width(index: $0, speed: 99999)] }
    check("width stays within 55%...140% of the base",
          extremes.allSatisfy { $0 >= trailConfig.baseWidth * 0.55 - 0.0001 && $0 <= trailConfig.baseWidth * 1.4 + 0.0001 })

    let stroke = (0..<60).map { PaintTrailPoint(x: Double($0) * 8, y: sin(Double($0) / 6) * 40, time: Double($0) / 60) }
    let widths = Trail.widths(for: stroke, now: 1, releasedAt: nil)
    equal("one width per point", widths.count, stroke.count)
    check("widths vary a little (hand-drawn)", (widths.max()! - widths.min()!) > 0.3)
    let jumps = zip(widths, widths.dropFirst()).map { abs($0 - $1) }
    check("widths change gradually", jumps.max()! < 1.5, "\(jumps.max()!)")
    equal("no points, no widths", Trail.widths(for: [], now: 0, releasedAt: nil), [])
}

// MARK: - Settings

func freshDefaults() -> (UserDefaults, String) {
    let name = "teachy-uiextras-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

equal("unknown voice falls back to Puck", TeachyVoiceCatalog.resolved("robot"), "Puck")
equal("nil voice falls back to Puck", TeachyVoiceCatalog.resolved(nil), "Puck")
equal("voice names are case-insensitive", TeachyVoiceCatalog.resolved("kore"), "Kore")
equal("eight voices", TeachyVoiceCatalog.voices.map(\.name),
      ["Puck", "Aoede", "Kore", "Leda", "Zephyr", "Charon", "Fenrir", "Orus"])
near("speed clamps low", TeachySpeechSpeed.normalized(0.1), 0.5)
near("speed clamps high", TeachySpeechSpeed.normalized(9), 1.5)
near("speed snaps to the step", TeachySpeechSpeed.normalized(1.0300001), 1.05)
near("NaN speed becomes the default", TeachySpeechSpeed.normalized(.nan), 1.0)
equal("speed label, whole tenth", TeachySpeechSpeed.label(1.0), "1.0×")
equal("speed label, hundredths", TeachySpeechSpeed.label(0.85), "0.85×")
equal("language codes are normalised", TeachyDictationLanguages.normalized(" EN "), "en")
equal("junk language becomes auto", TeachyDictationLanguages.normalized("english please"), "auto")
equal("language display name", TeachyDictationLanguages.name(for: "gu"), "Gujarati")
equal("unknown code shows as itself", TeachyDictationLanguages.name(for: "xx"), "XX")

equal("push-to-talk reads right", TeachyShortcutSet.standard.pushToTalk.displayText, "Hold control + option")
equal("text box reads right", TeachyShortcutSet.standard.textBox.displayText, "Double-tap control")
equal("dictation reads right", TeachyShortcutSet.standard.dictation.displayText, "Hold fn + control")
equal("hands-free reads right", TeachyShortcutSet.standard.handsFreeDictation.displayText, "Double-tap fn + control")
equal("modifiers are shown in a fixed order",
      TeachyShortcut([.command, .shift, .function, .option, .control]).keyLabels,
      ["fn", "control", "option", "shift", "command"])
do {
    var custom = TeachyShortcutSet()
    custom.pushToTalk = TeachyShortcut([.command, .shift])
    custom.textBox = TeachyShortcut([.option], doubleTap: true)
    let data = try! JSONEncoder().encode(custom)
    equal("shortcut set survives encode and decode", try! JSONDecoder().decode(TeachyShortcutSet.self, from: data), custom)

    let partial = Data(#"{"pushToTalk":{"modifiers":["command"],"isDoubleTap":false},"textBox":{"modifiers":[],"isDoubleTap":true},"dictation":"nonsense"}"#.utf8)
    let decoded = try! JSONDecoder().decode(TeachyShortcutSet.self, from: partial)
    equal("a valid entry is kept", decoded.pushToTalk, TeachyShortcut([.command]))
    equal("an empty entry falls back", decoded.textBox, TeachyShortcutSet.standard.textBox)
    equal("a broken entry falls back", decoded.dictation, TeachyShortcutSet.standard.dictation)
    equal("a missing entry falls back", decoded.handsFreeDictation, TeachyShortcutSet.standard.handsFreeDictation)
}

MainActor.assumeIsolated {
    let (defaults, suiteName) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = TeachySettings(defaults: defaults)
    equal("default voice", first.voiceName, "Puck")
    near("default speed", first.speechSpeed, 1.0)
    equal("captions default off", first.captionsEnabled, false)
    equal("default cursor colour", first.cursorColorName, "blue")
    equal("default dictation language", first.dictationLanguage, "auto")
    equal("cleanup default on", first.dictationCleanupEnabled, true)
    equal("sounds default on", first.soundsEnabled, true)
    equal("browser sign-ins default off", first.allowBrowserCookieTools, false)
    equal("default shortcuts", first.shortcuts, .standard)
    check("nothing is written until something changes", defaults.object(forKey: TeachySettingsKey.voiceName) == nil)

    first.voiceName = "Kore"
    first.speechSpeed = 1.234
    first.captionsEnabled = true
    first.cursorColorName = "green"
    first.dictationLanguage = "FR"
    first.dictationCleanupEnabled = false
    first.soundsEnabled = false
    first.allowBrowserCookieTools = true
    var shortcuts = TeachyShortcutSet()
    shortcuts.textBox = TeachyShortcut([.option], doubleTap: true)
    first.shortcuts = shortcuts

    near("speed is snapped when set", first.speechSpeed, 1.25)
    equal("language is normalised when set", first.dictationLanguage, "fr")
    equal("voice is saved under the key the synthesizer reads", defaults.string(forKey: "teachyPublikVoiceName"), "Kore")
    equal("cursor colour is saved under the existing key", defaults.string(forKey: "selectedCursorColor"), "green")
    near("speed is saved under teachySpeechSpeed", defaults.double(forKey: "teachySpeechSpeed"), 1.25)

    let second = TeachySettings(defaults: defaults)
    equal("voice round-trips", second.voiceName, "Kore")
    near("speed round-trips", second.speechSpeed, 1.25)
    equal("captions round-trip", second.captionsEnabled, true)
    equal("cursor colour round-trips", second.cursorColorName, "green")
    equal("language round-trips", second.dictationLanguage, "fr")
    equal("cleanup round-trips", second.dictationCleanupEnabled, false)
    equal("sounds round-trip", second.soundsEnabled, false)
    equal("browser sign-ins round-trip", second.allowBrowserCookieTools, true)
    equal("shortcuts round-trip", second.shortcuts, shortcuts)

    equal("storage reader agrees: voice", TeachySettingsStorage.voiceName(defaults), "Kore")
    near("storage reader agrees: speed", TeachySettingsStorage.speechSpeed(defaults), 1.25)
    equal("storage reader agrees: language code", TeachySettingsStorage.dictationLanguageCode(defaults), "fr")
    equal("storage reader agrees: cookies", TeachySettingsStorage.allowBrowserCookieTools(defaults), true)

    second.voiceName = "not-a-voice"
    equal("an unknown voice is refused", second.voiceName, "Puck")
    equal("and the default is what gets saved", defaults.string(forKey: "teachyPublikVoiceName"), "Puck")
    second.speechSpeed = 7
    near("an out-of-range speed is clamped", second.speechSpeed, 1.5)
    second.dictationLanguage = "auto"
    check("auto means no language code is sent", TeachySettingsStorage.dictationLanguageCode(defaults) == nil)

    defaults.set("garbage", forKey: TeachySettingsKey.shortcuts)
    defaults.set(42.0, forKey: TeachySettingsKey.speechSpeed)
    defaults.set("zzz", forKey: TeachySettingsKey.voiceName)
    let third = TeachySettings(defaults: defaults)
    equal("corrupt shortcuts load as the defaults", third.shortcuts, .standard)
    near("a corrupt speed loads clamped", third.speechSpeed, 1.5)
    equal("a corrupt voice loads as Puck", third.voiceName, "Puck")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
