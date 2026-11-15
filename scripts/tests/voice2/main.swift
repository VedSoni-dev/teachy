// Run: scripts/tests/run_voice2_tests.sh
// Pure logic behind always-on mode, quiet-on-calls, microphone failover, reply
// languages, the realtime voice's pace and screen memory. The voice detector is
// tested on synthetic sound (noise, bursts, pauses), not on a real microphone.
import Foundation

var failures = 0
func expect(_ name: String, _ condition: Bool) {
    if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected { print("ok   \(name)") } else { failures += 1; print("FAIL \(name): got \(actual), expected \(expected)") }
}

// MARK: - Synthetic sound

let sampleRate = 16_000.0
var randomState: UInt64 = 0x9E37_79B9_7F4A_7C15
func nextRandom() -> Float {
    randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Float(randomState >> 40) / Float(1 << 24) * 2 - 1   // -1…1
}
/// Steady noise with the given RMS loudness.
func noise(rms: Float, seconds: Double) -> [Float] {
    let amplitude = rms * Float(3).squareRoot()
    return (0..<Int(seconds * sampleRate)).map { _ in nextRandom() * amplitude }
}
/// Something shaped like speech: loud noise that swells and dips four times a second,
/// on top of the room's noise.
func speech(rms: Float, seconds: Double, room: Float = 0.002) -> [Float] {
    let amplitude = rms * Float(3).squareRoot() * 1.35
    let roomAmplitude = room * Float(3).squareRoot()
    return (0..<Int(seconds * sampleRate)).map { index in
        let time = Double(index) / sampleRate
        let envelope = Float(0.12 + 0.88 * abs(sin(2 * Double.pi * 2 * time)))
        return nextRandom() * amplitude * envelope + nextRandom() * roomAmplitude
    }
}

struct Heard {
    var events: [String] = []
    var utterances: [[Float]] = []
    var startTimes: [Double] = []
    var endTimes: [Double] = []
}
/// Feeds the sound in microphone-sized pieces and records what the segmenter reports and when.
func listen(_ sound: [Float], segmenter: inout UtteranceSegmenter, clock: inout Double) -> Heard {
    var heard = Heard()
    let chunk = 512
    var offset = 0
    while offset < sound.count {
        let end = min(sound.count, offset + chunk)
        let events = segmenter.feed(Array(sound[offset..<end]))
        clock += Double(end - offset) / sampleRate
        for event in events {
            switch event {
            case .started: heard.events.append("started"); heard.startTimes.append(clock)
            case .finished(let samples, _): heard.events.append("finished"); heard.utterances.append(samples); heard.endTimes.append(clock)
            case .discarded: heard.events.append("discarded")
            }
        }
        offset = end
    }
    return heard
}
func listen(_ sound: [Float], configuration: VoiceActivityDetector.Configuration = .init(), teachySpeaking: Bool = false) -> Heard {
    var segmenter = UtteranceSegmenter(sampleRate: sampleRate, configuration: configuration)
    segmenter.teachyIsSpeaking = teachySpeaking
    var clock = 0.0
    return listen(sound, segmenter: &segmenter, clock: &clock)
}
func seconds(_ samples: [Float]) -> Double { Double(samples.count) / sampleRate }

print("— voice detector —")
let room: Float = 0.002   // about -54 dB: a quiet room

