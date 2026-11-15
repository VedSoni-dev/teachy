//
//  SceneRefine.swift
//  leanring-buddy / Scene
//
//  Refining a drawing that is already on screen instead of drawing it again.
//
//    SceneRefineClassifier  is the new request about the model on screen, or a new drawing?
//    SceneSentenceSubject   which parts a narration sentence is about (its own lines first, then its words)
//    SceneLiveState         the model on screen described in a few lines, for the refine request
//    SceneRefinePrompt      the compact system prompt for a refine turn, and which lines it may contain
//    SceneDetail            `detail <id>`: a richer sub-assembly for the commonest ready-made parts
//
//  Pure (Foundation + simd). Tested in scripts/tests/scene3.
//

import Foundation
import simd

// MARK: - Refine or redraw

enum SceneRefineDecision: Equatable {
    /// Adjust the model on screen. `parts` are the parts of it the request names (may be empty).
    case refine(parts: [String], reason: String)
    case newDrawing(reason: String)

    var isRefine: Bool { if case .refine = self { return true } else { return false } }
}

enum SceneRefineClassifier {
    /// Requests that only make sense about the thing already on screen.
    static let refinePhrases: [String] = [
        "zoom", "closer", "close up", "closeup", "close-up", "magnify", "focus on", "look at the", "inside", "cut away", "cutaway", "cross section",
        "see through", "x-ray", "xray", "rotate", "turn it", "spin it", "flip it", "other side", "from the back", "from the top", "from the side",
        "from the front", "from above", "from below", "from behind", "explode", "exploded", "take it apart", "pull it apart", "pull apart", "apart",
        "put it back", "back together", "go back", "zoom out", "reset", "recenter", "re-center", "whole thing", "whole model", "everything again",
        "hide the", "remove the", "get rid of", "without the", "highlight", "point to", "point out", "where is the", "where's the", "which part",
        "what's that", "what is that", "whats that", "what's this", "what is this", "that part", "this part", "more detail", "in detail", "bigger",
        "up close", "show me the", "what does the", "what do the", "what does that", "label the", "name the parts",
    ]

    /// Requests that ask for a different picture.
    static let newPhrases: [String] = [
        "instead", "something else", "something different", "another one", "a different", "new drawing", "new model", "new diagram", "start over",
        "start again", "from scratch", "now draw", "now show me a", "now show me an", "now show me how", "on a card", "as a chart", "bar chart", "graph of",
    ]

    static let creationVerbs: Set<String> = ["draw", "sketch", "build", "make", "create", "design", "generate", "chart", "plot", "compare"]

