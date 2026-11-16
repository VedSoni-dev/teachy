// Run: scripts/tests/render_onboarding_shots.sh
// Renders the first-run screens of the notch panel to PNG files without launching
// Teachy: the publik sign-in gate, the permission wizard, the Automation heads-up,
// the API key step, every page of the product tour, the out-of-credit banner and
// the Home tab's Account row. The views are the real ones; the managers they talk
// to are stand-ins, so nothing here can ask macOS for a permission, sign in to
// publik, play a sound or reach the network. Nothing is put on screen.
// Output: $TMPDIR/teachy-onboarding-shots/
import AppKit
import Combine
import SwiftUI

// MARK: - Stand-ins for app types the real files refer to

enum ClickyCursorColor: String, CaseIterable, Identifiable {
    case red, blue, yellow, green
    var id: String { rawValue }
    var displayColor: Color { DS.Colors.pointerColor(named: rawValue) }
}

enum TeachyElevenLabsKeyStore {
    static var apiKey: String?
    static var isConfigured: Bool { apiKey != nil }
    static let voiceID = "preview"
}

extension VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer { _, _, _ in Data() }
}

struct DictationShortcutPickerRow: View {
    var body: some View { EmptyView() }
}

enum NotchPanelTab: String, CaseIterable {
    case home
}

/// The microphone is always "granted" here. The real wizard asks macOS for the
/// microphone itself, so a stand-in that left it ungranted would raise a real
/// permission prompt. Every other request goes through `WindowPositionManager`,
/// which is a stand-in that does nothing.
final class CompanionManager: ObservableObject {
    enum TeachyUISound {
        case pageAdvance
        case celebration
    }

    let hasMicrophonePermission = true
    @Published var requiresSpeechRecognitionPermission = false
    @Published var hasSpeechRecognitionPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var hasCompletedOnboarding = false
    @Published var teachyScreenProofDidPlay = false

    var allPermissionsGranted: Bool {
        let hasRequiredSpeechRecognitionPermission = !requiresSpeechRecognitionPermission || hasSpeechRecognitionPermission
        return hasMicrophonePermission && hasRequiredSpeechRecognitionPermission
            && hasScreenRecordingPermission && hasAccessibilityPermission
    }

    func refreshAllPermissions() {}
    func playTeachyUISound(_ sound: TeachyUISound) {}
    func beginTeachyScreenProofDemo() {}
    func startOnboardingMusic(forceRestart: Bool = false) {}
    func submitSyntheticCompanionRequest(_ text: String) {}
    func triggerOnboarding() {}
    func completeTeachyProductOnboarding() {}
}

final class NotchWindowManager: ObservableObject {
    @Published var isExpanded = true
    @Published var selectedTab: NotchPanelTab = .home
    func makePanelKey() {}
    func collapse() {}
}

enum WindowPositionManager {
    static func requestSpeechRecognitionPermission() {}
    static func requestScreenRecordingPermission() {}
    static func requestAccessibilityPermission() {}
    static func fixScreenRecordingAfterRebuild() {}
    static func revealAppInFinder() {}
    static func openAccessibilitySettings() {}
    static func openDictationSettings() {}
    static func openAutomationSettings() {}
}

enum TeachyAPIKeyStore {
    static var apiKey: String?
    static var isConfigured: Bool { apiKey != nil }
}

/// The two value types of publik's module that the views read. The module itself
/// is not compiled in, so no publik code can run here.
enum Publik {
    struct Wallet {
        var claimed: Bool
        var claimURL: String?
        var handle: String?
        var planKind: String
        var planLabel: String?
        var balanceMicros: Int
        var topUpURL: String
    }

    struct Screen {
        let id: String
        let title: String
        let body: String
        let note: String?
        let buttons: [(action: String, label: String)]
    }
}

final class GateModel: ObservableObject {
    @Published var screen: Publik.Screen?
    func press(_ action: String?) {}
}

struct TeachyAIBillingError {
    let message: String
    let topUpURL: URL?
}

final class TeachyPublikSession: ObservableObject {
    static let shared = TeachyPublikSession()
    let gate = GateModel()
    @Published var isReady = false
    @Published var wallet: Publik.Wallet?
    @Published var choice: String?
    @Published var billingNotice: TeachyAIBillingError?
    @Published var isSwitchingAccount = false
    @Published var accountError: String?
    var canLogOut = true
    func logOut() {}
    func changePaymentChoice() {}
    func refreshWallet() async {}
    func openTopUp() {}
}

// MARK: - Clicking in a view that is not on screen

