//
//  SceneCommand.swift
//  leanring-buddy / Scene
//
//  The command model of TeachyScene, the line-based scene script a model streams
//  to the drawing engine. Pure (Foundation + simd): compiled into the app and into
//  the standalone test and eval scripts.
//
//  One line = one command:   verb id key=value key="quoted text" flag
//

import Foundation
import simd

typealias SceneVec2 = SIMD2<Double>
typealias SceneVec3 = SIMD3<Double>

// MARK: - Verbs

enum SceneVerb: String, CaseIterable, Codable {
    // control
    case say, clear, remove, hide, show, set
    // 2D overlay
    case ring, rect, arrow, line, poly, label, highlight
    // card
    case card, text, bullet, formula, steps, chart, image, chip
    // 3D
    case scene3d, group, box, sphere, cyl, cone, tube, torus, capsule, lathe, extrude, arrow3, text3
    // part library
    case gear, helix, dna, spring, piston, wheel, fan, flow, board, comp, axes
    // whole objects, expanded by SceneMacros into the parts above
    case jet, engine, rocket, bridge, heart, eye, motor, battery, membrane, protein, planet, pendulum, chain, pins
    // motion
    case spin, move, pulse, explode, camera, orbit, beat
    // simulation
    case body, fixed, ground, joint, force, impulse, gravity, mesh, slider, plot

    static let aliases: [String: SceneVerb] = [
        "ellipse": .ring, "circle": .ring, "oval": .ring,
        "rectangle": .rect, "square": .rect,
        "polyline": .line, "path": .line, "curve": .line,
        "polygon": .poly, "pill": .label, "tag": .label, "callout": .label,
        "hl": .highlight, "hilite": .highlight,
        "note": .text, "p": .text, "eq": .formula, "math": .formula, "equation": .formula,
        "step": .steps, "chain": .steps, "img": .image, "photo": .image, "picture": .image,
        "followup": .chip, "bar": .chart, "graph": .chart,
        "scene": .scene3d, "model": .scene3d, "model3d": .scene3d, "3d": .scene3d,
        "cube": .box, "ball": .sphere, "cylinder": .cyl, "pipe": .tube, "ring3": .torus, "donut": .torus,
        "pill3": .capsule, "revolve": .lathe, "prism": .extrude,
        "arrow3d": .arrow3, "text3d": .text3, "label3": .text3,
        "blades": .fan, "rotor": .fan, "propeller": .fan, "coil": .spring,
        "component": .comp, "part": .comp, "pcb": .board, "plate": .board, "axis": .axes,
        "rotate": .spin, "animate": .move, "translate": .move, "blink": .pulse, "cutaway": .explode,
        "cam": .camera, "couple": .mesh, "coupling": .mesh, "floor": .ground,
        "delete": .remove, "anchor": .fixed, "push": .impulse,
        "turbofan": .jet, "jetengine": .jet, "turbojet": .jet, "suspensionbridge": .bridge,
        "bilayer": .membrane, "pump": .protein, "channel": .protein, "star": .planet,
        "sprocket": .gear, "cog": .gear, "belt": .chain, "header": .pins, "gpio": .pins,
        "heartbeat": .beat, "throb": .beat, "cell": .battery,
    ]

    static func lookup(_ word: String) -> SceneVerb? {
        var key = word.lowercased()
        while let last = key.last, last == ":" || last == "," { key.removeLast() }
        return SceneVerb(rawValue: key) ?? aliases[key]
    }

    /// Verbs whose first bare word is free text, not an id.
    var takesID: Bool {
        switch self {
        case .say, .clear, .text, .bullet, .formula, .steps, .gravity, .camera: return false
        default: return true
        }
    }

    enum Family { case control, overlay, card, scene3d }

    /// The renderer a verb belongs to when nothing else disambiguates it.
    var family: Family {
        switch self {
        case .say, .clear, .remove, .hide, .show, .set: return .control
        case .ring, .rect, .arrow, .line, .poly, .label, .highlight: return .overlay
        case .card, .text, .bullet, .formula, .steps, .chart, .image, .chip: return .card
        default: return .scene3d
        }
    }

    /// Whole objects that SceneMacros rewrites into several simpler commands.
    var isMacro: Bool {
        switch self {
        case .jet, .engine, .rocket, .bridge, .heart, .eye, .motor, .battery, .membrane, .protein, .planet, .pendulum, .pins: return true
        default: return false
        }
    }

