// Stand-ins for the app types that the real notch files refer to, shared by the
// Home tab renders (scripts/tests/render_home_shots.sh) and the notch demo
// (scripts/tests/run_notch_demo.sh). Nothing here touches the real app or ~/.teachy.
import AppKit
import Combine
import SwiftUI

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

final class VoiceModeController: ObservableObject {
    static let shared = VoiceModeController()
    @Published var state: AlwaysOnState = .off
    @Published var level: Float = 0
    @Published var notice: String?
    @Published var canInterruptBySpeaking = true
    func toggleAlwaysOn() {}
}

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    @Published var isRecordingNewShortcut = false
    @Published var keyCodesRecordedSoFar: [UInt16] = []
    var isEventTapActive = true
    func beginRecordingNewShortcut() {}
    func cancelRecordingNewShortcut() {}
}

enum CompanionVoiceState { case idle, listening, processing, responding }

enum AgentStatus: Equatable {
    case idle
    case reasoning
    case running(toolName: String)
    case completed(result: String)
    case failed(error: String)
}

final class BackgroundAgentManager: ObservableObject {
    @Published var status: AgentStatus = .idle
}

final class CompanionManager: ObservableObject {
    @Published var selectedCursorColor: ClickyCursorColor = .blue
    @Published var voiceState: CompanionVoiceState = .idle
    let backgroundAgentManager = BackgroundAgentManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    func setSelectedCursorColor(_ cursorColor: ClickyCursorColor) { selectedCursorColor = cursorColor }
    func replayOnboarding() {}
}



/// The real window manager owns an NSPanel; this one keeps only the open / closed
/// state and springs for deterministic rendering. Hover behavior is tested against
/// the real manager by run_notch_hover_tests.sh.
final class NotchWindowManager: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var isHoveringNotch = false
    @Published var selectedTab: NotchPanelTab = .home
    @Published var settingsPage: TeachySettingsPage = .account
    @Published var setupMode = false
    var expandedSize: CGSize { ClickyNotchSizing.expandedSize(for: selectedTab, setup: setupMode) }
    var hostingSize: CGSize {
        let size = isExpanded ? expandedSize : ClickyNotchSizing.openNotchSize
        return CGSize(width: size.width, height: size.height + ClickyNotchSizing.shadowPadding)
    }
    func openSettings(_ page: TeachySettingsPage = .account) {
        settingsPage = page
        selectedTab = .settings
        expand()
    }
    func setInteractionPinned(_ pinned: Bool) {}
    func setSetupMode(_ needed: Bool) { setupMode = needed }
    func makePanelKey() {}
    var notchGeometry = NotchScreenGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        notchHeight: 0, notchWidth: 0, notchLeftEdgeX: 0, notchCenterX: 960,
        leftAuxiliaryAreaWidth: 0, hasNotch: false
    )
    private var hoverOpenTask: Task<Void, Never>?

    func currentNotchGeometry() -> NotchScreenGeometry { notchGeometry }
    func setAttachmentDragTargeted(_ targeted: Bool) {}

    func expand() {
        hoverOpenTask?.cancel()
        withAnimation(ClickyNotchSizing.openSpring) { isExpanded = true }
    }

    func collapse() {
        hoverOpenTask?.cancel()
        withAnimation(ClickyNotchSizing.closeSpring) {
            isExpanded = false
            isHoveringNotch = false
        }
    }

    func handleNotchHover(_ hovering: Bool) {
        hoverOpenTask?.cancel()
        withAnimation(ClickyNotchSizing.interactiveSpring) { isHoveringNotch = hovering }
        guard hovering, !isExpanded else { return }
        hoverOpenTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, self.isHoveringNotch, !self.isExpanded else { return }
            self.expand()
        }
    }
}

