//
//  AudioHardware.swift
//  leanring-buddy
//
//  The CoreAudio questions the voice features ask: where does sound come out
//  (headphones or speakers), is the Mac muted, and which other apps have the
//  microphone open. Reads only; nothing here changes a setting. The answers are
//  handed to the pure rules in VoicePolicy.swift.
//

import AudioToolbox
import CoreAudio
import Foundation

nonisolated enum AudioHardware {
    struct OutputDevice: Equatable, Sendable {
        let deviceID: AudioDeviceID
        let name: String
        let transportType: UInt32
        /// 'hdpn', 'ispk' … for built-in outputs; nil when the device has no data sources.
        let dataSource: UInt32?
        let isMuted: Bool?
        let volume: Float?

        var route: OutputRouteKind {
            OutputRouteKind.classify(transportType: transportType, dataSource: dataSource, deviceName: name)
        }
        var isSilent: Bool { OutputLoudness.isSilent(isMuted: isMuted, volume: volume) }
    }

    // MARK: - Output

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &deviceID),
              deviceID != 0 else { return nil }
        return deviceID
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &deviceID),
              deviceID != 0 else { return nil }
        return deviceID
    }

    static func defaultOutputDevice() -> OutputDevice? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var transport: UInt32 = 0
        _ = read(deviceID, kAudioDevicePropertyTransportType, into: &transport)

        var dataSource: UInt32 = 0
        let hasDataSource = read(deviceID, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, into: &dataSource)

        var muteValue: UInt32 = 0
        let hasMute = read(deviceID, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, into: &muteValue)

        return OutputDevice(
            deviceID: deviceID,
            name: string(deviceID, kAudioObjectPropertyName) ?? "",
            transportType: transport,
            dataSource: hasDataSource ? dataSource : nil,
            isMuted: hasMute ? muteValue != 0 : nil,
            volume: outputVolume(of: deviceID)
        )
    }

    /// 0…1, or nil when the device has no volume control.
    static func outputVolume(of deviceID: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        // The main (virtual) volume is what the volume keys change.
        if read(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput, into: &volume) {
            return volume
        }
        if read(deviceID, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, into: &volume) {
            return volume
        }
        // Some devices only have per-channel volume: use the loudest of the first two.
        var loudest: Float32?
        for channel in 1...2 {
            var channelVolume: Float32 = 0
            if read(deviceID, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: UInt32(channel), into: &channelVolume) {
                loudest = max(loudest ?? 0, channelVolume)
            }
        }
        return loudest
    }

    /// True when the Mac's output is muted or at zero volume.
    static var isOutputSilent: Bool {
        defaultOutputDevice()?.isSilent ?? false
    }

    // MARK: - Who has the microphone

    /// True when any process (Teachy included) has the default input device running.
    static func isDefaultInputInUse() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        var running: UInt32 = 0
        guard read(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running) else { return false }
        return running != 0
    }

    /// Bundle identifiers of the other apps that have a microphone open right now.
    /// Nil when macOS doesn't give a per-app answer.
    static func otherBundleIDsUsingMicrophone() -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return nil }
        var processObjects = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &processObjects) == noErr else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var bundleIDs: [String] = []
        for processObject in processObjects {
            var isRunningInput: UInt32 = 0
            guard read(processObject, kAudioProcessPropertyIsRunningInput, into: &isRunningInput), isRunningInput != 0 else { continue }
            var pid: pid_t = 0
            if read(processObject, kAudioProcessPropertyPID, into: &pid), pid == ownPID { continue }
            if let bundleID = string(processObject, kAudioProcessPropertyBundleID), !bundleID.isEmpty {
                bundleIDs.append(bundleID)
            }
        }
        return bundleIDs
    }

    // MARK: - Change notifications

    /// Calls `handler` on the main queue when the default input or output device changes,
    /// or when the given device's properties (running state, mute, volume, data source) change.
    /// Returns a token; keep it for as long as the notifications are wanted.
    final class Observation {
        fileprivate var removals: [() -> Void] = []
        func cancel() { removals.forEach { $0() }; removals.removeAll() }
        deinit { cancel() }
    }

    static func observe(
        object: AudioObjectID,
        selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)],
        handler: @escaping @Sendable () -> Void
    ) -> Observation {
        let observation = Observation()
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { continue }
            observation.removals.append {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
            }
        }
        return observation
    }

    // MARK: - Reading

    private static func read<Value>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        into value: inout Value
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var dataSize = UInt32(MemoryLayout<Value>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, pointer) == noErr
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