    /// Ready-made parts: one line that the engine expands into placed geometry.
    var isLibraryPart: Bool {
        switch self {
        case .gear, .helix, .dna, .spring, .piston, .wheel, .fan, .flow, .board, .comp, .axes, .chain: return true
        default: return isMacro
        }
    }

    /// Verbs that put at least one visible 3D part into the scene.
    var makes3DPart: Bool {
        switch self {
        case .box, .sphere, .cyl, .cone, .tube, .torus, .capsule, .lathe, .extrude, .arrow3, .text3,
             .gear, .helix, .dna, .spring, .piston, .wheel, .fan, .flow, .board, .comp, .axes, .body, .ground,
             .jet, .engine, .rocket, .bridge, .heart, .eye, .motor, .battery, .membrane, .protein, .planet, .pendulum, .chain, .pins:
            return true
        default:
            return false
        }
    }
}

// MARK: - Command

struct SceneWord: Equatable, Codable {
    var text: String
    var quoted: Bool
}

struct SceneCommand: Equatable, Codable {
    var verb: SceneVerb
    /// Explicit id from the script, or an auto id like "_ring12".
    var id: String
    var hasExplicitID: Bool
    /// Words after the id that are not key=value pairs (free text, flags, extra ids).
    var words: [SceneWord]
    var args: [String: String]
    /// Spoken sentence this command belongs to (from `say N` / `@N`), if any.
    var cue: Int?
    var lineNumber: Int

    init(verb: SceneVerb, id: String, hasExplicitID: Bool = true, words: [SceneWord] = [],
         args: [String: String] = [:], cue: Int? = nil, lineNumber: Int = 0) {
        self.verb = verb
        self.id = id
        self.hasExplicitID = hasExplicitID
        self.words = words
        self.args = args
        self.cue = cue
        self.lineNumber = lineNumber
    }

    // MARK: Typed accessors

    func string(_ keys: String...) -> String? {
        for key in keys { if let value = args[key], !value.isEmpty { return value } }
        return nil
    }

    func number(_ keys: String...) -> Double? {
        for key in keys { if let value = args[key], let n = SceneNumbers.scan(value).first { return n } }
        return nil
    }

    func numbers(_ key: String) -> [Double] {
        args[key].map(SceneNumbers.scan) ?? []
    }

    func vec2(_ keys: String...) -> SceneVec2? {
        for key in keys {
            let n = numbers(key)
            if n.count >= 2 { return SceneVec2(n[0], n[1]) }
        }
        return nil
    }

    /// Three numbers; one number is spread to all three axes when `spread` is on.
    func vec3(_ key: String, spread: Bool = false) -> SceneVec3? {
        let n = numbers(key)
        if n.count >= 3 { return SceneVec3(n[0], n[1], n[2]) }
        if n.count == 2 { return SceneVec3(n[0], n[1], 0) }
        if n.count == 1 && spread { return SceneVec3(repeating: n[0]) }
        return nil
    }

