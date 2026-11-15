//
//  PushToTalkWarmup.swift
//  leanring-buddy
//
//  Bluetooth headsets and push-to-talk. A Bluetooth headset plays music in one
//  mode and records in another, and switching takes it a second or so the moment
//  the microphone opens: the first words of a question are lost.
//
//  What this does about it, when the live microphone is a Bluetooth one:
//  - Keep-warm: when the talk key goes down, a second, idle recording engine opens
//    the same microphone and stays open for `keepWarmSeconds` after the key comes
//    up. The headset stays in recording mode, so the next question (follow-ups
//    usually come within seconds) starts with no switch at all.
//  - Pre-roll: while warm, the last moments of sound are kept in a ring. Recording
//    proper only starts a few tenths of a second after the key goes down (permission
//    checks, opening the recogniser); `drainPreRoll` hands over what was said in
//    that gap so it can be fed to the recogniser first.
//
//  What it can't do: the very first question after a quiet spell still waits for
//  the headset to switch. Nothing on the Mac can make that switch faster; the
//  Microphone card says so and suggests a wired or built-in mic.
//
//  Cost: while warm, the headset's playback is in its lower-quality call mode.
//  That is why it lets go after `keepWarmSeconds`. Set that to 0 to switch all of this off.
//

import AVFoundation
import Combine
import Foundation

/// The last moments of microphone sound, written from the audio thread and read from the main one.
nonisolated final class PreRollRing: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(at: TimeInterval, buffer: AVAudioPCMBuffer)] = []
    private let keepSeconds: TimeInterval

    init(keepSeconds: TimeInterval = 2.0) {
        self.keepSeconds = keepSeconds
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
        } else {
            return
        }
        lock.lock()
        entries.append((time, copy))
        entries.removeAll { time - $0.at > keepSeconds }
        lock.unlock()
    }

    /// Buffers captured at or after `start`, oldest first, then forgets everything.
    func drain(from start: TimeInterval) -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { entries.removeAll(); lock.unlock() }
        let times = entries.map(\.at)
        return PushToTalkWarmupPlan.preRollIndexes(bufferTimes: times, keyDownAt: start).map { entries[$0].buffer }
    }

    func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}

@MainActor
final class PushToTalkWarmup: ObservableObject {
    static let shared = PushToTalkWarmup()

    /// How long the Bluetooth microphone is held open after the talk key comes up. 0 = never.
    var keepWarmSeconds: TimeInterval = PushToTalkWarmupPlan.defaultKeepWarmSeconds
    /// True while the idle engine is holding the microphone open.
    @Published private(set) var isWarm = false

    private var engine: AVAudioEngine?
    private var warmFormat: AVAudioFormat?
    private let ring = PreRollRing()
    private var releaseWorkItem: DispatchWorkItem?
    private var keyDownAt: TimeInterval?
    private var wasWarmAtKeyDown = false

    private init() {}

    /// Call first thing when the talk key goes down.
    func talkKeyDown() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        keyDownAt = ProcessInfo.processInfo.systemUptime
        wasWarmAtKeyDown = isWarm
        let microphone = MicrophoneCenter.activeDevice()
        let plan = PushToTalkWarmupPlan.decide(
            activeMicrophoneIsBluetooth: microphone?.isBluetooth ?? false,
            isAlreadyWarm: isWarm,
            keepWarmSeconds: keepWarmSeconds
        )
        if plan == .startWarmEngine { startWarmEngine() }
    }

    /// Call when the talk key comes up.
    func talkKeyUp() {
        keyDownAt = nil
        guard isWarm else { return }
        releaseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopWarmEngine() }
        releaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keepWarmSeconds, execute: work)
    }

    /// What was said between the key going down and now, to feed to the recogniser before
    /// the live audio. Empty unless the microphone was already warm when the key went down
    /// and `format` is the format it was recorded in.
    func drainPreRoll(matching format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        guard wasWarmAtKeyDown, let keyDownAt, let warmFormat,
              warmFormat.sampleRate == format.sampleRate, warmFormat.channelCount == format.channelCount,
              warmFormat.commonFormat == format.commonFormat
        else {
            ring.clear()
            return []
        }
        return ring.drain(from: keyDownAt)
    }

    /// Lets go of the microphone now (for example when always-on takes it over).
    func stopWarmEngine() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        warmFormat = nil
        ring.clear()
        if isWarm { isWarm = false }
    }

    private func startWarmEngine() {
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let newEngine = AVAudioEngine()
        guard MicrophoneCenter.applyWithFailover(to: newEngine) != nil else { return }
        let format = newEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(ring: ring))
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            newEngine.inputNode.removeTap(onBus: 0)
            return
        }
        engine = newEngine
        warmFormat = format
        isWarm = true
    }

    /// Runs on the audio thread. The sound is only kept for two seconds, in memory.
    private nonisolated static func makeTapBlock(ring: PreRollRing) -> AVAudioNodeTapBlock {
        { buffer, _ in ring.append(buffer, at: ProcessInfo.processInfo.systemUptime) }
    }
}