do {
    let heard = listen(noise(rms: room, seconds: 12))
    equal("a quiet room produces nothing", heard.events, [])
}
do {
    let heard = listen(noise(rms: 0, seconds: 5))
    equal("digital silence produces nothing", heard.events, [])
}
do {
    let heard = listen(noise(rms: room, seconds: 2) + speech(rms: 0.1, seconds: 1.5) + noise(rms: room, seconds: 2))
    equal("one sentence is one utterance", heard.events, ["started", "finished"])
    if let utterance = heard.utterances.first {
        let length = seconds(utterance)
        // 0.4 s pre-roll + 1.5 s speech + 0.2 s kept silence, give or take the detector's frames.
        expect("the utterance holds the whole sentence and little else (\(String(format: "%.2f", length)) s)", length > 1.9 && length < 2.5)
        // The pre-roll: its first 0.3 s are the quiet room from before the sentence began.
        let lead = utterance.prefix(Int(0.3 * sampleRate))
        let leadRMS = (lead.reduce(0) { $0 + $1 * $1 } / Float(lead.count)).squareRoot()
        expect("it starts before the first syllable (pre-roll is room noise, \(leadRMS))", leadRMS < 0.01)
        let speechStartsBy = utterance.prefix(Int(0.7 * sampleRate)).contains { abs($0) > 0.05 }
        expect("the first syllable is inside it", speechStartsBy)
    }
    if let started = heard.startTimes.first {
        expect("speech is noticed within 0.2 s of starting (\(String(format: "%.2f", started - 2.0)) s)", started - 2.0 <= 0.2)
    }
    if let ended = heard.endTimes.first {
        let wait = ended - 3.5
        expect("it ends about 0.9 s after the last word (\(String(format: "%.2f", wait)) s)", wait > 0.7 && wait < 1.2)
    }
}
do {
    let heard = listen(noise(rms: room, seconds: 2) + noise(rms: 0.2, seconds: 0.06) + noise(rms: room, seconds: 3))
    equal("a 60 ms click starts nothing", heard.events, [])
}
do {
    let heard = listen(noise(rms: room, seconds: 2) + noise(rms: 0.2, seconds: 0.2) + noise(rms: room, seconds: 3))
    equal("a 200 ms bump is thrown away, not sent", heard.events, ["started", "discarded"])
}
do {
    let sound = noise(rms: room, seconds: 2) + speech(rms: 0.1, seconds: 1.5) + noise(rms: room, seconds: 0.6)
        + speech(rms: 0.1, seconds: 1.5) + noise(rms: room, seconds: 2)
    let heard = listen(sound)
    equal("a 0.6 s pause mid-sentence does not split it", heard.events, ["started", "finished"])
    if let utterance = heard.utterances.first {
        expect("both halves are in the one utterance (\(String(format: "%.2f", seconds(utterance))) s)", seconds(utterance) > 3.6)
    }
}
do {
    let sound = noise(rms: room, seconds: 2) + speech(rms: 0.1, seconds: 1.5) + noise(rms: room, seconds: 1.6)
        + speech(rms: 0.1, seconds: 1.5) + noise(rms: room, seconds: 2)
    let heard = listen(sound)
    equal("a 1.6 s pause makes two utterances", heard.events, ["started", "finished", "started", "finished"])
}
do {
    let heard = listen(noise(rms: room, seconds: 2) + speech(rms: 0.1, seconds: 14) + noise(rms: room, seconds: 2))
    equal("14 s of talking is one utterance", heard.events, ["started", "finished"])
    if let utterance = heard.utterances.first {
        expect("and none of it is cut (\(String(format: "%.1f", seconds(utterance))) s)", seconds(utterance) > 14)
    }
}
do {
    let heard = listen(noise(rms: room, seconds: 1) + speech(rms: 0.1, seconds: 36) + noise(rms: room, seconds: 2))
    expect("talking past 30 s is cut off at the limit", heard.utterances.first.map { seconds($0) > 29 && seconds($0) < 31.5 } ?? false)
}
do {
    // A fan switches on: steady noise 23 dB louder than the room, for a long time.
    var segmenter = UtteranceSegmenter(sampleRate: sampleRate)
    var clock = 0.0
    _ = listen(noise(rms: room, seconds: 3), segmenter: &segmenter, clock: &clock)
    let fanStart = listen(noise(rms: 0.03, seconds: 8), segmenter: &segmenter, clock: &clock)
    expect("a fan switching on is not held open for ever (\(fanStart.events))", !segmenter.isInSpeech)
    let fanLater = listen(noise(rms: 0.03, seconds: 15), segmenter: &segmenter, clock: &clock)
    equal("once the fan is the room, it produces nothing", fanLater.events, [])
    expect("the noise floor followed the fan (\(segmenter.detector.noiseFloorDB) dB)", segmenter.detector.noiseFloorDB > -36)
    let overFan = listen(speech(rms: 0.2, seconds: 1.5, room: 0.03) + noise(rms: 0.03, seconds: 2), segmenter: &segmenter, clock: &clock)
    equal("speech over the fan is still heard", overFan.events, ["started", "finished"])
    let afterFan = listen(noise(rms: room, seconds: 6) + speech(rms: 0.05, seconds: 1.2) + noise(rms: room, seconds: 2), segmenter: &segmenter, clock: &clock)
    equal("when the fan stops, quiet speech is heard again", afterFan.events, ["started", "finished"])
}

print("— while Teachy is talking —")
do {
    // What is left of Teachy's voice after echo cancellation: quiet, speech-shaped.
    let residue = noise(rms: room, seconds: 2) + speech(rms: 0.008, seconds: 4) + noise(rms: room, seconds: 2)
    expect("that residue would count as speech in normal listening", listen(residue).events.contains("started"))
    equal("it does not while Teachy is talking", listen(residue, teachySpeaking: true).events, [])
}
do {
    let sound = noise(rms: room, seconds: 2) + speech(rms: 0.008, seconds: 2) + speech(rms: 0.12, seconds: 1.5) + noise(rms: room, seconds: 2)
    let heard = listen(sound, teachySpeaking: true)
    equal("the person talking over Teachy is heard", heard.events, ["started", "finished"])
    if let started = heard.startTimes.first {
        expect("within 0.2 s, so speech can stop in time (\(String(format: "%.2f", started - 4.0)) s)", started - 4.0 > 0 && started - 4.0 <= 0.2)
    }
    if let utterance = heard.utterances.first {
        expect("and their utterance is captured from its start (\(String(format: "%.2f", seconds(utterance))) s)", seconds(utterance) > 1.9)
    }
}
do {
    let heard = listen(noise(rms: room, seconds: 2) + noise(rms: 0.2, seconds: 0.1) + noise(rms: room, seconds: 2), teachySpeaking: true)
    equal("a 100 ms knock does not interrupt Teachy", heard.events, [])
}
do {
    var detector = VoiceActivityDetector()
    let normal = detector.currentStartThresholdDB
    detector.teachyIsSpeaking = true
    expect("the bar is higher while Teachy talks (\(normal) → \(detector.currentStartThresholdDB) dB)", detector.currentStartThresholdDB >= normal + 8)
}