    /// A direction: "x", "-y", "z" or three numbers.
    func axis(_ key: String = "axis") -> SceneVec3? {
        guard let raw = args[key]?.lowercased() else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "x", "+x": return SceneVec3(1, 0, 0)
        case "-x": return SceneVec3(-1, 0, 0)
        case "y", "+y", "up": return SceneVec3(0, 1, 0)
        case "-y", "down": return SceneVec3(0, -1, 0)
        case "z", "+z": return SceneVec3(0, 0, 1)
        case "-z": return SceneVec3(0, 0, -1)
        default:
            guard let v = vec3(key), simd_length(v) > 1e-9 else { return nil }
            return simd_normalize(v)
        }
    }

    func points2(_ key: String = "pts") -> [SceneVec2] {
        guard let raw = args[key] else { return [] }
        return SceneNumbers.groups(raw, size: 2).map { SceneVec2($0[0], $0[1]) }
    }

    func points3(_ key: String = "pts") -> [SceneVec3] {
        guard let raw = args[key] else { return [] }
        return SceneNumbers.groups(raw, size: 3).map { SceneVec3($0[0], $0[1], $0[2]) }
    }

    func color(_ key: String = "color") -> SceneColor? {
        args[key].flatMap(SceneColor.parse)
    }

    /// True for `key=yes|true|1|on` or for the bare word `key` on the line.
    func flag(_ key: String) -> Bool {
        if let value = args[key]?.lowercased() {
            return !["no", "false", "0", "off", "none"].contains(value)
        }
        return words.contains { !$0.quoted && $0.text.lowercased() == key }
    }

    /// Free text of the line: `text=`, else the first quoted word, else all bare words.
    var freeText: String? {
        if let explicit = string("text", "t", "caption") { return explicit }
        if let quoted = words.first(where: { $0.quoted && !$0.text.isEmpty }) { return quoted.text }
        let bare = words.filter { !$0.quoted }.map(\.text).joined(separator: " ")
        return bare.isEmpty ? nil : bare
    }

    /// Every quoted word, or one `a|b|c` / `a > b > c` list split into items.
    func textItems(_ key: String = "items") -> [String] {
        let quoted = words.filter { $0.quoted }.map(\.text)
        if quoted.count > 1 { return quoted }
        guard let source = string(key) ?? quoted.first ?? freeText else { return [] }
        for separator in ["|", "→", "->", ">", ";"] where source.contains(separator) {
            return source.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return [source]
    }

    /// Canonical one-line form, so a recorded scene can be saved as plain script.
    var scriptLine: String {
        var parts: [String] = []
        if let cue { parts.append("@\(cue)") }
        parts.append(verb.rawValue)
        if hasExplicitID { parts.append(id) }
        for word in words {
            parts.append(word.quoted ? "\"\(word.text.replacingOccurrences(of: "\"", with: "'"))\"" : word.text)
        }
        for key in args.keys.sorted() {
            let value = args[key] ?? ""
            let needsQuotes = value.isEmpty || value.contains(where: { $0 == " " || $0 == "\t" })
            parts.append(needsQuotes ? "\(key)=\"\(value.replacingOccurrences(of: "\"", with: "'"))\"" : "\(key)=\(value)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Numbers

enum SceneNumbers {
    /// Largest magnitude a script number may have; keeps bad input from building absurd geometry.
    static let limit = 1_000_000.0

    /// Every number in a string, ignoring units and brackets: "(1.5, -2e1, 30deg)" → [1.5, -20, 30].
    static func scan(_ text: String) -> [Double] {
        var result: [Double] = []
        var current = ""
        func flush() {
            while let last = current.last, last == "e" || last == "-" || last == "." { current.removeLast() }
            if !current.isEmpty, let value = Double(current), value.isFinite {
                result.append(max(-limit, min(limit, value)))
            }
            current = ""
        }
        for character in text.unicodeScalars {
            switch character {
            case "0"..."9":
                current.unicodeScalars.append(character)
            case ".":
                if current.contains(".") || current.contains("e") { flush() }
                current.unicodeScalars.append(character)
            case "-", "+", "−":
                if current.hasSuffix("e") {
                    if character != "+" { current.append("-") }
                } else {
                    flush()
                    if character != "+" { current = "-" }
                }
            case "e", "E":
                if let last = current.unicodeScalars.last, ("0"..."9").contains(last), !current.contains("e") {
                    current.append("e")
                } else {
                    flush()
                }
            default:
                flush()
            }
            if result.count >= 4096 { return result }
        }
        flush()
        return result
    }

    /// Points from "1,2;3,4", "1,2 3,4", "[[1,2],[3,4]]" or a flat "1,2,3,4".
    /// A segment shorter than `size` is padded with zeros (2D points given to a 3D verb).
    static func groups(_ text: String, size: Int) -> [[Double]] {
        guard size > 0 else { return [] }
        var segments: [String] = []
        if text.contains(";") || text.contains("|") {
            segments = text.split(whereSeparator: { $0 == ";" || $0 == "|" }).map(String.init)
        } else if text.contains("],") || text.contains("),") || text.contains("] [") || text.contains(") (") {
            segments = text.split(whereSeparator: { $0 == "]" || $0 == ")" }).map(String.init)
        } else if text.contains(" ") && text.contains(",") {
            segments = text.split(separator: " ").map(String.init)
        }
        if segments.count > 1 {
            return segments.compactMap { segment in
                var values = scan(segment)
                if values.isEmpty { return nil }
                while values.count < size { values.append(0) }
                return Array(values.prefix(size))
            }
        }
        let flat = scan(text)
        guard flat.count >= size else { return [] }
        return stride(from: 0, through: flat.count - size, by: size).map { Array(flat[$0..<($0 + size)]) }
    }
}

// MARK: - Colours

