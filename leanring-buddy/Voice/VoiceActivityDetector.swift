//
//  VoiceActivityDetector.swift
//  leanring-buddy
//
//  Finds where speech starts and stops in a live microphone signal, for always-on
//  (hands-free) mode. Pure logic, no audio APIs: tested on synthetic sound in
//  scripts/tests/voice2.
//
//  How it decides:
//  - Loudness is measured in 20 ms frames. The room's noise floor is the level the
//    quietest tenth of the last few seconds sat at, so it follows a fan switching on
//    but is not dragged up by someone talking (speech has gaps between words).
//  - A frame is "loud" when it is well above that floor. Speech starts once loud
//    frames have lasted `minimumSpeechDuration`; a click or a tap on the desk is
//    shorter than that and never starts anything.
//  - Speech ends after `hangover` of quiet, so a breath or a pause for thought in
//    the middle of a sentence does not cut it in two.
//  - While Teachy is talking the bar is higher and the required length longer
//    (`teachyIsSpeaking`), so its own voice leaking from the speakers is less
//    likely to count as the person interrupting.
//

import Foundation

nonisolated struct VoiceActivityDetector {
    struct Configuration: Equatable {
        /// Length of one analysis frame, in seconds.
        var frameDuration: TimeInterval = 0.02
        /// A frame this many dB above the noise floor is loud.
        var startMarginDB: Float = 10
        /// Once speaking, a frame stays loud down to this many dB above the floor.
        var continueMarginDB: Float = 6
        /// Added to both margins while Teachy is talking.
        var teachySpeakingExtraMarginDB: Float = 8
        /// Nothing quieter than this ever counts as speech, however quiet the room.
        var absoluteMinimumDB: Float = -48
        /// While Teachy is talking the absolute bar rises to this.
        var teachySpeakingAbsoluteMinimumDB: Float = -34
        /// Loud frames must last this long before speech has "started".
        var minimumSpeechDuration: TimeInterval = 0.10
        /// The same, while Teachy is talking.
        var teachySpeakingMinimumSpeechDuration: TimeInterval = 0.14
        /// Quiet for this long ends the utterance.
        var hangover: TimeInterval = 0.9
        /// An utterance with less loud sound than this in total is thrown away.
        var minimumUtteranceVoicedDuration: TimeInterval = 0.3
        /// An utterance is cut off at this length whatever happens.
        var maximumUtteranceDuration: TimeInterval = 30
        /// How much history the noise floor looks at.
        var noiseWindow: TimeInterval = 4
        /// The floor is this fraction of the way up the sorted window (0.1 = quietest tenth).
        var noisePercentile: Double = 0.1
        /// Used until enough frames have been heard to measure the room.
        var initialNoiseFloorDB: Float = -55
    }

    enum Event: Equatable {
        /// Speech began. `lookback` is how long ago the first loud frame was, so the
        /// caller knows how much of its pre-roll buffer belongs to the utterance.
        case started(lookback: TimeInterval)
        /// Speech ended. `trailingSilence` is the quiet at the end (the hangover).
        case ended(duration: TimeInterval, voicedDuration: TimeInterval, trailingSilence: TimeInterval)
        /// What started turned out to be too short to be speech (a cough, a door).
        case discarded
    }

    private enum Phase: Equatable {
        case quiet
        /// Loud frames are adding up but speech has not been confirmed.
        case maybe(loudFrames: Int, gapFrames: Int, totalFrames: Int)
        case speaking(totalFrames: Int, voicedFrames: Int, quietFrames: Int)
    }

    var configuration: Configuration
    /// Set while Teachy's voice is coming out of the speakers.
    var teachyIsSpeaking = false

    private var phase: Phase = .quiet
    private var recentLevels: [Float] = []
    private var recentIndex = 0
    private(set) var noiseFloorDB: Float

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.noiseFloorDB = configuration.initialNoiseFloorDB
    }

    var isInSpeech: Bool {
        if case .speaking = phase { return true }
        return false
    }

    /// The level a frame must reach to count as loud right now.
    var currentStartThresholdDB: Float {
        let margin = configuration.startMarginDB + (teachyIsSpeaking ? configuration.teachySpeakingExtraMarginDB : 0)
        let absolute = teachyIsSpeaking ? configuration.teachySpeakingAbsoluteMinimumDB : configuration.absoluteMinimumDB
        return max(noiseFloorDB + margin, absolute)
    }

    private var currentContinueThresholdDB: Float {
        let margin = configuration.continueMarginDB + (teachyIsSpeaking ? configuration.teachySpeakingExtraMarginDB : 0)
        let absolute = (teachyIsSpeaking ? configuration.teachySpeakingAbsoluteMinimumDB : configuration.absoluteMinimumDB) - 4
        return max(noiseFloorDB + margin, absolute)
    }

    mutating func reset() {
        phase = .quiet
        recentLevels.removeAll(keepingCapacity: true)
        recentIndex = 0
        noiseFloorDB = configuration.initialNoiseFloorDB
    }

    /// Forgets a half-heard utterance but keeps what is known about the room.
    mutating func abandonCurrentUtterance() {
        phase = .quiet
    }

    static func decibels(fromRMS rms: Float) -> Float {
        guard rms > 0.000_01 else { return -100 }
        return 20 * log10(rms)
    }

    /// Feed one frame's loudness (RMS of its samples, 0…1). Returns what changed, if anything.
    mutating func process(frameRMS: Float) -> Event? {
        process(frameLevelDB: Self.decibels(fromRMS: frameRMS))
    }

    mutating func process(frameLevelDB level: Float) -> Event? {
        trackNoiseFloor(level)
        let frame = configuration.frameDuration
        func frames(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / frame).rounded())) }

        switch phase {
        case .quiet:
            if level >= currentStartThresholdDB {
                phase = .maybe(loudFrames: 1, gapFrames: 0, totalFrames: 1)
                return confirmStartIfLongEnough()
            }
            return nil

        case .maybe(let loudFrames, let gapFrames, let totalFrames):
            if level >= currentStartThresholdDB {
                phase = .maybe(loudFrames: loudFrames + 1, gapFrames: 0, totalFrames: totalFrames + 1)
                return confirmStartIfLongEnough()
            }
            // One or two quiet frames inside a word are normal; more means it was a click.
            if gapFrames + 1 > 2 {
                phase = .quiet
            } else {
                phase = .maybe(loudFrames: loudFrames, gapFrames: gapFrames + 1, totalFrames: totalFrames + 1)
            }
            return nil

        case .speaking(let totalFrames, let voicedFrames, let quietFrames):
            let isLoud = level >= currentContinueThresholdDB
            let total = totalFrames + 1
            let voiced = voicedFrames + (isLoud ? 1 : 0)
            let quiet = isLoud ? 0 : quietFrames + 1
            let reachedHangover = quiet >= frames(configuration.hangover)
            let reachedMaximum = total >= frames(configuration.maximumUtteranceDuration)
            guard reachedHangover || reachedMaximum else {
                phase = .speaking(totalFrames: total, voicedFrames: voiced, quietFrames: quiet)
                return nil
            }
            phase = .quiet
            let voicedDuration = Double(voiced) * frame
            guard voicedDuration >= configuration.minimumUtteranceVoicedDuration else { return .discarded }
            return .ended(duration: Double(total) * frame, voicedDuration: voicedDuration, trailingSilence: Double(quiet) * frame)
        }
    }

    private mutating func confirmStartIfLongEnough() -> Event? {
        guard case .maybe(let loudFrames, _, let totalFrames) = phase else { return nil }
        let needed = teachyIsSpeaking ? configuration.teachySpeakingMinimumSpeechDuration : configuration.minimumSpeechDuration
        guard Double(loudFrames) * configuration.frameDuration >= needed - 0.000_1 else { return nil }
        phase = .speaking(totalFrames: totalFrames, voicedFrames: loudFrames, quietFrames: 0)
        return .started(lookback: Double(totalFrames) * configuration.frameDuration)
    }

    private mutating func trackNoiseFloor(_ level: Float) {
        let capacity = max(8, Int(configuration.noiseWindow / configuration.frameDuration))
        // Digital silence would otherwise pull the floor to the bottom of the scale.
        let clamped = max(level, -80)
        if recentLevels.count < capacity {
            recentLevels.append(clamped)
        } else {
            recentLevels[recentIndex] = clamped
            recentIndex = (recentIndex + 1) % capacity
        }
        // Wait for a third of a second of sound before trusting the measurement.
        guard Double(recentLevels.count) * configuration.frameDuration >= 0.3 else { return }
        let sorted = recentLevels.sorted()
        let target = sorted[min(sorted.count - 1, Int(Double(sorted.count) * configuration.noisePercentile))]
        // Fall quickly (the room got quieter), rise gently.
        noiseFloorDB += (target - noiseFloorDB) * (target < noiseFloorDB ? 0.3 : 0.08)
    }
}

