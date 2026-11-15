//
//  WritingPrompt.swift
//  leanring-buddy
//
//  Pure parts of "write it for me": the system prompt, the request body, and the
//  tidy-up of what the model answers. Foundation only, so
//  scripts/tests/dictspeed/main.swift compiles it on its own.
//

import Foundation

nonisolated enum WritingPrompt {
    /// Screenshots sent with one request. The first is the screen with the cursor.
    static let maximumScreenshots = 2
    /// publik's body limit is 4 MB; base64 grows the bytes by a third.
    static let screenshotBase64BudgetBytes = 3_300_000
    static let maximumFieldContextCharacters = 1_200

    static let systemPrompt = """
    You write text for a person, as that person. They are looking at their screen (screenshots attached) and have asked you out loud to write something into the text field they have focused. Whatever you answer is typed into that field exactly as it is.

    Output ONLY the text to insert. No preamble, no explanation, no surrounding quotes, no "Here is", no notes after it.

    How to write it:
    - Write as the person, in the first person, in their own voice. Use what you know about them (below) for who they are and how they write. Never mention that you are an AI or that this was drafted.
    - Read the screen to see what they are replying to or filling in: who wrote, what they asked, the names, the thread. Answer that, and do what the spoken instruction says. Do not invent facts, dates, prices, links or commitments that are neither on the screen, in the instruction, nor in what you know about them. If a detail is missing, write around it.
    - Match the language of the conversation on screen, and its register: a one-line chat reply for a chat, a short email for an email, a formal tone only where the thread is formal. Keep it as short as a person typing it would.
    - Greeting and sign-off only where that kind of message has them. Sign with their name only if the other messages in the thread are signed.
    - Plain text. No markdown, no bullet symbols, no code fences, unless the field is clearly a markdown or code field.
    - No em dashes. No emojis unless the thread uses them.

    Special targets:
    - Terminal or shell prompt: output one line only, with no trailing newline. For a commit message, output only the message text (no "git commit", no quotes) unless the instruction asks for the full command.
    - A coding agent or AI chat box: write the instruction the person would give it: specific, naming the files, errors or behaviour visible on screen, saying what should be true when it is done.
    - A form field: output only the value for that one field.
    - If the field already has text in it, write what continues or completes it; do not repeat what is there.
    """

    static func systemPrompt(memory: String) -> String {
        let trimmed = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return systemPrompt + "\n\nYou know nothing about this person yet. Use a neutral, friendly, direct voice."
        }
        return systemPrompt + "\n\nWhat you know about the person and how they write:\n" + trimmed
    }

    /// The text part of the user message.
    static func userText(
        instruction: String,
        screenshotLabels: [String],
        frontmostApp: String?,
        focusedFieldContext: String?
    ) -> String {
        var lines: [String] = []
        if let frontmostApp, !frontmostApp.isEmpty { lines.append("App in front: \(frontmostApp)") }
        if let focusedFieldContext, !focusedFieldContext.isEmpty {
            lines.append("Focused field: \(String(focusedFieldContext.prefix(maximumFieldContextCharacters)))")
        }
        for (index, label) in screenshotLabels.enumerated() where !label.isEmpty {
            lines.append("Screenshot \(index + 1): \(label)")
        }
        lines.append("What they asked for: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("Write the text to insert.")
        return lines.joined(separator: "\n")
    }

    static func mediaType(for image: Data) -> String {
        image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    /// Keeps the first screenshots that fit publik's request size.
    static func screenshotsThatFit(_ screenshots: [(data: Data, label: String)]) -> [(data: Data, label: String)] {
        var kept: [(data: Data, label: String)] = []
        var spent = 0
        for screenshot in screenshots.prefix(maximumScreenshots) {
            let base64Bytes = (screenshot.data.count + 2) / 3 * 4
            if !kept.isEmpty && spent + base64Bytes > screenshotBase64BudgetBytes { break }
            kept.append(screenshot)
            spent += base64Bytes
        }
        return kept
    }

    /// OpenAI chat-completions body. No "model" key: TeachyAIRouter sets it.
    static func requestBody(
        instruction: String,
        screenshots: [(data: Data, label: String)],
        frontmostApp: String?,
        focusedFieldContext: String?,
        memory: String
    ) -> [String: Any] {
        let kept = screenshotsThatFit(screenshots)
        var content: [[String: Any]] = kept.map { screenshot in
            [
                "type": "image_url",
                "image_url": ["url": "data:\(mediaType(for: screenshot.data));base64,\(screenshot.data.base64EncodedString())"],
            ]
        }
        content.append([
            "type": "text",
            "text": userText(
                instruction: instruction,
                screenshotLabels: kept.map(\.label),
                frontmostApp: frontmostApp,
                focusedFieldContext: focusedFieldContext
            ),
        ])
        return [
            "messages": [
                ["role": "system", "content": systemPrompt(memory: memory)],
                ["role": "user", "content": content],
            ],
            "max_tokens": 1200,
            "stream": false,
        ]
    }

    // MARK: - Tidying the answer

    static let preamblePattern = "^(sure|okay|ok|certainly|of course)?[,!. ]*(here(’|')?s|here is)\\b[^\\n:]{0,80}:\\s*\\n+"

    /// What actually goes into the field: the model's answer without a code fence
    /// around the whole of it, without quotes around the whole of it, without a
    /// "Here's your reply:" line, and without em dashes.
    static func textToInsert(fromModelOutput output: String, isTerminal: Bool) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if let regex = try? NSRegularExpression(pattern: preamblePattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        // A fence around the whole answer.
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                text = lines.joined(separator: "\n")
            } else {
                text = String(text.dropFirst(3).dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Quotes around the whole answer (and none inside it).
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("`", "`")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) {
                text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break
        }

        text = text.replacingOccurrences(of: " \u{2014} ", with: ", ").replacingOccurrences(of: "\u{2014}", with: ", ")

        if isTerminal {
            // A newline in a terminal runs the command.
            text = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return text
    }

    /// The assistant text from a chat-completions response body.
    static func content(fromResponse data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        else { return nil }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Voice hook

    /// The rule to add to the companion's system prompt so the voice model hands
    /// writing over with a [WRITE: …] tag.
    static let voicePromptRule = """
    - When they ask you to WRITE something into the field they have focused — "type a reply to this person saying thanks", "write a commit message", "reply that I'm in", "fill this in", "draft a follow-up for the agent" — do not dictate the text yourself. Add [WRITE: what to write, in one sentence, with every detail they gave] and SAY one short line such as "Writing it now." Teachy reads the screen, writes it in their voice and types it into that field. Use [WRITE:] only when the text should land in the field in front of them; for a prompt they will paste somewhere else keep using [CLIPBOARD:].
    """
}
