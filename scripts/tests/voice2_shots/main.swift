// Run: scripts/tests/render_voice2_shots.sh
// Renders the always-on pill in every state, the Voice card and the Microphone card
// to PNG files without launching Teachy. Nothing is put on screen and the microphone
// is not opened. Output: $TMPDIR/voice2-shots/
import AppKit
import Combine
import SwiftUI

// MARK: - Stand-ins for app types the real files refer to

struct KeyboardKeyLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
    }
}

enum ClickyCursorColor: String, CaseIterable, Identifiable {
    case red, blue, yellow, green
    var id: String { rawValue }
    var displayColor: Color { .blue }
}

enum TeachyElevenLabsKeyStore {
    static var apiKey: String?
    static var isConfigured: Bool { apiKey != nil }
    static let voiceID = "preview"
}

extension VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer { _, _, _ in Data() }
}

/// The real row talks to the dictation controller.
struct DictationShortcutPickerRow: View {
    var body: some View { EmptyView() }
}

/// The pill's live wrapper watches this; here it never opens a microphone.
final class VoiceModeController: ObservableObject {
    static let shared = VoiceModeController()
    @Published var state: AlwaysOnState = .listening
    @Published var level: Float = 0.6
    @Published var notice: String? = "Always-on switched off after 5 quiet minutes."
    @Published var canInterruptBySpeaking = true
    func toggleAlwaysOn() {}
}

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice2-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    func render<V: View>(_ view: V, width: CGFloat, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { print("FAIL no bitmap for \(name)"); return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let states: [(AlwaysOnState, Float)] = [
        (.off, 0), (.listening, 0.15), (.hearing, 0.8), (.thinking, 0), (.speaking, 0),
        (.pausedForCall, 0), (.needsHeadphones, 0), (.unavailable("No working microphone"), 0),
    ]
    render(
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
                AlwaysOnPill(state: entry.0, level: entry.1)
            }
            AlwaysOnPillView()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black),
        width: 320, name: "01-always-on-pill"
    )

    let homeWidth: CGFloat = 640 - 2 * 12 - 2 * 8
    let settings = TeachySettings.shared
    settings.voiceName = "Puck"
    settings.speechSpeed = 1.15
    settings.replyLanguage = "es"
    settings.captionsEnabled = true
    render(VoiceSettingsSection().padding(8).background(Color.black), width: homeWidth + 16, name: "02-voice-collapsed")
    render(VoiceSettingsSection(startsExpanded: true).padding(8).background(Color.black), width: homeWidth + 16, name: "03-voice")
    settings.voiceName = "Vindemiatrix"
    settings.replyLanguage = "auto"
    render(VoiceSettingsSection(startsExpanded: true, showsMoreVoices: true).padding(8).background(Color.black), width: homeWidth + 16, name: "04-voice-all-voices")
    render(MicrophoneSettingsSection(startsExpanded: true).padding(8).background(Color.black), width: homeWidth + 16, name: "05-microphone")
    render(MicrophoneNotice(icon: "exclamationmark.triangle.fill", text: MicrophoneCenter.bluetoothWarning).padding(8).background(Color.black), width: homeWidth + 16, name: "06-bluetooth-warning")
    exit(0)
}

MainActor.assumeIsolated { runShots() }