print("— control taps —")
let controlDown = ControlTapCountStateMachine.Event.modifiersChanged(flagsRawValue: ControlTapCountStateMachine.controlMask)
let allUp = ControlTapCountStateMachine.Event.modifiersChanged(flagsRawValue: 0)
/// Taps Control `count` times, 0.08 s down and `gap` apart. Returns the outputs and the time after the last release.
func tap(_ machine: inout ControlTapCountStateMachine, times count: Int, from start: Double, gap: Double = 0.12, hold: Double = 0.08) -> (outputs: [ControlTapCountStateMachine.Output], end: Double) {
    var outputs: [ControlTapCountStateMachine.Output] = []
    var time = start
    for _ in 0..<count {
        if let output = machine.handle(controlDown, at: time) { outputs.append(output) }
        time += hold
        if let output = machine.handle(allUp, at: time) { outputs.append(output) }
        time += gap
    }
    return (outputs, time - gap)
}
do {
    var machine = ControlTapCountStateMachine()
    equal("one tap is nothing", tap(&machine, times: 1, from: 0).outputs, [])
    machine.reset()
    equal("two taps are a double tap, at once", tap(&machine, times: 2, from: 10).outputs, [.doubleTap])
    machine.reset()
    equal("three taps are a double tap and then a triple tap", tap(&machine, times: 3, from: 20).outputs, [.doubleTap, .tripleTap])
    machine.reset()
    equal("a fourth and fifth tap in the burst add nothing", tap(&machine, times: 5, from: 30).outputs, [.doubleTap, .tripleTap])
    let later = tap(&machine, times: 2, from: 40)
    equal("after a pause, tapping works again", later.outputs, [.doubleTap])
}
do {
    var machine = ControlTapCountStateMachine()
    let first = tap(&machine, times: 2, from: 0)
    let third = tap(&machine, times: 1, from: first.end + 0.6)
    equal("a third tap that comes too late is not a triple tap", first.outputs + third.outputs, [.doubleTap])
    let more = tap(&machine, times: 1, from: third.end + 0.1)
    equal("it starts a new count instead", more.outputs, [.doubleTap])
}
do {
    var machine = ControlTapCountStateMachine()
    var outputs = tap(&machine, times: 2, from: 0).outputs
    _ = machine.handle(controlDown, at: 0.5)
    if let output = machine.handle(allUp, at: 1.4) { outputs.append(output) }
    equal("holding Control for the third press is not a triple tap", outputs, [.doubleTap])
}
do {
    var machine = ControlTapCountStateMachine()
    var outputs = tap(&machine, times: 2, from: 0).outputs
    _ = machine.handle(controlDown, at: 0.4)
    if let output = machine.handle(.otherInput, at: 0.42) { outputs.append(output) }   // Control+C
    if let output = machine.handle(allUp, at: 0.5) { outputs.append(output) }
    equal("Control+C as the third press is not a triple tap", outputs, [.doubleTap])
}
do {
    var machine = ControlTapCountStateMachine()
    var outputs: [ControlTapCountStateMachine.Output] = []
    let controlOption = ControlTapCountStateMachine.Event.modifiersChanged(
        flagsRawValue: ControlTapCountStateMachine.controlMask | ControlTapCountStateMachine.optionMask)
    for index in 0..<3 {
        let time = Double(index) * 0.2
        if let output = machine.handle(controlOption, at: time) { outputs.append(output) }
        if let output = machine.handle(allUp, at: time + 0.08) { outputs.append(output) }
    }
    equal("Control+Option (the talk key) three times is nothing", outputs, [])
}
do {
    var configuration = ControlTapCountStateMachine.Configuration()
    configuration.doubleTapRule = .waitForPossibleThird
    var machine = ControlTapCountStateMachine(configuration: configuration)
    let two = tap(&machine, times: 2, from: 0)
    equal("waiting rule: two taps report nothing yet", two.outputs, [])
    equal("waiting rule: a deadline is set one gap after the second tap", machine.pendingDoubleTapDeadline.map { ($0 * 1000).rounded() / 1000 }, ((two.end + 0.35) * 1000).rounded() / 1000)
    equal("waiting rule: too early to confirm", machine.poll(at: two.end + 0.2), nil)
    equal("waiting rule: confirmed as a double tap after the gap", machine.poll(at: two.end + 0.36), .doubleTap)
    equal("waiting rule: confirmed only once", machine.poll(at: two.end + 0.5), nil)

    machine.reset()
    equal("waiting rule: three taps are only a triple tap", tap(&machine, times: 3, from: 10).outputs, [.tripleTap])
    equal("waiting rule: nothing is left waiting after a triple tap", machine.pendingDoubleTapDeadline, nil)

    machine.reset()
    let typed = tap(&machine, times: 2, from: 20)
    equal("waiting rule: typing right after two taps confirms the double tap at once", machine.handle(.otherInput, at: typed.end + 0.1), .doubleTap)

    machine.reset()
    let held = tap(&machine, times: 2, from: 30)
    _ = machine.handle(controlDown, at: held.end + 0.1)
    equal("waiting rule: two taps then a hold is still a double tap", machine.handle(allUp, at: held.end + 1.0), .doubleTap)
}
do {
    // Next to the text box's own monitor: both see the same keys.
    var textBox = DoubleTapControlStateMachine()
    var counter = ControlTapCountStateMachine()
    var textBoxFired = 0
    var counterOutputs: [ControlTapCountStateMachine.Output] = []
    var time = 0.0
    for _ in 0..<3 {
        if textBox.handle(.modifiersChanged(flagsRawValue: DoubleTapControlStateMachine.controlMask), at: time) { textBoxFired += 1 }
        if let output = counter.handle(controlDown, at: time) { counterOutputs.append(output) }
        time += 0.08
        if textBox.handle(.modifiersChanged(flagsRawValue: 0), at: time) { textBoxFired += 1 }
        if let output = counter.handle(allUp, at: time) { counterOutputs.append(output) }
        time += 0.12
    }
    equal("three taps: the text box monitor fires once (on the second)", textBoxFired, 1)
    equal("three taps: the counter reports the triple on the third", counterOutputs.last, .tripleTap)
}

