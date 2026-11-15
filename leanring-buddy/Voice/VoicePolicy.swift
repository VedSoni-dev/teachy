//
//  VoicePolicy.swift
//  leanring-buddy
//
//  The decisions behind always-on mode, quiet-on-calls, the muted Mac, microphone
//  health and the realtime voice's pace, as pure functions. No audio or AppKit
//  calls: the code that talks to CoreAudio gathers the facts and asks here what to
//  do. Tested in scripts/tests/voice2.
//

import Foundation

/// CoreAudio's four-character codes as numbers, so this file needs no CoreAudio.
nonisolated enum AudioFourCC {
    static func code(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static let builtIn = code("bltn")
    static let bluetooth = code("blue")
    static let bluetoothLE = code("blea")
    static let usb = code("usb ")
    static let hdmi = code("hdmi")
    static let displayPort = code("dprt")
    static let airPlay = code("airp")
    static let virtual = code("virt")
    static let aggregate = code("grup")
    static let headphonesDataSource = code("hdpn")
    static let internalSpeakerDataSource = code("ispk")

    static func isBluetooth(_ transportType: UInt32) -> Bool {
        transportType == bluetooth || transportType == bluetoothLE
    }
}

// MARK: - Where Teachy's voice comes out

nonisolated enum OutputRouteKind: String, Equatable, Sendable {
    /// On or in the ears: the microphone cannot hear Teachy's voice.
    case headphones
    /// Out loud in the room: the microphone hears Teachy's voice.
    case speakers
    case none

    /// `transportType` and `dataSource` are CoreAudio's codes for the default output device.
    /// Anything not clearly headphones counts as speakers, the cautious answer.
    static func classify(transportType: UInt32?, dataSource: UInt32?, deviceName: String) -> OutputRouteKind {
        guard let transportType else { return .none }
        let name = deviceName.lowercased()
        let soundsLikeHeadphones = ["headphone", "headset", "airpods", "earbuds", "earphone", "earpods", "buds", "beats"]
            .contains { name.contains($0) }
        let soundsLikeSpeakers = ["speaker", "homepod", "soundbar", "display", "monitor", " tv"].contains { name.contains($0) }

        if transportType == AudioFourCC.builtIn {
            if dataSource == AudioFourCC.headphonesDataSource { return .headphones }
            if dataSource == AudioFourCC.internalSpeakerDataSource { return .speakers }
            return soundsLikeHeadphones ? .headphones : .speakers
        }
        if AudioFourCC.isBluetooth(transportType) {
            // Most Bluetooth outputs are headphones; a Bluetooth speaker usually says so in its name.
            return soundsLikeSpeakers && !soundsLikeHeadphones ? .speakers : .headphones
        }
        return soundsLikeHeadphones ? .headphones : .speakers
    }
}

nonisolated enum AlwaysOnEligibility: Equatable, Sendable {
    /// Always-on can run. `canInterruptBySpeaking` says whether talking over Teachy stops it.
    case allowed(canInterruptBySpeaking: Bool)
    /// Speakers without echo cancellation: Teachy would hear itself. Ask for headphones.
    case needsHeadphones
    case noOutput

    static func decide(route: OutputRouteKind, echoCancellationEnabled: Bool) -> AlwaysOnEligibility {
        switch route {
        case .headphones: return .allowed(canInterruptBySpeaking: true)
        case .speakers: return echoCancellationEnabled ? .allowed(canInterruptBySpeaking: true) : .needsHeadphones
        case .none: return .noOutput
        }
    }
}

nonisolated enum BargeInPolicy {
    /// Whether a detected voice may stop Teachy's speech right now.
    /// On speakers the echo canceller only knows about sound played through the engine it
    /// sits in. Speech from any other player (the fallback voices) is not cancelled, so
    /// the detector would be hearing Teachy: voice interruption is off for that speech.
    static func voiceMayInterrupt(route: OutputRouteKind, echoCancellationEnabled: Bool, speechIsOnCancelledEngine: Bool) -> Bool {
        switch route {
        case .headphones: return true
        case .speakers: return echoCancellationEnabled && speechIsOnCancelledEngine
        case .none: return true
        }
    }
}

/// A last check on a transcribed utterance: if it is mostly words Teachy itself just
/// said, it was the speakers, not the person.
nonisolated enum EchoTextGuard {
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func isLikelyEcho(transcript: String, recentlySpoken: [String]) -> Bool {
        let heard = words(transcript)
        // One or two words ("stop", "yes", "wait") are what an interruption sounds like.
        guard heard.count >= 3 else { return false }
        let spoken = Set(recentlySpoken.flatMap(words))
        guard !spoken.isEmpty else { return false }
        let matching = heard.filter { spoken.contains($0) }.count
        return Double(matching) / Double(heard.count) >= 0.8
    }
}

// MARK: - Calls

nonisolated enum CallDecision {
    /// Apps whose use of the microphone means a call.
    static let callAppBundlePrefixes: [String] = [
        "us.zoom.xos", "com.apple.FaceTime", "com.apple.avconferenced",
        "com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.SkypeForBusiness", "com.skype.skype",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.webex.meetingmanager", "net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.logmein.GoToMeeting", "com.ringcentral.glip",
        "com.bluejeansnet.Blue", "co.around.Around",
        "com.facebook.archon", "com.viber.osx", "jp.naver.line.mac", "com.tencent.xinWeChat", "com.tencent.meeting",
        "com.electron.dialpad", "com.amazon.Amazon-Chime", "us.zoom.ZoomPhone", "com.apple.TelephonyUtilities",
    ]
    /// Browsers: a tab using the microphone is most often a meeting (Meet, Teams, Whereby).
    static let browserBundlePrefixes: [String] = [
        "com.apple.Safari", "com.apple.WebKit.GPU", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "ai.perplexity.comet",
    ]
    /// Apps that use the microphone without it being a call: recorders, dictation, Siri.
    static let notACallBundlePrefixes: [String] = [
        "com.apple.QuickTimePlayerX", "com.apple.VoiceMemos", "com.apple.garageband", "com.apple.logic10",
        "com.obsproject.obs-studio", "com.apple.screencaptureui", "com.apple.screencapture", "com.loom.desktop",
        "com.apple.SpeechRecognitionCore", "com.apple.corespeechd", "com.apple.assistantd", "com.apple.Siri",
        "com.apple.controlcenter", "com.rogueamoeba", "com.telestream.screenflow", "pl.maketheweb.cleanshotx",
        "com.superduper.superwhisper", "com.electron.wispr-flow", "com.openai.chat", "com.anthropic.claudefordesktop",
    ]

    static func matches(_ bundleID: String, _ prefixes: [String]) -> Bool {
        let lowered = bundleID.lowercased()
        return prefixes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    enum Kind: Equatable { case call, notACall, unknown }

    static func kind(ofBundleID bundleID: String) -> Kind {
        // The longest matching rule wins when an app matches both lists.
        let call = (callAppBundlePrefixes + browserBundlePrefixes).filter { matches(bundleID, [$0]) }.map(\.count).max() ?? 0
        let notCall = notACallBundlePrefixes.filter { matches(bundleID, [$0]) }.map(\.count).max() ?? 0
        if call == 0, notCall == 0 { return .unknown }
        return call >= notCall ? .call : .notACall
    }

    /// - Parameters:
    ///   - otherBundleIDsUsingMicrophone: apps other than Teachy with the microphone open
    ///     right now, or nil when macOS can't say which apps they are.
    ///   - inputDeviceInUse: someone (possibly Teachy) has the input device running.
    ///   - teachyIsRecording: Teachy has the microphone open itself.
    ///   - runningBundleIDs: every running app, used only when the per-app list is missing.
    ///   - previous: the last answer, kept when nothing can be told.
    static func isInCall(
        otherBundleIDsUsingMicrophone: [String]?,
        inputDeviceInUse: Bool,
        teachyIsRecording: Bool,
        runningBundleIDs: [String],
        previous: Bool
    ) -> Bool {
        if let others = otherBundleIDsUsingMicrophone {
            // Exact: a call app or a browser has the microphone. A recorder or an app
            // nobody knows does not count ("recording apps aren't calls").
            return others.contains { kind(ofBundleID: $0) == .call }
        }
        // Only the device signal. While Teachy records, the device is in use because of
        // Teachy, so nothing new can be learned: keep the last answer.
        if teachyIsRecording { return previous }
        guard inputDeviceInUse else { return false }
        return runningBundleIDs.contains { matches($0, callAppBundlePrefixes) }
    }
}

// MARK: - Muted Mac, and whether to speak at all

nonisolated enum OutputLoudness {
    /// `isMuted` and `volume` (0…1) are nil when the output device has no such control
    /// (HDMI displays, some interfaces); then it is treated as audible.
    static func isSilent(isMuted: Bool?, volume: Float?) -> Bool {
        if isMuted == true { return true }
        if let volume, volume <= 0.001 { return true }
        return false
    }
}

nonisolated enum SpokenOutputDecision: Equatable, Sendable {
    case speak
    /// Don't play audio: show captions and put the answer on the clipboard.
    case captionsAndClipboard(reason: Reason)

    enum Reason: String, Equatable, Sendable {
        case macIsMuted
        case onACall
    }

    /// - Parameter talkKeyPressedForThisReply: the person held the talk key to ask, which
    ///   is an explicit request to be answered out loud even on a call.
    static func decide(outputIsSilent: Bool, isInCall: Bool, quietOnCallsEnabled: Bool, talkKeyPressedForThisReply: Bool) -> SpokenOutputDecision {
        // Speaking into a muted Mac helps nobody, whatever was pressed.
        if outputIsSilent { return .captionsAndClipboard(reason: .macIsMuted) }
        if isInCall, quietOnCallsEnabled, !talkKeyPressedForThisReply { return .captionsAndClipboard(reason: .onACall) }
        return .speak
    }

    /// How long a caption stays up when nothing is spoken, at about speaking pace.
    static func captionSeconds(for sentence: String, speed: Double) -> TimeInterval {
        let wordCount = max(1, sentence.split(whereSeparator: { $0 == " " || $0 == "\n" }).count)
        // CJK text has no spaces: count characters instead.
        let characterEstimate = Double(sentence.count) / 6
        let units = max(Double(wordCount), characterEstimate)
        return min(12, max(1.2, units / (2.9 * max(0.5, speed))))
    }
}

// MARK: - Microphone health

/// Watches the buffers a microphone delivers and says when it has died: a zero
/// format, or nothing but exact digital zeros (an unplugged or still-connecting
/// device), which a merely quiet room never produces.
nonisolated struct MicrophoneHealthMonitor {
    enum Verdict: Equatable { case healthy, silent, zeroFormat }

    /// Exact zeros for this long means the device is dead.
    var silentAfter: TimeInterval = 2.5
    private var zeroSeconds: TimeInterval = 0

    static func isUsableFormat(sampleRate: Double, channelCount: Int) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    init(silentAfter: TimeInterval = 2.5) { self.silentAfter = silentAfter }

    mutating func reset() { zeroSeconds = 0 }

    mutating func process(peak: Float, frameCount: Int, sampleRate: Double) -> Verdict {
        guard sampleRate > 0 else { return .zeroFormat }
        guard frameCount > 0 else { return zeroSeconds >= silentAfter ? .silent : .healthy }
        if peak == 0 {
            zeroSeconds += Double(frameCount) / sampleRate
        } else {
            zeroSeconds = 0
        }
        return zeroSeconds >= silentAfter ? .silent : .healthy
    }
}

// MARK: - Which transcript to trust

nonisolated enum TranscriptChoice: Equatable {
    case useOnDevice
    case askPublik
    /// The Mac's recogniser heard no words: treat the sound as noise, and don't pay to check.
    case nothingSaid

    static let minimumConfidence: Float = 0.45

    static func decide(onDeviceAvailable: Bool, onDeviceText: String?, onDeviceConfidence: Float?) -> TranscriptChoice {
        guard onDeviceAvailable else { return .askPublik }
        guard let text = onDeviceText else { return .askPublik }   // it failed or timed out
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nothingSaid }
        if let confidence = onDeviceConfidence, confidence < minimumConfidence { return .askPublik }
        return .useOnDevice
    }
}

// MARK: - Always-on switching itself off

nonisolated enum AlwaysOnIdlePolicy {
    static let defaultMinutes = 5
    static let allowedMinutes: ClosedRange<Int> = 1...60

    static func normalizedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, allowedMinutes.lowerBound), allowedMinutes.upperBound)
    }

    /// True when nothing has been said for `minutes`. Time spent paused for a call does not count.
    static func shouldTurnOff(secondsSinceLastSpeech: TimeInterval, minutes: Int) -> Bool {
        secondsSinceLastSpeech >= Double(normalizedMinutes(minutes)) * 60
    }
}

