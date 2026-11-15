//
//  BrowserExtensionCard.swift
//  leanring-buddy
//
//  The settings card for the browser extension, as a plain view: it is given
//  the connection state and what to do when a button is pressed, and knows
//  nothing about the bridge. `BrowserExtensionSection` (next file) feeds it
//  from BrowserBridge; scripts/tests/render_chrome_shots.sh renders it to PNG.
//
//  Three faces:
//    not set up   -> "Install the browser helper" (or the steps, when this build cannot)
//    waiting      -> how to add the extension, "Open chrome://extensions"
//    connected    -> which browser, and what agents may and may not do there
//

import SwiftUI

struct BrowserExtensionCard: View {
    let state: BrowserConnectionState
    /// Browsers that already have the helper ("Chrome", "Arc").
    var browsersWithHelper: [String] = []
    /// The app can run the install script itself. False: show the steps instead.
    var canInstall: Bool = true
    var isInstalling: Bool = false
    /// The line under the buttons after an install attempt, or why the bridge could not listen.
    var message: String?
    var messageIsProblem: Bool = false
    var manualSteps: [String] = []
    var startsExpanded: Bool = false
    var onInstall: () -> Void = {}
    var onOpenExtensionsPage: () -> Void = {}
    var onCheckAgain: () -> Void = {}

    @State private var showsSteps = false

    var body: some View {
        SettingsDisclosureCard(
            icon: "globe",
            title: "Browser",
            summary: summary,
            startsExpanded: startsExpanded
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    caption(explanation)
                }
            }

            switch state {
            case .notInstalled:
                HStack(spacing: 12) {
                    primaryButton(isInstalling ? "Installing…" : "Install the browser helper", isBusy: isInstalling) {
                        if canInstall { onInstall() } else { showsSteps = true }
                    }
                    if canInstall {
                        quietButton(showsSteps ? "Hide the steps" : "Do it by hand") { showsSteps.toggle() }
                    }
                }
                if showsSteps || !canInstall {
                    steps(manualSteps)
                }

            case .waitingForChrome:
                steps([
                    "Open the extensions page in your browser.",
                    "Add the Teachy extension, and leave it switched on.",
                    "This card turns green by itself. If it does not, restart the browser."
                ])
                HStack(spacing: 12) {
                    primaryButton("Open chrome://extensions", isBusy: false, action: onOpenExtensionsPage)
                    quietButton("Check again", action: onCheckAgain)
                    quietButton(isInstalling ? "Installing…" : "Reinstall the helper", action: onInstall)
                }

            case .connected:
                SettingsDivider()
                fact(icon: "rectangle.stack", text: "Agents work in their own tab group, named after the job. Your other tabs are not read.")
                fact(icon: "hand.raised", text: "Teachy asks before it acts on a site, and every time before buying, paying, sending, posting, deleting or uploading a file.")
                fact(icon: "key", text: "Passwords, verification codes and card numbers are handed back to you to type. Teachy never reads them.")
                fact(icon: "escape", text: "Press Escape on the page, or click the Teachy button in the toolbar, to take the browser back.")
            }

            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(messageIsProblem ? DS.Colors.warningText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Words

    private var summary: String {
        switch state {
        case .notInstalled: return "Not set up"
        case .waitingForChrome: return "Waiting for your browser"
        case .connected(let browserName): return "Connected to \(browserName)"
        }
    }

    private var headline: String {
        switch state {
        case .notInstalled: return "Let Teachy work in your browser"
        case .waitingForChrome: return "Waiting for your browser"
        case .connected(let browserName): return "Connected to \(browserName)"
        }
    }

    private var explanation: String {
        switch state {
        case .notInstalled:
            return "Agents can do things on websites for you, in your own Chrome, Edge, Brave, Arc or Vivaldi, on the sites you are already signed in to. You watch it happen. This installs a small helper so the Teachy extension can reach this app; it talks to nothing else."
        case .waitingForChrome:
            let browsers = browsersWithHelper.isEmpty ? "your browser" : Self.list(browsersWithHelper)
            return "The helper is installed for \(browsers). Teachy is waiting for the extension to say hello."
        case .connected:
            return "Agents can now work on websites for you."
        }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    private var dotColor: Color {
        switch state {
        case .notInstalled: return DS.Colors.textTertiary
        case .waitingForChrome: return DS.Colors.warning
        case .connected: return DS.Colors.success
        }
    }

    // MARK: Pieces

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func steps(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 12, alignment: .trailing)
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func fact(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.learnAccent)
                .frame(width: 16)
                .padding(.top, 1)
            caption(text)
        }
    }

    private func primaryButton(_ title: String, isBusy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.accent.opacity(isBusy ? 0.5 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .pointerCursor(isEnabled: !isBusy)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
