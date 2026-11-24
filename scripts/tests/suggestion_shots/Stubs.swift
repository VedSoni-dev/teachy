// Stand-ins so the real suggestion panel renders without the app.
import AppKit

@MainActor
final class SuggestionCenter {
    static let shared = SuggestionCenter()
    func accept(_ suggestion: TeachySuggestion) {}
    func accept(_ suggestion: TeachySuggestion, withChange change: String) {}
    func dismiss(_ suggestion: TeachySuggestion) {}
}

enum AgentNotchLayout {
    static let pillSlotHeight: CGFloat = 40
    static func frame(for size: NSSize, offset: CGFloat = 0, on screen: NSScreen? = nil) -> NSRect? { NSRect(origin: .zero, size: size) }
}

@MainActor
final class DriveTakeoverMonitor {
    static let shared = DriveTakeoverMonitor()
    var isDriving: Bool { false }
}