print("— where sound comes out —")
equal("built-in speakers", OutputRouteKind.classify(transportType: AudioFourCC.builtIn, dataSource: AudioFourCC.internalSpeakerDataSource, deviceName: "MacBook Pro Speakers"), .speakers)
equal("the headphone jack", OutputRouteKind.classify(transportType: AudioFourCC.builtIn, dataSource: AudioFourCC.headphonesDataSource, deviceName: "External Headphones"), .headphones)
equal("built-in with no data source, named headphones", OutputRouteKind.classify(transportType: AudioFourCC.builtIn, dataSource: nil, deviceName: "External Headphones"), .headphones)
equal("built-in with no data source (Mac mini speaker)", OutputRouteKind.classify(transportType: AudioFourCC.builtIn, dataSource: nil, deviceName: "Mac mini Speakers"), .speakers)
equal("AirPods", OutputRouteKind.classify(transportType: AudioFourCC.bluetooth, dataSource: nil, deviceName: "Ved's AirPods Pro"), .headphones)
equal("a Bluetooth headset with a model number for a name", OutputRouteKind.classify(transportType: AudioFourCC.bluetooth, dataSource: nil, deviceName: "WH-CH720N"), .headphones)
equal("a Bluetooth speaker", OutputRouteKind.classify(transportType: AudioFourCC.bluetooth, dataSource: nil, deviceName: "JBL Flip 6 Speaker"), .speakers)
equal("a monitor over HDMI", OutputRouteKind.classify(transportType: AudioFourCC.hdmi, dataSource: nil, deviceName: "LG UltraFine"), .speakers)
equal("a USB interface counts as speakers", OutputRouteKind.classify(transportType: AudioFourCC.usb, dataSource: nil, deviceName: "Scarlett 2i2"), .speakers)
equal("a USB headset", OutputRouteKind.classify(transportType: AudioFourCC.usb, dataSource: nil, deviceName: "Jabra Evolve Headset"), .headphones)
equal("no output device", OutputRouteKind.classify(transportType: nil, dataSource: nil, deviceName: ""), OutputRouteKind.none)

equal("headphones: always-on allowed", AlwaysOnEligibility.decide(route: .headphones, echoCancellationEnabled: false), .allowed(canInterruptBySpeaking: true))
equal("speakers with echo cancellation: allowed", AlwaysOnEligibility.decide(route: .speakers, echoCancellationEnabled: true), .allowed(canInterruptBySpeaking: true))
equal("speakers without it: needs headphones", AlwaysOnEligibility.decide(route: .speakers, echoCancellationEnabled: false), .needsHeadphones)
expect("on speakers, speech outside the cancelled engine can't be interrupted by voice",
       !BargeInPolicy.voiceMayInterrupt(route: .speakers, echoCancellationEnabled: true, speechIsOnCancelledEngine: false))
expect("on speakers, speech through the cancelled engine can",
       BargeInPolicy.voiceMayInterrupt(route: .speakers, echoCancellationEnabled: true, speechIsOnCancelledEngine: true))
expect("on headphones, any speech can",
       BargeInPolicy.voiceMayInterrupt(route: .headphones, echoCancellationEnabled: false, speechIsOnCancelledEngine: false))

let justSaid = ["Open the File menu and choose Export.", "Then pick PDF from the list."]
expect("Teachy's own sentence coming back is an echo", EchoTextGuard.isLikelyEcho(transcript: "open the file menu and choose export", recentlySpoken: justSaid))
expect("part of it is too", EchoTextGuard.isLikelyEcho(transcript: "then pick PDF from the list", recentlySpoken: justSaid))
expect("a real interruption is not", !EchoTextGuard.isLikelyEcho(transcript: "no wait, I meant the other window", recentlySpoken: justSaid))
expect("one or two words are never called an echo", !EchoTextGuard.isLikelyEcho(transcript: "export", recentlySpoken: justSaid))
expect("nothing spoken, nothing to echo", !EchoTextGuard.isLikelyEcho(transcript: "open the file menu", recentlySpoken: []))

print("— calls —")
func inCall(_ others: [String]?, inUse: Bool = true, recording: Bool = false, running: [String] = [], previous: Bool = false) -> Bool {
    CallDecision.isInCall(otherBundleIDsUsingMicrophone: others, inputDeviceInUse: inUse, teachyIsRecording: recording, runningBundleIDs: running, previous: previous)
}
expect("Zoom with the microphone is a call", inCall(["us.zoom.xos"]))
expect("FaceTime is a call", inCall(["com.apple.FaceTime"]))
expect("the new Teams is a call", inCall(["com.microsoft.teams2"]))
expect("a browser with the microphone is a call (Meet)", inCall(["com.google.Chrome.helper"]))
expect("Safari's audio process is a call", inCall(["com.apple.WebKit.GPU"]))
expect("nobody else on the microphone is not a call", !inCall([]))
expect("QuickTime recording is not a call", !inCall(["com.apple.QuickTimePlayerX"]))
expect("Voice Memos is not a call", !inCall(["com.apple.VoiceMemos"]))
expect("Siri listening is not a call", !inCall(["com.apple.corespeechd"]))
expect("an app nobody knows is not a call", !inCall(["com.example.mystery"]))
expect("a recorder and Zoom together is a call", inCall(["com.obsproject.obs-studio", "us.zoom.xos"]))
expect("Zoom merely running, off the microphone, is not a call", !inCall([], running: ["us.zoom.xos"]))
expect("Teachy's own recording is never a call", !inCall([], recording: true))
// Older macOS: only "the input device is in use" is known.
expect("device signal: in use and Zoom running is a call", inCall(nil, inUse: true, running: ["us.zoom.xos", "com.apple.finder"]))
expect("device signal: in use but no call app running is not", !inCall(nil, inUse: true, running: ["com.apple.finder"]))
expect("device signal: a browser alone is not enough", !inCall(nil, inUse: true, running: ["com.google.Chrome"]))
expect("device signal: not in use is not a call", !inCall(nil, inUse: false, running: ["us.zoom.xos"]))
expect("device signal: while Teachy records, the last answer is kept (true)", inCall(nil, inUse: true, recording: true, running: [], previous: true))
expect("device signal: while Teachy records, the last answer is kept (false)", !inCall(nil, inUse: true, recording: true, running: ["us.zoom.xos"], previous: false))
equal("kind of a call app", CallDecision.kind(ofBundleID: "com.hnc.Discord"), .call)
equal("kind of a recorder", CallDecision.kind(ofBundleID: "com.apple.garageband10"), .notACall)
equal("kind of anything else", CallDecision.kind(ofBundleID: "com.apple.Notes"), .unknown)

