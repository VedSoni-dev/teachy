//
//  scene_eval.swift
//
//  Asks the model for drawings and measures how well it writes TeachyScene:
//  time to the first drawable command, total time, output size, how many lines
//  parse, and how many 3D parts come out.
//
//  Every call goes through TeachyAIRouter (job .scene), exactly as the app does.
//  Run with scripts/eval/run_scene_eval.sh. Each answer is saved so it can be
//  looked at:  TEACHY_SCENE_DEMO=x TEACHY_SCENE_DEMO_SCRIPT=<file> Teachy
//

import Foundation

struct ScenePromptCase {
    let name: String
    let prompt: String
}

let sceneEvalCases: [ScenePromptCase] = [
    ScenePromptCase(name: "turbofan", prompt: "show me how a turbofan works in 3D"),
    ScenePromptCase(name: "dna", prompt: "draw a DNA double helix"),
    ScenePromptCase(name: "pendulum", prompt: "pendulum I can play with"),
    ScenePromptCase(name: "gears", prompt: "gear train 3:1"),
    ScenePromptCase(name: "pi5", prompt: "raspberry pi 5 board with labeled parts"),
    ScenePromptCase(name: "chainrule", prompt: "explain the chain rule on a card"),
    ScenePromptCase(name: "moons", prompt: "bar chart of planets by moons"),
    ScenePromptCase(name: "piston", prompt: "how a piston engine works"),
    ScenePromptCase(name: "solar", prompt: "solar system orbits"),
    ScenePromptCase(name: "pump", prompt: "sodium-potassium pump"),
]

/// Shared between the stream reader and the watchdog.
final class SceneEvalProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastActivity = Date()
    private var _finished = false

    func touch() { lock.lock(); _lastActivity = Date(); lock.unlock() }
    func finish() { lock.lock(); _finished = true; lock.unlock() }
    var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(_lastActivity) }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
}

struct SceneEvalResult {
    var name: String
    var firstCommand: Double?
    var total = 0.0
    var characters = 0
    var stats = SceneParseStats()
    var parts = 0
    var surface = "-"
    var ending = "ok"
    var rejections: [String] = []
}

@main
enum SceneEval {
    static let overallTimeout: TimeInterval = 20
    static let idleTimeout: TimeInterval = 4

    static func main() async {
        let arguments = CommandLine.arguments
        let only = arguments.firstIndex(of: "--only").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let outputFolder = URL(fileURLWithPath: arguments.firstIndex(of: "--out").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? NSTemporaryDirectory() + "scene-eval")
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        guard TeachyAIRouter.isReadyForAI else {
            print("Teachy isn't signed in to publik on this Mac, so there is no model to ask. Open Teachy once and sign in, then run this again.")
            exit(2)
        }

        var results: [SceneEvalResult] = []
        for testCase in sceneEvalCases where only == nil || only == testCase.name {
            let result = await run(testCase, outputFolder: outputFolder)
            results.append(result)
            print(row(result))
        }

        print("\n" + header)
        for result in results { print(row(result)) }
        let rates = results.map { $0.stats.parseRate }
        let firsts = results.compactMap(\.firstCommand)
        if !results.isEmpty {
            print(String(format: "\nmean parse rate %.0f%%   median first command %.1f s   mean total %.1f s   answers in %@",
                         rates.reduce(0, +) / Double(rates.count) * 100,
                         firsts.sorted()[safe: firsts.count / 2] ?? .nan,
                         results.map(\.total).reduce(0, +) / Double(results.count),
                         outputFolder.path))
        }
        for result in results where !result.rejections.isEmpty {
            print("\n\(result.name): lines that did not parse")
            for rejection in result.rejections.prefix(8) { print("  " + rejection) }
        }
    }

    static let header = "prompt      surface  first cmd   total   ~tokens  lines  parsed  3D parts  end"