struct SceneColor: Equatable, Codable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    func with(alpha: Double) -> SceneColor { SceneColor(r, g, b, alpha) }

    func mixed(with other: SceneColor, amount: Double) -> SceneColor {
        SceneColor(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount, a)
    }

    static let marker = SceneColor(hex: 0xE5484D)
    static let ink = SceneColor(hex: 0x26324A)

    static let named: [String: SceneColor] = [
        "red": SceneColor(hex: 0xE5484D), "orange": SceneColor(hex: 0xF76B15), "amber": SceneColor(hex: 0xFFB224),
        "yellow": SceneColor(hex: 0xFFC53D), "gold": SceneColor(hex: 0xE9B13B), "green": SceneColor(hex: 0x30A46C),
        "lime": SceneColor(hex: 0x99D52A), "teal": SceneColor(hex: 0x12A594), "cyan": SceneColor(hex: 0x22B8CF),
        "blue": SceneColor(hex: 0x3B82F6), "sky": SceneColor(hex: 0x7CC4FA), "lightblue": SceneColor(hex: 0x7CC4FA),
        "navy": SceneColor(hex: 0x1E3A8A), "indigo": SceneColor(hex: 0x4F46E5), "purple": SceneColor(hex: 0x8E4EC6),
        "violet": SceneColor(hex: 0xA78BFA), "pink": SceneColor(hex: 0xE93D82), "magenta": SceneColor(hex: 0xD6409F),
        "white": SceneColor(hex: 0xF8F8F5), "black": SceneColor(hex: 0x1B1B1F), "gray": SceneColor(hex: 0x8B8D98),
        "grey": SceneColor(hex: 0x8B8D98), "darkgray": SceneColor(hex: 0x4A4D57), "darkgrey": SceneColor(hex: 0x4A4D57),
        "lightgray": SceneColor(hex: 0xC9CBD3), "lightgrey": SceneColor(hex: 0xC9CBD3),
        "silver": SceneColor(hex: 0xC8CCD4), "steel": SceneColor(hex: 0x8A96A8), "metal": SceneColor(hex: 0xB4BAC4),
        "brown": SceneColor(hex: 0x8D5A3B), "copper": SceneColor(hex: 0xC77B4A), "bronze": SceneColor(hex: 0xB08D57),
        "cream": SceneColor(hex: 0xF6EFD9), "tan": SceneColor(hex: 0xD9C3A0), "beige": SceneColor(hex: 0xD9C3A0),
        "glass": SceneColor(hex: 0xBFE3FF, alpha: 0.35), "ink": SceneColor(hex: 0x26324A),
        "pcb": SceneColor(hex: 0x1F7A4D), "skin": SceneColor(hex: 0xF0C8A0),
    ]

    /// Distinct, friendly colours handed to parts that don't name one.
    static let palette: [SceneColor] = ["blue", "orange", "teal", "pink", "yellow", "purple", "green", "red"]
        .compactMap { named[$0] }

    static func parse(_ text: String) -> SceneColor? {
        let key = text.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if let color = named[key] { return color }
        if key.hasPrefix("#") || key.hasPrefix("0x") {
            let digits = key.hasPrefix("#") ? String(key.dropFirst()) : String(key.dropFirst(2))
            if digits.count == 6, let value = UInt32(digits, radix: 16) { return SceneColor(hex: value) }
            if digits.count == 3, let value = UInt32(digits, radix: 16) {
                let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
                return SceneColor(hex: (r * 17) << 16 | (g * 17) << 8 | (b * 17))
            }
        }
        if key.hasPrefix("dark"), let base = named[String(key.dropFirst(4))] {
            return base.mixed(with: SceneColor(0, 0, 0), amount: 0.35)
        }
        if key.hasPrefix("light"), let base = named[String(key.dropFirst(5))] {
            return base.mixed(with: SceneColor(1, 1, 1), amount: 0.45)
        }
        return nil
    }

    /// A stable palette colour for an id.
    static func automatic(for id: String) -> SceneColor {
        palette[Int(SceneRNG.hash(id) % UInt64(palette.count))]
    }
}

// MARK: - Deterministic randomness

/// SplitMix64, seeded from an id, so the same script always draws the same wobble.
struct SceneRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    init(id: String) { self.init(seed: SceneRNG.hash(id)) }

    /// FNV-1a.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Uniform in -1...1.
    mutating func signed() -> Double { unit() * 2 - 1 }

    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
}
