//
//  VoiceModeController.swift
//  leanring-buddy
//
//  Always-on (hands-free) mode. While it is on the microphone stays open, a local
//  voice detector (`UtteranceSegmenter`) cuts what it hears into utterances, each
//  one is transcribed (`UtteranceTranscriber`) and handed to the app through
//  `onUtterance`, which the app wires to its normal voice turn.
//
//  Talking over Teachy stops it ("barge-in"). The hard part is not mistaking
//  Teachy's own voice from the speakers for the person, so:
//  - the microphone engine runs Apple's voice processing (echo cancellation), and
//    the realtime voice plays through that same engine so the canceller knows
//    exactly what is being said (`RealtimeVoice.useSharedEngine`);
//  - while Teachy talks, the detector's bar is higher and a sound must last longer;
//  - speech that isn't playing through that engine (the fallback voices) can't be
//    cancelled, so on speakers the detector is simply not listened to during it;
//  - if voice processing can't be switched on, always-on only runs on headphones
//    and says so (`State.needsHeadphones`);
//  - a transcript made mostly of words Teachy just said is dropped (`EchoTextGuard`).
//
//  It pauses during calls, moves to another microphone when the live one dies,
//  and switches itself off after a few quiet minutes and when the Mac locks or sleeps.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

@MainActor
final class VoiceModeController: ObservableObject {
    static let shared = VoiceModeController()

    typealias State = AlwaysOnState

    @Published private(set) var state: State = .off
    /// The person's switch. Stays true while paused for a call or waiting for headphones.
    @Published private(set) var isAlwaysOn = false
    /// The microphone that is really open, after any failover.
    @Published private(set) var liveMicrophoneName: String?
    /// Input loudness from 0 to 1, for the pill.
    @Published private(set) var level: Float = 0
    /// True when talking over Teachy will stop it with the current devices.
    @Published private(set) var canInterruptBySpeaking = false
    /// Why it last switched itself off or changed microphone, for a line under the pill.
    @Published private(set) var notice: String?

    /// Each finished utterance, as text. Wire this to the normal voice turn.
    var onUtterance: ((String) -> Void)?
    /// The person started talking over Teachy. Speech has already been stopped; cancel the reply being written.
    var onBargeIn: (() -> Void)?

    /// Minutes of quiet before always-on switches itself off.
    var autoOffMinutes: Int { TeachySettingsStorage.alwaysOnAutoOffMinutes() }

    // Capture
    private var engine: AVAudioEngine?
    private var segmenter: UtteranceSegmenter?
    private var engineObserver: NSObjectProtocol?
    private var captureGeneration = 0
    private var echoCancellationEnabled = false
    private var outputRoute: OutputRouteKind = .none
    private var liveMicrophone: MicrophoneDevice?
    private var failedMicrophoneUIDs: Set<String> = []
    /// Bluetooth mics deliver zeros for a second or two while they switch profile; allow for it.
    private var healthMonitor = MicrophoneHealthMonitor(silentAfter: 4)
    private var unavailableTicks = 0
    private var lastBufferAt = Date()
    private var lastLevelPublishedAt = Date.distantPast

    // Turn state
    private var lastSpeechAt = Date()
    private var awaitingReplyUntil: Date?
    private var replyHasStartedSpeaking = false
    private var teachyStoppedSpeakingAt = Date.distantPast
    private var transcriptionTask: Task<Void, Never>?
    private var suspendReasons: Set<String> = []

    // Watching the world
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var outputObservation: AudioHardware.Observation?
    private var outputDeviceObservation: AudioHardware.Observation?
    private var housekeepingTimer: Timer?
    private var restartWorkItem: DispatchWorkItem?
    private var hotkeyMonitor: ControlTapMonitor?
    private var hotkeyPermissionTimer: Timer?

    var isCapturing: Bool { engine?.isRunning ?? false }

