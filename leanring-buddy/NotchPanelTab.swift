import Foundation

enum NotchPanelTab: String, CaseIterable, Identifiable {
    case home, chat, agents, drawings, connections, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .agents: return "person.2"
        case .drawings: return "scribble.variable"
        case .connections: return "link"
        case .settings: return "slider.horizontal.3"
        }
    }
}
