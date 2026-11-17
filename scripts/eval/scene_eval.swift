//
//  scene_eval.swift
//
//  Asks the model for drawings and measures two things.
//
//  1. How well it writes TeachyScene: time to the first drawable command, total time,
//     how many lines parse, how many 3D parts come out.
//  2. What the camera does with the answer. Each script is played into an off-screen scene
//     with a stand-in voice (a clock: each sentence "lasts" a few seconds). At the end of every
//     sentence the real camera node is asked where the sentence's subject is in the picture:
//     is the camera on it, is all of it in view, does it fill a sensible share of the shorter
//     side (20–75%), is something in front of it, are the label chips in the picture.
//
//  And the refine cases: on a drawing that is already up, "zoom in on the turbine",
//  "show me inside", "what's that orange part", "explode it", "go back" and a tap on a part go
//  through SceneDirector exactly as in the app (classifier → the model → the live scene),
//  with the latency of each and whether the right part ended up framed.
//
//  Every model call goes through TeachyAIRouter (job .scene). Nothing is shown on screen.
//
//    scripts/eval/run_scene_eval.sh                       17 prompts + 6 refine cases (23 model calls)
//    scripts/eval/run_scene_eval.sh --only oslayers,agentloop,network   selected prompts
//    scripts/eval/run_scene_eval.sh --strict              fail on parse errors, failures or the wrong presentation
//    scripts/eval/run_scene_eval.sh --no-refine           skip the refine cases
//    scripts/eval/run_scene_eval.sh --refine-only [DIR]   only the refine cases, on DIR/turbofan.txt if it exists
//    scripts/eval/run_scene_eval.sh --score DIR           measure saved answers again, no model calls
//    scripts/eval/run_scene_eval.sh --score DIR --no-direct   …with the camera as it was before it directed itself
//    scripts/eval/run_scene_eval.sh --shots a,b,c,d       also write a PNG per sentence for those scenes
//    scripts/eval/run_scene_eval.sh --out DIR             where answers go (default $TMPDIR/teachy-scene3/eval)
//
//  Pictures go to $TMPDIR/teachy-scene3/shots/<scene>/NN.png.
//

import AppKit
import Foundation
import SceneKit

// This eval uses Publik only. Do not prompt for an unrelated OpenRouter Keychain
// credential from a freshly compiled command-line executable. The production
// router and Publik credential selection are otherwise used unchanged.
enum TeachyAPIKeyStore {
    static var apiKey: String? { nil }
}

struct ScenePromptCase {
    let name: String
    let prompt: String
    let expected: ScenePresentationExpectation

    init(name: String, prompt: String, expected: ScenePresentationExpectation = .drawing) {
        self.name = name
        self.prompt = prompt
        self.expected = expected
    }
}

let sceneEvalCases: [ScenePromptCase] = [
    ScenePromptCase(name: "turbofan", prompt: "show me how a turbofan works in 3D"),
    ScenePromptCase(name: "turbineask", prompt: "how does the turbine in a jet engine work"),
    ScenePromptCase(name: "gears", prompt: "gear train 3:1"),
    ScenePromptCase(name: "pi5", prompt: "raspberry pi 5 board with labeled parts"),
    ScenePromptCase(name: "piston", prompt: "how a piston engine works"),
    ScenePromptCase(name: "pump", prompt: "sodium-potassium pump"),
    ScenePromptCase(name: "heart", prompt: "how the human heart pumps blood, in 3D"),
    ScenePromptCase(name: "eye", prompt: "show me the inside of an eye"),
    ScenePromptCase(name: "motor", prompt: "how does an electric motor spin"),
    ScenePromptCase(name: "battery", prompt: "what's inside a battery"),
    ScenePromptCase(name: "bridge", prompt: "why does a suspension bridge stay up"),
    ScenePromptCase(name: "rocket", prompt: "draw a rocket and its stages in 3D"),
    ScenePromptCase(name: "oslayers", prompt: "how does an operating system work"),
    ScenePromptCase(name: "agentloop", prompt: "show me how an AI agent works"),
    ScenePromptCase(name: "network", prompt: "draw how a browser request reaches a server"),
    ScenePromptCase(name: "textcard", prompt: "Make a plain text reference card summarizing operating system responsibilities in three bullets. Do not draw a diagram.", expected: .referenceCard),
    ScenePromptCase(name: "chart", prompt: "Make a bar chart comparing requests served: Monday 20, Tuesday 35, Wednesday 25.", expected: .referenceCard),
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
    var quality = SceneQualityReport()
}

