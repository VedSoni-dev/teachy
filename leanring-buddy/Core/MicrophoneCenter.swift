//
//  MicrophoneCenter.swift
//  leanring-buddy
//
//  Which microphone Teachy listens with. Lists the Mac's input devices, remembers
//  the person's pick (or "follow the system"), and points an AVAudioEngine at it
//  before recording starts. Voice questions and dictation both go through here,
//  so the mic shown in Settings is the mic actually used.
//
//  Failover: when the chosen mic is gone, or opens with no usable format, the next
//  one in `failoverCandidates` is used (the Mac's input, then the built-in mic, then
//  anything else). `MicrophoneDeviceWatcher` tells the Settings card and always-on
//  mode when devices come and go.
//

import AVFoundation
import Combine
import CoreAudio
import Foundation

nonisolated struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    let deviceID: AudioDeviceID
    /// Stable across restarts and replugging; this is what is saved.
    let uid: String
    let name: String
    /// CoreAudio's transport code ('bltn', 'blue', 'usb ' …). 0 when unknown.
    var transportType: UInt32 = 0
    var id: String { uid }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
}

nonisolated enum MicrophoneCenter {
    static let selectedUIDDefaultsKey = "teachyMicrophoneUID"

    /// The saved pick, or nil to follow the system's input device.
    static var selectedUID: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: selectedUIDDefaultsKey) ?? ""
            return stored.isEmpty ? nil : stored
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: selectedUIDDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedUIDDefaultsKey)
            }
        }
    }

    // MARK: - Devices

    /// Every device that has at least one input channel.
    static func inputDevices() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard inputChannelCount(of: deviceID) > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
            else { return nil }
            return MicrophoneDevice(deviceID: deviceID, uid: uid, name: name, transportType: transportType(of: deviceID))
        }
    }

    static func systemDefaultInput() -> MicrophoneDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return inputDevices().first { $0.deviceID == deviceID }
    }

    /// The microphone Teachy will record from right now: the saved pick if it is
    /// plugged in, otherwise the system's input.
    static func activeDevice() -> MicrophoneDevice? {
        resolveActiveDevice(selectedUID: selectedUID, devices: inputDevices(), systemDefault: systemDefaultInput())
    }

    /// Pure choice rule (tested): a saved pick wins only while that device exists.
    static func resolveActiveDevice(
        selectedUID: String?,
        devices: [MicrophoneDevice],
        systemDefault: MicrophoneDevice?
    ) -> MicrophoneDevice? {
        if let selectedUID, let chosen = devices.first(where: { $0.uid == selectedUID }) {
            return chosen
        }
        return systemDefault ?? devices.first
    }

    /// Shown in the Microphone card when the live mic is a Bluetooth one.
    static let bluetoothWarning = "Bluetooth mics can cut off your first words; a wired or built-in mic is more reliable."

    /// Pure choice rule (tested): every microphone worth trying, best first. The saved pick
    /// (if connected), then the Mac's input, then the built-in mic, then the rest; never one
    /// in `excluding` (mics that already failed this session).
    static func failoverCandidates(
        selectedUID: String?,
        devices: [MicrophoneDevice],
        systemDefault: MicrophoneDevice?,
        excluding failedUIDs: Set<String> = []
    ) -> [MicrophoneDevice] {
        var ordered: [MicrophoneDevice] = []
        func add(_ device: MicrophoneDevice?) {
            guard let device, !failedUIDs.contains(device.uid),
                  devices.contains(where: { $0.uid == device.uid }),
                  !ordered.contains(where: { $0.uid == device.uid }) else { return }
            ordered.append(device)
        }
        if let selectedUID { add(devices.first { $0.uid == selectedUID }) }
        add(systemDefault)
        devices.filter(\.isBuiltIn).forEach(add)
        // Bluetooth mics last: they are the ones that drop out.
        devices.filter { !$0.isBluetooth }.forEach(add)
        devices.forEach(add)
        return ordered
    }

    /// The live list, in the order Teachy would try them.
    static func failoverCandidates(excluding failedUIDs: Set<String> = []) -> [MicrophoneDevice] {
        failoverCandidates(selectedUID: selectedUID, devices: inputDevices(), systemDefault: systemDefaultInput(), excluding: failedUIDs)
    }

    /// True when the saved microphone is not connected and Teachy fell back to the system's.
    static var isSelectedDeviceMissing: Bool {
        guard let selectedUID else { return false }
        return !inputDevices().contains { $0.uid == selectedUID }
    }

    // MARK: - Applying to an engine

    /// Points `engine`'s input at the chosen microphone. Call BEFORE reading the input
    /// format or installing a tap. Does nothing when following the system input.
    @discardableResult
    static func apply(to engine: AVAudioEngine) -> MicrophoneDevice? {
        let active = activeDevice()
        guard let selectedUID, let active, active.uid == selectedUID,
              let audioUnit = engine.inputNode.audioUnit else { return active }
        var deviceID = active.deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("⚠️ Microphone: couldn't switch to \(active.name) (\(status)); using the system input")
            return systemDefaultInput()
        }
        return active
    }

    /// Points `engine`'s input at one specific microphone. Returns false if CoreAudio refused.
    @discardableResult
    static func apply(_ device: MicrophoneDevice, to engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else { return false }
        var deviceID = device.deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr { print("⚠️ Microphone: couldn't switch to \(device.name) (\(status))") }
        return status == noErr
    }

    /// Like `apply(to:)`, but checks that the microphone opened with a usable format
    /// (a sample rate and at least one channel) and moves down `failoverCandidates`
    /// until one does. Call BEFORE installing a tap. Returns the mic that is live, or
    /// nil when none works.
    @discardableResult
    static func applyWithFailover(to engine: AVAudioEngine, excluding failedUIDs: Set<String> = []) -> MicrophoneDevice? {
        let candidates = failoverCandidates(excluding: failedUIDs)
        let systemDefault = systemDefaultInput()
        for (index, candidate) in candidates.enumerated() {
            // Following the system and it is the first choice: nothing to set.
            let needsExplicitSwitch = !(index == 0 && selectedUID == nil && candidate.uid == systemDefault?.uid)
            if needsExplicitSwitch, !apply(candidate, to: engine) { continue }
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                if index > 0 { print("🎙️ Microphone failover: using \(candidate.name)") }
                return candidate
            }
            print("⚠️ Microphone: \(candidate.name) has no usable format; trying the next one")
        }
        return nil
    }

    // MARK: - CoreAudio helpers

    static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Loudness of a buffer from 0 to 1, shaped so normal speech fills most of a meter.
    static func meterLevel(fromRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        // -60 dB (silence) → 0, -10 dB (loud speech) → 1
        return max(0, min(1, (decibels + 60) / 50))
    }
}

