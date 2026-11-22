import Foundation

/// Routes owned-canvas requests before the screen-capture/vision pipeline.
/// External screen tasks retain their existing route even while a drawing is open.
enum SceneCanvasRoute: Equatable {
    case inspect
    case commands(String)
    case refine(parts: [String], reason: String)
    case external

    /// Words that point outside Teachy's own canvas ("on my screen", "in chrome", "this error").
    static let externalTargetPhrases = ["screenshot", "on my screen", "on the screen", "in chrome", "in safari", "in firefox", "in the browser", "website", "web page", "my code", "this error", "terminal", "email", "spreadsheet", "settings", "this tab", "this window"]

    static func namesExternalTarget(_ request: String) -> Bool {
        let lower = request.lowercased()
        return externalTargetPhrases.contains(where: lower.contains)
    }

    static func decide(_ request: String, live: Bool, title: String?, parts: [SceneSubjectCandidate]) -> Self {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/canvas" || trimmed == "/canvas inspect" { return .inspect }
        if trimmed.hasPrefix("/canvas ") { return .commands(String(trimmed.dropFirst(8))) }
        guard live else { return .external }
        let lower = request.lowercased()
        guard !namesExternalTarget(request) else { return .external }
        let words = SceneSubjectMatcher.words(request)
        let newRequest = ["new diagram", "new model", "new drawing", "instead", "different subject"].contains(where: lower.contains)
            || words.contains(where: { ["draw", "sketch", "build", "create", "generate"].contains($0) })
        let ownedSubject = words.contains(where: { ["canvas", "diagram", "drawing", "model", "parts"].contains($0) })
        if ownedSubject && !newRequest {
            return .refine(parts: SceneSubjectMatcher.match(sentence: request, parts: parts), reason: "explicit owned canvas")
        }
        switch SceneRefineClassifier.classify(request: request, sceneIsLive: true, title: title, parts: parts) {
        case .refine(let parts, let reason): return .refine(parts: parts, reason: reason)
        case .newDrawing: return .external
        }
    }
}
