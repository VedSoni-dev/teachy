// Run: scripts/tests/run_notch_demo.sh
// Hosts the real ClickyNotchRootView in a window on screen, over a stand-in
// desktop, and opens and closes it on a loop. Real Liquid Glass needs a real
// window; off-screen renders can only draw the stand-in. Optionally records the
// window (not the screen) to a video and a GIF.
import AppKit
import Combine
import SwiftUI

typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

// MARK: - The stand-in desktop

/// A wallpaper, a document and a menu bar: enough busy colour behind the notch
/// to show what glass does with it.
struct StandInDesktop: View {
    let hasCameraHousing: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.2), Color(red: 1.0, green: 0.25, blue: 0.5), Color(red: 0.2, green: 0.45, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<16, id: \.self) { lineNumber in
                        Text("Quarterly report, line \(lineNumber): revenue was 84.6 million euros, up 11 percent.")
                            .font(.system(size: 13))
                            .foregroundColor(.black)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 52)
                .padding(.horizontal, 16)
                .frame(width: 520, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.white)
                .clipped()
                Spacer(minLength: 0)
            }

            // The menu bar.
            HStack(spacing: 18) {
                Text("Finder").fontWeight(.bold)
                Text("File"); Text("Edit"); Text("View"); Text("Window"); Text("Help")
                Spacer()
                Text("Fri 14 Nov  9:41")
            }
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.22))

            if hasCameraHousing {
                // The camera housing: hardware, always black.
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 185, height: 32)
            }
        }
    }
}

// MARK: - Window and recording

@MainActor
final class NotchDemo {
    let windowSize = NSSize(width: 1040, height: 480)
    let window: NSWindow
    let notchManager = NotchWindowManager()
    let companionManager = CompanionManager()
    var frameCounter = 0
    var recordingDirectory: URL?
    let frameQueue = DispatchQueue(label: "notch-demo.frames", qos: .userInitiated)

    init(hasCameraHousing: Bool) {
        if hasCameraHousing {
            notchManager.notchGeometry = NotchScreenGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1040, height: 480),
                notchHeight: 32, notchWidth: 185, notchLeftEdgeX: 427.5, notchCenterX: 520,
                leftAuxiliaryAreaWidth: 427.5, hasNotch: true
            )
        }
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.midY - windowSize.height / 2)
        window = NSWindow(contentRect: NSRect(origin: origin, size: windowSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView:
            ZStack(alignment: .top) {
                StandInDesktop(hasCameraHousing: hasCameraHousing)
                    .frame(width: windowSize.width, height: windowSize.height)
                    .clipped()
                ClickyNotchRootView(companionManager: companionManager, notchManager: notchManager)
            }
            .frame(width: windowSize.width, height: windowSize.height)
            .clipped()
        )
    }

    func startRecording(into directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        recordingDirectory = directory
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!
        let createImage = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        let windowNumber = UInt32(window.windowNumber)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let directory = self.recordingDirectory else { return }
                // Only this window: CGRectNull + "including window" captures nothing else.
                guard let image = createImage(CGRect.null, 1 << 3, windowNumber, 1 << 0)?.takeRetainedValue() else { return }
                self.frameCounter += 1
                let url = directory.appendingPathComponent(String(format: "frames/%05d.png", self.frameCounter))
                self.frameQueue.async {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    func finishRecording() {
        guard let directory = recordingDirectory else { return }
        recordingDirectory = nil
        frameQueue.sync {}
        let frames = directory.appendingPathComponent("frames/%05d.png").path
        func ffmpeg(_ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-y", "-loglevel", "error"] + arguments
            try? process.run()
            process.waitUntilExit()
        }
        ffmpeg(["-framerate", "20", "-i", frames, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", directory.appendingPathComponent("notch.mp4").path])
        ffmpeg(["-framerate", "20", "-i", frames, "-vf", "scale=760:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4", directory.appendingPathComponent("notch.gif").path])
        print("recorded \(frameCounter) frames to \(directory.path)")
    }

    /// Closed for a moment, then open, then closed again, on a loop.
    func startLoop() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            while true {
                notchManager.expand()
                try? await Task.sleep(for: .seconds(4.2))
                notchManager.collapse()
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }
}

@MainActor
func runDemo() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else { return nil }
        return arguments[flagIndex + 1]
    }
    let seconds = Double(value(after: "--seconds") ?? "30") ?? 30
    let hasCameraHousing = arguments.contains("--notched")

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let demo = NotchDemo(hasCameraHousing: hasCameraHousing)
    demo.window.orderFrontRegardless()
    if let recordPath = value(after: "--record") {
        demo.startRecording(into: URL(fileURLWithPath: recordPath, isDirectory: true))
    }
    demo.startLoop()

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated {
            demo.finishRecording()
            exit(0)
        }
    }
    arguments.removeAll()
    NSApp.run()
}

MainActor.assumeIsolated { runDemo() }
