//
//  MicrophoneCenter.swift
//  leanring-buddy
//
//  Which microphone Teachy listens with. Lists the Mac's input devices, remembers
//  the person's pick (or "follow the system"), and points an AVAudioEngine at it
//  before recording starts. Voice questions and dictation both go through here,
//  so the mic shown in Settings is the mic actually used.
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
    var id: String { uid }
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
            return MicrophoneDevice(deviceID: deviceID, uid: uid, name: name)
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

    // MARK: - CoreAudio helpers

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
