//
//  SceneScriptParser.swift
//  leanring-buddy / Scene
//
//  Streaming parser for TeachyScene. Feed it text in any chunking; it hands back a
//  typed SceneCommand for each line the moment that line is complete. Nothing in
//  the input is fatal: prose, code fences, bullets, unknown verbs, missing
//  arguments and truncated lines are skipped and counted.
//
//  Pure (Foundation only).
//

import Foundation

struct SceneParseStats: Equatable {
    /// Lines that carried content (not blank, comment or code fence).
    var contentLines = 0
    /// Lines that became a command.
    var commands = 0
    /// Lines whose first word is not a verb.
    var prose = 0
    /// Lines with a verb but missing or unusable arguments.
    var invalid = 0
    /// 3D parts those commands create (macros count each sub-part once as one command).
    var partCommands = 0

    /// Share of content lines that parsed, 0...1.
    var parseRate: Double { contentLines == 0 ? 1 : Double(commands) / Double(contentLines) }
}

final class SceneScriptParser {
    /// Called for each command, in order, as its line completes.
    var onCommand: ((SceneCommand) -> Void)?
    private(set) var stats = SceneParseStats()
    /// Why the most recent lines were dropped (kept short; for the eval and debugging).
    private(set) var rejections: [String] = []

    private var buffer = ""
    private var lineNumber = 0
    private var currentCue: Int?

    /// A line longer than this is treated as garbage and cut.
    static let maximumLineLength = 8_000

    init() {}

