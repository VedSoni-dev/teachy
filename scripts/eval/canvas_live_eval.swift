// One synthetic live AI request: edit known engine parts without screenshots or rebuilding.
// Uses the real routing/auth request builder, but sends exactly one HTTP request (no retries).
import AppKit
import Foundation
import SceneKit

// Match the existing scene eval: Publik only; never prompt for an unrelated Keychain key.
enum TeachyAPIKeyStore { static var apiKey: String? { nil } }

@main enum CanvasLiveEval {
    static let requestText = "Move valve to (2,0,0) and make it blue without rebuilding."

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.async { Task { @MainActor in await run() } }
        app.run()
    }

    @MainActor static func run() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--out"), args.indices.contains(index + 1) else {
            print("Usage: canvas_live_eval --out PATH"); exit(2)
        }
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let scene = SceneSession()
        var summary: [String: Any] = ["request": requestText, "http_requests": 0, "screenshots_sent": 0]
        var raw = ""
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Isolate any future history wiring from the person's real saved drawings.
            setenv("TEACHY_DRAWINGS_DIR", output.appendingPathComponent("synthetic-history").path, 1)
            scene.beginHeadless(size: CGSize(width: 640, height: 480), timing: .stagger)
            scene.feed(chunk: "scene3d fixture title=\"Pump and valve\"\nbox pump at=-2,0,0 size=1,1,1 color=red label=\"Pump\"\nbox valve at=0,0,0 size=0.6,0.6,0.6 color=orange label=\"Valve\"\nframe all hold\n")
            scene.end()
            for frame in 0...90 { scene.advance(to: Double(frame) / 30) }
            guard let window = scene.modelWindow,
                  let valve = window.controller.scene.rootNode.childNode(withName: "valve", recursively: true),
                  let pump = window.controller.scene.rootNode.childNode(withName: "pump", recursively: true) else {
                throw Failure("Synthetic scene did not initialize its two parts")
            }
            let controller = window.controller
            let pumpGeometry = pump.geometry
            let before = controller.liveState
            try before.text().write(to: output.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
            guard let route = try TeachyAIRouter.routes(for: .scene, hasImages: false).first, route.isPublik else {
                throw Failure("No Publik route is available; sign into Teachy first")
            }
            summary["requested_model"] = route.model
            print("Canvas eval: one text-only request to \(route.model)")
            let body = SceneRefinePrompt.requestBody(request: requestText, state: before)
            let request = try TeachyAIRouter.makeRequest(for: route, job: .scene, body: body, timeout: 45)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            scene.beginRefinement(timing: .stagger)
            var rejected: [String] = []
            scene.commandFilter = { command in
                let accepted = SceneRefinePrompt.allows(command) && controller.canApplyCanvasCommand(command)
                if !accepted { rejected.append("\(command.verb.rawValue) \(command.id)") }
                return accepted
            }
            let parser = SceneScriptParser()
            var commands: [SceneCommand] = []
            let started = Date()
            summary["http_requests"] = 1
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw Failure("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1); no retry performed")
            }
            for try await line in StreamIdleGuard.lines(from: bytes) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let model = event["model"] as? String { summary["response_model"] = model }
                if event["error"] != nil { throw Failure("Provider returned a streaming error; no retry performed") }
                guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
                if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                    raw += text
                    commands += parser.feed(text)
                    scene.feed(chunk: text)
                    scene.advance(to: 3 + Date().timeIntervalSince(started))
                }
                if let reason = choice["finish_reason"] as? String { summary["finish_reason"] = reason; break }
            }
            commands += parser.finish()
            scene.end()
            // Run the same renderer clock as the headless scene eval, so animated moves settle too.
            let streamEnded = 3 + Date().timeIntervalSince(started)
            for frame in 0...180 {
                scene.advance(to: streamEnded + Double(frame) / 30)
                _ = controller.renderFrame(size: CGSize(width: 64, height: 48))
            }
            let after = controller.liveState
            try after.text().write(to: output.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
            let finalValve = after.parts.first { $0.id == "valve" }
            let unchangedIDs = Set(before.parts.map(\.id)) == Set(after.parts.map(\.id))
            let sameObjects = scene.modelWindow === window
                && controller.scene.rootNode.childNode(withName: "valve", recursively: true) === valve
                && controller.scene.rootNode.childNode(withName: "pump", recursively: true) === pump
                && pump.geometry === pumpGeometry
            let position = finalValve?.position ?? SceneVec3(repeating: .infinity)
            let moved = simd_length(position - SceneVec3(2, 0, 0)) < 0.001
            let blue = finalValve?.colour == "blue"
            let safeCommands = !commands.isEmpty && parser.stats.invalid == 0 && parser.stats.prose == 0 && rejected.isEmpty
                && !commands.contains { $0.verb.makes3DPart || [.scene3d, .clear, .remove, .card].contains($0.verb) }
            let pumpUnchanged = pump.simdPosition == SIMD3<Float>(-2, 0, 0)
                && after.parts.first(where: { $0.id == "pump" })?.colour == before.parts.first(where: { $0.id == "pump" })?.colour
            summary.merge([
                "duration_seconds": Date().timeIntervalSince(started),
                "commands": commands.count,
                "rejected_commands": rejected,
                "parse_invalid": parser.stats.invalid,
                "parse_prose": parser.stats.prose,
                "same_window_and_nodes": sameObjects,
                "same_part_ids": unchangedIDs,
                "valve_position": [position.x, position.y, position.z].filter { $0.isFinite },
                "valve_color": finalValve?.colour ?? "missing",
                "pump_unchanged": pumpUnchanged,
                "valid_commands": safeCommands,
                "passed": sameObjects && unchangedIDs && moved && blue && pumpUnchanged && safeCommands
            ], uniquingKeysWith: { _, new in new })
            try save(summary, raw: raw, output: output)
            print("\(summary["passed"] as? Bool == true ? "PASS" : "FAIL"): same objects=\(sameObjects), exact IDs=\(unchangedIDs), moved=\(moved), blue=\(blue), pump unchanged=\(pumpUnchanged), commands valid=\(safeCommands)")
            scene.clear()
            exit(summary["passed"] as? Bool == true ? 0 : 1)
        } catch {
            summary["passed"] = false
            summary["error"] = error.localizedDescription
            try? save(summary, raw: raw, output: output)
            print("FAIL: \(error.localizedDescription)")
            scene.clear()
            exit(1)
        }
    }

    static func save(_ summary: [String: Any], raw: String, output: URL) throws {
        try raw.write(to: output.appendingPathComponent("response.teachyscene"), atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("result.json"))
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
