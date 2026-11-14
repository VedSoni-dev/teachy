//
//  SceneDirector.swift
//  leanring-buddy
//
//  Connects the voice turn to the drawing engine. When a spoken answer carries
//  [SHOW: what to draw], the director asks the model for a scene script and feeds
//  it to a SceneSession line by line, so the drawing builds while it streams.
//

import AppKit
import Foundation

@MainActor
final class SceneDirector {
    static let shared = SceneDirector()

    private let scene = SceneSession()
    private var streamTask: Task<Void, Never>?

    /// Called when the person taps a follow-up chip or a part of a 3D model.
    var onFollowUpQuestion: ((String) -> Void)?

    private init() {
        scene.onChipTapped = { [weak self] question in self?.onFollowUpQuestion?(question) }
        scene.onPartTapped = { [weak self] _, label in
            guard !label.isEmpty else { return }
            self?.onFollowUpQuestion?("Tell me about the \(label).")
        }
    }

    /// Pulls `[SHOW: …]` out of a reply. Returns the text without the tag and what to draw.
    static func extractShowRequest(from text: String) -> (text: String, request: String?) {
        guard let regex = try? NSRegularExpression(pattern: #"\[SHOW:\s*([^\]]+)\]"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let inner = Range(match.range(at: 1), in: text)
        else { return (text, nil) }
        let request = text[inner].trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = text
        stripped.removeSubrange(whole)
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), request.isEmpty ? nil : request)
    }

    /// Draws `request` on the display under the mouse. Replaces any drawing already up.
    func show(_ request: String) {
        streamTask?.cancel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return }

        scene.begin(anchor: .display(frame: screenFrame, timing: .stagger))
        let startedAt = Date()
        streamTask = Task { [scene] in
            var firstLineLogged = false
            do {
                let bytes = try await TeachyAIRouter.openStream(
                    job: .scene,
                    hasImages: false,
                    session: .shared,
                    body: SceneScriptPrompt.requestBody(question: request)
                )
                for try await line in StreamIdleGuard.lines(from: bytes) {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let delta = (event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                          let chunk = delta["content"] as? String, !chunk.isEmpty
                    else { continue }
                    if !firstLineLogged, chunk.contains("\n") {
                        firstLineLogged = true
                        print("🎨 First drawing line \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s after the request")
                    }
                    scene.feed(chunk: chunk)
                }
            } catch {
                print("⚠️ Drawing failed: \(error.localizedDescription)")
            }
            if !Task.isCancelled { scene.end() }
        }
    }

    func clear() {
        streamTask?.cancel()
        scene.clear()
    }
}