print("— muted Mac, and whether to speak —")
expect("muted is silent", OutputLoudness.isSilent(isMuted: true, volume: 0.5))
expect("volume at zero is silent", OutputLoudness.isSilent(isMuted: false, volume: 0))
expect("normal volume is not", !OutputLoudness.isSilent(isMuted: false, volume: 0.4))
expect("no volume control at all is not silent", !OutputLoudness.isSilent(isMuted: nil, volume: nil))
equal("normally: speak", SpokenOutputDecision.decide(outputIsSilent: false, isInCall: false, quietOnCallsEnabled: true, talkKeyPressedForThisReply: false), .speak)
equal("muted: captions and clipboard", SpokenOutputDecision.decide(outputIsSilent: true, isInCall: false, quietOnCallsEnabled: true, talkKeyPressedForThisReply: false), .captionsAndClipboard(reason: .macIsMuted))
equal("muted, even with the talk key", SpokenOutputDecision.decide(outputIsSilent: true, isInCall: false, quietOnCallsEnabled: true, talkKeyPressedForThisReply: true), .captionsAndClipboard(reason: .macIsMuted))
equal("on a call: captions and clipboard", SpokenOutputDecision.decide(outputIsSilent: false, isInCall: true, quietOnCallsEnabled: true, talkKeyPressedForThisReply: false), .captionsAndClipboard(reason: .onACall))
equal("on a call with the talk key held: speak", SpokenOutputDecision.decide(outputIsSilent: false, isInCall: true, quietOnCallsEnabled: true, talkKeyPressedForThisReply: true), .speak)
equal("on a call with the setting off: speak", SpokenOutputDecision.decide(outputIsSilent: false, isInCall: true, quietOnCallsEnabled: false, talkKeyPressedForThisReply: false), .speak)
let shortCaption = SpokenOutputDecision.captionSeconds(for: "Sure.", speed: 1)
let longCaption = SpokenOutputDecision.captionSeconds(for: "Open the File menu, choose Export, then pick PDF from the list at the bottom.", speed: 1)
expect("a one-word caption still stays up over a second (\(shortCaption))", shortCaption >= 1.2)
expect("a longer caption stays up longer (\(longCaption))", longCaption > 3 && longCaption < 8)
expect("a faster voice shortens it", SpokenOutputDecision.captionSeconds(for: "Open the File menu, choose Export, then pick PDF from the list.", speed: 1.5) < SpokenOutputDecision.captionSeconds(for: "Open the File menu, choose Export, then pick PDF from the list.", speed: 0.7))
expect("text with no spaces is timed by its length", SpokenOutputDecision.captionSeconds(for: "ファイルメニューを開いて、名前を付けて保存を選んでください。", speed: 1) > 1.5)

print("— microphone health and failover —")
do {
    var monitor = MicrophoneHealthMonitor()
    var verdict = MicrophoneHealthMonitor.Verdict.healthy
    for _ in 0..<20 { verdict = monitor.process(peak: 0.0004, frameCount: 4800, sampleRate: 48_000) }
    equal("a very quiet room is a healthy microphone", verdict, .healthy)
    for _ in 0..<20 { verdict = monitor.process(peak: 0, frameCount: 4800, sampleRate: 48_000) }
    equal("two seconds of exact zeros is not yet dead", verdict, .healthy)
    for _ in 0..<6 { verdict = monitor.process(peak: 0, frameCount: 4800, sampleRate: 48_000) }
    equal("past 2.5 s of exact zeros it is", verdict, .silent)
    equal("sound brings it back", monitor.process(peak: 0.01, frameCount: 4800, sampleRate: 48_000), .healthy)
    equal("a zero sample rate is a dead format", monitor.process(peak: 0.1, frameCount: 512, sampleRate: 0), .zeroFormat)
    expect("48 kHz mono is usable", MicrophoneHealthMonitor.isUsableFormat(sampleRate: 48_000, channelCount: 1))
    expect("no channels is not", !MicrophoneHealthMonitor.isUsableFormat(sampleRate: 48_000, channelCount: 0))
}
let builtInMic = MicrophoneDevice(deviceID: 1, uid: "builtin", name: "MacBook Pro Microphone", transportType: AudioFourCC.builtIn)
let usbMic = MicrophoneDevice(deviceID: 2, uid: "usb", name: "Yeti", transportType: AudioFourCC.usb)
let airPodsMic = MicrophoneDevice(deviceID: 3, uid: "airpods", name: "AirPods Pro", transportType: AudioFourCC.bluetooth)
func order(selected: String?, devices: [MicrophoneDevice], system: MicrophoneDevice?, failed: Set<String> = []) -> [String] {
    MicrophoneCenter.failoverCandidates(selectedUID: selected, devices: devices, systemDefault: system, excluding: failed).map(\.uid)
}
equal("the pick, then the Mac's input, then built-in, then the rest",
      order(selected: "usb", devices: [airPodsMic, builtInMic, usbMic], system: airPodsMic), ["usb", "airpods", "builtin"])
