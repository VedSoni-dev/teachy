//
//  SceneJevRouter.swift
//  leanring-buddy / Core
//
//  Jev as the 3D engine's fast front door. While a 3D drawing is up, a spoken
//  follow-up that the keyword rules can't place ("could you get a bit nearer",
//  "what's the red thing at the back doing") used to go the long way: screenshot,
//  a full voice turn, then a [SHOW:] that refines the drawing. One Jev call
//  (cheap, a fraction of a second) answers three questions instead:
//
//    control        is the whole request just a view or speed control? which one?
//    about_drawing  is it about the drawing on screen at all?
//    part           which part of the drawing does it name?
//
//  A control runs locally at once (SceneLiveAdjustment, no model). A request about
//  the drawing goes straight to SceneDirector.refine, skipping the screenshot and
//  the voice turn. Anything else, or Jev unsure, unreachable or slow, falls back
//  to the old path unchanged.
//
//  `questions` and `decision` are pure; `decide` makes the one network call.
//

import Foundation

enum SceneJevDecision: Equatable {
    /// Run this canonical control phrase through SceneLiveAdjustment.
    case adjust(phrase: String)
    /// Refine the drawing on screen; `parts` may be empty.
    case refine(parts: [String])
}

enum SceneJevRouter {
    /// Control option id → (what it means for Jev, the phrase SceneLiveAdjustment already knows).
    static let controls: [(id: String, meaning: String, phrase: String)] = [
        ("zoom_in", "Move the view closer / zoom in, nothing else asked", "zoom in"),
        ("zoom_out", "Move the view further away / zoom out, nothing else asked", "zoom out"),
        ("recenter", "Reset or recenter the view to show the whole drawing, nothing else asked", "recenter"),
        ("slower", "Slow the animation or motion down, nothing else asked", "slow it down"),
        ("faster", "Speed the animation or motion up, nothing else asked", "speed it up"),
        ("pause", "Pause or freeze the animation, nothing else asked", "pause motion"),
        ("resume", "Resume or continue the paused animation, nothing else asked", "resume motion"),
        ("normal_speed", "Put the animation back to normal speed, nothing else asked", "normal speed"),
    ]
    static let noneOptionID = "none"

    /// Parts offered to Jev's `part` question. Choice allows up to 255 options; keep the prompt small.
    static let maximumPartOptions = 60

    static let controlConfidenceNeeded = 0.8
    static let aboutDrawingProbabilityNeeded = 0.8
    static let partConfidenceNeeded = 0.6

    /// Jev's answer must arrive within this, or the old path runs.
    static let timeout: TimeInterval = 1.5

    /// Part option ids are `p0`, `p1`…; this maps them back to the drawing's part ids.
    struct PartOptions: Equatable {
        var criteria: [String: String] = [:]
        var partIDForOptionID: [String: String] = [:]
    }

    static func partOptions(from candidates: [SceneSubjectCandidate]) -> PartOptions {
        var options = PartOptions()
        var index = 0
        for candidate in candidates {
            let description = [candidate.label, candidate.name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: " — ")
            guard !description.isEmpty else { continue }
            let optionID = "p\(index)"
            options.criteria[optionID] = description
            options.partIDForOptionID[optionID] = candidate.id
            index += 1
            if index >= maximumPartOptions { break }
        }
        return options
    }

    static func state(request: String, title: String?) -> String {
        let drawingName = (title?.isEmpty == false) ? "\"\(title!)\"" : "an untitled 3D drawing"
        return """
        Teachy, a screen assistant, is showing \(drawingName) as a live 3D drawing. \
        The person just said: "\(request)"
        """
    }

    static func questions(title: String?, partOptions: PartOptions) -> [String: TeachyJevQuestion] {
        var controlCriteria: [String: String] = [:]
        for control in controls { controlCriteria[control.id] = control.meaning }
        controlCriteria[noneOptionID] = "Anything else: a question, an explanation, a change to parts, a new subject, or a control combined with another request"

        var questions: [String: TeachyJevQuestion] = [
            "control": .choice(
                instructions: "Is the person's whole request only a view or animation-speed control for the 3D drawing? Which one?",
                criteria: controlCriteria
            ),
            "about_drawing": .noul(
                instructions: "The person is asking about, or asking to change or look at, the 3D drawing that is on screen (its view, parts, motion or how it works), not asking for a different subject and not about another app or website."
            ),
        ]
        if !partOptions.criteria.isEmpty {
            var partCriteria = partOptions.criteria
            partCriteria[noneOptionID] = "No single part of the drawing is named or pointed at"
            questions["part"] = .choice(
                instructions: "Which part of the 3D drawing does the person name or point at?",
                criteria: partCriteria
            )
        }
        return questions
    }

    /// What to do with Jev's answers. Nil: not sure enough, use the old path.
    static func decision(from answers: TeachyJevAnswers, partOptions: PartOptions) -> SceneJevDecision? {
        if let control = answers.choices["control"], control.choice != noneOptionID,
           control.confidence >= controlConfidenceNeeded,
           let phrase = controls.first(where: { $0.id == control.choice })?.phrase {
            return .adjust(phrase: phrase)
        }
        guard let aboutDrawing = answers.nouls["about_drawing"], aboutDrawing >= aboutDrawingProbabilityNeeded else { return nil }
        var parts: [String] = []
        if let part = answers.choices["part"], part.choice != noneOptionID, part.confidence >= partConfidenceNeeded,
           let partID = partOptions.partIDForOptionID[part.choice] {
            parts = [partID]
        }
        return .refine(parts: parts)
    }

    /// One Jev call for a request the keyword rules sent away from a live drawing.
    static func decide(request: String, title: String?, candidates: [SceneSubjectCandidate]) async -> SceneJevDecision? {
        guard TeachyJev.isAvailable, !SceneCanvasRoute.namesExternalTarget(request) else { return nil }
        let partOptions = partOptions(from: candidates)
        let startedAt = Date()
        do {
            let answers = try await TeachyJev.ask(
                state: state(request: request, title: title),
                questions: questions(title: title, partOptions: partOptions),
                timeout: timeout
            )
            let decision = decision(from: answers, partOptions: partOptions)
            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("⚡️ Jev routed a drawing follow-up in \(milliseconds) ms → \(decision.map { "\($0)" } ?? "old path")")
            return decision
        } catch {
            print("⚠️ Jev unavailable for drawing routing: \(error.localizedDescription)")
            return nil
        }
    }
}