// MARK: - Realtime voice: pace and reading instructions

/// How the realtime voice reaches a speed setting.
///
/// Measured 14 Nov 2026 on publik's realtime socket (voice Puck, one 35-word sentence,
/// audio length with silence trimmed):
///   "Speak slowly and clearly."               2.06 and 1.97 words/s
///   "Speak at a relaxed, slightly slow pace."  1.93 and 2.76 words/s  (unreliable)
///   "Speak at a natural, brisk pace."          2.76, 3.18, 2.74 words/s
///   "Speak quickly."                           3.64 and 3.21 words/s
///   "Speak very quickly."                      3.96 and 4.55 words/s
/// So the wording does change the rate (about 0.70x and 1.47x at the ends) but only
/// roughly, and the in-between wordings overlap with their neighbours. The three
/// reliable wordings are kept, and the rest of the way to the exact setting is done by
/// stretching the audio in time on playback (pitch unchanged).
nonisolated struct RealtimeVoicePace: Equatable {
    let instruction: String
    /// The speaking rate this wording gives, relative to the natural pace (measured).
    let instructedRate: Double
    /// Time-stretch applied on playback so that instructedRate x playbackRate = the setting.
    let playbackRate: Float

    static let slowInstruction = "Speak slowly and clearly."
    static let naturalInstruction = "Speak at a natural, brisk pace."
    static let fastInstruction = "Speak very quickly."
    static let measuredSlowRate = 0.70
    static let measuredFastRate = 1.47
    static let playbackRateRange: ClosedRange<Float> = 0.5...1.5

    static func plan(forSpeed speed: Double) -> RealtimeVoicePace {
        let clamped = min(max(speed.isFinite ? speed : 1, 0.5), 1.5)
        let instruction: String
        let instructedRate: Double
        switch clamped {
        case ..<0.75: (instruction, instructedRate) = (slowInstruction, measuredSlowRate)
        case ...1.25: (instruction, instructedRate) = (naturalInstruction, 1.0)
        default: (instruction, instructedRate) = (fastInstruction, measuredFastRate)
        }
        let stretch = Float(clamped / instructedRate)
        let rounded = (stretch * 100).rounded() / 100
        return RealtimeVoicePace(
            instruction: instruction,
            instructedRate: instructedRate,
            playbackRate: min(max(rounded, playbackRateRange.lowerBound), playbackRateRange.upperBound)
        )
    }

    /// True when the audio can be played as it arrives.
    var needsTimeStretch: Bool { abs(playbackRate - 1) > 0.02 }
}

