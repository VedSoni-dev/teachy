//
//  ControlTapCountStateMachine.swift
//  leanring-buddy
//
//  Counts clean taps of Control: two open the text box, three switch always-on
//  (hands-free) mode. Pure logic, same rules for a "clean tap" as
//  `DoubleTapControlStateMachine`: Control alone goes down and comes back up
//  quickly, with no other key, modifier, click or scroll in between.
//
//  Two taps and three taps start the same way, so one of two rules must apply
//  (`Configuration.doubleTapRule`):
//  - `.immediate` (the default): the double tap is reported on the second release,
//    exactly when it is today, so the text box still opens instantly. If a third tap
//    follows, a triple tap is reported too and the host undoes the double (closes
//    the text box it just opened).
//  - `.waitForPossibleThird`: nothing is reported on the second release. The double
//    tap is reported by `poll(at:)` once the gap has passed with no third tap.
//    Nothing ever needs undoing, but the text box opens about a third of a second
//    later.
//  After a triple tap, more taps in the same burst are ignored.
//

import Foundation

nonisolated struct ControlTapCountStateMachine {
    enum Event: Equatable {
        /// The modifier keys changed. `flagsRawValue` is `CGEventFlags.rawValue`.
        case modifiersChanged(flagsRawValue: UInt64)
        /// A non-modifier key went down, a mouse button went down, or the wheel scrolled.
        case otherInput
    }

    enum Output: Equatable {
        case doubleTap
        case tripleTap
    }

    enum DoubleTapRule: Equatable {
        case immediate
        case waitForPossibleThird
    }

    struct Configuration: Equatable {
        /// Control held longer than this is a hold, not a tap.
        var tapMaximumDuration: TimeInterval = 0.30
        /// The next tap must start within this long after the last one ended.
        var tapGap: TimeInterval = 0.35
        var doubleTapRule: DoubleTapRule = .immediate
    }

    private enum State: Equatable {
        case idle
        /// Control is down for tap number `count` (1, 2 or 3).
        case down(count: Int, at: TimeInterval)
        /// Tap number `count` (1 or 2) has ended; waiting to see if another follows.
        case up(count: Int, at: TimeInterval)
        /// A triple tap was reported; ignore taps until the burst is over.
        case burstFinished(lastActivityAt: TimeInterval, isDown: Bool)
        /// Something else is going on. Nothing counts until every modifier is released.
        case blocked
    }

    // CGEventFlags raw values (numbers so this file needs no CoreGraphics).
    static let shiftMask: UInt64 = 0x0002_0000
    static let controlMask: UInt64 = 0x0004_0000
    static let optionMask: UInt64 = 0x0008_0000
    static let commandMask: UInt64 = 0x0010_0000
    static let functionMask: UInt64 = 0x0080_0000
    static let modifierMask = shiftMask | controlMask | optionMask | commandMask | functionMask

    var configuration: Configuration
    private var state: State = .idle
    private var isControlDown = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        state = .idle
        isControlDown = false
    }

    /// With `.waitForPossibleThird`: the time at which `poll(at:)` should be called
    /// because a double tap is waiting to be confirmed. Nil when nothing is waiting.
    var pendingDoubleTapDeadline: TimeInterval? {
        guard configuration.doubleTapRule == .waitForPossibleThird,
              case .up(count: 2, let releasedAt) = state else { return nil }
        return releasedAt + configuration.tapGap
    }

    /// Call at (or after) `pendingDoubleTapDeadline`. Reports the double tap if no third tap began.
    mutating func poll(at now: TimeInterval) -> Output? {
        guard let deadline = pendingDoubleTapDeadline, now >= deadline else { return nil }
        state = .idle
        return .doubleTap
    }

    mutating func handle(_ event: Event, at now: TimeInterval) -> Output? {
        switch event {
        case .otherInput:
            // A waiting double tap is still a double tap: the person tapped twice and
            // started typing before the wait was over.
            let confirmed = confirmWaitingDoubleTap()
            if state != .idle { state = isControlDown ? .blocked : .idle }
            return confirmed

        case .modifiersChanged(let flagsRawValue):
            let held = flagsRawValue & Self.modifierMask
            isControlDown = held & Self.controlMask != 0
            if held == 0 { return allReleased(at: now) }
            if held == Self.controlMask { return controlAloneDown(at: now) }
            // Any other modifier, alone or with Control.
            let confirmed = confirmWaitingDoubleTap()
            state = .blocked
            return confirmed
        }
    }

    private mutating func confirmWaitingDoubleTap() -> Output? {
        guard configuration.doubleTapRule == .waitForPossibleThird, case .up(count: 2, _) = state else { return nil }
        state = .idle
        return .doubleTap
    }

    private mutating func controlAloneDown(at now: TimeInterval) -> Output? {
        switch state {
        case .idle:
            state = .down(count: 1, at: now)
        case .up(let count, let releasedAt):
            if now - releasedAt <= configuration.tapGap {
                state = .down(count: count + 1, at: now)
            } else {
                // Too late to continue the burst: this is a new first tap. A double
                // tap that was waiting has passed its deadline, so report it now.
                let confirmed = confirmWaitingDoubleTap()
                state = .down(count: 1, at: now)
                return confirmed
            }
        case .burstFinished(let lastActivityAt, _):
            state = now - lastActivityAt <= configuration.tapGap
                ? .burstFinished(lastActivityAt: now, isDown: true)
                : .down(count: 1, at: now)
        case .down, .blocked:
            // The other Control key joined, a repeated event, or Option was released
            // while Control is still held.
            break
        }
        return nil
    }

    private mutating func allReleased(at now: TimeInterval) -> Output? {
        switch state {
        case .down(let count, let downAt):
            guard now - downAt <= configuration.tapMaximumDuration else {
                // A hold. A double tap that came before it still stands.
                if count == 3, configuration.doubleTapRule == .waitForPossibleThird {
                    state = .idle
                    return .doubleTap
                }
                state = .idle
                return nil
            }
            switch count {
            case 1:
                state = .up(count: 1, at: now)
                return nil
            case 2:
                state = .up(count: 2, at: now)
                return configuration.doubleTapRule == .immediate ? .doubleTap : nil
            default:
                state = .burstFinished(lastActivityAt: now, isDown: false)
                return .tripleTap
            }
        case .burstFinished(_, let isDown):
            state = isDown ? .burstFinished(lastActivityAt: now, isDown: false) : state
            return nil
        case .up:
            return nil
        case .idle, .blocked:
            state = .idle
            return nil
        }
    }
}
