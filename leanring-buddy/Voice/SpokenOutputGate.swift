//
//  SpokenOutputGate.swift
//  leanring-buddy
//
//  Asked by `LocalSpeechSynthesizer` at the start of every reply: speak it, or stay
//  silent and show it instead? Silent when the Mac is muted (the answer would go
//  nowhere) and when the person is on a call (unless they held the talk key, which
//  is asking to be answered aloud). A silent reply is shown as captions and its
//  text is put on the clipboard. The rule itself is `SpokenOutputDecision.decide`.
//

import AppKit
import Combine
import Foundation

@MainActor
final class SpokenOutputGate: ObservableObject {
    static let shared = SpokenOutputGate()

    /// Why the last reply was not spoken, or nil if it was. For a hint in the UI.
    @Published private(set) var lastSilentReason: SpokenOutputDecision.Reason?

    /// Until when a reply counts as "asked for with the talk key".
    private var talkKeyReplyDeadline: Date?
    private static let talkKeyWindowSeconds: TimeInterval = 90

    private init() {}

    /// Call when the push-to-talk key goes down: the reply to this question is spoken even on a call.
    func noteTalkKeyPressed() {
        talkKeyReplyDeadline = Date().addingTimeInterval(Self.talkKeyWindowSeconds)
    }

    /// Call when a question arrives another way (always-on, the text box): the talk-key
    /// exception no longer applies.
    func noteQuestionWithoutTalkKey() {
        talkKeyReplyDeadline = nil
    }

    private var talkKeyPressedForThisReply: Bool {
        guard let talkKeyReplyDeadline else { return false }
        return Date() < talkKeyReplyDeadline
    }

    /// Looks at the Mac right now and decides for the reply that is about to start.
    func decideForNextReply() -> SpokenOutputDecision {
        // Test hook used by timing harnesses: always "speak" (into a silenced mixer).
        if ProcessInfo.processInfo.environment["TEACHY_SILENT_AUDIO"] != nil { return .speak }
        let decision = SpokenOutputDecision.decide(
            outputIsSilent: AudioHardware.isOutputSilent,
            isInCall: CallDetector.shared.refresh(),
            quietOnCallsEnabled: TeachySettingsStorage.quietOnCallsEnabled(),
            talkKeyPressedForThisReply: talkKeyPressedForThisReply
        )
        if case .captionsAndClipboard(let reason) = decision {
            lastSilentReason = reason
            print("🔇 Not speaking this reply (\(reason.rawValue)); showing captions and copying it instead")
        } else {
            lastSilentReason = nil
        }
        return decision
    }

    /// Puts a silent reply on the clipboard, unless something else was copied since the
    /// reply began (for example a prompt the reply itself placed there).
    func copyReplyToClipboard(_ text: String, ifPasteboardUnchangedSince changeCount: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NSPasteboard.general.changeCount == changeCount else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
    }
}