    static func row(_ r: SceneEvalResult) -> String {
        let first = r.firstCommand.map { String(format: "%6.1f s", $0) } ?? "     –  "
        return r.name.padding(toLength: 11, withPad: " ", startingAt: 0) + " "
            + r.surface.padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(format: "%@  %5.1f s  %7d  %5d  %5.0f%%  %8d  %@", first, r.total, r.characters / 4, r.stats.contentLines, r.stats.parseRate * 100, r.parts, r.ending)
    }

    static func run(_ testCase: ScenePromptCase, outputFolder: URL) async -> SceneEvalResult {
        var result = SceneEvalResult(name: testCase.name)
        // SCENE_EVAL_EFFORT=none|minimal|low|medium overrides the effort the app would send.
        let effort = ProcessInfo.processInfo.environment["SCENE_EVAL_EFFORT"]
        let body = effort == nil ? SceneScriptPrompt.requestBody(question: testCase.prompt)
            : SceneScriptPrompt.requestBody(question: testCase.prompt, reasoningEffort: effort == "none" ? nil : effort)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = overallTimeout
        let session = URLSession(configuration: configuration)
        let progress = SceneEvalProgress()
        let started = Date()

        let reader = Task { () -> (text: String, firstCommand: Double?, commands: [SceneCommand], stats: SceneParseStats, rejections: [String], error: String?) in
            let parser = SceneScriptParser()
            var text = ""
            var commands: [SceneCommand] = []
            var firstCommand: Double?
            var failure: String?
            do {
                let bytes = try await TeachyAIRouter.openStream(job: .scene, hasImages: false, timeout: overallTimeout, session: session, body: body)
                progress.touch()
                for try await line in bytes.lines {
                    progress.touch()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                    if let delta = (choice["delta"] as? [String: Any])?["content"] as? String, !delta.isEmpty {
                        text += delta
                        let fresh = parser.feed(delta)
                        if firstCommand == nil, fresh.contains(where: { $0.verb != .say }) {
                            firstCommand = Date().timeIntervalSince(started)
                        }
                        commands += fresh
                    }
                    if choice["finish_reason"] is String { break }
                }
            } catch is CancellationError {
                failure = "cut"
            } catch {
                failure = Task.isCancelled ? "cut" : "error: \(error.localizedDescription.prefix(60))"
            }
            commands += parser.finish()
            progress.finish()
            return (text, firstCommand, commands, parser.stats, parser.rejections, failure)
        }

        // Some tiers never close the stream: stop on 20 s overall or 4 s of silence.
        var ending = "ok"
        while !progress.finished {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Date().timeIntervalSince(started) > overallTimeout {
                ending = "20 s limit"
                reader.cancel()
                break
            }
            if progress.idle > idleTimeout {
                ending = "idle 4 s"
                reader.cancel()
                break
            }
        }
        let outcome = await reader.value
        session.invalidateAndCancel()

        result.total = Date().timeIntervalSince(started) - (ending == "idle 4 s" ? idleTimeout : 0)
        result.firstCommand = outcome.firstCommand
        result.characters = outcome.text.count
        result.stats = outcome.stats
        result.rejections = outcome.rejections
        result.parts = SceneRouter.count3DParts(in: outcome.commands)
        if let error = outcome.error, error != "cut" { ending = error }
        if outcome.text.isEmpty, ending == "ok" { ending = "empty" }
        result.ending = ending
        var surfaces: [String] = []
        var current: SceneSurface?
        for command in outcome.commands where command.verb.family != .control {
            guard let surface = SceneRouter.surface(for: command, current: current) else { continue }
            current = surface
            let name = surface == .scene3d ? "3D" : (surface == .card ? "card" : "overlay")
            if !surfaces.contains(name) { surfaces.append(name) }
        }
        result.surface = surfaces.isEmpty ? "-" : surfaces.joined(separator: "+")
        try? outcome.text.write(to: outputFolder.appendingPathComponent("\(testCase.name).txt"), atomically: true, encoding: .utf8)
        return result
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