equal("no pick: the Mac's input first, built-in next", order(selected: nil, devices: [airPodsMic, usbMic, builtInMic], system: airPodsMic), ["airpods", "builtin", "usb"])
equal("the pick is unplugged: start from the Mac's input", order(selected: "gone", devices: [builtInMic, usbMic], system: usbMic), ["usb", "builtin"])
equal("the pick went silent: skip it", order(selected: "airpods", devices: [airPodsMic, builtInMic, usbMic], system: airPodsMic, failed: ["airpods"]), ["builtin", "usb"])
equal("the pick and the Mac's input both failed: any other input", order(selected: "airpods", devices: [airPodsMic, builtInMic, usbMic], system: builtInMic, failed: ["airpods", "builtin"]), ["usb"])
equal("everything failed: nothing", order(selected: nil, devices: [builtInMic], system: builtInMic, failed: ["builtin"]), [])
equal("a default that is no longer in the list is not offered", order(selected: nil, devices: [builtInMic], system: usbMic), ["builtin"])
expect("AirPods are a Bluetooth microphone", airPodsMic.isBluetooth && !builtInMic.isBluetooth && !usbMic.isBluetooth)
expect("the Bluetooth warning says what to do instead", MicrophoneCenter.bluetoothWarning.contains("wired or built-in"))
equal("a Bluetooth mic, not yet warm: open the idle engine", PushToTalkWarmupPlan.decide(activeMicrophoneIsBluetooth: true, isAlreadyWarm: false, keepWarmSeconds: 20), .startWarmEngine)
equal("already warm: nothing to do", PushToTalkWarmupPlan.decide(activeMicrophoneIsBluetooth: true, isAlreadyWarm: true, keepWarmSeconds: 20), .nothing)
equal("a wired mic never needs it", PushToTalkWarmupPlan.decide(activeMicrophoneIsBluetooth: false, isAlreadyWarm: false, keepWarmSeconds: 20), .nothing)
equal("keep-warm set to 0 switches it off", PushToTalkWarmupPlan.decide(activeMicrophoneIsBluetooth: true, isAlreadyWarm: false, keepWarmSeconds: 0), .nothing)
equal("pre-roll is what was said since just before the key went down",
      PushToTalkWarmupPlan.preRollIndexes(bufferTimes: [9.0, 9.5, 9.95, 10.05, 10.15, 10.25], keyDownAt: 10.0), [2, 3, 4, 5])
equal("pre-roll is never more than 1.5 s", PushToTalkWarmupPlan.preRollIndexes(bufferTimes: [10.0, 10.5, 11.0, 11.5, 12.0], keyDownAt: 10.0), [1, 2, 3, 4])
equal("no buffers, no pre-roll", PushToTalkWarmupPlan.preRollIndexes(bufferTimes: [], keyDownAt: 10.0), [])

print("— which transcript —")
equal("no on-device recogniser: ask publik", TranscriptChoice.decide(onDeviceAvailable: false, onDeviceText: nil, onDeviceConfidence: nil), .askPublik)
equal("a confident on-device transcript is used", TranscriptChoice.decide(onDeviceAvailable: true, onDeviceText: "what is this button", onDeviceConfidence: 0.9), .useOnDevice)
equal("an unsure one goes to publik", TranscriptChoice.decide(onDeviceAvailable: true, onDeviceText: "what his this but on", onDeviceConfidence: 0.3), .askPublik)
equal("on-device failed or timed out: ask publik", TranscriptChoice.decide(onDeviceAvailable: true, onDeviceText: nil, onDeviceConfidence: nil), .askPublik)
equal("on-device heard no words: nothing was said", TranscriptChoice.decide(onDeviceAvailable: true, onDeviceText: "  ", onDeviceConfidence: nil), .nothingSaid)
equal("no confidence reported: trust the words", TranscriptChoice.decide(onDeviceAvailable: true, onDeviceText: "open safari", onDeviceConfidence: nil), .useOnDevice)

print("— switching itself off —")
expect("four quiet minutes: stays on", !AlwaysOnIdlePolicy.shouldTurnOff(secondsSinceLastSpeech: 4 * 60, minutes: 5))
expect("five quiet minutes: off", AlwaysOnIdlePolicy.shouldTurnOff(secondsSinceLastSpeech: 5 * 60, minutes: 5))
expect("the limit can be changed", AlwaysOnIdlePolicy.shouldTurnOff(secondsSinceLastSpeech: 61, minutes: 1))
equal("a silly limit is clamped", AlwaysOnIdlePolicy.normalizedMinutes(0), 1)
equal("the default is five minutes", AlwaysOnIdlePolicy.defaultMinutes, 5)
equal("pill label while paused", AlwaysOnState.pausedForCall.label, "Paused for your call")
equal("pill label when it can't run", AlwaysOnState.unavailable("No working microphone").label, "No working microphone")

