//
//  ScreenAwareWriter.swift
//  leanring-buddy
//
//  "Write it for me": the person says what they want written ("type a reply to
//  this person saying thanks and ask about his use cases"), Teachy reads the
//  screen, drafts it in their voice from memory, and types it into the focused
//  field. One model call through TeachyAIRouter, then DictationTextInserter.
//
//  Job `.voice` (smart tier, minimal effort). Measured 14 Nov 2026 on seven
//  synthetic screens (email, Slack thread, terminal commit, coding agent,
//  LinkedIn, form field, Spanish email): 1.6 to 3.2 s per draft, against 2.7 to
//  7.0 s for job `.write` (balanced tier), with drafts at least as good.
//  The voice turn calls `writeAndInsert` when the model emits
//  [WRITE: instruction] (rule text: `WritingPrompt.voicePromptRule`).
//

import AppKit
import ApplicationServices
import Foundation

enum WriteOutcome: Equatable {
    /// Typed or pasted into the focused field.
    case inserted(String)
    /// No text field was in focus (or the insertion failed); the text is on the clipboard.
    case copiedToClipboard(String)
    case failed(message: String)

    /// One short line for the voice to say.
    var spokenLine: String {
        switch self {
        case .inserted: return "I pasted your reply."
        case .copiedToClipboard: return "I couldn't find a text field, so it's on your clipboard."
        case .failed(let message): return message
        }
    }
}

@MainActor
final class ScreenAwareWriter {
    static let shared = ScreenAwareWriter()

    static let job: TeachyAIJob = .voice
    static let timeoutSeconds: TimeInterval = 25

    struct WriterError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init() {}

    /// The text the last [WRITE:] typed, so "Make it shorter" can rewrite it where it sits.
    private(set) var lastInsertedText: String?

    /// Rewrites the text Teachy typed last, in place: finds it in the focused field, asks the
    /// model for the new version and replaces just that part. If the field no longer holds it
    /// (the person edited it, or moved to another field), the new version goes on the clipboard.
    func rewriteLastWriting(change: String) async -> WriteOutcome {
        guard let originalText = lastInsertedText else {
            return .failed(message: "I don't have anything I typed to change.")
        }
        let newText: String
        do {
            newText = try await write(
                instruction: NextStepRules.rewriteInstruction(originalText: originalText, change: change),
                screenshots: [],
                frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                focusedFieldContext: nil
            )
        } catch let error as TeachyAIBillingError {
            return .failed(message: error.message)
        } catch let error as WriterError {
            return .failed(message: error.message)
        } catch {
            return .failed(message: "I couldn't rewrite that just now. Try again in a moment.")
        }

        if let element = DictationTextInserter.focusedElement() {
            let field = DictationAXField(element: element, bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            if let fieldValue = field.value(),
               let range = NextStepRules.rangeOfLastWriting(originalText, in: fieldValue),
               field.setSelectedRange(range) {
                // Replace the selection: through Accessibility when the field allows it,
                // otherwise the inserter pastes over the selected text.
                let replaced: Bool
                let accessibilityResult = field.setSelectedText(newText)
                // A timed-out set may still land later, so never paste on top of it.
                if accessibilityResult == .accepted || accessibilityResult == .timedOut {
                    replaced = true
                } else {
                    switch await DictationTextInserter.insert(newText) {
                    case .accessibility, .pasted: replaced = true
                    default: replaced = false
                    }
                }
                if replaced {
                    lastInsertedText = newText
                    return .inserted(newText)
                }
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(newText, forType: .string)
        return .copiedToClipboard(newText)
    }

    /// The text to insert, and nothing else. One model call.
    func write(
        instruction: String,
        screenshots: [(data: Data, label: String)],
        frontmostApp: String?,
        focusedFieldContext: String?
    ) async throws -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else { throw WriterError(message: "I didn't catch what to write.") }

        let body = WritingPrompt.requestBody(
            instruction: trimmedInstruction,
            screenshots: screenshots,
            frontmostApp: frontmostApp,
            focusedFieldContext: focusedFieldContext,
            memory: BrainStore.shared.promptContext()
        )
        let response = try await TeachyAIRouter.sendJSON(
            job: Self.job,
            hasImages: !screenshots.isEmpty,
            timeout: Self.timeoutSeconds,
            body: body
        )
        let isTerminal = DictationInsertionRules.isTerminal(
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        let text = WritingPrompt.textToInsert(
            fromModelOutput: WritingPrompt.content(fromResponse: response) ?? "",
            isTerminal: isTerminal
        )
        guard !text.isEmpty else { throw WriterError(message: "I couldn't write that. Try again.") }
        return text
    }

    /// Writes and inserts into the field that is focused now. Never throws; the
    /// outcome says what happened and `spokenLine` is what to say.
    func writeAndInsert(
        instruction: String,
        screenshots: [(data: Data, label: String)],
        frontmostApp: String? = nil,
        focusedFieldContext: String? = nil
    ) async -> WriteOutcome {
        let appName = frontmostApp ?? NSWorkspace.shared.frontmostApplication?.localizedName
        let fieldContext = focusedFieldContext ?? Self.describeFocusedField()
        let text: String
        do {
            text = try await write(
                instruction: instruction,
                screenshots: screenshots,
                frontmostApp: appName,
                focusedFieldContext: fieldContext
            )
        } catch let error as TeachyAIBillingError {
            return .failed(message: error.message)
        } catch let error as WriterError {
            return .failed(message: error.message)
        } catch {
            print("⚠️ Writer: \(error.localizedDescription)")
            return .failed(message: "I couldn't write that just now. Try again in a moment.")
        }

        switch await DictationTextInserter.insert(text) {
        case .accessibility, .pasted:
            lastInsertedText = text
            return .inserted(text)
        case .copiedToClipboard:
            return .copiedToClipboard(text)
        case .failed:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copiedToClipboard(text)
        }
    }

    /// What the focused field is and what is already in it, for the prompt:
    /// "text area, labelled Message, empty" or "text field, placeholder Search, contains: …".
    static func describeFocusedField() -> String? {
        guard let element = DictationTextInserter.focusedElement() else { return nil }
        // Never read a password field into a prompt.
        if DictationTextInserter.stringAttribute(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return "password field"
        }
        var parts: [String] = []
        if let role = DictationTextInserter.stringAttribute(element, kAXRoleDescriptionAttribute)
            ?? DictationTextInserter.stringAttribute(element, kAXRoleAttribute) {
            parts.append(role)
        }
        for (name, attribute) in [("labelled", kAXTitleAttribute), ("described as", kAXDescriptionAttribute), ("placeholder", kAXPlaceholderValueAttribute)] {
            if let value = DictationTextInserter.stringAttribute(element, attribute), !value.isEmpty {
                parts.append("\(name) \"\(value.prefix(80))\"")
            }
        }
        if let value = DictationTextInserter.stringAttribute(element, kAXValueAttribute) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(trimmed.isEmpty ? "empty" : "already contains: \"\(trimmed.suffix(600))\"")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