    static let colourWords: Set<String> = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "white", "black", "gray", "grey", "silver",
                                           "gold", "golden", "copper", "brown", "cream"]

    /// Conservative: with no drawing on screen it is always a new drawing; with one, the request is a
    /// refinement when it uses camera words, points at "that" thing, or names a part of the model.
    /// When nothing says either way, it is a new drawing.
    static func classify(request: String, sceneIsLive: Bool, title: String?, parts: [SceneSubjectCandidate]) -> SceneRefineDecision {
        guard sceneIsLive else { return .newDrawing(reason: "nothing on screen") }
        let lowered = " " + request.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let tokens = SceneSubjectMatcher.words(request)
        guard !tokens.isEmpty else { return .newDrawing(reason: "empty request") }
        let matched = SceneSubjectMatcher.match(sentence: request, parts: parts)

        let asksForNew = newPhrases.contains { lowered.contains($0) }
        let startsWithCreation = tokens.first.map { creationVerbs.contains($0) } ?? false
        if asksForNew && matched.isEmpty { return .newDrawing(reason: "asks for something else") }

        if let phrase = refinePhrases.first(where: { lowered.contains($0) }) {
            // "show me the inside of a rocket" while a jet engine is up is a new drawing: a camera
            // phrase only refines when nothing in the request names a thing the model does not have.
            if matched.isEmpty, startsWithCreation { return .newDrawing(reason: "asks to draw something") }
            if matched.isEmpty, namesAnotherThing(tokens: tokens, title: title, parts: parts, phrase: phrase) {
                return .newDrawing(reason: "names something that is not in this model")
            }
            return .refine(parts: matched, reason: "camera words: \(phrase.trimmingCharacters(in: .whitespaces))")
        }

        // "what's that orange thing", "the blue one".
        if tokens.contains(where: colourWords.contains), tokens.contains(where: { ["part", "thing", "bit", "piece", "one", "tube", "ring", "blob"].contains($0) }) {
            return .refine(parts: matched, reason: "asks about a part by colour")
        }

        if !matched.isEmpty {
            if startsWithCreation, asksForNew { return .newDrawing(reason: "asks for something else") }
            return .refine(parts: matched, reason: "names a part of the model")
        }

        // A short request that leans on "it" / "that" is about what is on screen.
        let pronouns: Set<String> = ["it", "that", "this", "these", "those", "there"]
        if tokens.count <= 7, tokens.contains(where: pronouns.contains), !startsWithCreation {
            return .refine(parts: [], reason: "short request about \"it\"")
        }

        // Asking more about the very thing in the title.
        if let title, !startsWithCreation {
            let titleWords = Set(SceneSubjectMatcher.words(title).filter { $0.count >= 4 && !SceneSubjectMatcher.stopWords.contains($0) && !["work", "works"].contains($0) })
            if !titleWords.isEmpty, tokens.contains(where: titleWords.contains), tokens.count <= 9 {
                return .refine(parts: [], reason: "about the model in the title")
            }
        }
        return .newDrawing(reason: "nothing ties it to the model on screen")
    }

    static let wholePhrases: [String] = ["go back", "zoom out", "reset", "recenter", "re-center", "whole thing", "whole model", "whole engine", "everything again",
                                         "back to the whole", "back out", "put it back", "back together"]

    /// What can be done the instant the request arrives, before the model has answered: the camera
    /// goes to the part the request names, or back to the whole model. Nil when the request does not
    /// say plainly where to look (the model's own lines then do everything).
    static func instantScript(request: String, parts: [String]) -> String? {
        let lowered = " " + request.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if wholePhrases.contains(where: { lowered.contains($0) }) { return "frame all" }
        guard !parts.isEmpty else { return nil }
        let tight = ["zoom", "closer", "close up", "closeup", "close-up", "up close", "magnify", "more detail", "in detail", "bigger"].contains { lowered.contains($0) }
        return "focus \(parts.joined(separator: ",")) zoom=\(tight ? "tight" : "medium")"
    }

    /// After a camera phrase, does the request go on to name a thing ("…inside a rocket") that this model is not?
    private static func namesAnotherThing(tokens: [String], title: String?, parts: [SceneSubjectCandidate], phrase: String) -> Bool {
        // "a/an <noun>" introduces a new thing; "the <noun>", "it", "that" refer to this one.
        guard let article = tokens.firstIndex(where: { $0 == "a" || $0 == "an" }), article + 1 < tokens.count else { return false }
        let known = Set((title.map(SceneSubjectMatcher.words) ?? []) + parts.flatMap { SceneSubjectMatcher.words($0.label ?? "") + SceneSubjectMatcher.words($0.name ?? "") + SceneSubjectMatcher.idWords($0.id) })
        let following = tokens[(article + 1)...].filter { !SceneSubjectMatcher.stopWords.contains($0) }
        guard let noun = following.first else { return false }
        if ["bit", "little", "lot", "closer", "look", "moment", "second", "different"].contains(noun) { return noun == "different" }
        return !following.contains(where: known.contains)
    }
}

// MARK: - What a sentence is about