/// Sends a mouse click straight to the hosting view, so a shot can be taken of
/// a state that is only reached by a click (the later pages of the tour, an
/// opened settings row). The point is in the view's own coordinates, measured
/// from its top-left corner. Every action in these views goes to a stand-in,
/// so a click that lands on the wrong button still does nothing real.
@MainActor
func click(atPointFromTopLeft pointFromTopLeft: CGPoint, in hostingView: NSView, of window: NSWindow) {
    let pointInWindow = CGPoint(x: pointFromTopLeft.x, y: hostingView.bounds.height - pointFromTopLeft.y)
    for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let mouseEvent = NSEvent.mouseEvent(
            with: eventType, location: pointInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: eventType == .leftMouseDown ? 1 : 0
        ) else { continue }
        window.sendEvent(mouseEvent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

// MARK: - Rendering

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-onboarding-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var failureCount = 0

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    /// A view hosted off screen. It stays alive between shots so a button in it
    /// can be pressed and the next state drawn.
    final class HostedView {
        let hostingView: NSHostingView<AnyView>
        let window: NSWindow
        let width: CGFloat

        init<V: View>(_ view: V, width: CGFloat) {
            self.width = width
            hostingView = NSHostingView(rootView: AnyView(view.frame(width: width).environment(\.colorScheme, .dark)))
            // A place no display covers, so the window is never seen. It has to be
            // in the window list for a click sent to it to reach a SwiftUI button.
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hostingView
            window.orderFrontRegardless()
        }

        deinit {
            window.orderOut(nil)
        }

        func settle(forSeconds seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            let size = NSSize(width: width, height: hostingView.fittingSize.height)
            window.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: true)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func write(_ hosted: HostedView, name: String) {
        let size = hosted.hostingView.frame.size
        // Drawn at 2x, the way a Retina display shows it: type weight cannot be judged at 1x.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { failureCount += 1; print("FAIL no bitmap for \(name)"); return }
        bitmap.size = size
        hosted.hostingView.cacheDisplay(in: hosted.hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failureCount += 1; print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    }

    func render<V: View>(_ view: V, width: CGFloat, name: String, settleSeconds: TimeInterval = 0.5) {
        let hosted = HostedView(view, width: width)
        hosted.settle(forSeconds: settleSeconds)
        write(hosted, name: name)
    }

    // The open notch is 640 wide. ClickyNotchRootView pads its content by 19 + 12
    // on each side and NotchPanelView by 8 more, and by 4 above and 8 below.
    // About 270 pt of the panel's height is left for a shot's full height (that
    // padding included) before the panel has to scroll.
    let panelWidth: CGFloat = 640
    let panelSideInset: CGFloat = 19 + 12 + 8
    func onNotchPanel<V: View>(_ view: V) -> some View {
        view
            .padding(.horizontal, panelSideInset)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(DS.Colors.notchBlack)
    }

    /// The two flags the setup view keeps in UserDefaults, set for this process only.
    func setSetupFlags(hasSeenAutomationExplainer: Bool, hasSkippedAPIKeySetup: Bool) {
        UserDefaults.standard.setVolatileDomain(
            [
                "teachyHasSeenAutomationPermissionExplainer": hasSeenAutomationExplainer,
                "teachyHasSkippedAPIKeySetup": hasSkippedAPIKeySetup,
            ],
            forName: UserDefaults.argumentDomain
        )
    }

    let session = TeachyPublikSession.shared
    let notchManager = NotchWindowManager()
    func setupView(_ companionManager: CompanionManager) -> some View {
        onNotchPanel(NotchSetupOnboardingView(companionManager: companionManager, notchManager: notchManager))
    }

    // ── The publik gate ─────────────────────────────────────────────
    setSetupFlags(hasSeenAutomationExplainer: false, hasSkippedAPIKeySetup: false)
    session.isReady = false
    session.gate.screen = nil
    render(setupView(CompanionManager()), width: panelWidth, name: "01-gate-connecting")

    session.gate.screen = Publik.Screen(
        id: "sign_in", title: "Sign in with publik",
        body: "This app uses your publik account. Click Sign in with publik, then sign in in your browser. This window continues when you are signed in.",
        note: nil, buttons: [("sign_in", "Sign in with publik")]
    )
    render(setupView(CompanionManager()), width: panelWidth, name: "02-gate-sign-in")
    session.isSwitchingAccount = true
    render(setupView(CompanionManager()), width: panelWidth, name: "22-gate-after-logout")
    session.isSwitchingAccount = false

    session.gate.screen = Publik.Screen(
        id: "sign_in", title: "Sign in with publik",
        body: "This app uses your publik account. Click Sign in with publik, then sign in in your browser. This window continues when you are signed in.",
        note: "Waiting for you to sign in in your browser.", buttons: [("sign_in", "Sign in with publik")]
    )
    render(setupView(CompanionManager()), width: panelWidth, name: "03-gate-sign-in-waiting")

    session.gate.screen = Publik.Screen(
        id: "choose", title: "Choose how to pay for AI",
        body: "You are signed in as @sample. This app uses AI. Get a publik plan, or use your own key.",
        note: nil, buttons: [("get_plan", "Get a plan"), ("own_key", "Use my own key")]
    )
    render(setupView(CompanionManager()), width: panelWidth, name: "04-gate-choose")

    session.gate.screen = nil
    session.isReady = true
    session.choice = "publik"

    // ── Permissions ─────────────────────────────────────────────────
    let askingForScreenRecording = CompanionManager()
    let screenRecordingStep = HostedView(setupView(askingForScreenRecording), width: panelWidth)
    screenRecordingStep.settle(forSeconds: 0.5)
    write(screenRecordingStep, name: "05-permissions-screen-recording")

    // The grant lands: the row is checked off and closes before the next one opens.
    askingForScreenRecording.hasScreenRecordingPermission = true
    screenRecordingStep.settle(forSeconds: 0.45)
    write(screenRecordingStep, name: "06-permissions-just-granted")

    let askingForAccessibility = CompanionManager()
    askingForAccessibility.hasScreenRecordingPermission = true
    render(setupView(askingForAccessibility), width: panelWidth, name: "07-permissions-accessibility")

    let askingForSpeechRecognition = CompanionManager()
    askingForSpeechRecognition.requiresSpeechRecognitionPermission = true
    render(setupView(askingForSpeechRecognition), width: panelWidth, name: "08-permissions-speech-recognition")

    // ── Automation heads-up, API key ────────────────────────────────
    let everythingGranted = CompanionManager()
    everythingGranted.hasScreenRecordingPermission = true
    everythingGranted.hasAccessibilityPermission = true
    render(setupView(everythingGranted), width: panelWidth, name: "09-automation-heads-up", settleSeconds: 1.0)

    setSetupFlags(hasSeenAutomationExplainer: true, hasSkippedAPIKeySetup: false)
    session.choice = "own_key"
    render(setupView(everythingGranted), width: panelWidth, name: "10-api-key")

    // ── The product tour, page by page ──────────────────────────────
    session.choice = "publik"
    let tour = HostedView(setupView(everythingGranted), width: panelWidth)
    tour.settle(forSeconds: 0.5)
    write(tour, name: "11-tour-1-say-hi")
    // The main button of a tour page is the first thing in its last row: the
    // panel's inset and 6 pt of page inset from the left, 8 + 10 pt from the
    // bottom, 28 pt tall.
    func clickTourMainButton() {
        let viewHeight = tour.hostingView.bounds.height
        click(atPointFromTopLeft: CGPoint(x: panelSideInset + 6 + 22, y: viewHeight - 8 - 10 - 14), in: tour.hostingView, of: tour.window)
    }
    clickTourMainButton()
    tour.settle(forSeconds: 0.7)
    write(tour, name: "12-tour-2-watch-it-point")

    // The live pointing demo has played: the page moves on by itself.
    everythingGranted.teachyScreenProofDidPlay = true
    tour.settle(forSeconds: 0.7)
    write(tour, name: "13-tour-3-circle-and-ask")

    clickTourMainButton()
    tour.settle(forSeconds: 0.7)
    write(tour, name: "14-tour-4-dictate")

    clickTourMainButton()
    tour.settle(forSeconds: 0.7)
    write(tour, name: "15-tour-5-hand-it-a-job")

    // ── Out of credit, and the Account row on Home ──────────────────
    session.billingNotice = TeachyAIBillingError(
        message: "You are out of publik credit.",
        topUpURL: URL(string: "https://example.com/top-up")
    )
    render(onNotchPanel(PublikBillingBanner()), width: panelWidth, name: "16-billing-banner")
    session.billingNotice = TeachyAIBillingError(
        message: "Your publik plan has reached its limit for this month. Add credit to keep using AI in every publik app.",
        topUpURL: URL(string: "https://example.com/top-up")
    )
    render(onNotchPanel(PublikBillingBanner()), width: panelWidth, name: "17-billing-banner-long-message")
    session.billingNotice = nil

    session.wallet = Publik.Wallet(
        claimed: true, claimURL: nil, handle: "sample", planKind: "none", planLabel: nil,
        balanceMicros: 8_400_000, topUpURL: "https://example.com/wallet"
    )
    // Home mounts the Account row as the first row of its settings group.
    func onHomeSettingsList<V: View>(_ row: V) -> some View {
        onNotchPanel(
            VStack(alignment: .leading, spacing: 0) {
                row
                SettingsDisclosureCard(icon: "waveform", title: "Voice", summary: "Puck") { EmptyView() }
            }
            .teachyGroup()
            .padding(.horizontal, 6)
        )
    }
    let accountRow = HostedView(onHomeSettingsList(PublikAccountSection()), width: panelWidth)
    accountRow.settle(forSeconds: 0.4)
    write(accountRow, name: "18-account-row-closed")
    // The row's header is the first thing in the group.
    click(atPointFromTopLeft: CGPoint(x: panelWidth / 2, y: 4 + 20), in: accountRow.hostingView, of: accountRow.window)
    accountRow.settle(forSeconds: 0.6)
    write(accountRow, name: "19-account-row-open-balance")

    session.wallet = Publik.Wallet(
        claimed: true, claimURL: nil, handle: "sample", planKind: "plan", planLabel: "Fellowship",
        balanceMicros: 0, topUpURL: "https://example.com/wallet"
    )
    accountRow.settle(forSeconds: 0.3)
    write(accountRow, name: "20-account-row-open-plan")

    session.choice = "own_key"
    accountRow.settle(forSeconds: 0.3)
    write(accountRow, name: "21-account-row-open-own-key")

    if failureCount > 0 {
        print("\(failureCount) FAILED")
        exit(1)
    }
    print("ALL RENDERED")
    exit(0)
}

MainActor.assumeIsolated { runShots() }