print("— languages —")
let languages = TeachyReplyLanguages.all
expect("at least 40 languages (\(languages.count))", languages.count >= 40)
equal("codes are unique", Set(languages.map(\.code)).count, languages.count)
expect("every language has an English and a native name", languages.allSatisfy { !$0.englishName.isEmpty && !$0.nativeName.isEmpty })
expect("every locale belongs to its language and names a region", languages.allSatisfy {
    let locale = Locale(identifier: $0.localeIdentifier)
    return locale.language.languageCode?.identifier == $0.code && locale.region != nil
})
equal("native name: Hindi", TeachyReplyLanguages.language(for: "hi")?.nativeName, "हिन्दी")
equal("native name: Japanese", TeachyReplyLanguages.language(for: "ja")?.nativeName, "日本語")
equal("picker label", TeachyReplyLanguages.language(for: "es")?.pickerLabel, "Español (Spanish)")
equal("English is not shown twice", TeachyReplyLanguages.language(for: "en")?.pickerLabel, "English")
equal("auto is not a language", TeachyReplyLanguages.language(for: "auto")?.code, nil)
equal("an unknown code becomes auto", TeachyReplyLanguages.normalized("xx"), "auto")
equal("codes are case-insensitive", TeachyReplyLanguages.normalized(" ES "), "es")
expect("auto prompt: match what they spoke", TeachyReplyLanguages.promptSentence(for: "auto").contains("language they just spoke"))
expect("fixed prompt names the language both ways", TeachyReplyLanguages.promptSentence(for: "de").contains("German (Deutsch)"))
expect("the prompt keeps the tags in English", TeachyReplyLanguages.promptSentence(for: "de").contains("[POINT:]"))
equal("recogniser locale: fixed reply language wins", TeachyReplyLanguages.recognizerLocaleIdentifier(replyLanguage: "fr", dictationLanguage: "en"), "fr-FR")
equal("recogniser locale: auto uses the dictation language", TeachyReplyLanguages.recognizerLocaleIdentifier(replyLanguage: "auto", dictationLanguage: "hi"), "hi-IN")
equal("recogniser locale: auto and no dictation language is the Mac's own", TeachyReplyLanguages.recognizerLocaleIdentifier(replyLanguage: "auto", dictationLanguage: nil), nil)
equal("transcription code: fixed", TeachyReplyLanguages.transcriptionLanguageCode(replyLanguage: "ja", dictationLanguage: nil), "ja")
equal("transcription code: auto detects", TeachyReplyLanguages.transcriptionLanguageCode(replyLanguage: "auto", dictationLanguage: nil), nil)
do {
    let suite = "teachy-voice2-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    equal("reply language defaults to auto", TeachySettingsStorage.replyLanguage(defaults), "auto")
    equal("always-on auto-off defaults to 5 minutes", TeachySettingsStorage.alwaysOnAutoOffMinutes(defaults), 5)
    expect("quiet on calls defaults to on", TeachySettingsStorage.quietOnCallsEnabled(defaults))
    defaults.set("pt", forKey: TeachySettingsKey.replyLanguage)
    equal("a saved reply language is read back", TeachySettingsStorage.replyLanguage(defaults), "pt")
    defaults.set(500, forKey: TeachySettingsKey.alwaysOnAutoOffMinutes)
    equal("a silly auto-off value is clamped", TeachySettingsStorage.alwaysOnAutoOffMinutes(defaults), 60)
    defaults.removePersistentDomain(forName: suite)
}

print("— voices —")
equal("30 voices in all", TeachyVoiceCatalog.allVoices.count, 30)
equal("no voice twice", Set(TeachyVoiceCatalog.allVoices.map(\.name)).count, 30)
equal("the first eight are unchanged", TeachyVoiceCatalog.voices.map(\.name), ["Puck", "Aoede", "Kore", "Leda", "Zephyr", "Charon", "Fenrir", "Orus"])
equal("a newly added voice is accepted", TeachyVoiceCatalog.resolved("sulafat"), "Sulafat")
expect("every voice has a character", TeachyVoiceCatalog.allVoices.allSatisfy { !$0.character.isEmpty })

print("— realtime pace —")
for speed in stride(from: 0.5, through: 1.5, by: 0.05) {
    let plan = RealtimeVoicePace.plan(forSpeed: speed)
    let achieved = plan.instructedRate * Double(plan.playbackRate)
    if abs(achieved - speed) > 0.012 { expect("speed \(speed) is reached (got \(achieved))", false) }
    if plan.playbackRate < 0.7 || plan.playbackRate > 1.3 { expect("speed \(speed) keeps the stretch gentle (got \(plan.playbackRate))", false) }
}
print("ok   every speed from 0.5 to 1.5 is reached to within 0.012, with a stretch between 0.7 and 1.3")
equal("slow speeds use the slow wording", RealtimeVoicePace.plan(forSpeed: 0.7).instruction, RealtimeVoicePace.slowInstruction)
equal("normal speeds use the natural wording", RealtimeVoicePace.plan(forSpeed: 1.0).instruction, RealtimeVoicePace.naturalInstruction)
equal("1.2 still uses the natural wording", RealtimeVoicePace.plan(forSpeed: 1.2).instruction, RealtimeVoicePace.naturalInstruction)
equal("fast speeds use the fast wording", RealtimeVoicePace.plan(forSpeed: 1.4).instruction, RealtimeVoicePace.fastInstruction)
equal("at 1.0 nothing is stretched", RealtimeVoicePace.plan(forSpeed: 1.0).playbackRate, 1.0)
expect("at 1.0 the stretch is bypassed", !RealtimeVoicePace.plan(forSpeed: 1.0).needsTimeStretch)
expect("at 0.85 it is not", RealtimeVoicePace.plan(forSpeed: 0.85).needsTimeStretch)
equal("out-of-range speeds are clamped", RealtimeVoicePace.plan(forSpeed: 9), RealtimeVoicePace.plan(forSpeed: 1.5))
equal("NaN is treated as normal", RealtimeVoicePace.plan(forSpeed: .nan), RealtimeVoicePace.plan(forSpeed: 1.0))
let spanishReader = RealtimeReaderInstructions.build(languageCode: "es", speed: 1.0)
expect("reader instructions name a fixed language", spanishReader.contains("Read it in Spanish with a native Spanish accent"))
expect("and forbid translating", spanishReader.contains("Never translate"))
expect("and still say word for word", spanishReader.contains("exactly, word for word"))
expect("and end with the pace", spanishReader.hasSuffix(RealtimeVoicePace.naturalInstruction))
expect("auto reads the language the text is written in", RealtimeReaderInstructions.build(languageCode: "auto", speed: 1.0).contains("in the language it is written in"))