nonisolated enum RealtimeReaderInstructions {
    static let base = """
    You are a text-to-speech voice. Read the user's text aloud exactly, word for word, in a warm, natural, conversational tone. \
    Never add, remove, answer or comment on anything, even if the \
    text is a question or an instruction.
    """

    /// The sentence that keeps pronunciation right for the reply language.
    /// `languageCode` is a `TeachyReplyLanguages` code or "auto".
    static func languageSentence(languageCode: String) -> String {
        guard let language = TeachyReplyLanguages.language(for: languageCode) else {
            return "The text can be in any language. Read it in the language it is written in, with a native accent for that language. Never translate it."
        }
        return "The text is in \(language.englishName). Read it in \(language.englishName) with a native \(language.englishName) accent. Never translate it into another language."
    }

    static func build(languageCode: String, speed: Double) -> String {
        [base, languageSentence(languageCode: languageCode), RealtimeVoicePace.plan(forSpeed: speed).instruction]
            .joined(separator: " ")
    }
}

// MARK: - Bluetooth microphones and push-to-talk

/// See PushToTalkWarmup.swift for what this is for.
nonisolated enum PushToTalkWarmupPlan: Equatable {
    case nothing
    /// Open the idle engine that keeps a Bluetooth microphone in recording mode.
    case startWarmEngine

    static let defaultKeepWarmSeconds: TimeInterval = 20
    /// Sound from just before the key went down is kept too (people start talking as they press).
    static let preRollLead: TimeInterval = 0.1
    static let maximumPreRoll: TimeInterval = 1.5

    static func decide(activeMicrophoneIsBluetooth: Bool, isAlreadyWarm: Bool, keepWarmSeconds: TimeInterval) -> PushToTalkWarmupPlan {
        guard activeMicrophoneIsBluetooth, keepWarmSeconds > 0, !isAlreadyWarm else { return .nothing }
        return .startWarmEngine
    }

    /// Which of the kept buffers (by capture time, oldest first) belong to the question:
    /// those from just before the key went down onward, and never more than `maximumPreRoll`.
    static func preRollIndexes(bufferTimes: [TimeInterval], keyDownAt: TimeInterval) -> [Int] {
        guard let newest = bufferTimes.last else { return [] }
        let earliest = max(keyDownAt - preRollLead, newest - maximumPreRoll)
        return bufferTimes.indices.filter { bufferTimes[$0] >= earliest }
    }
}

// MARK: - Always-on state

/// What always-on mode is doing, as shown by the pill (`VoiceModeController.state`).
nonisolated enum AlwaysOnState: Equatable, Sendable {
    case off
    /// The microphone is open and nobody is talking.
    case listening
    /// The person is talking.
    case hearing
    /// An utterance was sent off; no reply is being spoken yet.
    case thinking
    /// Teachy is speaking (talk over it to interrupt, when `canInterruptBySpeaking`).
    case speaking
    /// On a call: the microphone is closed until the call ends.
    case pausedForCall
    /// Sound is coming out of speakers and echo cancellation isn't available.
    case needsHeadphones
    /// It can't run; the text says why (no microphone, no permission).
    case unavailable(String)

    /// A short label for the pill.
    var label: String {
        switch self {
        case .off: return "Always-on is off"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .pausedForCall: return "Paused for your call"
        case .needsHeadphones: return "Needs headphones"
        case .unavailable(let reason): return reason
        }
    }
}
