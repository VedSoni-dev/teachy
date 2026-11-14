//
//  DictationHotkeyMonitor.swift
//  leanring-buddy
//
//  A second CGEvent tap, separate from GlobalPushToTalkShortcutMonitor, that watches
//  for the dictation shortcut (DictationShortcut: Fn+Control by default, or whatever
//  the person recorded) and for Escape. It passes every event through untouched,
//  except the shortcut's own non-modifier key (so Control+D doesn't also type "d")
//  and keys pressed while a new shortcut is being recorded.
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
    private var heldModifiers = Set<UInt16>()
    private var heldOtherKeys = Set<UInt16>()
    private var shortcut = DictationShortcut.current()
    private var shortcutObserver: NSObjectProtocol?

    // Recording a new shortcut
    private var recordingCompletion: (([UInt16]?) -> Void)?
    private var recordedKeys: [UInt16] = []

    var isRunning: Bool { eventTap != nil }
    var isRecordingShortcut: Bool { recordingCompletion != nil }

    /// Returns false when the tap can't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DictationHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's source is on the main run loop, so this is the main thread.
            let shouldSwallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return shouldSwallow ? nil : Unmanaged.passUnretained(event)
        }

        // An active tap (not listen-only) so a shortcut that includes a normal key, like
        // Control+D or F5, doesn't also type that key into the app in front.
        var createdTap: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            createdTap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
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
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: DictationShortcut.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadShortcut() }
        }
        print("⌨️ Dictation hotkey monitor active (key codes \(shortcut))")
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
        shortcutObserver = nil
        runLoopSource = nil
        eventTap = nil
        resetHeldKeys()
    }

    private func reloadShortcut() {
        shortcut = DictationShortcut.current()
        resetHeldKeys()
    }

    private func resetHeldKeys() {
        heldModifiers = []
        heldOtherKeys = []
        if isChordHeld {
            isChordHeld = false
            onEvent?(.chordUp, ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: - Recording a new shortcut

    /// The next keys held together become the result: completion gets them once every key
    /// is released, or nil if the person pressed Escape. Key presses are kept from other
    /// apps while recording.
    func beginRecordingShortcut(completion: @escaping ([UInt16]?) -> Void) {
        cancelRecordingShortcut()
        recordedKeys = []
        heldModifiers = []
        heldOtherKeys = []
        recordingCompletion = completion
    }

    func cancelRecordingShortcut() {
        guard let completion = recordingCompletion else { return }
        recordingCompletion = nil
        recordedKeys = []
        completion(nil)
    }

    private func finishRecording(with keys: [UInt16]?) {
        guard let completion = recordingCompletion else { return }
        recordingCompletion = nil
        recordedKeys = []
        heldModifiers = []
        heldOtherKeys = []
        completion(keys)
    }

    /// Returns true when the event should be kept from the app in front.
    private func handleWhileRecording(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = DictationShortcut.normalized(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
        switch type {
        case .flagsChanged:
            heldModifiers = DictationShortcut.heldModifiers(flagsRawValue: event.flags.rawValue)
            for modifier in heldModifiers where !recordedKeys.contains(modifier) { recordedKeys.append(modifier) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
            if keyCode == DictationShortcut.escapeKey, heldModifiers.isEmpty, heldOtherKeys.isEmpty {
                finishRecording(with: nil)
                return true
            }
            heldOtherKeys.insert(keyCode)
            if !recordedKeys.contains(keyCode) { recordedKeys.append(keyCode) }
            return true
        case .keyUp:
            heldOtherKeys.remove(keyCode)
        default:
            return false
        }
        if heldModifiers.isEmpty, heldOtherKeys.isEmpty, !recordedKeys.isEmpty {
            finishRecording(with: DictationShortcut.orderedForDisplay(recordedKeys))
        }
        return type != .flagsChanged
    }

    // MARK: - Events

    /// Returns true when the event should be kept from the app in front.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            // Key edges may have been missed while the tap was off.
            resetHeldKeys()
            return false
        }
        // Never react to the Command+V this app types to paste dictated text.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker { return false }
        if isRecordingShortcut { return handleWhileRecording(type: type, event: event) }

        let keyCode = DictationShortcut.normalized(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
        let shortcutOtherKey = DictationShortcut.otherKey(of: shortcut)
        var shouldSwallow = false

        switch type {
        case .flagsChanged:
            heldModifiers = DictationShortcut.heldModifiers(flagsRawValue: event.flags.rawValue)
            if heldModifiers.isEmpty { heldOtherKeys = heldOtherKeys.intersection(shortcutOtherKey.map { [$0] } ?? []) }

        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if keyCode == shortcutOtherKey {
                let wantedModifiers = Set(shortcut.map(DictationShortcut.normalized).filter(DictationShortcut.isModifier))
                // Only claim the key when the shortcut's own modifiers (and no others) are down.
                guard heldModifiers == wantedModifiers else { break }
                heldOtherKeys.insert(keyCode)
                shouldSwallow = true
            } else if !isRepeat {
                onEvent?(keyCode == DictationShortcut.escapeKey ? .escape : .otherKeyDown, now)
            }

        case .keyUp:
            if keyCode == shortcutOtherKey, heldOtherKeys.contains(keyCode) {
                heldOtherKeys.remove(keyCode)
                shouldSwallow = true
            }

        default:
            return false
        }

        let held = DictationShortcut.isHeld(shortcut: shortcut, heldModifiers: heldModifiers, heldOtherKeys: heldOtherKeys)
        if held != isChordHeld {
            isChordHeld = held
            onEvent?(held ? .chordDown : .chordUp, now)
        }
        return shouldSwallow
    }
}
