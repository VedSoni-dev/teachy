//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    @Published private(set) var isEventTapActive = false

    /// True while the Home tab's "Change" button is waiting for the person to
    /// press their two new keys. Push-to-talk is paused during recording.
    @Published private(set) var isRecordingNewShortcut = false
    /// Keys captured so far during recording, shown live in the UI.
    @Published private(set) var keyCodesRecordedSoFar: [UInt16] = []

    /// The two keys that start push-to-talk. Reloaded whenever the saved shortcut changes.
    private var activeShortcutKeyCodes: [UInt16] = PushToTalkShortcutKeys.currentShortcutKeyCodes
    /// Regular (non-modifier) keys currently held down, from keyDown/keyUp events.
    private var heldRegularKeyCodes: Set<UInt16> = []
    /// Modifier flags from the latest flagsChanged event. Only flagsChanged updates
    /// this, because keyDown events for arrows/F-keys carry a synthetic fn flag.
    private var latestModifierFlags: NSEvent.ModifierFlags = []
    private var shortcutDidChangeObserver: NSObjectProtocol?
    /// While the shortcut is held and includes a regular key, this timer re-checks the
    /// real keyboard state. macOS can withhold the keyUp from the event tap (secure
    /// input in a password field, or the tap being disabled for a timeout), and without
    /// this check push-to-talk would stay on after the person let go.
    private var stuckRegularKeyWatchdogTimer: Timer?
    private static let stuckRegularKeyWatchdogInterval: TimeInterval = 0.15

    init() {
        shortcutDidChangeObserver = NotificationCenter.default.addObserver(
            forName: PushToTalkShortcutKeys.shortcutDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activeShortcutKeyCodes = PushToTalkShortcutKeys.currentShortcutKeyCodes
            self?.releaseShortcutIfPressed()
        }
    }

    deinit {
        if let shortcutDidChangeObserver {
            NotificationCenter.default.removeObserver(shortcutDidChangeObserver)
        }
        stop()
    }

    // MARK: - Recording a new shortcut

    /// Captures the next two distinct keys the person presses and saves them as
    /// the push-to-talk shortcut. Pressing Escape first cancels. Uses the same
    /// global event tap, so it works even though the notch panel never takes focus.
    func beginRecordingNewShortcut() {
        releaseShortcutIfPressed()
        keyCodesRecordedSoFar = []
        isRecordingNewShortcut = true
    }

    func cancelRecordingNewShortcut() {
        isRecordingNewShortcut = false
        keyCodesRecordedSoFar = []
    }

    private func recordKeyPressDuringShortcutRecording(keyCode: UInt16) {
        let normalizedKeyCode = PushToTalkShortcutKeys.normalizedKeyCode(keyCode)

        if normalizedKeyCode == UInt16(kVK_Escape) && keyCodesRecordedSoFar.isEmpty {
            cancelRecordingNewShortcut()
            return
        }
        // Caps Lock toggles rather than being held, so it can't work as push-to-talk.
        guard normalizedKeyCode != UInt16(kVK_CapsLock) else { return }
        guard !keyCodesRecordedSoFar.contains(normalizedKeyCode) else { return }

        keyCodesRecordedSoFar.append(normalizedKeyCode)

        if keyCodesRecordedSoFar.count == PushToTalkShortcutKeys.numberOfKeysInShortcut {
            let newShortcutKeyCodes = keyCodesRecordedSoFar
            isRecordingNewShortcut = false
            PushToTalkShortcutKeys.saveShortcutKeyCodes(newShortcutKeyCodes)
            print("⌨️ Push-to-talk shortcut set to \(PushToTalkShortcutKeys.currentShortcutDisplayText)")
        }
    }

    private func releaseShortcutIfPressed() {
        if isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = false
            stopStuckRegularKeyWatchdog()
            shortcutTransitionPublisher.send(.released)
        }
    }

    // MARK: - Missed keyUp protection

    /// Asks the keyboard hardware whether a key is down right now, independent of
    /// which events reached our tap.
    private func isRegularKeyPhysicallyHeld(_ keyCode: UInt16) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }

    /// Drops any regular key we think is held but the hardware says is up — i.e. its
    /// keyUp never reached the event tap.
    /// `keyCodeJustPressed` is always kept: inside its own keyDown callback the hardware
    /// state may not have caught up yet.
    private func forgetRegularKeysWhoseKeyUpWasMissed(keepingKeyCodeJustPressed keyCodeJustPressed: UInt16? = nil) {
        heldRegularKeyCodes = heldRegularKeyCodes.filter { heldKeyCode in
            heldKeyCode == keyCodeJustPressed || isRegularKeyPhysicallyHeld(heldKeyCode)
        }
    }

    private var activeShortcutIncludesRegularKey: Bool {
        activeShortcutKeyCodes.contains { !PushToTalkShortcutKeys.isModifierKey($0) }
    }

    private func startStuckRegularKeyWatchdogIfNeeded() {
        guard activeShortcutIncludesRegularKey, stuckRegularKeyWatchdogTimer == nil else { return }
        let watchdogTimer = Timer(timeInterval: Self.stuckRegularKeyWatchdogInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.forgetRegularKeysWhoseKeyUpWasMissed()
            self.updateShortcutPressedState()
        }
        // .common so the check keeps running while menus or tracking loops are active.
        RunLoop.main.add(watchdogTimer, forMode: .common)
        stuckRegularKeyWatchdogTimer = watchdogTimer
    }

    private func stopStuckRegularKeyWatchdog() {
        stuckRegularKeyWatchdogTimer?.invalidate()
        stuckRegularKeyWatchdogTimer = nil
    }

    /// Sends .pressed / .released when the "both shortcut keys held" state changes.
    private func updateShortcutPressedState() {
        let areAllShortcutKeysHeld = activeShortcutKeyCodes.allSatisfy { shortcutKeyCode in
            if let shortcutModifierFlag = PushToTalkShortcutKeys.modifierFlag(forKeyCode: shortcutKeyCode) {
                return latestModifierFlags.contains(shortcutModifierFlag)
            }
            return heldRegularKeyCodes.contains(shortcutKeyCode)
        }

        if areAllShortcutKeysHeld && !isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = true
            startStuckRegularKeyWatchdogIfNeeded()
            shortcutTransitionPublisher.send(.pressed)
        } else if !areAllShortcutKeysHeld && isShortcutCurrentlyPressed {
            releaseShortcutIfPressed()
        }
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        guard WindowPositionManager.hasAccessibilityPermission() else {
            print("⚠️ Global push-to-talk: accessibility permission required")
            isEventTapActive = false
            return
        }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        // HID-level tap receives modifier keys globally, even when another app is focused.
        let globalEventTap = createGlobalEventTap(eventMask: eventMask, callback: eventTapCallback)

        guard let globalEventTap else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap — grant Accessibility in System Settings")
            isEventTapActive = false
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            isEventTapActive = false
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        isEventTapActive = true
        print("⌨️ Global push-to-talk monitor active (\(PushToTalkShortcutKeys.currentShortcutDisplayText))")
    }

    func stop() {
        stopStuckRegularKeyWatchdog()
        isShortcutCurrentlyPressed = false
        heldRegularKeyCodes = []
        latestModifierFlags = []
        isEventTapActive = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func createGlobalEventTap(
        eventMask: CGEventMask,
        callback: @escaping CGEventTapCallBack
    ) -> CFMachPort? {
        let tapLocations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]

        for tapLocation in tapLocations {
            if let eventTap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                print("⌨️ Global push-to-talk using \(tapLocation == .cghidEventTap ? "HID" : "session") event tap")
                return eventTap
            }
        }

        return nil
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            // keyUps sent while the tap was off are gone; re-sync with the hardware.
            if !isRecordingNewShortcut {
                forgetRegularKeysWhoseKeyUpWasMissed()
                updateShortcutPressedState()
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutoRepeatKeyDown = eventType == .keyDown
            && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let previousModifierFlags = latestModifierFlags

        switch eventType {
        case .flagsChanged:
            latestModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
        case .keyDown:
            heldRegularKeyCodes.insert(eventKeyCode)
        case .keyUp:
            heldRegularKeyCodes.remove(eventKeyCode)
        default:
            return Unmanaged.passUnretained(event)
        }

        if isRecordingNewShortcut {
            if eventType == .keyDown && !isAutoRepeatKeyDown {
                recordKeyPressDuringShortcutRecording(keyCode: eventKeyCode)
            } else if eventType == .flagsChanged,
                      let changedModifierFlag = PushToTalkShortcutKeys.modifierFlag(forKeyCode: eventKeyCode),
                      latestModifierFlags.contains(changedModifierFlag),
                      !previousModifierFlags.contains(changedModifierFlag) {
                // A modifier went down (flagsChanged also fires on release, which we skip).
                recordKeyPressDuringShortcutRecording(keyCode: eventKeyCode)
            }
            return Unmanaged.passUnretained(event)
        }

        // A keyUp missed earlier would otherwise leave a stale key "held" and let the
        // next press of just the other key start push-to-talk.
        forgetRegularKeysWhoseKeyUpWasMissed(
            keepingKeyCodeJustPressed: eventType == .keyDown ? eventKeyCode : nil
        )
        updateShortcutPressedState()

        return Unmanaged.passUnretained(event)
    }
}
