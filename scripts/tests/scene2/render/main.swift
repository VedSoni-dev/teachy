//
//  Renders scene scripts to PNG without the app:
//      scene2_render <out-folder> <seconds> <script.txt>...
//  Windows are placed far off every display; the pictures come from the
//  in-process renderers, so nothing appears on screen.
//
import AppKit
import SceneKit

let arguments = CommandLine.arguments
guard arguments.count >= 4, let seconds = Double(arguments[2]) else {
    print("usage: scene2_render <out-folder> <seconds> <script.txt>...")
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let files = Array(arguments.dropFirst(3))
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

var sessions: [SceneSession] = []
func renderNext(_ index: Int) {
    guard index < files.count else { exit(0) }
    let path = files[index]
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard let script = try? String(contentsOfFile: path, encoding: .utf8) else { renderNext(index + 1); return }
    let session = SceneSession()
    sessions = [session]
    var anchor = SceneAnchor(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), timing: .stagger)
    anchor.cardTopLeft = CGPoint(x: -30000, y: -30000)
    anchor.modelTopLeft = CGPoint(x: -30000, y: -30000)
    anchor.hostsOverlay = true
    session.begin(anchor: anchor)
    session.feed(chunk: script)
    session.end()
    session.speechEnded()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        if let controller = session.modelWindow?.controller {
            controller.freezeCamera(azimuth: 0.5)
            // The window is off every display, so its view never draws and fade-ins never run.
            // Drawing a few frames here runs them.
            let pump = SCNRenderer(device: nil, options: nil)
            pump.scene = controller.scene
            pump.pointOfView = controller.view.pointOfView
            let start = CACurrentMediaTime()
            for frame in 0..<45 {
                _ = pump.snapshot(atTime: start + Double(frame) / 30, with: CGSize(width: 64, height: 48), antialiasingMode: .none)
            }
            controller.freezeCamera(azimuth: 0.5)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for (surface, image) in session.snapshots() {
                writePNG(image, to: folder.appendingPathComponent("\(name)-\(surface).png"))
            }
            print("\(name): \(session.parseStats.commands)/\(session.parseStats.contentLines) parsed, \(session.partCount) parts")
            session.clear()
            renderNext(index + 1)
        }
    }
}
DispatchQueue.main.async { renderNext(0) }
app.run()