/// Cuts a stream of microphone samples into utterances. Keeps the last moments of
/// sound in a ring so an utterance includes its first syllable, which the detector
/// only recognises after the fact. Pure: samples in, events out.
nonisolated struct UtteranceSegmenter {
    enum Event: Equatable {
        case started
        /// A finished utterance: mono samples at `sampleRate`.
        case finished(samples: [Float], voicedDuration: TimeInterval)
        case discarded
    }

    let sampleRate: Double
    /// How much sound from before the detected start is kept.
    var preRollDuration: TimeInterval = 0.4
    /// How much of the closing silence is kept.
    var keptTrailingSilence: TimeInterval = 0.2
    private(set) var detector: VoiceActivityDetector

    private let frameLength: Int
    private var pendingFrame: [Float] = []
    private var preRoll: [Float] = []
    private var current: [Float]?
    /// Loudness of the newest frame, for a level display.
    private(set) var lastFrameRMS: Float = 0

    init(sampleRate: Double, configuration: VoiceActivityDetector.Configuration = .init()) {
        self.sampleRate = sampleRate
        self.detector = VoiceActivityDetector(configuration: configuration)
        self.frameLength = max(1, Int((sampleRate * configuration.frameDuration).rounded()))
    }

    var teachyIsSpeaking: Bool {
        get { detector.teachyIsSpeaking }
        set { detector.teachyIsSpeaking = newValue }
    }

    var isInSpeech: Bool { detector.isInSpeech }

    /// Drops a half-captured utterance (for example when always-on is paused).
    mutating func abandonCurrentUtterance() {
        current = nil
        detector.abandonCurrentUtterance()
    }

    mutating func feed(_ samples: [Float]) -> [Event] {
        var events: [Event] = []
        pendingFrame.append(contentsOf: samples)
        var offset = 0
        while pendingFrame.count - offset >= frameLength {
            let frame = Array(pendingFrame[offset..<(offset + frameLength)])
            offset += frameLength
            if let event = process(frame) { events.append(event) }
        }
        if offset > 0 { pendingFrame.removeFirst(offset) }
        return events
    }

    private mutating func process(_ frame: [Float]) -> Event? {
        var sumOfSquares: Float = 0
        for sample in frame { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(frame.count)).squareRoot()
        lastFrameRMS = rms
        let wasCapturing = current != nil
        if wasCapturing { current?.append(contentsOf: frame) }

        let detectorEvent = detector.process(frameRMS: rms)

        if !wasCapturing {
            preRoll.append(contentsOf: frame)
            let lookbackCapacity = Int(sampleRate * (preRollDuration + 1.0))
            if preRoll.count > lookbackCapacity { preRoll.removeFirst(preRoll.count - lookbackCapacity) }
        }

        switch detectorEvent {
        case .started(let lookback):
            // The ring already holds the frames that triggered the start, plus the pre-roll before them.
            let wanted = Int(sampleRate * (lookback + preRollDuration))
            current = Array(preRoll.suffix(wanted))
            preRoll.removeAll(keepingCapacity: true)
            return .started
        case .ended(_, let voicedDuration, let trailingSilence):
            guard var samples = current else { return nil }
            current = nil
            let surplus = Int(sampleRate * max(0, trailingSilence - keptTrailingSilence))
            if surplus > 0, surplus < samples.count { samples.removeLast(surplus) }
            return .finished(samples: samples, voicedDuration: voicedDuration)
        case .discarded:
            current = nil
            return .discarded
        case nil:
            return nil
        }
    }
}
