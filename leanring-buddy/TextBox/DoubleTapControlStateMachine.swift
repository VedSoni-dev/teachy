//
//  DoubleTapControlStateMachine.swift
//  leanring-buddy
//
//  Decides when Control was double-tapped (the text box shortcut). Pure logic:
//  the event tap feeds modifier changes and other input with timestamps, and
//  `handle` returns true on the release of the second clean tap.
//
//  A clean tap is: no modifiers held, then Control alone goes down and comes back
//  up quickly, with no key, click or scroll in between. So these never fire it:
//  Control+C, Control+Option (push-to-talk), Fn+Control (dictation), Control+click,
//  Control+scroll, or holding Control.
//

import CoreGraphics
import Foundation

nonisolated struct DoubleTapControlStateMachine {
    enum Event: Equatable {
        /// The modifier keys changed. `flagsRawValue` is `CGEventFlags.rawValue`.
        case modifiersChanged(flagsRawValue: UInt64)
        /// A non-modifier key went down, a mouse button went down, or the wheel scrolled.
        case otherInput
    }

    struct Configuration: Equatable {
        /// Control held longer than this is a hold, not a tap.
        var tapMaximumDuration: TimeInterval = 0.30
        /// The second tap must start within this long after the first tap ends.
        var doubleTapGap: TimeInterval = 0.35
    }

    enum State: Equatable {
        case idle
        case firstDown(at: TimeInterval)
        case firstUp(at: TimeInterval)
        case secondDown(at: TimeInterval)
        /// Something else is going on (another modifier, a key, a long hold).
        /// Nothing counts until every modifier is released.
        case blocked
    }

    // CGEventFlags raw values (numbers so this file needs no CoreGraphics).
    static let shiftMask: UInt64 = 0x0002_0000
    static let controlMask: UInt64 = 0x0004_0000
    static let optionMask: UInt64 = 0x0008_0000
    static let commandMask: UInt64 = 0x0010_0000
    static let functionMask: UInt64 = 0x0080_0000
    /// Caps Lock and the other bits are ignored on purpose.
    static let modifierMask = shiftMask | controlMask | optionMask | commandMask | functionMask

    private(set) var state: State = .idle
    private var isControlDown = false
    var configuration = Configuration()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        state = .idle
        isControlDown = false
    }

    /// Returns true when this event completes a double-tap.
    mutating func handle(_ event: Event, at now: TimeInterval) -> Bool {
        switch event {
        case .otherInput:
            // Typing or clicking cancels a tap in progress. With Control still
            // down (Control+C) stay blocked until it is released.
            if state != .idle { state = isControlDown ? .blocked : .idle }
            return false

        case .modifiersChanged(let flagsRawValue):
            let held = flagsRawValue & Self.modifierMask
            isControlDown = held & Self.controlMask != 0

            if held == 0 { return allReleased(at: now) }
            if held == Self.controlMask { controlAloneDown(at: now); return false }
            // Any other modifier, alone or with Control.
            state = .blocked
            return false
        }
    }

    private mutating func controlAloneDown(at now: TimeInterval) {
        switch state {
        case .idle:
            state = .firstDown(at: now)
        case .firstUp(let releasedAt):
            // Too late for a second tap: this is a new first tap.
            state = now - releasedAt <= configuration.doubleTapGap ? .secondDown(at: now) : .firstDown(at: now)
        case .firstDown, .secondDown:
            // The other Control key joined, or a repeated event. Keep the original time.
            break
        case .blocked:
            // For example Option was released while Control is still held.
            break
        }
    }

    private mutating func allReleased(at now: TimeInterval) -> Bool {
        switch state {
        case .firstDown(let downAt):
            state = now - downAt <= configuration.tapMaximumDuration ? .firstUp(at: now) : .idle
            return false
        case .secondDown(let downAt):
            state = .idle
            return now - downAt <= configuration.tapMaximumDuration
        case .firstUp:
            return false
        case .idle, .blocked:
            state = .idle
            return false
        }
    }
}

/// Where the text box goes: just below and to the right of the pointer, moved
/// as needed to stay fully on the screen. AppKit coordinates (origin bottom-left).
nonisolated enum TextBoxPlacement {
    static func origin(
        cursor: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        offset: CGSize = CGSize(width: 14, height: 18),
        margin: CGFloat = 10
    ) -> CGPoint {
        var x = cursor.x + offset.width
        // The panel's top edge sits `offset.height` below the pointer.
        var y = cursor.y - offset.height - panelSize.height
        // Not enough room below: go above the pointer instead.
        if y < visibleFrame.minY + margin { y = cursor.y + offset.height }
        // Not enough room on the right: go to the left of the pointer.
        if x + panelSize.width > visibleFrame.maxX - margin { x = cursor.x - offset.width - panelSize.width }
        let lowestX = visibleFrame.minX + margin
        let lowestY = visibleFrame.minY + margin
        x = min(max(x, lowestX), max(lowestX, visibleFrame.maxX - margin - panelSize.width))
        y = min(max(y, lowestY), max(lowestY, visibleFrame.maxY - margin - panelSize.height))
        return CGPoint(x: x, y: y)
    }
}
