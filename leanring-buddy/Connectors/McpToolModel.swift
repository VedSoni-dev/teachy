//
//  McpToolModel.swift
//  leanring-buddy
//
//  What Teachy keeps about a connector's tool: its description and schema, how
//  risky the server says it is, the name the agent sees, and how a tool result
//  becomes the text handed back to the model.
//

import Foundation

/// How much a tool can change, according to the server's own annotations.
/// These are hints from the server — a dishonest server can lie — so the
/// permission gate should treat `readOnly` as "the server claims read-only".
nonisolated enum McpToolRisk: String, Sendable, Equatable, CaseIterable {
    case readOnly
    case writes
    case destructive
    /// The server said nothing. Treat as `writes`.
    case unknown

    /// The risk to act on: `unknown` counts as `writes`.
    var effective: McpToolRisk { self == .unknown ? .writes : self }

    /// Maps MCP tool annotations to a risk.
    /// Per the spec, `destructiveHint` defaults to true once a tool is known not to be read-only.
    static func from(annotations: JSONValue?) -> McpToolRisk {
        guard let annotations, case .object = annotations else { return .unknown }
        let readOnlyHint = annotations["readOnlyHint"]?.boolValue
        let destructiveHint = annotations["destructiveHint"]?.boolValue
        if readOnlyHint == nil && destructiveHint == nil { return .unknown }
        // A tool claiming both read-only and destructive contradicts itself; believe the scarier claim.
        if destructiveHint == true { return .destructive }
        if readOnlyHint == true { return .readOnly }
        if destructiveHint == false { return .writes }
        return .destructive // readOnlyHint == false, destructiveHint absent
    }
}

nonisolated struct McpToolDescriptor: Sendable, Equatable {
    /// The name the server uses; what goes into `tools/call`.
    var name: String
    var title: String?
    var description: String
    var inputSchema: JSONValue
    var annotations: JSONValue?

    var risk: McpToolRisk { McpToolRisk.from(annotations: annotations) }
    /// True when the tool reaches beyond the server's own data (the web, other people).
    var openWorld: Bool? { annotations?["openWorldHint"]?.boolValue }

    init(name: String, title: String? = nil, description: String = "", inputSchema: JSONValue = McpToolDescriptor.emptySchema, annotations: JSONValue? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    static let emptySchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    /// One entry of a `tools/list` result. Returns nil for entries with no usable name.
    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        let annotations = json["annotations"]
        self.annotations = annotations
        self.title = json["title"]?.stringValue ?? annotations?["title"]?.stringValue
        self.description = json["description"]?.stringValue ?? ""
        var schema = json["inputSchema"] ?? McpToolDescriptor.emptySchema
        // Model APIs insist on an object schema; repair the few servers that send less.
        if case .object(var members) = schema {
            if members["type"] == nil { members["type"] = .string("object") }
            if members["properties"] == nil { members["properties"] = .object([:]) }
            schema = .object(members)
        } else {
            schema = McpToolDescriptor.emptySchema
        }
        self.inputSchema = schema
    }
}

// MARK: - Names

nonisolated enum McpToolNaming {
    static let maximumLength = 64
    static let prefix = "mcp__"
    static let separator = "__"

    /// Keeps `[a-zA-Z0-9_-]`, turns everything else into `_`.
    static func sanitise(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            let isAllowed = (scalar.value >= 48 && scalar.value <= 57)      // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)               // A-Z
                || (scalar.value >= 97 && scalar.value <= 122)              // a-z
                || scalar == "_" || scalar == "-"
            result.unicodeScalars.append(isAllowed ? scalar : "_")
        }
        return result
    }

    /// A connector id never contains `__`, so the registered name splits unambiguously.
    static func sanitiseConnectorID(_ raw: String) -> String {
        var id = sanitise(raw.lowercased())
        while id.contains("__") { id = id.replacingOccurrences(of: "__", with: "_") }
        id = id.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        if id.count > 24 { id = String(id.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "_-")) }
        return id.isEmpty ? "connector" : id
    }

    /// Stable short hash (FNV-1a), used to keep shortened names distinct.
    static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    /// The names the agent sees for a connector's tools, in the same order as `toolNames`:
    /// `mcp__<connectorid>__<toolname>`, only `[a-zA-Z0-9_-]`, at most 64 characters, all distinct.
    static func registeredNames(connectorID: String, toolNames: [String]) -> [String] {
        let head = prefix + sanitiseConnectorID(connectorID) + separator
        let room = max(8, maximumLength - head.count)
        var taken = Set<String>()
        var result: [String] = []

        for toolName in toolNames {
            var tail = sanitise(toolName)
            if tail.isEmpty { tail = "tool" }
            if tail.count > room {
                // Too long: keep the start, end with a hash of the full original name.
                tail = String(tail.prefix(room - 9)) + "_" + shortHash(toolName)
            }
            var candidate = head + tail
            if taken.contains(candidate) {
                // Two tools sanitised to the same thing ("a.b" and "a/b"). Tell them apart by hash, then by counter.
                let base = String(tail.prefix(room - 9))
                candidate = head + base + "_" + shortHash(toolName)
                var counter = 2
                while taken.contains(candidate) {
                    let suffix = "_\(counter)"
                    candidate = head + String(base.prefix(room - 9 - suffix.count)) + "_" + shortHash(toolName) + suffix
                    counter += 1
                }
            }
            taken.insert(candidate)
            result.append(candidate)
        }
        return result
    }
}

// MARK: - Results

nonisolated enum McpContentFlattener {
    static let defaultMaximumCharacters = 20_000

    /// Turns a `tools/call` result into the text the model reads.
    static func flatten(_ result: JSONValue, maximumCharacters: Int = defaultMaximumCharacters) -> String {
        var parts: [String] = []
        for block in result["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { parts.append(text) }
            case "image":
                parts.append("[image]")
            case "audio":
                parts.append("[audio]")
            case "resource":
                let resource = block["resource"]
                if let text = resource?["text"]?.stringValue, !text.isEmpty {
                    parts.append(text)
                } else {
                    parts.append("[resource \(resource?["uri"]?.stringValue ?? "attachment")]")
                }
            case "resource_link":
                let name = block["name"]?.stringValue ?? block["title"]?.stringValue ?? "resource"
                parts.append("[link: \(name) \(block["uri"]?.stringValue ?? "")]".replacingOccurrences(of: " ]", with: "]"))
            default:
                parts.append("[unsupported content]")
            }
        }

        // Newer servers may answer with structured data only.
        if parts.isEmpty, let structured = result["structuredContent"], !structured.isNull {
            parts.append(structured.serializedString(sortedKeys: true))
        }

        var text = parts.joined(separator: "\n")
        let isError = result["isError"]?.boolValue ?? false
        if isError {
            text = text.isEmpty ? "The tool reported an error." : "The tool reported an error: \(text)"
        } else if text.isEmpty {
            text = "(the tool returned nothing)"
        }
        return truncate(text, maximumCharacters: maximumCharacters)
    }

    static func truncate(_ text: String, maximumCharacters: Int) -> String {
        guard maximumCharacters > 0, text.count > maximumCharacters else { return text }
        let dropped = text.count - maximumCharacters
        return String(text.prefix(maximumCharacters)) + "\n[…cut \(dropped) more characters]"
    }
}
