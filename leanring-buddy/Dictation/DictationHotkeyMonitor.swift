//
//  DictationHotkeyMonitor.swift
//  leanring-buddy
//
//  A second listen-only CGEvent tap, separate from GlobalPushToTalkShortcutMonitor,
//  that watches `.flagsChanged` for Fn+Control and `.keyDown` for Escape. It never
//  changes or swallows an event, so the Control+Option push-to-talk and the app in
//  front see exactly what they saw before.
//

import AppKit
import CoreGraphics
import Foundation

final class DictationHotkeyMonitor {
    /// Stamped on the Command+V this app synthesizes so the tap ignores it.
    nonisolated static let syntheticEventMarker: Int64 = 0x7EAC_D1C7

    /// Called on the main thread with each key edge and the time it happened.
    var onEvent: ((DictationHotkeyStateMachine.Event, TimeInterval) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isChordHeld = false

    var isRunning: Bool { eventTap != nil }

    /// Returns false when the tap can't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let monitor = Unmanaged<DictationHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
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
        print("⌨️ Dictation hotkey monitor active (fn + control)")
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        isChordHeld = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            // Key edges may have been missed while the tap was off.
            if isChordHeld {
                isChordHeld = false
                onEvent?(.chordUp, now)
            }

        case .flagsChanged:
            let held = DictationChord.isHeld(flagsRawValue: event.flags.rawValue)
            guard held != isChordHeld else { return }
            isChordHeld = held
            onEvent?(held ? .chordDown : .chordUp, now)

        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else { return }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            onEvent?(keyCode == 53 ? .escape : .otherKeyDown, now)

        default:
            break
        }
    }
}