/// Publishes the microphones as they come and go (a headset plugged in, AirPods
/// connecting, the Mac's input changed in System Settings), using CoreAudio's own
/// change notifications. The Settings card and always-on mode observe it.
@MainActor
final class MicrophoneDeviceWatcher: ObservableObject {
    static let shared = MicrophoneDeviceWatcher()
    /// Also posted on every change, for code that isn't SwiftUI.
    static let didChangeNotification = Notification.Name("TeachyMicrophoneDevicesDidChange")

    @Published private(set) var devices: [MicrophoneDevice] = []
    @Published private(set) var systemDefault: MicrophoneDevice?
    /// The mic Teachy would record from right now.
    @Published private(set) var active: MicrophoneDevice?
    /// Set by whoever is recording when failover picked a different mic than `active`.
    @Published var liveOverride: MicrophoneDevice?

    /// The mic that is really in use: the failover pick while one is in force, else `active`.
    var live: MicrophoneDevice? { liveOverride ?? active }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
    ]

    private init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listenerBlock = block
        for selector in Self.watchedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
    }

    func refresh() {
        let newDevices = MicrophoneCenter.inputDevices()
        let newDefault = MicrophoneCenter.systemDefaultInput()
        let newActive = MicrophoneCenter.resolveActiveDevice(
            selectedUID: MicrophoneCenter.selectedUID, devices: newDevices, systemDefault: newDefault
        )
        let changed = newDevices != devices || newDefault != systemDefault || newActive != active
        devices = newDevices
        systemDefault = newDefault
        active = newActive
        if let override = liveOverride, !newDevices.contains(where: { $0.uid == override.uid }) { liveOverride = nil }
        if changed { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }
}

/// A live input level for the Settings card, so people can see the mic is hearing them.
/// Runs only while the card is open and only if microphone permission is already granted.
/// The audio is measured for loudness and thrown away: nothing is recorded or sent.
@MainActor
final class MicrophoneLevelMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isRunning = false
    @Published private(set) var listeningToName: String?
    @Published private(set) var problem: String?

    private var engine: AVAudioEngine?

    func start() {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            problem = "Teachy doesn't have microphone permission yet."
            return
        }
        let newEngine = AVAudioEngine()
        let active = MicrophoneCenter.apply(to: newEngine)
        let inputNode = newEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone found."
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sumOfSquares: Float = 0
            for index in 0..<Int(buffer.frameLength) { sumOfSquares += samples[index] * samples[index] }
            let level = MicrophoneCenter.meterLevel(fromRMS: (sumOfSquares / Float(buffer.frameLength)).squareRoot())
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                // Fast rise, slow fall, like a hardware meter.
                self.level = level > self.level ? level : self.level * 0.8 + level * 0.2
            }
        }
        newEngine.prepare()
        do {
            try newEngine.start()
            engine = newEngine
            isRunning = true
            listeningToName = active?.name
            problem = nil
        } catch {
            inputNode.removeTap(onBus: 0)
            problem = "Couldn't open the microphone: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }
}
