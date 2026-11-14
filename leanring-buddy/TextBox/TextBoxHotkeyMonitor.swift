//
//  TextBoxHotkeyMonitor.swift
//  leanring-buddy
//
//  A listen-only CGEvent tap that watches for a double-tap of Control and calls
//  `onDoubleTap`. It never changes or swallows an event, so push-to-talk,
//  dictation and the app in front see exactly what they saw before. The
//  decision itself is `DoubleTapControlStateMachine`.
//

import AppKit
import CoreGraphics
import Foundation

final class TextBoxHotkeyMonitor {
    /// Called on the main thread when Control is double-tapped.
    var onDoubleTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine = DoubleTapControlStateMachine()

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
                let monitor = Unmanaged<TextBoxHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
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
        print("⌨️ Text box hotkey monitor active (double-tap control)")
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
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
            if stateMachine.handle(.modifiersChanged(flagsRawValue: event.flags.rawValue), at: now) {
                onDoubleTap?()
            }

        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            _ = stateMachine.handle(.otherInput, at: now)

        default:
            break
        }
    }
}