enum SceneSentenceSubject {
    /// The parts sentence `text` is about. Its own lines decide first: parts it labels, then parts it
    /// moves or pulses, then parts it creates (when there are only a few). Otherwise the words decide.
    /// Empty means "the whole model".
    static func infer(sentence text: String, commands: [SceneCommand], candidates: [SceneSubjectCandidate]) -> [String] {
        var labelled: [String] = [], acted: [String] = [], created: [String] = []
        func add(_ id: String, to list: inout [String]) { if !list.contains(id) { list.append(id) } }
        for command in commands {
            switch command.verb {
            case .label:
                if let target = command.string("on") { add(target, to: &labelled) }
            case .pulse, .beat, .spin, .move:
                if command.hasExplicitID { add(command.id, to: &acted) }
            case .highlight where command.isPartHighlight:
                for id in command.targetIDs { add(id, to: &acted) }
            case .say, .scene3d, .chip, .slider, .plot, .ground, .gravity, .text3, .flow, .axes, .group:
                break
            default:
                guard command.verb.makes3DPart, command.hasExplicitID, command.verb != .arrow3 else { break }
                if command.string("label") != nil { add(command.id, to: &labelled) } else { add(command.id, to: &created) }
            }
        }
        let spoken = SceneSubjectMatcher.match(sentence: text, parts: candidates)
        func narrowed(_ ids: [String]) -> [String] {
            // A sentence that labels five parts is a tour of the whole thing, unless its words single some out.
            if ids.count <= 3 { return ids }
            let named = ids.filter(spoken.contains)
            return named.isEmpty || named.count > 3 ? [] : named
        }
        if !labelled.isEmpty { return narrowed(labelled) }
        if !acted.isEmpty { return narrowed(acted) }
        // A sentence that builds the whole object is about the whole object: the words decide.
        if !created.isEmpty, created.count <= 2, spoken.isEmpty, !commands.contains(where: { $0.verb == .scene3d }) { return created }
        return spoken
    }

    /// True when one of a sentence's own lines already tells the camera what to do.
    static func hasCameraDirection(_ commands: [SceneCommand]) -> Bool {
        commands.contains { $0.movesCamera && !$0.flag("auto") }
    }
}

// MARK: - The model on screen, in words

struct SceneLivePart: Equatable {
    var id: String
    /// Its label or built-in name.
    var title: String?
    var colour: String?
    /// The part it sits inside (which hides it).
    var inside: String?
    var isGhosted = false
    var isHidden = false
    /// `detail <id>` has something to add.
    var canDetail = false
}

struct SceneLiveState: Equatable {
    var title: String?
    var parts: [SceneLivePart] = []
    var focus: [String] = []
    var isExploded = false

