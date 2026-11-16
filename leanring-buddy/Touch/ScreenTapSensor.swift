//
//  ScreenTapSensor.swift
//  leanring-buddy
//
//  Reads the built-in sensors a MacBook exposes through its sensor processor
//  (IOKit services named AppleSPUHIDDevice): ambient light, accelerometer,
//  gyroscope and lid angle, and feeds them to `ScreenTapRecognizer`.
//
//  Everything runs on one dedicated thread with its own run loop, because HID
//  callbacks arrive at hundreds of samples a second and must never touch the
//  main thread. Only a recognised tap is handed out, through `onTap`.
//
//  The motion sensors normally report slowly to save power. While running, the
//  sensor asks their drivers for a fast report interval and puts the original
//  value back when it stops (unless another app changed it in the meantime).
//
//  Desktop Macs and older Intel MacBooks have none of these devices; `start`
//  then reports `.unavailable` and nothing else happens.
//

import Foundation
import IOKit
import IOKit.hid

nonisolated final class ScreenTapSensor: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case stopped
        case starting
        /// Running, but the lid moved recently or a stream has not reported yet.
        case settling
        case ready
        /// This Mac has no light + motion sensors Teachy can read.
        case unavailable
    }

    /// Called on the sensor thread when a tap is recognised.
    var onTap: (@Sendable () -> Void)?
    /// Called on the sensor thread whenever the status changes.
    var onStatusChange: (@Sendable (Status) -> Void)?

    // HID usage values of the sensor processor's devices (vendor page 0xFF00, lid on the sensor page).
    private static let vendorUsagePage = 0xFF00
    private static let accelerometerUsage = 3
    private static let ambientLightUsage = 4
    private static let gyroscopeUsage = 9
    private static let lidSensorUsagePage = 0x20
    private static let lidAngleUsage = 0x8A
    /// Fast motion reporting while running, in microseconds (800 Hz).
    private static let fastMotionReportIntervalInMicroseconds = 1250

    private let stateLock = NSLock()
    private var shouldRun = false
    private var isThreadRunning = false
    private var requestedSensitivity: ScreenTapSensitivity = .standard

    // Owned by the sensor thread only.
    private var recognizer = ScreenTapRecognizer()
    private var openedStreams: [SensorStream] = []
    private var lidAngleDevice: IOHIDDevice?
    private var savedMotionReportIntervals: [(driver: io_service_t, originalInterval: CFTypeRef)] = []
    private var lastPublishedStatus: Status = .stopped

    /// One opened HID device plus the buffer IOKit writes its reports into.
    private final class SensorStream {
        let device: IOHIDDevice
        let usage: Int
        let reportBuffer: UnsafeMutablePointer<UInt8>
        static let reportBufferCapacity = 128
        weak var owner: ScreenTapSensor?

        init(device: IOHIDDevice, usage: Int, owner: ScreenTapSensor) {
            self.device = device
            self.usage = usage
            self.owner = owner
            self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferCapacity)
        }

        deinit { reportBuffer.deallocate() }
    }

    // MARK: - Control (any thread)

    /// True when this Mac exposes all the sensors a tap needs. Cheap; does not open anything.
    static var isSupportedOnThisMac: Bool {
        var foundUsages: Set<Int> = []
        var foundLidSensor = false
        for service in matchingServices(named: "AppleSPUHIDDevice") {
            let usagePage = integerProperty(service, "PrimaryUsagePage")
            let usage = integerProperty(service, "PrimaryUsage")
            if usagePage == vendorUsagePage, [accelerometerUsage, ambientLightUsage, gyroscopeUsage].contains(usage) {
                foundUsages.insert(usage)
            }
            if usagePage == lidSensorUsagePage && usage == lidAngleUsage { foundLidSensor = true }
            IOObjectRelease(service)
        }
        return foundUsages.count == 3 && foundLidSensor
    }

    func start(sensitivity: ScreenTapSensitivity) {
        let shouldLaunchThread: Bool = stateLock.withLock {
            shouldRun = true
            requestedSensitivity = sensitivity
            guard !isThreadRunning else { return false }
            isThreadRunning = true
            return true
        }
        guard shouldLaunchThread else { return }
        let sensorThread = Thread { [self] in runSensorLoop() }
        sensorThread.name = "Teachy screen tap sensor"
        sensorThread.qualityOfService = .utility
        sensorThread.start()
    }

    func updateSensitivity(_ sensitivity: ScreenTapSensitivity) {
        stateLock.withLock { requestedSensitivity = sensitivity }
    }

    /// Asks the thread to close the sensors and exit. Returns at once.
    func stop() {
        stateLock.withLock { shouldRun = false }
    }

    private var currentRequest: (shouldRun: Bool, sensitivity: ScreenTapSensitivity) {
        stateLock.withLock { (shouldRun, requestedSensitivity) }
    }

    // MARK: - Sensor thread

    private func runSensorLoop() {
        publish(.starting)
        if openSensors() {
            var lastLidPollTime = -Double.infinity
            while currentRequest.shouldRun {
                recognizer.sensitivity = currentRequest.sensitivity
                let now = Self.monotonicSeconds()
                if now - lastLidPollTime >= 0.1 {
                    lastLidPollTime = now
                    recognizer.addLidReading(angleInDegrees: readLidAngleInDegrees(), at: now)
                    publish(recognizer.lidGuard.isSettled(at: now) ? .ready : .settling)
                }
                // Lets the HID callbacks run for a short slice, then loops to re-check the request.
                CFRunLoopRunInMode(.defaultMode, 0.05, false)
            }
            closeSensors()
            publish(.stopped)
        } else {
            closeSensors()
            publish(.unavailable)
        }
        let shouldRestart: Bool = stateLock.withLock {
            isThreadRunning = false
            return shouldRun && lastPublishedStatus != .unavailable
        }
        // `start` was called again while this thread was shutting down.
        if shouldRestart { start(sensitivity: currentRequest.sensitivity) }
    }

    private func publish(_ status: Status) {
        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        onStatusChange?(status)
    }

    private func openSensors() -> Bool {
        recognizer.reset()
        for service in Self.matchingServices(named: "AppleSPUHIDDevice") {
            defer { IOObjectRelease(service) }
            let usagePage = Self.integerProperty(service, "PrimaryUsagePage")
            let usage = Self.integerProperty(service, "PrimaryUsage")
            let maximumReportSize = Self.integerProperty(service, "MaxInputReportSize")

            let isMotionStream = usagePage == Self.vendorUsagePage
                && (usage == Self.accelerometerUsage || usage == Self.gyroscopeUsage)
                && maximumReportSize == ScreenTapSensorReportDecoder.motionReportLengthInBytes
            let isLightStream = usagePage == Self.vendorUsagePage && usage == Self.ambientLightUsage
                && maximumReportSize == ScreenTapSensorReportDecoder.ambientLightReportLengthInBytes
            let isLidSensor = usagePage == Self.lidSensorUsagePage && usage == Self.lidAngleUsage

            guard isMotionStream || isLightStream || isLidSensor else { continue }
            if isLidSensor && lidAngleDevice != nil { continue }
            if openedStreams.contains(where: { $0.usage == usage }) { continue }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
                  IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }

            if isLidSensor {
                lidAngleDevice = device
                continue
            }

            let stream = SensorStream(device: device, usage: usage, owner: self)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device, stream.reportBuffer, SensorStream.reportBufferCapacity,
                { context, result, _, _, _, reportPointer, reportLength, _ in
                    guard result == kIOReturnSuccess, let context else { return }
                    let stream = Unmanaged<SensorStream>.fromOpaque(context).takeUnretainedValue()
                    let reportBytes = Array(UnsafeBufferPointer(start: reportPointer, count: reportLength))
                    stream.owner?.handleReport(reportBytes, fromUsage: stream.usage)
                },
                Unmanaged.passUnretained(stream).toOpaque()
            )
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            openedStreams.append(stream)
        }
        guard openedStreams.count == 3, lidAngleDevice != nil else { return false }
        speedUpMotionReporting()
        return true
    }

    private func speedUpMotionReporting() {
        for driver in Self.matchingServices(named: "AppleSPUHIDDriver") {
            let usagePage = Self.integerProperty(driver, "PrimaryUsagePage")
            let usage = Self.integerProperty(driver, "PrimaryUsage")
            guard usagePage == Self.vendorUsagePage,
                  usage == Self.accelerometerUsage || usage == Self.gyroscopeUsage,
                  let originalInterval = IORegistryEntryCreateCFProperty(driver, "ReportInterval" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString,
                                               NSNumber(value: Self.fastMotionReportIntervalInMicroseconds)) == kIOReturnSuccess
            else {
                IOObjectRelease(driver)
                continue
            }
            savedMotionReportIntervals.append((driver, originalInterval))
        }
    }

    private func closeSensors() {
        for stream in openedStreams {
            IOHIDDeviceUnscheduleFromRunLoop(stream.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(stream.device, stream.reportBuffer, SensorStream.reportBufferCapacity, nil, nil)
            IOHIDDeviceClose(stream.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        openedStreams.removeAll()
        if let lidAngleDevice { IOHIDDeviceClose(lidAngleDevice, IOOptionBits(kIOHIDOptionsTypeNone)) }
        lidAngleDevice = nil
        for (driver, originalInterval) in savedMotionReportIntervals {
            // Leave it alone if some other app has since asked for a different rate.
            if Self.integerProperty(driver, "ReportInterval") == Self.fastMotionReportIntervalInMicroseconds {
                IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, originalInterval)
            }
            IOObjectRelease(driver)
        }
        savedMotionReportIntervals.removeAll()
        recognizer.reset()
    }

    /// Runs on the sensor thread (HID callbacks are scheduled on its run loop).
    private func handleReport(_ reportBytes: [UInt8], fromUsage usage: Int) {
        // The report's own timestamp and our clock can disagree on some models;
        // the receive time is consistent across all three streams, which is what matters.
        let receiveTime = Self.monotonicSeconds()
        switch usage {
        case Self.accelerometerUsage:
            if let accelerationInG = ScreenTapSensorReportDecoder.motionVector(fromReportBytes: reportBytes) {
                recognizer.addAccelerometerSample(accelerationInG, at: receiveTime)
            }
        case Self.gyroscopeUsage:
            if let rotation = ScreenTapSensorReportDecoder.motionVector(fromReportBytes: reportBytes) {
                recognizer.addGyroscopeSample(rotation, at: receiveTime)
            }
        case Self.ambientLightUsage:
            if let lux = ScreenTapSensorReportDecoder.ambientLightLux(fromReportBytes: reportBytes),
               recognizer.addAmbientLightSample(lux: lux, at: receiveTime) {
                onTap?()
            }
        default:
            break
        }
    }

    /// Lid angle in degrees, from the lid sensor's feature report. Newer models
    /// answer report 7 with hundredths of a degree; older ones report 1 with whole degrees.
    private func readLidAngleInDegrees() -> Double? {
        guard let lidAngleDevice else { return nil }
        var reportBytes = [UInt8](repeating: 0, count: 8)
        var reportLength = reportBytes.count
        if IOHIDDeviceGetReport(lidAngleDevice, kIOHIDReportTypeFeature, 7, &reportBytes, &reportLength) == kIOReturnSuccess,
           reportLength >= 5, reportBytes[0] == 7 {
            let hundredthsOfDegree = UInt32(reportBytes[1]) | UInt32(reportBytes[2]) << 8
                | UInt32(reportBytes[3]) << 16 | UInt32(reportBytes[4]) << 24
            return Double(hundredthsOfDegree) / 100
        }
        reportLength = reportBytes.count
        if IOHIDDeviceGetReport(lidAngleDevice, kIOHIDReportTypeFeature, 1, &reportBytes, &reportLength) == kIOReturnSuccess,
           reportLength >= 3, reportBytes[0] == 1 {
            return Double(UInt16(reportBytes[1]) | UInt16(reportBytes[2]) << 8)
        }
        return nil
    }

    // MARK: - IOKit helpers

    private static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    private static func integerProperty(_ service: io_service_t, _ propertyName: String) -> Int {
        let propertyValue = IORegistryEntryCreateCFProperty(service, propertyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (propertyValue as? NSNumber)?.intValue ?? -1
    }

    /// The caller owns (and must release) every returned service.
    private static func matchingServices(named serviceClassName: String) -> [io_service_t] {
        var serviceIterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClassName), &serviceIterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(serviceIterator) }
        var services: [io_service_t] = []
        while true {
            let service = IOIteratorNext(serviceIterator)
            guard service != 0 else { break }
            services.append(service)
        }
        return services
    }
}
