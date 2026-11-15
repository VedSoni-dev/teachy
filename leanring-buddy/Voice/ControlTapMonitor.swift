//
//  ControlTapMonitor.swift
//  leanring-buddy
//
//  A listen-only CGEvent tap that counts clean taps of Control: `onDoubleTap` (the
//  text box) and `onTripleTap` (always-on mode). It never changes or swallows an
//  event. The counting is `ControlTapCountStateMachine`.
//
//  It has the same `start()`, `stop()`, `isRunning` and `onDoubleTap` as
//  `TextBoxHotkeyMonitor`, so it can take that monitor's place and be the one tap
//  that serves both shortcuts. Used on its own next to the text box monitor, leave
//  `onDoubleTap` nil and only the triple tap is acted on.
//

import AppKit
import CoreGraphics
import Foundation

final class ControlTapMonitor {
    /// Called on the main thread when Control is tapped twice.
    var onDoubleTap: (() -> Void)?
    /// Called on the main thread when Control is tapped three times.
    var onTripleTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine: ControlTapCountStateMachine
    private var pendingDoubleTapTimer: Timer?

    init(doubleTapRule: ControlTapCountStateMachine.DoubleTapRule = .immediate) {
        var configuration = ControlTapCountStateMachine.Configuration()
        configuration.doubleTapRule = doubleTapRule
        stateMachine = ControlTapCountStateMachine(configuration: configuration)
    }

    var isRunning: Bool { eventTap != nil }

    /// Returns false when the tap can't be created (Accessibility not granted).
    /// Never asks for permission.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let watched: [CGEventType] = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        let mask = watched.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let monitor = Unmanaged<ControlTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // The tap's source is on the main run loop, so this is the main thread.
                MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        var createdTap: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            createdTap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            if createdTap != nil { break }
        }
        guard let createdTap,
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
        else {
            if let createdTap { CFMachPortInvalidate(createdTap) }
            return false
        }

        eventTap = createdTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        print("⌨️ Control tap monitor active (triple-tap control = always-on)")
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        pendingDoubleTapTimer?.invalidate()
        pendingDoubleTapTimer = nil
        stateMachine.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            // Key edges may have been missed while the tap was off.
            stateMachine.reset()

        case .flagsChanged:
            deliver(stateMachine.handle(.modifiersChanged(flagsRawValue: event.flags.rawValue), at: now))

        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            deliver(stateMachine.handle(.otherInput, at: now))

        default:
            break
        }
        schedulePendingDoubleTap(now: now)
    }

    private func deliver(_ output: ControlTapCountStateMachine.Output?) {
        switch output {
        case .doubleTap: onDoubleTap?()
        case .tripleTap: onTripleTap?()
        case nil: break
        }
    }

    /// With the "wait for a possible third tap" rule, the double tap is confirmed by a timer.
    private func schedulePendingDoubleTap(now: TimeInterval) {
        pendingDoubleTapTimer?.invalidate()
        pendingDoubleTapTimer = nil
        guard let deadline = stateMachine.pendingDoubleTapDeadline else { return }
        let timer = Timer(timeInterval: max(0.01, deadline - now + 0.005), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deliver(self.stateMachine.poll(at: ProcessInfo.processInfo.systemUptime))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingDoubleTapTimer = timer
    }
}