    /// A few lines a model can read. Capped so a big scene does not swamp the request.
    func text(limit: Int = 44) -> String {
        var lines: [String] = []
        lines.append("Model on screen: \"\(title ?? "untitled")\"")
        lines.append("Parts (id \"name\" colour notes):")
        for part in parts.prefix(limit) {
            var line = part.id
            if let title = part.title, !title.isEmpty { line += " \"\(title)\"" }
            if let colour = part.colour { line += " \(colour)" }
            if let inside = part.inside { line += " inside=\(inside)" }
            if part.canDetail { line += " detail" }
            if part.isGhosted { line += " ghosted" }
            if part.isHidden { line += " hidden" }
            lines.append(line)
        }
        if parts.count > limit { lines.append("(and \(parts.count - limit) smaller parts)") }
        lines.append("Camera now: " + (focus.isEmpty ? "the whole model" : "on " + focus.joined(separator: ",")))
        if isExploded { lines.append("The model is exploded (pulled apart).") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The refine request

enum SceneRefinePrompt {
    static let system = """
    A 3D model is ALREADY on screen and the person asked about it. You direct the camera and say a little. Output ONLY TeachyScene lines: one command per line, no prose, no markdown.
    Do NOT rebuild the model: never write scene3d, card, clear, or the object again. Use part ids exactly as listed.
    say N "sentence" is spoken aloud; the lines after it happen while it is spoken. Write 1-2 short sentences (under 16 words) that answer what was asked. For a pure camera request ("rotate it", "go back") one very short sentence.
    focus id[,id] zoom=tight|medium|wide (ease the camera onto those parts) / frame all (back to the whole model) / orbit id deg=180 dur=5 (swing slowly round a part; `orbit all` = round the model) / ghost id id (make parts see-through to show what is inside; `ghost others` ghosts everything but the focused part) / show all (everything solid and visible again) / hide id / highlight id color=yellow (a glow on the part you are talking about) / explode (pull the parts apart; `explode dist=0` puts them back) / detail id (adds finer pieces and their names to a part marked `detail`; use it when you zoom in on one) / label x on=id text="Name" / pulse id
    You may add a FEW small things in the focused part: arrow3 id from=x,y,z to=x,y,z, flow id pts=x,y,z;x,y,z color=, text3 id at= text="…", or one shape with parent=partId.
    "zoom in on X": focus X zoom=tight, and detail X if marked. "show me inside": ghost what is around it (a part's inside= names what hides it) or `ghost others`. "what is that <colour> part": find it by colour, focus and highlight it, say what it is. "go back", "zoom out", "reset": show all, frame all (and explode dist=0 if exploded). A tapped part: focus it, highlight it, say what it does.

    Example (zoom in on the turbine):
    say 1 "Here is the turbine. Hot gas pushes these blades round."
    focus j.turbine zoom=tight
    ghost j.casing j.nacelle
    detail j.turbine
    highlight j.turbine

    Example (go back):
    say 1 "Back to the whole engine."
    show all
    frame all
    """

    /// The chat-completions body for a refine turn (no "model": TeachyAIRouter sets it).
    /// Thinking is kept minimal: the answer is five short lines about a model that is already described.
    static func requestBody(request: String, state: SceneLiveState, tappedPart: String? = nil, reasoningEffort: String? = "minimal") -> [String: Any] {
        var user = state.text() + "\n\n"
        if let tappedPart {
            user += "The person tapped the part \(tappedPart). " + request
        } else {
            user += "The person asked: " + request
        }
        var body: [String: Any] = [
            "stream": true,
            "max_tokens": 600,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        return body
    }

    /// Lines a refine turn may contain: camera, visibility, labels, speech, and small additions.
    /// Anything that would rebuild or replace the model is dropped.
    static func allows(_ command: SceneCommand) -> Bool {
        if command.directsView { return true }
        switch command.verb {
        case .say, .show, .hide, .pulse, .explode, .spin, .beat, .move, .chip, .orbit:
            return true
        case .label:
            return command.string("on") != nil
        case .arrow, .arrow3, .line:
            return command.numbers("from").count >= 3 || command.numbers("to").count >= 3 || command.numbers("pts").count >= 6
        case .flow, .text3, .box, .sphere, .cyl, .cone, .torus, .capsule, .tube:
            return true
        default:
            return false
        }
    }

    static var examples: [String] {
        system.components(separatedBy: "):\n").dropFirst().map { chunk in
            (chunk.components(separatedBy: "\n\nExample").first ?? chunk).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Detail on demand

/// What `detail <id>` knows about the part it is asked to enrich.
struct SceneDetailSubject {
    var id: String
    /// The line that made the part (`fan j.fan r=0.98 …`), when it came from one.
    var source: SceneCommand?
    /// The whole object the part belongs to (`heart` for `h.lv`).
    var macro: SceneVerb?
    /// The lines that made its children, when the part is a group (the stages of a turbine).
    var children: [SceneCommand] = []
    var parent: String?
    /// The part's own size, in its own space.
    var localSize = SceneVec3(1, 1, 1)
}

enum SceneDetail {
    enum Kind: String, Equatable {
        case fan, fanStack, gear, piston, wheel, component, heartChamber, dna
    }

    /// The kind of sub-assembly a part gets, or nil when `detail` has nothing to add (a no-op).
    static func kind(of subject: SceneDetailSubject) -> Kind? {
        if let verb = subject.source?.verb {
            switch verb {
            case .fan: return .fan
            case .gear: return .gear
            case .piston: return .piston
            case .wheel: return .wheel
            case .comp, .chip: return .component
            case .dna: return .dna
            case .sphere where subject.macro == .heart:
                let suffix = subject.id.split(separator: ".").last.map(String.init) ?? ""
                return ["ra", "rv", "la", "lv"].contains(suffix) ? .heartChamber : nil
            case .group where subject.children.filter({ $0.verb == .fan }).count >= 2:
                return .fanStack
            default: break
            }
        }
        return nil
    }

    private static func n(_ value: Double) -> String { SceneMacros.n(value) }

    /// The lines that enrich the part: a few more pieces as its children, and names for them.
    static func commands(for subject: SceneDetailSubject) -> [SceneCommand] {
        guard let kind = kind(of: subject) else { return [] }
        let id = subject.id
        let c = subject.source
        var lines: [String] = []
        switch kind {
        case .fan:
            let radius = abs(c?.number("r") ?? 1)
            let hub = min(abs(c?.number("hub") ?? radius * 0.25), radius * 0.9)
            let blades = Int(min(max(c?.number("blades", "n", "count") ?? 8, 2), 64))
            let depth = abs(c?.number("thick", "depth", "w") ?? radius * 0.22)
            let pitch = c?.number("pitch") ?? 32
            // Thin splitter blades between the main ones, a root ring where blades meet the hub, and the shaft behind.
            let extra = min(blades, 24)
            let span = (radius - hub) * 0.62, middle = hub * 0.9 + span / 2
            for index in 0..<extra {
                let angle = (Double(index) + 0.5) / Double(extra) * 360
                let radians = angle * Double.pi / 180
                lines.append("box \(id).split\(index) parent=\(id) at=\(n(cos(radians) * middle)),0,\(n(sin(radians) * middle)) size=\(n(span)),\(n(radius * 0.016)),\(n(radius * 0.16)) rot=\(n(pitch)),\(n(-angle)),0 color=silver mat=metal")
            }
            lines.append("torus \(id).root parent=\(id) r=\(n(hub * 1.03)) r2=\(n(radius * 0.022)) color=darkgray mat=metal name=\"Blade roots\"")
            lines.append("cyl \(id).dshaft parent=\(id) from=0,\(n(-depth * 0.55)),0 to=0,\(n(-depth * 0.55 - radius * 0.55)),0 r=\(n(hub * 0.34)) color=silver name=\"Shaft\"")
            lines.append("label \(id).dl1 on=\(id).blade0 text=\"Blades\"")
            lines.append("label \(id).dl2 on=\(id).hub text=\"Hub\"")
            lines.append("label \(id).dl3 on=\(id).dshaft text=\"Shaft\"")
        case .fanStack:
            let stages = subject.children.filter { $0.verb == .fan }.sorted { ($0.vec3("at")?.y ?? 0) < ($1.vec3("at")?.y ?? 0) }
            let plain = c?.args["at"] == nil && c?.args["axis"] == nil && c?.args["rot"] == nil && c?.args["scale"] == nil
            if plain, let home = subject.parent ?? c?.string("parent") {
                // Still vanes between the turning stages (they hang from the casing, so they are not children of the spinning group).
                for (index, pair) in zip(stages, stages.dropFirst()).enumerated() {
                    let a = pair.0, b = pair.1
                    let y = ((a.vec3("at")?.y ?? 0) + (b.vec3("at")?.y ?? 0)) / 2
                    let radius = ((a.number("r") ?? 0.5) + (b.number("r") ?? 0.5)) / 2
                    let hub = ((a.number("hub") ?? radius * 0.4) + (b.number("hub") ?? radius * 0.4)) / 2
                    lines.append("fan \(id).stator\(index + 1) parent=\(home) at=0,\(n(y)),0 axis=y r=\(n(radius * 0.98)) hub=\(n(hub)) blades=24 pitch=-42 thick=\(n(radius * 0.1)) color=gray name=\"Stator vanes\"")
                }
                if !stages.isEmpty { lines.append("label \(id).dl2 on=\(id).stator1 text=\"Stator vanes\"") }
            }
            if let first = stages.first {
                lines.append("label \(id).dl1 on=\(first.id).blade0 text=\"Rotor blades\"")
                lines.append("label \(id).dl3 on=\(first.id).hub text=\"Disc\"")
            }
            if let home = subject.parent { lines.append("label \(id).dl4 on=\(home).shaft text=\"Shaft\"") }
        case .gear:
            let radius = max(subject.localSize.x, subject.localSize.y) / 2
            let depth = max(subject.localSize.z, radius * 0.1)
            let hole = min(max(c?.number("hole") ?? radius * 0.18, radius * 0.08), radius * 0.6)
            lines.append("cyl \(id).boss parent=\(id) axis=z r=\(n(max(hole * 1.9, radius * 0.26))) h=\(n(depth * 1.5)) color=steel name=\"Hub\"")
            lines.append("cyl \(id).axle parent=\(id) axis=z r=\(n(hole * 0.98)) h=\(n(depth * 4.2)) color=silver name=\"Axle\"")
            lines.append("box \(id).key parent=\(id) at=0,\(n(hole * 1.05)),0 size=\(n(hole * 0.5)),\(n(hole * 0.5)),\(n(depth * 1.6)) color=darkgray mat=metal name=\"Key\"")
            lines.append("torus \(id).pitch parent=\(id) axis=z r=\(n(radius * 0.88)) r2=\(n(radius * 0.012)) color=red name=\"Pitch circle\"")
            lines.append("label \(id).dl1 on=\(id).boss text=\"Hub\"")
            lines.append("label \(id).dl2 on=\(id).axle text=\"Axle\"")
            lines.append("label \(id).dl3 on=\(id).pitch text=\"Pitch circle\"")
        case .piston:
            let bore = abs(c?.number("bore") ?? (c?.number("r").map { $0 * 2 }) ?? 1)
            let headHeight = bore * 0.55
            for (index, y) in [0.3, 0.12, -0.08].enumerated() {
                lines.append("torus \(id).head.ring\(index + 1) parent=\(id).head at=0,\(n(headHeight * y)),0 r=\(n(bore / 2)) r2=\(n(bore * 0.022)) color=black mat=metal")
            }
            lines.append("cyl \(id).head.wrist parent=\(id).head at=0,\(n(-headHeight * 0.2)),0 axis=z r=\(n(bore * 0.075)) h=\(n(bore * 0.86)) color=silver name=\"Wrist pin\"")
            lines.append("label \(id).dl1 on=\(id).head text=\"Piston\"")
            lines.append("label \(id).dl2 on=\(id).head.ring1 text=\"Piston rings\"")
            lines.append("label \(id).dl3 on=\(id).rod text=\"Connecting rod\"")
            lines.append("label \(id).dl4 on=\(id).crank text=\"Crank\"")
            lines.append("label \(id).dl5 on=\(id).cylinder text=\"Cylinder\"")
        case .wheel:
            let radius = abs(c?.number("r") ?? 1)
            let width = abs(c?.number("w", "width", "thick") ?? radius * 0.35)
            lines.append("cyl \(id).disc parent=\(id) at=0,\(n(-width * 0.3)),0 r=\(n(radius * 0.46)) h=\(n(width * 0.07)) color=steel name=\"Brake disc\"")
            lines.append("box \(id).caliper parent=\(id) at=\(n(radius * 0.4)),\(n(-width * 0.3)),0 size=\(n(radius * 0.2)),\(n(width * 0.3)),\(n(radius * 0.3)) color=red name=\"Caliper\"")
            for index in 0..<5 {
                let angle = Double(index) / 5 * 2 * Double.pi
                lines.append("cyl \(id).nut\(index) parent=\(id) at=\(n(cos(angle) * radius * 0.1)),\(n(width * 0.42)),\(n(sin(angle) * radius * 0.1)) r=\(n(radius * 0.022)) h=\(n(width * 0.1)) color=silver")
            }
            lines.append("label \(id).dl1 on=\(id).tire text=\"Tyre\"")
            lines.append("label \(id).dl2 on=\(id).rim text=\"Rim\"")
            lines.append("label \(id).dl3 on=\(id).hub text=\"Hub\"")
            lines.append("label \(id).dl4 on=\(id).disc text=\"Brake disc\"")
        case .component:
            let width = subject.localSize.x, height = subject.localSize.y, depth = subject.localSize.z
            // Legs down both long sides, like a chip package, and a mark for pin 1.
            let alongX = width >= depth
            let long = max(width, depth), short = min(width, depth)
            let count = min(max(Int(long / max(short * 0.22, 1e-4)), 4), 14)
            for side in [-1.0, 1.0] {
                for pin in 0..<count {
                    let along = (Double(pin) + 0.5) * long / Double(count) - long / 2
                    let across = side * (short / 2 + short * 0.05)
                    let at = alongX ? "\(n(along)),\(n(-height * 0.3)),\(n(across))" : "\(n(across)),\(n(-height * 0.3)),\(n(along))"
                    let size = alongX ? "\(n(long / Double(count) * 0.45)),\(n(height * 0.3)),\(n(short * 0.12))" : "\(n(short * 0.12)),\(n(height * 0.3)),\(n(long / Double(count) * 0.45))"
                    lines.append("box \(id).leg\(side < 0 ? "a" : "b")\(pin) parent=\(id) at=\(at) size=\(size) color=silver mat=metal")
                }
            }
            lines.append("cyl \(id).pin1 parent=\(id) at=\(n(-width * 0.36)),\(n(height * 0.5)),\(n(-depth * 0.36)) r=\(n(short * 0.05)) h=\(n(height * 0.04)) color=white name=\"Pin 1 mark\"")
            lines.append("label \(id).dl1 on=\(id).lega0 text=\"Pins\"")
            lines.append("label \(id).dl2 on=\(id).pin1 text=\"Pin 1\"")
        case .heartChamber:
            let radius = abs(c?.number("r") ?? 0.5)
            let upper = subject.id.hasSuffix("a")
            // The valve the blood leaves through: a pale ring with three leaflets.
            let y = upper ? -radius * 0.82 : radius * 0.84
            lines.append("torus \(id).valve parent=\(id) at=0,\(n(y)),\(n(radius * 0.35)) r=\(n(radius * 0.3)) r2=\(n(radius * 0.05)) color=cream name=\"Valve\"")
            for index in 0..<3 {
                let angle = Double(index) / 3 * 2 * Double.pi
                lines.append("sphere \(id).leaf\(index) parent=\(id) at=\(n(cos(angle) * radius * 0.13)),\(n(y)),\(n(radius * 0.35 + sin(angle) * radius * 0.13)) r=\(n(radius * 0.13)) scale=1,0.35,1 color=white")
            }
            lines.append("label \(id).dl1 on=\(id).valve text=\"Valve\"")
        case .dna:
            let pairs = Int(min(max(c?.number("pairs") ?? ((c?.number("turns") ?? 2) * 10).rounded(), 2), 160))
            lines.append("label \(id).dl1 on=\(id).strand1 text=\"Sugar-phosphate backbone\"")
            lines.append("label \(id).dl2 on=\(id).b\(pairs / 2)a text=\"Base pair\"")
        }
        var result: [SceneCommand] = []
        for line in lines { result += SceneScriptParser.parse(line) }
        return result
    }
}
