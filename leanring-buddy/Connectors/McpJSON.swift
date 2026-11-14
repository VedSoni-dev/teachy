//
//  McpJSON.swift
//  leanring-buddy
//
//  A Sendable JSON value. MCP messages are dynamic JSON, and `[String: Any]`
//  can't cross actor boundaries cleanly, so the connector code passes this
//  around instead and converts to `Any` only at the edges.
//

import Foundation

nonisolated enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Conversion from Foundation JSON

    init(any value: Any?) {
        guard let value else { self = .null; return }
        switch value {
        case let existing as JSONValue:
            self = existing
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber hides booleans; CFBoolean is the only reliable tell.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: value))
        }
    }

    /// The Foundation shape `JSONSerialization` understands.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let members): return members.mapValues(\.anyValue)
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: object)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Compact, single-line JSON (no raw newlines — safe for newline-delimited framing).
    func serialized(sortedKeys: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if sortedKeys { options.insert(.sortedKeys) }
        return try JSONSerialization.data(withJSONObject: anyValue, options: options)
    }

    func serializedString(sortedKeys: Bool = false) -> String {
        guard let data = try? serialized(sortedKeys: sortedKeys) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded() && abs(value) < 9e15: return Int(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