    /// Feed any amount of text. Returns the commands completed by this chunk.
    @discardableResult
    func feed(_ chunk: String) -> [SceneCommand] {
        var completed: [SceneCommand] = []
        buffer.append(chunk)
        while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let command = consume(line: line) { completed.append(command) }
        }
        if buffer.count > Self.maximumLineLength {
            // No newline in sight: don't let a runaway line grow without bound.
            let line = buffer
            buffer = ""
            if let command = consume(line: line) { completed.append(command) }
        }
        return completed
    }

    /// The stream ended: parse whatever is left without a trailing newline.
    @discardableResult
    func finish() -> [SceneCommand] {
        let line = buffer
        buffer = ""
        guard !line.isEmpty, let command = consume(line: line) else { return [] }
        return [command]
    }

    func reset() {
        buffer = ""
        lineNumber = 0
        currentCue = nil
        stats = SceneParseStats()
        rejections = []
    }

    /// Parse a whole script at once.
    static func parse(_ script: String) -> [SceneCommand] {
        let parser = SceneScriptParser()
        return parser.feed(script) + parser.finish()
    }

    // MARK: - One line

    private func consume(line rawLine: String) -> SceneCommand? {
        lineNumber += 1
        var line = String(rawLine.prefix(Self.maximumLineLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return nil }
        line = Self.strippingListMarker(line)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { return nil }

        stats.contentLines += 1
        var tokens = Self.tokenize(line)
        guard !tokens.isEmpty else { return reject(line, as: \.prose, "no words") }

        var cueOnThisLine: Int?
        // "@3" on its own sets the cue; "@3 ring …" sets it and continues.
        if let first = tokens.first, first.key == nil, !first.quoted, first.text.hasPrefix("@"),
           let cue = Int(first.text.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ":"))) {
            currentCue = cue
            cueOnThisLine = cue
            tokens.removeFirst()
            if tokens.isEmpty {
                stats.commands += 1
                return nil
            }
        }

        guard let head = tokens.first, head.key == nil, !head.quoted, let verb = SceneVerb.lookup(head.text) else {
            return reject(line, as: \.prose, "not a verb")
        }
        tokens.removeFirst()

        var id: String?
        if verb.takesID, let first = tokens.first, first.key == nil, !first.quoted, Self.looksLikeID(first.text) {
            id = first.text
            tokens.removeFirst()
        }

        var words: [SceneWord] = []
        var args: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let key = token.key {
                if args[key] == nil { args[key] = token.text }
            } else if !token.quoted, token.text == "->" || token.text == "→" || token.text == "=>" {
                if index + 1 < tokens.count, tokens[index + 1].key == nil {
                    args["bind"] = tokens[index + 1].text
                    index += 1
                }
            } else {
                words.append(SceneWord(text: token.text, quoted: token.quoted))
            }
            index += 1
        }

        var command = SceneCommand(
            verb: verb,
            id: id ?? "_\(verb.rawValue)\(lineNumber)",
            hasExplicitID: id != nil,
            words: words,
            args: args,
            cue: currentCue,
            lineNumber: lineNumber
        )
        Self.normalize(&command, originalVerbWord: head.text.lowercased())

        if verb == .say {
            let bareNumber = command.words.first(where: { !$0.quoted }).flatMap { Int($0.text) }
            let cue = bareNumber ?? command.number("n").map { Int($0) } ?? cueOnThisLine ?? ((currentCue ?? 0) + 1)
            currentCue = cue
            command.cue = cue
            command.words.removeAll { !$0.quoted && Int($0.text) != nil }
        }

        if let problem = SceneValidator.problem(with: command) {
            // A line with no key=value and no quotes that fails validation is prose
            // that happened to start with a verb word ("line up the parts…").
            let looksLikeScript = !args.isEmpty || words.contains(where: \.quoted)
            return reject(line, as: looksLikeScript ? \.invalid : \.prose, problem)
        }

        stats.commands += 1
        if verb.makes3DPart { stats.partCommands += 1 }
        onCommand?(command)
        return command
    }

    private func reject(_ line: String, as counter: WritableKeyPath<SceneParseStats, Int>, _ reason: String) -> SceneCommand? {
        stats[keyPath: counter] += 1
        if rejections.count < 200 { rejections.append("\(lineNumber): \(reason): \(line.prefix(120))") }
        return nil
    }

    // MARK: - Normalising loose forms

    static let jointKinds: Set<String> = ["hinge", "slider", "ball", "spring", "rod", "rope"]
    static let chartKinds: Set<String> = ["bar", "line", "area", "point", "scatter", "pie"]

    /// Folds the looser spellings models produce into the canonical argument names.
    private static func normalize(_ command: inout SceneCommand, originalVerbWord: String) {
        func takeFirstBareWord(where predicate: (String) -> Bool) -> String? {
            guard let index = command.words.firstIndex(where: { !$0.quoted && predicate($0.text.lowercased()) }) else { return nil }
            return command.words.remove(at: index).text
        }
        func promoteWordToID() {
            if let index = command.words.firstIndex(where: { !$0.quoted && looksLikeID($0.text) && Double($0.text) == nil }) {
                command.id = command.words.remove(at: index).text
                command.hasExplicitID = true
            } else {
                command.id = "_\(command.verb.rawValue)\(command.lineNumber)"
                command.hasExplicitID = false
            }
        }

        switch command.verb {
        case .joint:
            // "joint hinge j1 a=… b=…": the kind came first and was read as the id.
            if command.hasExplicitID, jointKinds.contains(command.id.lowercased()) {
                if command.args["type"] == nil { command.args["type"] = command.id.lowercased() }
                promoteWordToID()
            } else if command.args["type"] == nil, let kind = takeFirstBareWord(where: jointKinds.contains) {
                command.args["type"] = kind.lowercased()
            }
        case .chart:
            if command.hasExplicitID, chartKinds.contains(command.id.lowercased()) {
                if command.args["type"] == nil { command.args["type"] = command.id.lowercased() }
                promoteWordToID()
            } else if command.args["type"] == nil, let kind = takeFirstBareWord(where: chartKinds.contains) {
                command.args["type"] = kind.lowercased()
            }
            if command.args["type"] == nil, originalVerbWord == "bar" { command.args["type"] = "bar" }
            if command.args["data"] == nil, let values = command.args["values"] ?? command.args["y"] { command.args["data"] = values }
        case .slider:
            // "slider len 0.5 3 1.5": positional min max value.
            let positional = command.words.filter { !$0.quoted }.compactMap { Double($0.text) }
            if positional.count >= 2 {
                if command.args["min"] == nil { command.args["min"] = String(positional[0]) }
                if command.args["max"] == nil { command.args["max"] = String(positional[1]) }
                if positional.count >= 3, command.args["value"] == nil { command.args["value"] = String(positional[2]) }
                command.words.removeAll { !$0.quoted && Double($0.text) != nil }
            }
            if command.args["bind"] == nil, let target = command.args["target"] ?? command.args["to"] ?? command.args["binds"] {
                command.args["bind"] = target
            }
        case .mesh:
            // "mesh a b ratio=3" or "mesh a=g1 b=g2".
            if command.args["a"] == nil, command.hasExplicitID { command.args["a"] = command.id }
            if command.args["b"] == nil, let other = takeFirstBareWord(where: { _ in true }) { command.args["b"] = other }
        case .gravity:
            if command.args["g"] == nil, let value = takeFirstBareWord(where: { !SceneNumbers.scan($0).isEmpty }) {
                command.args["g"] = value
            }
        case .image:
            if command.args["query"] == nil, let query = command.args["q"] ?? command.args["search"] ?? command.freeText {
                command.args["query"] = query
            }
        case .label, .text3:
            if command.args["on"] == nil, let target = command.args["part"] ?? command.args["of"] ?? command.args["for"] {
                command.args["on"] = target
            }
        case .plot:
            if command.args["of"] == nil, let source = command.args["value"] ?? command.args["bind"] ?? command.args["source"] {
                command.args["of"] = source
            }
        case .ring:
            if command.args["at"] == nil, let center = command.args["center"] { command.args["at"] = center }
        case .set:
            if command.args["value"] == nil, let value = takeFirstBareWord(where: { Double($0) != nil }) {
                command.args["value"] = value
            }
        default:
            break
        }

        // Shared synonyms.
        let synonyms: [(String, [String])] = [
            ("at", ["pos", "position", "center", "xyz"]),
            ("color", ["colour", "col", "c"]),
            ("pts", ["points", "path", "profile", "outline"]),
            ("r", ["radius", "rad"]),
            ("h", ["height", "len", "length"]),
            ("size", ["dims", "dim"]),
            ("rot", ["rotation", "rotate", "euler"]),
            ("label", ["lbl"]),
            ("opacity", ["alpha"]),
        ]
        for (canonical, others) in synonyms where command.args[canonical] == nil {
            // `length` stays its own key for joints and springs; `c` is a body for joints.
            if command.verb == .joint || command.verb == .slider { continue }
            if canonical == "at", command.verb == .camera { continue }
            for other in others {
                if let value = command.args[other] {
                    command.args[canonical] = value
                    break
                }
            }
        }
    }

    // MARK: - Tokens

    struct Token: Equatable {
        var text: String
        var quoted: Bool
        var key: String?
    }

    static func looksLikeID(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, text.count <= 64 else { return false }
        let allowedStart = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let allowed = allowedStart.union(CharacterSet(charactersIn: ".-:#"))
        return allowedStart.contains(first) && text.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func strippingListMarker(_ line: String) -> String {
        var rest = Substring(line)
        for marker in ["- ", "* ", "• ", "> ", "– ", "— "] where rest.hasPrefix(marker) {
            rest = rest.dropFirst(marker.count)
        }
        // "3. ring …" or "3) ring …"
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") { rest = after.dropFirst(2) }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static let openQuotes: [Character: Character] = ["\"": "\"", "“": "”", "”": "”", "'": "'", "‘": "’"]

    /// Splits a line into bare words, quoted strings and key=value pairs.
    static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(line)
        var index = 0

        func readQuoted(closing: Character) -> String {
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\\", index < characters.count {
                    text.append(characters[index])
                    index += 1
                } else if character == closing || (closing == "”" && character == "\"") {
                    break
                } else {
                    text.append(character)
                }
            }
            return text
        }

        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" {
                index += 1
                continue
            }
            if let closing = openQuotes[character] {
                // A quote opening a word.
                index += 1
                tokens.append(Token(text: readQuoted(closing: closing), quoted: true, key: nil))
                continue
            }
            // Bare word, possibly key=value.
            var word = ""
            var key: String?
            var valueQuoted = false
            while index < characters.count {
                let c = characters[index]
                if c == " " || c == "\t" { break }
                if c == "=", key == nil, isKey(word) {
                    key = word
                    word = ""
                    index += 1
                    if index < characters.count, let closing = openQuotes[characters[index]] {
                        index += 1
                        word = readQuoted(closing: closing)
                        valueQuoted = true
                        break
                    }
                    continue
                }
                word.append(c)
                index += 1
            }
            if key == nil, word.hasPrefix("//") || (word.hasPrefix("#") && tokens.count > 0 && word.count == 1) {
                break // trailing comment
            }
            tokens.append(Token(text: word, quoted: valueQuoted, key: key))
        }

        // Rejoin values that were split by a space: "at=1, 2, 3", "at= 1,2", "pts=[(1,2), (3,4)]".
        var merged: [Token] = []
        for token in tokens {
            if var last = merged.last, !last.quoted, !token.quoted, token.key == nil, last.key != nil {
                let endsOpen = last.text.isEmpty || last.text.hasSuffix(",") || last.text.hasSuffix(";")
                let startsOpen = token.text.hasPrefix(",") || token.text.hasPrefix(";")
                if endsOpen || startsOpen {
                    last.text += token.text
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(token)
        }
        for index in merged.indices where merged[index].key != nil && !merged[index].quoted {
            while let last = merged[index].text.last, last == "," || last == ";" { merged[index].text.removeLast() }
        }
        return merged
    }

    private static func isKey(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, word.count <= 24 else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return word.unicodeScalars.allSatisfy(allowed.contains)
    }
}