    private init() {
        CallDetector.shared.teachyIsRecording = { [weak self] in self?.isCapturing ?? false }
        _ = MicrophoneDeviceWatcher.shared

        CallDetector.shared.$isInCall
            .removeDuplicates()
            .sink { [weak self] inCall in self?.callStateChanged(inCall) }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: LocalSpeechSynthesizer.speakingDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.speakingChanged() }
        })
        observers.append(center.addObserver(forName: MicrophoneDeviceWatcher.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.microphonesChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.switchOffBecause("Always-on switched off because your Mac went to sleep.") }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.switchOffBecause("Always-on switched off because your Mac was locked.") }
        })
    }

    // MARK: - Switching on and off

    func toggleAlwaysOn() { setAlwaysOn(!isAlwaysOn) }

    func setAlwaysOn(_ on: Bool) {
        guard on != isAlwaysOn else { return }
        isAlwaysOn = on
        if on {
            notice = nil
            failedMicrophoneUIDs.removeAll()
            lastSpeechAt = Date()
            watchOutputDevice()
            startHousekeeping()
            startCapture()
        } else {
            stopCapture()
            stopHousekeeping()
            outputObservation = nil
            outputDeviceObservation = nil
            awaitingReplyUntil = nil
            state = .off
        }
        print("🎧 Always-on \(on ? "on" : "off") (\(state.label))")
    }

    private func switchOffBecause(_ reason: String) {
        guard isAlwaysOn else { return }
        setAlwaysOn(false)
        notice = reason
    }

    /// Installs the triple-tap Control shortcut on its own event tap. Use this when the text
    /// box keeps its own double-tap monitor; when `ControlTapMonitor` replaces that monitor,
    /// set its `onTripleTap` to `handleTripleTap` instead and don't call this.
    func installHotkey() {
        guard hotkeyMonitor == nil else { return }
        let monitor = ControlTapMonitor()
        monitor.onTripleTap = { [weak self] in self?.handleTripleTap() }
        hotkeyMonitor = monitor
        if monitor.start() { return }
        // Accessibility isn't granted yet: check quietly until it is. Never prompts.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.hotkeyMonitor?.start() == true else { return }
                self.hotkeyPermissionTimer?.invalidate()
                self.hotkeyPermissionTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hotkeyPermissionTimer = timer
    }

    /// Control was tapped three times: switch always-on, and close the text box that the
    /// first two taps of the same gesture opened.
    func handleTripleTap() {
        if TextBoxController.shared.isVisible { TextBoxController.shared.close() }
        toggleAlwaysOn()
    }

    // MARK: - Hooks for the rest of the app

    /// The reply to the last utterance is over (or failed without speaking). Optional:
    /// without it "Thinking" clears when speech ends, or after 45 seconds.
    func turnDidEnd() {
        awaitingReplyUntil = nil
        refreshState()
    }

    /// Stop listening for a while without closing the microphone: the person is holding
    /// the talk key or dictating, and that recording must not also arrive as an utterance.
    func suspend(reason: String) {
        suspendReasons.insert(reason)
        segmenter?.abandonCurrentUtterance()
        refreshState()
    }

    func resume(reason: String) {
        suspendReasons.remove(reason)
        refreshState()
    }

    // MARK: - Capture

    private func startCapture() {
        stopCapture()
        guard isAlwaysOn else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            state = .unavailable("Teachy needs microphone permission")
            return
        }
        if CallDetector.shared.refresh(), TeachySettingsStorage.quietOnCallsEnabled() {
            state = .pausedForCall
            return
        }

        outputRoute = AudioHardware.defaultOutputDevice()?.route ?? .none

        // First with echo cancellation. If that can't be had, without it, but then only on headphones.
        var prepared = Self.prepareEngine(voiceProcessing: true, excluding: failedMicrophoneUIDs)
        if prepared == nil || !prepared!.echoCancellationEnabled {
            guard case .allowed = AlwaysOnEligibility.decide(route: outputRoute, echoCancellationEnabled: false) else {
                RealtimeVoice.shared.useSharedEngine(nil)
                state = outputRoute == .speakers ? .needsHeadphones : .unavailable("No sound output")
                canInterruptBySpeaking = false
                return
            }
            if prepared == nil { prepared = Self.prepareEngine(voiceProcessing: false, excluding: failedMicrophoneUIDs) }
        }
        guard let prepared else {
            RealtimeVoice.shared.useSharedEngine(nil)
            state = .unavailable("No working microphone")
            return
        }
        let newEngine = prepared.engine
        let microphone: MicrophoneDevice? = prepared.microphone
        let format = prepared.format
        echoCancellationEnabled = prepared.echoCancellationEnabled

        captureGeneration += 1
        let generation = captureGeneration
        segmenter = UtteranceSegmenter(sampleRate: format.sampleRate)
        healthMonitor.reset()
        lastBufferAt = Date()
        newEngine.inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: format,
            block: Self.makeTapBlock { [weak self] samples, peak in
                Task { @MainActor in self?.process(samples: samples, peak: peak, generation: generation) }
            }
        )
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            newEngine.inputNode.removeTap(onBus: 0)
            RealtimeVoice.shared.useSharedEngine(nil)
            print("⚠️ Always-on: the microphone engine failed to start: \(error.localizedDescription)")
            state = .unavailable("Couldn't open the microphone")
            return
        }

        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            // The device or its format changed under the engine, which has stopped itself.
            MainActor.assumeIsolated { self?.scheduleRestart() }
        }

        engine = newEngine
        liveMicrophone = microphone
        liveMicrophoneName = microphone?.name
        unavailableTicks = 0
        let expected = MicrophoneDeviceWatcher.shared.active
        MicrophoneDeviceWatcher.shared.liveOverride = microphone?.uid == expected?.uid ? nil : microphone
        if let microphone, let expected, microphone.uid != expected.uid {
            notice = "\(expected.name) isn't working, so Teachy is listening with \(microphone.name)."
        }
        canInterruptBySpeaking = BargeInPolicy.voiceMayInterrupt(
            route: outputRoute, echoCancellationEnabled: echoCancellationEnabled, speechIsOnCancelledEngine: true
        )
        refreshState()
        print("🎧 Always-on listening with \(microphone?.name ?? "?"), output \(outputRoute.rawValue), echo cancellation \(echoCancellationEnabled ? "on" : "off")")
    }

    private func stopCapture() {
        captureGeneration += 1
        restartWorkItem?.cancel()
        restartWorkItem = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            RealtimeVoice.shared.useSharedEngine(nil)
            engine.stop()
        }
        engine = nil
        segmenter = nil
        level = 0
        liveMicrophone = nil
        liveMicrophoneName = nil
        MicrophoneDeviceWatcher.shared.liveOverride = nil
    }

    /// Several change notifications often arrive together; restart once, a moment later.
    private func scheduleRestart() {
        guard isAlwaysOn else { return }
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startCapture() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private struct PreparedEngine {
        let engine: AVAudioEngine
        let microphone: MicrophoneDevice
        let format: AVAudioFormat
        let echoCancellationEnabled: Bool
    }

    /// A new engine pointed at a working microphone, not started. With voice processing the
    /// realtime voice is attached to it first, because that changes the input's format.
    /// Nil when no microphone gives a usable format this way.
    private static func prepareEngine(voiceProcessing: Bool, excluding failedUIDs: Set<String>) -> PreparedEngine? {
        let engine = AVAudioEngine()
        let echoCancellationEnabled = voiceProcessing && enableVoiceProcessing(on: engine)
        guard let microphone = MicrophoneCenter.applyWithFailover(to: engine, excluding: failedUIDs) else { return nil }
        // Teachy's voice goes out through this engine, so the echo canceller has it as reference.
        RealtimeVoice.shared.useSharedEngine(echoCancellationEnabled ? engine : nil)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard MicrophoneHealthMonitor.isUsableFormat(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)) else {
            RealtimeVoice.shared.useSharedEngine(nil)
            return nil
        }
        return PreparedEngine(engine: engine, microphone: microphone, format: format, echoCancellationEnabled: echoCancellationEnabled)
    }

    /// Apple's voice-processing I/O: echo cancellation and noise reduction. Must be set before the engine starts.
    private static func enableVoiceProcessing(on engine: AVAudioEngine) -> Bool {
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("⚠️ Always-on: voice processing isn't available on this device: \(error.localizedDescription)")
            return false
        }
        // Don't turn down the person's music more than voice processing has to.
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min
        )
        return engine.inputNode.isVoiceProcessingEnabled
    }

    /// Runs on the audio thread: copies the first channel out and hands it on.
    private nonisolated static func makeTapBlock(_ deliver: @escaping @Sendable ([Float], Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channel = buffer.floatChannelData?[0] else {
                deliver([], 0)
                return
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
            var peak: Float = 0
            for sample in samples { peak = max(peak, abs(sample)) }
            deliver(samples, peak)
        }
    }

    // MARK: - Audio in

    private func process(samples: [Float], peak: Float, generation: Int) {
        guard generation == captureGeneration, var activeSegmenter = segmenter else { return }
        lastBufferAt = Date()

        switch healthMonitor.process(peak: peak, frameCount: samples.count, sampleRate: activeSegmenter.sampleRate) {
        case .healthy:
            break
        case .silent, .zeroFormat:
            microphoneDied()
            return
        }

        let teachyIsSpeaking = LocalSpeechSynthesizer.isAnySpeaking
        activeSegmenter.teachyIsSpeaking = teachyIsSpeaking
            || Date().timeIntervalSince(teachyStoppedSpeakingAt) < 0.35   // the tail still ringing in the room

        // Deaf on purpose: held talk key, or Teachy talking through a path that can't be cancelled.
        let mayListen = suspendReasons.isEmpty && (!teachyIsSpeaking || BargeInPolicy.voiceMayInterrupt(
            route: outputRoute,
            echoCancellationEnabled: echoCancellationEnabled,
            speechIsOnCancelledEngine: RealtimeVoice.shared.isSpeaking && RealtimeVoice.shared.isUsingSharedEngine
        ))
        guard mayListen else {
            activeSegmenter.abandonCurrentUtterance()
            segmenter = activeSegmenter
            publishLevel(0)
            return
        }

        let events = activeSegmenter.feed(samples)
        segmenter = activeSegmenter
        publishLevel(MicrophoneCenter.meterLevel(fromRMS: activeSegmenter.lastFrameRMS))

        for event in events {
            switch event {
            case .started:
                lastSpeechAt = Date()
                if teachyIsSpeaking { bargeIn() }
                refreshState()
            case .finished(let utterance, _):
                lastSpeechAt = Date()
                handleUtterance(utterance, sampleRate: activeSegmenter.sampleRate)
            case .discarded:
                refreshState()
            }
        }
    }

    private func publishLevel(_ newLevel: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublishedAt) > 0.06 else { return }
        lastLevelPublishedAt = now
        // Fast rise, slow fall.
        level = newLevel > level ? newLevel : level * 0.7 + newLevel * 0.3
    }

    private func bargeIn() {
        print("🎧 Always-on: the person spoke over Teachy; stopping speech")
        RealtimeVoice.shared.stop()
        LocalSpeechSynthesizer.stopAllPlayback()
        awaitingReplyUntil = nil
        onBargeIn?()
    }

    private func handleUtterance(_ samples: [Float], sampleRate: Double) {
        awaitingReplyUntil = Date().addingTimeInterval(45)
        replyHasStartedSpeaking = false
        refreshState()
        let previous = transcriptionTask
        let generation = captureGeneration
        transcriptionTask = Task { [weak self] in
            await previous?.value
            let outcome = await UtteranceTranscriber.transcribe(samples: samples, sampleRate: sampleRate)
            guard let self, self.isAlwaysOn, generation == self.captureGeneration else { return }
            guard let outcome else {
                // Noise, not words.
                self.awaitingReplyUntil = nil
                self.refreshState()
                return
            }
            if EchoTextGuard.isLikelyEcho(transcript: outcome.text, recentlySpoken: LocalSpeechSynthesizer.recentlySpokenSentences()) {
                print("🎧 Always-on: ignored Teachy's own voice coming back through the microphone")
                self.awaitingReplyUntil = nil
                self.refreshState()
                return
            }
            print("🎧 Always-on heard (\(outcome.source)): \(outcome.text)")
            self.lastSpeechAt = Date()
            SpokenOutputGate.shared.noteQuestionWithoutTalkKey()
            self.onUtterance?(outcome.text)
        }
    }

    // MARK: - State

    private func refreshState() {
        guard isAlwaysOn else {
            if state != .off { state = .off }
            return
        }
        // These are set where they are decided and stay until capture restarts.
        guard isCapturing else { return }
        let newState: State
        if segmenter?.isInSpeech == true, suspendReasons.isEmpty {
            newState = .hearing
        } else if LocalSpeechSynthesizer.isAnySpeaking {
            newState = .speaking
        } else if let awaitingReplyUntil, Date() < awaitingReplyUntil {
            newState = .thinking
        } else {
            newState = .listening
        }
        if newState != state { state = newState }
    }

    private func speakingChanged() {
        guard isAlwaysOn else { return }
        if LocalSpeechSynthesizer.isAnySpeaking {
            replyHasStartedSpeaking = true
            // A long answer is not quiet time.
            lastSpeechAt = Date()
        } else {
            teachyStoppedSpeakingAt = Date()
            lastSpeechAt = Date()
            if replyHasStartedSpeaking { awaitingReplyUntil = nil }
        }
        refreshState()
    }

    // MARK: - Calls, devices, quiet

    private func callStateChanged(_ inCall: Bool) {
        guard isAlwaysOn, TeachySettingsStorage.quietOnCallsEnabled() else { return }
        if inCall {
            guard state != .pausedForCall else { return }
            stopCapture()
            state = .pausedForCall
            print("🎧 Always-on paused: on a call")
        } else if state == .pausedForCall {
            // Time on the call doesn't count as quiet.
            lastSpeechAt = Date()
            startCapture()
        }
    }

    private func microphoneDied() {
        guard let dead = liveMicrophone else { return }
        print("⚠️ Always-on: \(dead.name) went silent; trying another microphone")
        failedMicrophoneUIDs.insert(dead.uid)
        startCapture()
    }

    private func microphonesChanged() {
        guard isAlwaysOn, state != .pausedForCall else { return }
        let devices = MicrophoneDeviceWatcher.shared.devices
        // A microphone that failed and was unplugged gets another chance when it comes back.
        failedMicrophoneUIDs = failedMicrophoneUIDs.filter { uid in devices.contains { $0.uid == uid } }
        let wanted = MicrophoneCenter.failoverCandidates(excluding: failedMicrophoneUIDs).first
        if wanted?.uid != liveMicrophone?.uid { scheduleRestart() }
    }

    private func watchOutputDevice() {
        outputObservation = AudioHardware.observe(
            object: AudioObjectID(kAudioObjectSystemObject),
            selectors: [(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)]
        ) { [weak self] in
            Task { @MainActor in
                self?.watchOutputDataSource()
                self?.outputChanged()
            }
        }
        watchOutputDataSource()
    }

    /// Plugging headphones into a Mac with one built-in output changes its data source, not the device.
    private func watchOutputDataSource() {
        outputDeviceObservation = nil
        guard let deviceID = AudioHardware.defaultOutputDeviceID() else { return }
        outputDeviceObservation = AudioHardware.observe(
            object: deviceID,
            selectors: [(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)]
        ) { [weak self] in
            Task { @MainActor in self?.outputChanged() }
        }
    }

    private func outputChanged() {
        guard isAlwaysOn, state != .pausedForCall else { return }
        let newRoute = AudioHardware.defaultOutputDevice()?.route ?? .none
        if newRoute != outputRoute || state == .needsHeadphones { scheduleRestart() }
    }

    private func startHousekeeping() {
        stopHousekeeping()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeeping() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    private func stopHousekeeping() {
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
    }

    private func housekeeping() {
        guard isAlwaysOn else { return }
        refreshState()
        if case .unavailable = state {
            // Every half minute, forget which microphones failed and try again.
            unavailableTicks += 1
            if unavailableTicks >= 6 {
                unavailableTicks = 0
                failedMicrophoneUIDs.removeAll()
                startCapture()
            }
            return
        }
        if isCapturing, Date().timeIntervalSince(lastBufferAt) > 3 {
            // The engine says it runs but delivers nothing: the device is gone.
            microphoneDied()
            return
        }
        guard state == .listening else { return }
        let minutes = autoOffMinutes
        if AlwaysOnIdlePolicy.shouldTurnOff(secondsSinceLastSpeech: Date().timeIntervalSince(lastSpeechAt), minutes: minutes) {
            switchOffBecause("Always-on switched off after \(minutes) quiet minute\(minutes == 1 ? "" : "s").")
        }
    }
}