/// The real panel body also handles sign-in and onboarding; this is its Home path.
struct NotchPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager

    var body: some View {
        Group {
            switch notchManager.selectedTab {
            case .home:
                NotchHomeTabView(companionManager: companionManager, notchManager: notchManager)
            case .chat:
                SectionPlaceholder(title: "Chat shell", detail: "Conversation content is tested in the chat render harness.")
                    .padding(24)
            default:
                SectionPlaceholder(title: notchManager.settingsPage.rawValue,
                                   detail: "Settings content is tested in the settings render harness.")
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Teachy's pointer triangle, as OverlayWindow.swift draws it.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// The real modifier lets a file be dropped on the notch; nothing to drop here.
    func attachmentDropTarget(shelf: AttachmentShelf? = nil, cornerRadius: CGFloat = 14, showsHighlight: Bool = true, onTargetedChange: ((Bool) -> Void)? = nil) -> some View {
        self
    }
}

struct AttachmentShelf {}

final class TeachySoftwareUpdater: ObservableObject {
    static let shared = TeachySoftwareUpdater()
    let shortVersionString = "2.4.0"
    let buildNumberString = "412"
    let canCheckForUpdates = true
    func checkForUpdates() {}
}

final class ChatWindowController {
    static let shared = ChatWindowController()
    func show() {}
}

struct AttachmentChipsView: View {
    var compact = false
    var body: some View { EmptyView() }
}

/// Marks where a section that needs live data goes. Its own shots are rendered
/// by the harness that owns it (agents2, chrome, voice2).
struct SectionPlaceholder: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TeachySectionTitle(title: title, detail: detail)
            TeachyRule()
        }
    }
}

/// The real agents, routines and jobs lists, drawn from sample values instead of the live stores.
struct AgentsSection: View {
    var body: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15, minute: 20))!
        func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        var notificationsRoutine = Routine(
            id: "r1", task: "Check my GitHub notifications and tell me which ones need me.",
            schedule: .weekdays(hour: 9, minute: 0), createdAt: minutesAgo(5_000)
        )
        notificationsRoutine.lastRun = minutesAgo(380)
        notificationsRoutine.lastResult = "Three need you: a review request from Kabir, a failing check on your branch, and a mention in the pricing discussion."
        notificationsRoutine.lastStatus = "ok"
        notificationsRoutine.hasUnreadResult = true

        return AgentsSectionContent(
            agents: [
                AgentProfile(slug: "builder", name: "Builder", role: "Builds small apps, scripts and sites on this Mac."),
                AgentProfile(slug: "research-buddy", name: "Research buddy", role: "Finds things out and tells you what matters.")
            ],
            routines: [notificationsRoutine],
            jobs: [],
            now: now,
            calendar: calendar
        )
    }
}
struct ConnectorsSection: View { var body: some View { SectionPlaceholder(title: "Connectors", detail: "2 connected") } }
struct DrawingsSection: View { var startsExpanded = false; var body: some View { SectionPlaceholder(title: "Drawings", detail: "12") } }
struct BrainMemorySection: View { var body: some View { SectionPlaceholder(title: "Memory", detail: "14 things") } }
struct PublikAccountSection: View {
    var body: some View {
        SettingsDisclosureCard(icon: "person.crop.circle", title: "Account", summary: "publik · 8.40 left") { EmptyView() }
    }
}
struct BrowserExtensionSection: View {
    var body: some View {
        SettingsDisclosureCard(icon: "globe", title: "Browser", summary: "chrome · connected") { EmptyView() }
    }
}


struct HomeShotDrawing: Identifiable {
    let id: String
    let title: String
}
final class SceneHistory: ObservableObject {
    static let shared = SceneHistory()
    @Published var entries = [HomeShotDrawing(id: "jet", title: "Jet turbine"), HomeShotDrawing(id: "keyboard", title: "Keyboard switch")]
    func reload() {}
    func replay(_ id: String) {}
    func thumbnail(for id: String) -> NSImage? { NSImage(systemSymbolName: id == "jet" ? "airplane" : "keyboard", accessibilityDescription: nil) }
}
final class ConnectorCenter: ObservableObject {
    static let shared = ConnectorCenter()
    @Published var connectors: [String] = []
    struct State { var isConnected = false }
    @Published var states: [String: State] = [:]
}

final class TeachyAnnouncementController {
    static let shared = TeachyAnnouncementController()
    func showLatest() {}
}