/// What the camera did over one script.
struct SceneCameraReport {
    var name: String
    var sentences = 0
    /// Sentences that are about some part (the script focused one, or one can be inferred from its lines and words).
    var withSubject = 0
    /// …of which the script itself told the camera where to go.
    var explicit = 0
    /// Sentences at whose end the camera is on a part.
    var onTarget = 0
    /// Sentences about a part whose part is all in the picture and fills 20–75% of the shorter side.
    var framed = 0
    /// …and is not hidden behind something else (less than half of the lines of sight blocked).
    var clear = 0
    /// Sentences where every label chip showing is inside the picture, and a focused part that has a label shows it.
    var labelsGood = 0
    /// Sentences where the camera sits inside or against geometry.
    var insideGeometry = 0
    var endsOnWhole = false
    var fills: [Double] = []
    var notes: [String] = []
}

@main
enum SceneEval {
    static let overallTimeout: TimeInterval = 20
    static let idleTimeout: TimeInterval = 4
    static let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-scene3", isDirectory: true)

    static func main() {
        // Drawings the director would keep go to a temp folder, never the real ~/.teachy.
        setenv("TEACHY_DRAWINGS_DIR", work.appendingPathComponent("eval-drawings-\(UUID().uuidString.prefix(8))").path, 1)
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.async { Task { @MainActor in await run() } }
        app.run()
    }

