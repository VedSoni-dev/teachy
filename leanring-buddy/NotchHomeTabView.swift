import AppKit
import SwiftUI

/// Quiet launcher; conversation and settings have their own sized surfaces.
struct NotchHomeTabView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var connections = ConnectorCenter.shared
    @State private var shortcut = PushToTalkShortcutKeys.currentShortcutDisplayText
    @State private var greeting = "Hello."

    var body: some View {
        VStack(spacing: 5) {
            Text(greeting)
                .font(DS.Fonts.sans(19, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold \(shortcut) and tell me what to take off your plate.")
                .font(DS.Fonts.sans(12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Button { notchManager.openSettings(.drawings) } label: {
                    Label("Drawings", systemImage: "scribble.variable")
                }
                .teachyButton(.secondary, size: .compact)
                Button { notchManager.openSettings(.routines) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .teachyIconButton(sideLength: 30)
                .accessibilityLabel("Routines")
                Spacer()
                Button { notchManager.openSettings(.integrations) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "puzzlepiece.extension.fill")
                        if !connections.connectors.isEmpty { Text("\(connections.connectors.count)") }
                        Image(systemName: "plus")
                    }
                }
                .teachyButton(.secondary, size: .compact)
                .accessibilityLabel("Manage integrations")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .onAppear {
            let hour = Calendar.current.component(.hour, from: Date())
            let salutation = hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
            let name = PersonNameComponentsFormatter().personNameComponents(from: NSFullUserName())?.givenName
            greeting = name.map { "\(salutation), \($0)." } ?? "\(salutation)."
        }
        .onReceive(NotificationCenter.default.publisher(for: PushToTalkShortcutKeys.shortcutDidChangeNotification)) { _ in
            shortcut = PushToTalkShortcutKeys.currentShortcutDisplayText
        }
    }
}
