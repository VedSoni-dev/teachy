//
//  Frame-time measurement for the 3D engine, off screen:
//      scene3_perf <script.txt>...
//  Each script is built headless, left to settle for two seconds, then 240 frames are stepped
//  (1/60 s each: motion, camera, labels) and drawn with SCNRenderer at 1280×940 while the camera
//  moves. Prints the time per frame for the step (main-thread work) and for the draw.
//  Uses only API that the engine had before the self-directing camera, so the same file
//  measures both versions.
//
import AppKit
import SceneKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let size = CGSize(width: 1280, height: 940)

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

@MainActor
func measure(_ path: String) {
    do {
    guard let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    var log = SceneReplayLog()
    for command in SceneScriptParser.parse(script) { log.record(command, at: 0) }
    let session = SceneSession()
    session.beginHeadless(log: log, size: size)
    var time = 0.0
    while time < 2 { time += 1.0 / 30; session.advance(to: time) }
    guard let controller = session.modelWindow?.controller else { print("\(path): no 3D model"); return }
    controller.viewportSize = size
    var nodes = 0
    controller.scene.rootNode.enumerateHierarchy { _, _ in nodes += 1 }
    for _ in 0..<10 { time += 1.0 / 60; session.advance(to: time); _ = controller.renderFrame(size: size) }
    var steps: [Double] = [], draws: [Double] = []
    for _ in 0..<240 {
        time += 1.0 / 60
        let a = CACurrentMediaTime()
        session.advance(to: time)
        let b = CACurrentMediaTime()
        _ = controller.renderFrame(size: size)
        let c = CACurrentMediaTime()
        steps.append((b - a) * 1000)
        draws.append((c - b) * 1000)
    }
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(v.count, 1)) }
    print(String(format: "%@  nodes %5d  step mean %.2f ms p95 %.2f   draw mean %.2f ms p95 %.2f   frame mean %.2f ms",
                 name.padding(toLength: 12, withPad: " ", startingAt: 0), nodes, mean(steps), percentile(steps, 0.95), mean(draws), percentile(draws, 0.95), mean(steps) + mean(draws)))
    session.clear()
    }
}

MainActor.assumeIsolated {
    for path in CommandLine.arguments.dropFirst() { measure(path) }
}
exit(0)