// MARK: - Validation

enum SceneValidator {
    /// A short reason this command can't be drawn, or nil when it can.
    static func problem(with command: SceneCommand) -> String? {
        let c = command
        func hasText() -> Bool { !(c.freeText ?? "").isEmpty }
        switch c.verb {
        case .ring:
            return c.vec2("at") == nil ? "ring needs at=x,y" : nil
        case .highlight where c.isPartHighlight:
            return c.hasExplicitID || !c.targetIDs.isEmpty || c.names("none") ? nil : "highlight needs from=x,y to=x,y or a part id"
        case .rect, .highlight:
            if c.vec2("from") != nil && c.vec2("to") != nil { return nil }
            if c.vec2("at") != nil && c.vec2("size") != nil { return nil }
            if c.numbers("box").count >= 4 { return nil }
            return "\(c.verb.rawValue) needs from=x,y to=x,y"
        case .arrow, .arrow3:
            return c.numbers("from").count >= 2 && c.numbers("to").count >= 2 ? nil : "arrow needs from= and to="
        case .line:
            return c.numbers("pts").count >= 4 || (c.numbers("from").count >= 2 && c.numbers("to").count >= 2) ? nil : "line needs pts= with two points"
        case .poly:
            return c.numbers("pts").count >= 6 ? nil : "poly needs pts= with three points"
        case .label:
            if !hasText() { return "label needs text" }
            return c.vec2("at") != nil || c.string("on") != nil ? nil : "label needs at=x,y or on=part"
        case .text, .bullet, .formula, .text3:
            return hasText() ? nil : "\(c.verb.rawValue) needs text"
        case .steps:
            return c.textItems().isEmpty ? "steps needs items" : nil
        case .chart:
            return c.numbers("data").isEmpty ? "chart needs data=" : nil
        case .image:
            return c.string("query") == nil ? "image needs query=" : nil
        case .chip:
            return hasText() || c.args["at"] != nil || c.args["size"] != nil || c.args["label"] != nil ? nil : "chip needs text"
        case .tube, .flow:
            return c.numbers("pts").count >= 4 ? nil : "\(c.verb.rawValue) needs pts= with two points"
        case .lathe:
            return c.numbers("pts").count >= 4 ? nil : "lathe needs pts= with two r,y points"
        case .extrude:
            return c.numbers("pts").count >= 6 ? nil : "extrude needs pts= with three x,y points"
        case .orbit where c.isCameraOrbit:
            return nil
        case .hide, .show:
            return c.hasExplicitID || !c.targetIDs.isEmpty ? nil : "\(c.verb.rawValue) needs a target id"
        case .spin, .pulse, .orbit, .remove, .body, .fixed, .force, .impulse:
            return c.hasExplicitID ? nil : "\(c.verb.rawValue) needs a target id"
        case .focus, .detail:
            return c.targetIDs.isEmpty ? "\(c.verb.rawValue) needs a part id" : nil
        case .ghost:
            return c.targetIDs.isEmpty && !c.names("others") && !c.names("other") && !c.names("all") && !c.names("none") ? "ghost needs part ids or `others`" : nil
        case .move:
            guard c.hasExplicitID else { return "move needs a target id" }
            return c.args["to"] != nil || c.args["by"] != nil ? nil : "move needs to= or by="
        case .mesh:
            return c.string("a") != nil && c.string("b") != nil ? nil : "mesh needs two gear ids"
        case .joint:
            return c.string("b") != nil || c.string("a") != nil ? nil : "joint needs a= and b="
        case .plot:
            return c.string("of") != nil ? nil : "plot needs of=part.property"
        case .set:
            return c.hasExplicitID && c.number("value", "to", "v") != nil ? nil : "set needs a slider id and value="
        case .camera:
            return c.args["to"] != nil || c.args["look"] != nil || c.args["zoom"] != nil ? nil : "camera needs to= or look="
        default:
            return nil
        }
    }
}