    static func argument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func run() async {
        let arguments = CommandLine.arguments
        let only = argument("--only").map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let strict = arguments.contains("--strict")
        if arguments.contains("--only"), only == nil || only?.isEmpty == true {
            print("--only needs a comma-separated list of case names.")
            exit(2)
        }
        if let only {
            let unknown = only.subtracting(sceneEvalCases.map(\.name))
            if !unknown.isEmpty {
                print("Unknown cases: " + unknown.sorted().joined(separator: ", "))
                exit(2)
            }
        }
        let direct = !arguments.contains("--no-direct")
        let shots = Set((argument("--shots") ?? "").split(separator: ",").map(String.init))
        let outputFolder = URL(fileURLWithPath: argument("--out") ?? work.appendingPathComponent("eval").path)
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        // --score DIR: measure answers saved by an earlier run, with no model calls.
        if arguments.contains("--score") {
            let folder = URL(fileURLWithPath: argument("--score") ?? outputFolder.path)
            var quality: [SceneEvalResult] = []
            var camera: [SceneCameraReport] = []
            for testCase in sceneEvalCases where only == nil || only!.contains(testCase.name) {
                guard let text = try? String(contentsOf: folder.appendingPathComponent("\(testCase.name).txt"), encoding: .utf8) else {
                    if strict || only != nil {
                        var missing = SceneEvalResult(name: testCase.name)
                        missing.ending = "missing saved answer"
                        quality.append(missing)
                    }
                    continue
                }
                let parser = SceneScriptParser()
                let commands = parser.feed(text) + parser.finish()
                var result = SceneEvalResult(name: testCase.name)
                result.stats = parser.stats
                result.quality = SceneQuality.report(commands: commands, stats: parser.stats, expected: testCase.expected)
                quality.append(result)
                if result.quality.surface.contains("3D") {
                    camera.append(await film(name: testCase.name, script: text, direct: direct, shots: shots.contains(testCase.name)))
                }
            }
            printQuality(quality)
            printCamera(camera, direct: direct)
            exit(strict && (quality.isEmpty || quality.contains(where: failed)) ? 1 : 0)
        }

        guard TeachyAIRouter.isReadyForAI else {
            print("Teachy isn't signed in to publik on this Mac, so there is no model to ask. Open Teachy once and sign in, then run this again.")
            exit(2)
        }

        if arguments.contains("--refine-only") {
            await refineCases(base: argument("--refine-only").map { URL(fileURLWithPath: $0) } ?? outputFolder)
            exit(0)
        }

        var results: [SceneEvalResult] = []
        var camera: [SceneCameraReport] = []
        for testCase in sceneEvalCases where only == nil || only!.contains(testCase.name) {
            let (result, text) = await ask(testCase, outputFolder: outputFolder)
            results.append(result)
            print(row(result))
            if result.quality.surface.contains("3D") {
                camera.append(await film(name: testCase.name, script: text, direct: direct, shots: shots.contains(testCase.name)))
            }
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
        printQuality(results)
        printCamera(camera, direct: direct)
        for result in results where !result.rejections.isEmpty {
            print("\n\(result.name): lines that did not parse")
            for rejection in result.rejections.prefix(8) { print("  " + rejection) }
        }
        if only == nil, !arguments.contains("--no-refine") { await refineCases(base: outputFolder) }
        exit(strict && (results.isEmpty || results.contains(where: failed)) ? 1 : 0)
    }

    static func failed(_ result: SceneEvalResult) -> Bool {
        result.ending != "ok" || result.stats.parseRate < 1 || !result.quality.presentationMatches || result.quality.surface == "-"
    }

    // MARK: - Tables

    static let qualityHeader = "prompt      surface   parse  parts  macros  labels  says  tied  bounds  score"

    static func qualityRow(_ name: String, _ q: SceneQualityReport) -> String {
        name.padding(toLength: 11, withPad: " ", startingAt: 0) + " " + q.surface.padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(format: " %4.0f%%  %5d  %6d  %6d  %4d  %4d  %6.2f  %5.0f", q.parseRate * 100, q.partCount, q.macroLines, q.labelCount, q.sayCount, q.tiedSays, q.boundsSanity, q.score)
    }

    static func printQuality(_ results: [SceneEvalResult]) {
        guard !results.isEmpty else { return }
        print("\n" + qualityHeader)
        for result in results {
            print(qualityRow(result.name, result.quality))
            if let reason = result.quality.presentationMismatch { print("  PRESENTATION MISMATCH: " + reason) }
            if result.ending != "ok" { print("  FAILURE: " + result.ending) }
        }
        let threeD = results.filter { $0.quality.surface.contains("3D") }
        let mean = { (values: [Double]) in values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        let says = results.map(\.quality.sayCount).reduce(0, +), tied = results.map(\.quality.tiedSays).reduce(0, +)
        print(String(format: "\nsentences tied to something appearing %d/%d (%.0f%%)   mean sentences %.1f", tied, says, says == 0 ? 0 : Double(tied) / Double(says) * 100,
                     Double(says) / Double(results.count)))
        print(String(format: "mean score %.1f   3D scenes %d   uses-macros rate %.0f%%   mean 3D parts %.1f   mean labels %.1f   mean bounds %.2f",
                     mean(results.map(\.quality.score)), threeD.count,
                     mean(threeD.map { $0.quality.usesMacros ? 1 : 0 }) * 100,
                     mean(threeD.map { Double($0.quality.partCount) }), mean(threeD.map { Double($0.quality.labelCount) }),
                     mean(threeD.map(\.quality.boundsSanity))))
    }

    static let cameraHeader = "scene       says  subject  explicit  on-target  framed  clear  labels-ok  in-geometry  ends-whole  fill (share of shorter side)"

    static func printCamera(_ reports: [SceneCameraReport], direct: Bool) {
        guard !reports.isEmpty else { return }
        print("\nCamera" + (direct ? "" : " (as before: it only frames the whole model)"))
        print(cameraHeader)
        for r in reports {
            let fills = r.fills.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " ")
            print(r.name.padding(toLength: 11, withPad: " ", startingAt: 0)
                  + String(format: " %4d  %7d  %8d  %9d  %6d  %5d  %9d  %11d  %10@  %@", r.sentences, r.withSubject, r.explicit, r.onTarget, r.framed, r.clear, r.labelsGood, r.insideGeometry,
                           r.endsOnWhole ? "yes" : "no", fills))
        }
        let total = { (path: KeyPath<SceneCameraReport, Int>) in reports.map { $0[keyPath: path] }.reduce(0, +) }
        let says = total(\.sentences), subject = total(\.withSubject), onTarget = total(\.onTarget), framed = total(\.framed), clear = total(\.clear)
        let percent = { (a: Int, b: Int) in b == 0 ? 0.0 : Double(a) / Double(b) * 100 }
        print(String(format: "\nsentences %d   about a part %d (%.0f%%)   camera on a part at the end of the sentence %d (%.0f%% of all, %.0f%% of those about a part)",
                     says, subject, percent(subject, says), onTarget, percent(onTarget, says), percent(onTarget, subject)))
        print(String(format: "of the %d sentences about a part: subject fully in view and 20–75%% of the shorter side %d (%.0f%%)   …and not hidden %d (%.0f%%)",
                     subject, framed, percent(framed, subject), clear, percent(clear, subject)))
        print(String(format: "labels in the picture %d/%d   camera in geometry %d   scenes ending on the whole model %d/%d",
                     total(\.labelsGood), says, total(\.insideGeometry), reports.filter(\.endsOnWhole).count, reports.count))
        for r in reports where !r.notes.isEmpty {
            print("\n\(r.name):")
            for note in r.notes { print("  " + note) }
        }
    }

    static let header = "prompt      surface  first cmd   total   ~tokens  lines  parsed  3D parts  end"

    static func row(_ r: SceneEvalResult) -> String {
        let first = r.firstCommand.map { String(format: "%6.1f s", $0) } ?? "     –  "
        return r.name.padding(toLength: 11, withPad: " ", startingAt: 0) + " "
            + r.surface.padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(format: "%@  %5.1f s  %7d  %5d  %5.0f%%  %8d  %@", first, r.total, r.characters / 4, r.stats.contentLines, r.stats.parseRate * 100, r.parts, r.ending)
    }

    // MARK: - The camera over a script

    static func writePNG(_ image: NSImage?, to url: URL) {
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    /// How long the stand-in voice takes over a sentence.
    static func spokenLength(_ text: String) -> Double {
        max(2.4, Double(text.split(separator: " ").count) * 0.33)
    }

    /// Plays `script` into an off-screen scene as the app would with a voice, and measures the camera at the end of each sentence.
    @MainActor
    static func film(name: String, script: String, direct: Bool, shots: Bool) async -> SceneCameraReport {
        var report = SceneCameraReport(name: name)
        let commands = SceneScriptParser.parse(script)
        let says = commands.filter { $0.verb == .say && $0.cue != nil }
        let session = SceneSession()
        session.directsCamera = direct
        session.beginHeadless(size: Scene3DView.viewSize, timing: .speech)
        session.feed(chunk: script)
        session.end()
        var time = 0.0
        func play(_ seconds: Double) {
            let end = time + seconds
            while time < end - 1e-9 {
                time += 1.0 / 30
                session.advance(to: time)
            }
        }
        let folder = work.appendingPathComponent("shots/\(name)\(direct ? "" : "-before")", isDirectory: true)
        if shots { try? FileManager.default.removeItem(at: folder) }
        var frame = 0
        func shoot() {
            guard shots else { return }
            frame += 1
            writePNG(session.modelWindow?.snapshot(), to: folder.appendingPathComponent(String(format: "%02d.png", frame)))
        }
        for say in says {
            guard let cue = say.cue else { continue }
            session.sentenceStarted(index: cue)
            play(spokenLength(say.freeText ?? ""))
            guard let controller = session.modelWindow?.controller else { continue }
            report.sentences += 1
            let lines = commands.filter { $0.cue == cue && $0.verb != .say }
            let explicit = SceneSentenceSubject.hasCameraDirection(lines)
            let focus = controller.focusIDs
            let inferred = SceneSentenceSubject.infer(sentence: say.freeText ?? "", commands: lines, candidates: controller.subjectCandidates)
            let subject = focus.isEmpty ? inferred : focus
            if !focus.isEmpty { report.onTarget += 1 }
            if explicit { report.explicit += 1 }
            var line = String(format: "%d  ", cue) + (focus.isEmpty ? "whole model" : "on " + focus.joined(separator: ","))
            if !subject.isEmpty, let projection = controller.projectedBounds(ofParts: subject) {
                report.withSubject += 1
                let sensible = projection.isInside && SceneFraming.sensibleFill.contains(projection.fill)
                let hidden = controller.occlusion(ofParts: subject)
                if sensible { report.framed += 1 }
                if sensible, hidden < 0.5 { report.clear += 1 }
                report.fills.append(projection.fill)
                line += String(format: "  subject %@ fills %.0f%% %@%@", subject.joined(separator: ","), projection.fill * 100, projection.isInside ? "in view" : "CUT OFF",
                               hidden >= 0.5 ? String(format: " HIDDEN %.0f%%", hidden * 100) : "")
            }
            let labels = controller.visibleLabels
            let labelsInside = labels.allSatisfy { abs($0.ndc.x) <= 1.0 && abs($0.ndc.y) <= 1.0 }
            if labelsInside { report.labelsGood += 1 } else { line += "  LABEL OFF-SCREEN: " + labels.filter { abs($0.ndc.x) > 1 || abs($0.ndc.y) > 1 }.map(\.part).joined(separator: ",") }
            if controller.clearanceAhead < 0.03 {
                report.insideGeometry += 1
                line += "  CAMERA IN GEOMETRY"
            }
            if !controller.ghostedIDs.isEmpty { line += "  ghosted: " + controller.ghostedIDs.joined(separator: ",") }
            if ProcessInfo.processInfo.environment["SCENE_EVAL_DEBUG"] != nil {
                let shown = controller.displayedPose
                line += String(format: "  [pose d=%.2f az=%.2f el=%.2f mode=%@]", shown.distance, shown.azimuth, shown.elevation, "\(controller.cameraMode)")
            }
            line += "  — \(say.freeText ?? "")"
            report.notes.append(line)
            shoot()
        }
        session.speechEnded()
        play(3.2)
        if let controller = session.modelWindow?.controller {
            report.endsOnWhole = controller.cameraMode == .whole && controller.focusIDs.isEmpty
            shoot()
        }
        if shots { print("  filmstrip: \(folder.path) (\(frame) pictures)") }
        try? session.log.encoded().write(to: work.appendingPathComponent("eval-logs/\(name).json"))
        session.clear()
        return report
    }

    // MARK: - Asking the model

    static func ask(_ testCase: ScenePromptCase, outputFolder: URL) async -> (SceneEvalResult, String) {
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

        let reader = Task.detached { () -> (text: String, firstCommand: Double?, commands: [SceneCommand], stats: SceneParseStats, rejections: [String], error: String?) in
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
        result.quality = SceneQuality.report(commands: outcome.commands, stats: outcome.stats, expected: testCase.expected)
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
        return (result, outcome.text)
    }

    // MARK: - Refining a drawing that is already up

    struct RefineCase {
        var name: String
        /// What the voice turn would hand to `SceneDirector.show`, or nil for a tap.
        var request: String?
        var tap: String?
        /// The part that should end up in the camera's focus (nil: none in particular).
        var expectFocus: String?
        var check: @MainActor (Scene3DController) -> (ok: Bool, what: String)
    }

    static let fallbackTurbofan = """
    say 1 "A turbofan pulls air in with a big fan at the front."
    scene3d t title="How a turbofan works"
    jet j
    label a on=j.fan text="Fan" n=1
    say 2 "The compressor squeezes that air, and fuel burns in the combustor."
    label b on=j.compressor text="Compressor" n=2
    label c on=j.combustor text="Combustor" n=3
    say 3 "Hot gas spins the turbine, which turns the fan, then rushes out the back."
    label d on=j.turbine text="Turbine" n=4
    label e on=j.nozzle text="Nozzle" n=5
    """

    @MainActor
    static func refineCases(base: URL) async {
        let script = (try? String(contentsOf: base.appendingPathComponent("turbofan.txt"), encoding: .utf8)).flatMap { $0.contains("jet ") ? $0 : nil } ?? fallbackTurbofan
        let jet = SceneScriptParser.parse(script).first { $0.verb == .jet }?.id ?? "j"
        func framed(_ controller: Scene3DController, _ part: String) -> (Bool, String) {
            guard controller.focusIDs.contains(where: { $0 == part || $0.hasPrefix(part + ".") }) else { return (false, "focus is " + (controller.focusIDs.isEmpty ? "the whole model" : controller.focusIDs.joined(separator: ","))) }
            guard let projection = controller.projectedBounds(ofParts: controller.focusIDs) else { return (false, "nothing to project") }
            let hidden = controller.occlusion(ofParts: controller.focusIDs)
            let good = projection.isInside && SceneFraming.sensibleFill.contains(projection.fill) && hidden < 0.5
            return (good, String(format: "on %@, fills %.0f%%, %@, %.0f%% hidden", controller.focusIDs.joined(separator: ","), projection.fill * 100, projection.isInside ? "in view" : "cut off", hidden * 100))
        }
        let cases: [RefineCase] = [
            RefineCase(name: "zoom", request: "zoom in on the turbine", expectFocus: "\(jet).turbine") { framed($0, "\(jet).turbine") },
            RefineCase(name: "inside", request: "show me inside the compressor", expectFocus: "\(jet).compressor") { controller in
                let (ok, what) = framed(controller, "\(jet).compressor")
                return (ok, what + (controller.ghostedIDs.isEmpty ? "" : ", ghosted " + controller.ghostedIDs.joined(separator: ",")))
            },
            RefineCase(name: "orange", request: "what's that orange part", expectFocus: "\(jet).combustor") { framed($0, "\(jet).combustor") },
            RefineCase(name: "explode", request: "explode it", expectFocus: nil) { controller in
                (controller.liveState.isExploded, controller.liveState.isExploded ? "the model is pulled apart" : "not exploded")
            },
            RefineCase(name: "goback", request: "go back", expectFocus: nil) { controller in
                let whole = controller.cameraMode == .whole && controller.focusIDs.isEmpty
                return (whole && controller.ghostedIDs.isEmpty, (whole ? "whole model" : "still on " + controller.focusIDs.joined(separator: ",")) + (controller.ghostedIDs.isEmpty ? "" : ", still ghosted " + controller.ghostedIDs.joined(separator: ",")))
            },
            RefineCase(name: "tap", request: nil, tap: "\(jet).fan", expectFocus: "\(jet).fan") { framed($0, "\(jet).fan") },
        ]

        let director = SceneDirector.shared
        director.placement = { anchor in
            anchor.headless = true
            anchor.hostsOverlay = true
        }
        var spoken: [String] = []
        // What the voice turn would keep in the conversation.
        var answered: [(question: String, answer: String)] = []
        director.onRefinementAnswered = { question, answer in answered.append((question, answer)) }
        director.speak = { text, onStarted in
            onStarted()
            spoken.append(text)
            try? await Task.sleep(nanoseconds: UInt64(min(spokenLength(text), 2.6) * 1_000_000_000))
        }
        // The drawing that is "already on screen", built off screen.
        let scene = director.scene
        scene.beginHeadless(size: Scene3DView.viewSize, timing: .stagger)
        scene.feed(chunk: script)
        scene.end()
        let began = CACurrentMediaTime()
        // The headless scene's clock follows the wall clock, so the director's real timing applies.
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                scene.advance(to: CACurrentMediaTime() - began)
                // A small frame each tick, as the window would draw, so SceneKit's own moves (explode) run in time.
                _ = scene.modelWindow?.controller.renderFrame(size: CGSize(width: 64, height: 48))
            }
        }
        RunLoop.main.add(clock, forMode: .common)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        // Kept in the Drawings list (a temp folder), as a finished drawing would be, so refinements update it.
        let saved = SceneHistory.shared.save(log: scene.log, question: "show me how a turbofan works in 3D", thumbnail: nil)
        director.adoptSavedDrawing(saved?.id)
        let savedLines = scene.log.entries.count
        guard let controller = scene.modelWindow?.controller else {
            print("refine: no 3D model to refine")
            return
        }
        let folder = work.appendingPathComponent("shots/refine", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        writePNG(scene.modelWindow?.snapshot(), to: folder.appendingPathComponent("00-start.png"))

        print("\nRefining a drawing that is already up (through SceneDirector, as in the app)")
        print("case      treated as   camera moved  first line  answer done  result  detail")
        var totals: [Double] = [], firsts: [Double] = [], moves: [Double] = []
        var passed = 0
        for (index, refineCase) in cases.enumerated() {
            spoken = []
            let linesBefore = scene.log.entries.count
            if let request = refineCase.request {
                director.show(request)
            } else if let tap = refineCase.tap {
                controller.tapPart(tap)
            }
            let asked = Date()
            // The stream ends, then the stand-in voice finishes and the camera settles.
            while director.lastTurn.streamEnded == nil, Date().timeIntervalSince(asked) < 25 { try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            let turn = director.lastTurn
            let live = scene.modelWindow?.controller ?? controller
            let (ok, what) = refineCase.check(live)
            if ok { passed += 1 }
            let kind = turn.kind == .refinement ? "refine" : "NEW DRAWING"
            let moved = turn.instantScript != nil ? 0.0 : (turn.firstLine ?? .nan)
            if let total = turn.streamEnded { totals.append(total) }
            if let first = turn.firstLine { firsts.append(first) }
            if moved.isFinite { moves.append(moved) }
            print(refineCase.name.padding(toLength: 9, withPad: " ", startingAt: 0) + " " + kind.padding(toLength: 12, withPad: " ", startingAt: 0)
                  + String(format: " %9.2f s  %8.2f s  %9.2f s  %@  %@", moved, turn.firstLine ?? .nan, turn.streamEnded ?? .nan, ok ? "ok  " : "FAIL", what))
            let added = scene.log.entries.dropFirst(linesBefore).map(\.command.scriptLine)
            print("            (" + turn.reason + ") lines: " + added.joined(separator: " | "))
            if !spoken.isEmpty { print("            said: " + spoken.joined(separator: " ")) }
            if let last = answered.last { print("            kept in the conversation: (\"\(last.question)\", \"\(last.answer)\")") }
            writePNG(scene.modelWindow?.snapshot(), to: folder.appendingPathComponent(String(format: "%02d-%@.png", index + 1, refineCase.name)))
        }
        let median = { (values: [Double]) in values.isEmpty ? Double.nan : values.sorted()[values.count / 2] }
        print("  answers handed to the conversation: \(answered.count) of \(cases.count)")
        if let id = saved?.id {
            let kept = SceneHistory.shared.store.log(for: id)?.entries.count ?? 0
            print("  the saved drawing now has \(kept) lines (\(savedLines) when first saved); entries in the Drawings list: \(SceneHistory.shared.entries.count)")
        }
        print(String(format: "\nrefine: %d/%d right   camera moved after (median) %.2f s   first model line %.2f s   answer complete %.2f s", passed, cases.count, median(moves), median(firsts), median(totals)))
        print("  pictures: \(folder.path)")
        clock.invalidate()
        director.stop()
        scene.clear()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