print("— screen memory —")
let pullRequests = ScreenSnapshot(frontApp: "Safari", windowTitle: "Pull requests · teachy", browserURL: "https://www.github.com/VedSoni-dev/teachy/pulls?q=is%3Aopen&token=secret#top", text: nil)
equal("app, title, host and path", ScreenMemorySummary.line(for: pullRequests), "Safari: \"Pull requests · teachy\" (github.com/VedSoni-dev/teachy/pulls)")
expect("the query string never gets written down", !(ScreenMemorySummary.line(for: pullRequests) ?? "").contains("secret"))
equal("an app with only a title", ScreenMemorySummary.line(for: ScreenSnapshot(frontApp: "Xcode", windowTitle: "teachy — VoicePolicy.swift", browserURL: nil, text: nil)), "Xcode: \"teachy — VoicePolicy.swift\"")
equal("an app with nothing to say is skipped", ScreenMemorySummary.line(for: ScreenSnapshot(frontApp: "Finder", windowTitle: "", browserURL: nil, text: nil)), nil)
equal("a title that only repeats the app is not repeated", ScreenMemorySummary.line(for: ScreenSnapshot(frontApp: "Notes", windowTitle: "Notes", browserURL: "https://example.com/a", text: nil)), "Notes (example.com/a)")
let withText = ScreenMemorySummary.line(for: ScreenSnapshot(frontApp: "Preview", windowTitle: "lease.pdf", browserURL: nil, text: String(repeating: "The tenant agrees to pay rent monthly. ", count: 20))) ?? ""
expect("visible text is added, cut at about 200 characters (\(withText.count))", withText.hasPrefix("Preview: \"lease.pdf\". The tenant agrees") && withText.count < 240 && withText.hasSuffix("…"))
equal("a password manager is never written", ScreenMemorySummary.line(for: ScreenSnapshot(frontApp: "1Password", windowTitle: "Bank login", browserURL: nil, text: nil)), nil)
equal("a private browser window is never written", ScreenMemorySummary.line(for: ScreenSnapshot(frontApp: "Safari", windowTitle: "Private Browsing — Gift ideas", browserURL: "https://shop.example.com", text: nil)), nil)
equal("the address is found inside the tab description", ScreenMemorySummary.firstURL(in: "Safari tab: \"GitHub\" — https://github.com/VedSoni-dev/teachy"), "https://github.com/VedSoni-dev/teachy")
equal("no address, no page", ScreenMemorySummary.hostAndPath(of: nil), nil)
do {
    var log = ScreenMemoryLog()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    expect("a new screen is written", log.lineToRecord(for: pullRequests, at: start) != nil)
    expect("the same screen on the next turn is not", log.lineToRecord(for: pullRequests, at: start.addingTimeInterval(20)) == nil)
    var scrolled = pullRequests
    scrolled.text = "Different words are visible now"
    scrolled.browserURL = "https://github.com/VedSoni-dev/teachy/pulls?page=2"
    expect("the same page scrolled, or with another query, is still the same screen", log.lineToRecord(for: scrolled, at: start.addingTimeInterval(40)) == nil)
    let other = ScreenSnapshot(frontApp: "Safari", windowTitle: "Issues · teachy", browserURL: "https://github.com/VedSoni-dev/teachy/issues", text: nil)
    expect("another page is written", log.lineToRecord(for: other, at: start.addingTimeInterval(60)) != nil)
    expect("going back to the first page is written again (not consecutive)", log.lineToRecord(for: pullRequests, at: start.addingTimeInterval(80)) != nil)
    expect("staying there for half an hour writes it once more", log.lineToRecord(for: pullRequests, at: start.addingTimeInterval(80 + 31 * 60)) != nil)

    var busy = ScreenMemoryLog()
    var written = 0
    for index in 0..<50 {
        let snapshot = ScreenSnapshot(frontApp: "Safari", windowTitle: "Page \(index)", browserURL: "https://example.com/\(index)", text: nil)
        if busy.lineToRecord(for: snapshot, at: start.addingTimeInterval(Double(index) * 10)) != nil { written += 1 }
    }
    equal("at most 20 notes in an hour, however often it is called", written, 20)
    let muchLater = ScreenSnapshot(frontApp: "Safari", windowTitle: "Later", browserURL: "https://example.com/later", text: nil)
    expect("and writing resumes the next hour", busy.lineToRecord(for: muchLater, at: start.addingTimeInterval(2 * 3600)) != nil)
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
