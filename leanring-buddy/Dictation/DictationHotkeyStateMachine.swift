//
//  DictationHotkeyStateMachine.swift
//  leanring-buddy
//
//  Turns raw Fn+Control key edges (with timestamps) into dictation actions:
//  hold = dictate while held, double-tap = hands-free, double-tap again = stop,
//  Escape = cancel. Pure logic: no AppKit, no timers. The driver feeds events
//  and calls `handle(.tick, at:)` when `deadline` passes.
//

import Foundation

/// Which modifier combination counts as the dictation chord.
nonisolated enum DictationChord {
    // CGEventFlags raw values (kept as numbers so this file needs no CoreGraphics).
    static let shiftMask: UInt64 = 0x0002_0000
    static let controlMask: UInt64 = 0x0004_0000
    static let optionMask: UInt64 = 0x0008_0000
    static let commandMask: UInt64 = 0x0010_0000
    static let functionMask: UInt64 = 0x0080_0000

    /// True when exactly Fn + Control are held. Any extra modifier (Option, Command,
    /// Shift) means the person is pressing some other shortcut, notably the
    /// Control+Option push-to-talk, so the chord is treated as not held.
    static func isHeld(flagsRawValue: UInt64) -> Bool {
        let required = functionMask | controlMask
        let forbidden = optionMask | commandMask | shiftMask
        return flagsRawValue & required == required && flagsRawValue & forbidden == 0
    }
}

nonisolated struct DictationHotkeyStateMachine {
    enum Event: Equatable {
        case chordDown
        case chordUp
        case escape
        /// Any other key went down. During a hold this means the person is using a
        /// Fn+Control keyboard shortcut, not dictating.
        case otherKeyDown
        /// Time passed; lets pending double-tap windows expire.
        case tick
    }

    enum Action: Equatable {
        case startRecording
        case enterHandsFree
        case finish
        case cancel
    }

    enum HandsFreePhase: Equatable {
        /// The second tap of the starting double-tap is still held.
        case entering
        case listening
        case stopTapDown(at: TimeInterval)
        case stopTapPending(releasedAt: TimeInterval)
    }

    enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        /// One quick tap happened. Recording keeps running in case a second tap follows.
        case tapPending(releasedAt: TimeInterval)
        case handsFree(HandsFreePhase)
    }

    struct Configuration: Equatable {
        /// A press shorter than this is a tap, not a hold.
        var tapMaximumDuration: TimeInterval = 0.35
        /// The second tap must begin within this long after the first tap ends.
        var doubleTapGap: TimeInterval = 0.40
    }

    private(set) var state: State = .idle
    var configuration = Configuration()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isRecording: Bool { state != .idle }

    /// When the driver should send a `.tick` (nil = nothing pending).
    var deadline: TimeInterval? {
        switch state {
        case .tapPending(let releasedAt), .handsFree(.stopTapPending(let releasedAt)):
            return releasedAt + configuration.doubleTapGap
        default:
            return nil
        }
    }

    mutating func reset() { state = .idle }

    mutating func handle(_ event: Event, at now: TimeInterval) -> [Action] {
        var actions = expirePendingWindows(at: now)
        actions.append(contentsOf: apply(event, at: now))
        return actions
    }

    private mutating func expirePendingWindows(at now: TimeInterval) -> [Action] {
        guard let deadline, now > deadline else { return [] }
        switch state {
        case .tapPending:
            // A single quick tap with no second tap: end it. The silence gate
            // decides whether anything was actually said.
            state = .idle
            return [.finish]
        case .handsFree(.stopTapPending):
            state = .handsFree(.listening)
            return []
        default:
            return []
        }
    }

    private mutating func apply(_ event: Event, at now: TimeInterval) -> [Action] {
        switch (state, event) {
        case (_, .tick):
            return []

        case (.idle, .chordDown):
            state = .holding(since: now)
            return [.startRecording]
        case (.idle, _):
            return []

        case (.holding(let since), .chordUp):
            if now - since <= configuration.tapMaximumDuration {
                state = .tapPending(releasedAt: now)
                return []
            }
            state = .idle
            return [.finish]
        case (.holding, .escape), (.holding, .otherKeyDown):
            state = .idle
            return [.cancel]
        case (.holding, .chordDown):
            return []

        case (.tapPending, .chordDown):
            // Still inside the window (expiry ran first), so this is a double-tap.
            state = .handsFree(.entering)
            return [.enterHandsFree]
        case (.tapPending, .escape), (.tapPending, .otherKeyDown):
            state = .idle
            return [.cancel]
        case (.tapPending, .chordUp):
            return []

        case (.handsFree, .escape):
            state = .idle
            return [.cancel]
        case (.handsFree, .otherKeyDown):
            // Typing while hands-free is fine.
            return []
        case (.handsFree(.entering), .chordUp):
            state = .handsFree(.listening)
            return []
        case (.handsFree(.entering), .chordDown):
            return []
        case (.handsFree(.listening), .chordDown):
            state = .handsFree(.stopTapDown(at: now))
            return []
        case (.handsFree(.listening), .chordUp):
            return []
        case (.handsFree(.stopTapDown(let downAt)), .chordUp):
            state = now - downAt <= configuration.tapMaximumDuration
                ? .handsFree(.stopTapPending(releasedAt: now))
                : .handsFree(.listening)
            return []
        case (.handsFree(.stopTapDown), .chordDown):
            return []
        case (.handsFree(.stopTapPending), .chordDown):
            state = .idle
            return [.finish]
        case (.handsFree(.stopTapPending), .chordUp):
            return []
        }
    }
}
