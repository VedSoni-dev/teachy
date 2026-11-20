//
//  BrainActions.swift
//  leanring-buddy
//
//  The structured memory actions a model can emit, the persisted conversation
//  window, and their (pure) encoding. `BrainStore` applies and persists them.
//

import Foundation

// MARK: - Memory actions

/// One memory change requested by the model.
///
///     {"type": "remember", "kind": "answerStyle", "note": "Length: keep it to two sentences"}
///     {"type": "forget", "phrase": "food truck"}
nonisolated enum BrainAction: Equatable, Sendable, Decodable {
    case remember(kind: BrainKind, note: String)
    case forget(phrase: String)

    private enum CodingKeys: String, CodingKey {
        case type, action, kind, note, phrase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actionName = try container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .action)
        guard let action = BrainAction(
            name: actionName,
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            phrase: try container.decodeIfPresent(String.self, forKey: .phrase)
        ) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Not a memory action"
            ))
        }
        self = action
    }

    /// Builds an action from loosely-typed fields; nil when it is not a usable memory action.
    init?(name: String?, kind: String?, note: String?, phrase: String?) {
        switch name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "remember":
            guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let parsedKind = BrainKind.parse(kind ?? "") else { return nil }
            self = .remember(kind: parsedKind, note: note)
        case "forget":
            guard let phrase = phrase ?? note,
                  !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .forget(phrase: phrase)
        default:
            return nil
        }
    }

    /// Lenient decoding of model output: a JSON array of actions or a single
    /// action object. Anything that is not a valid memory action is skipped.
    static func decodeList(fromJSON json: String) -> [BrainAction] {
        guard let jsonData = json.data(using: .utf8),
              let jsonValue = try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
        else { return [] }

        let candidateObjects: [Any]
        if let array = jsonValue as? [Any] {
            candidateObjects = array
        } else {
            candidateObjects = [jsonValue]
        }
        return candidateObjects.compactMap { candidate in
            guard let fields = candidate as? [String: Any] else { return nil }
            return BrainAction(
                name: (fields["type"] ?? fields["action"]) as? String,
                kind: fields["kind"] as? String,
                note: fields["note"] as? String,
                phrase: fields["phrase"] as? String
            )
        }
    }

    /// Paste into the system prompt so the model knows how to change memory.
    static let schemaDescription = """
        MEMORY ACTIONS
        To remember or forget something about the person, emit memory actions:
        {"type":"remember","kind":"<kind>","note":"<one short plain line>"}
        {"type":"forget","phrase":"<words to remove from memory>"}
        Kinds:
        - aboutMe: who they are (name, job, interests, life details)
        - answerStyle: how they want answers (tone, length, language). Use this when they say things like "you talk too much"
        - howToDoThings: how they want you to act ("YouTube: play it in my Chrome", "Don't move my mouse unless I ask")
        - likes: songs, artists, shows, food, brands, places they like, as "Subject: value" ("Favourite song: <title> by <artist>")
        - tools: apps and tools they use
        - skills: what they can do or are learning
        - mistakes: things that keep catching them (repeats are counted)
        - words: names and spellings to get right
        - project: what they are working on, as "Name: status; last blocker; link"
        - recent: a short note about what just happened
        - screen: one line about what was on their screen (text only)
        Remember only things worth knowing next week, one fact per action. Start a note with "Subject: " to replace the older note about that subject. Use forget whenever they ask you to forget something. Never store passwords, keys or card numbers.
        """
}

/// What `BrainStore.apply(actions:)` did.
nonisolated struct BrainApplyResult: Equatable, Sendable {
    /// One outcome per `remember` action, in order.
    var rememberOutcomes: [BrainRememberOutcome] = []
    /// The text of every bullet removed by `forget` actions.
    var forgotten: [String] = []
}

// MARK: - Conversation window

/// One turn of conversation, kept so talks carry across launches.
nonisolated struct BrainMessage: Codable, Equatable, Sendable {
    nonisolated enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var role: Role
    var text: String
    var date: Date
}

/// Encoding and trimming of `conversation.jsonl` (one JSON message per line).
nonisolated enum BrainConversationLog {
    /// How many messages are kept on disk.
    static let windowSize = 40
    /// Longer messages are stored shortened; this is context, not an archive.
    static let maximumMessageCharacters = 4000

    static func appending(
        _ message: BrainMessage,
        to messages: [BrainMessage],
        windowSize: Int = BrainConversationLog.windowSize
    ) -> [BrainMessage] {
        var storedMessage = message
        storedMessage.text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storedMessage.text.isEmpty else { return Array(messages.suffix(windowSize)) }
        if storedMessage.text.count > maximumMessageCharacters {
            storedMessage.text = String(storedMessage.text.prefix(maximumMessageCharacters - 1)) + "…"
        }
        return Array((messages + [storedMessage]).suffix(windowSize))
    }

    static func encode(_ messages: [BrainMessage]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = messages.compactMap { message -> String? in
            guard let lineData = try? encoder.encode(message) else { return nil }
            return String(data: lineData, encoding: .utf8)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Unreadable lines (hand edits, a torn write) are skipped, not fatal.
    static func decode(_ jsonLines: String) -> [BrainMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return jsonLines.split(whereSeparator: \.isNewline).compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(BrainMessage.self, from: lineData)
        }
    }

    /// Drops messages that mention a forgotten phrase, so "forget X" also
    /// stops X coming back through the conversation window.
    static func removingMessages(mentioning phrase: String, from messages: [BrainMessage]) -> [BrainMessage] {
        let wantedPhrase = BrainText.normalized(phrase)
        guard wantedPhrase.count >= 3 else { return messages }
        return messages.filter { !(" " + BrainText.normalized($0.text)).contains(" " + wantedPhrase) }
    }
}
