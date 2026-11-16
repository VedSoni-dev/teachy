//
//  BrowserExtensionCard.swift
//  leanring-buddy
//
//  The settings row for the browser extension, as a plain view: it is given
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
    /// Saves the extension zip to Downloads and has Teachy show where to click.
    var onGetExtension: () -> Void = {}
    var isSavingExtension: Bool = false
    var onCheckAgain: () -> Void = {}

    @State private var showsSteps = false

    var body: some View {
        SettingsDisclosureCard(
            icon: "globe",
            title: "Browser",
            summary: summary,
            startsExpanded: startsExpanded
        ) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headline)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        TeachyStatusMark(kind: statusKind)
                        Text(statusWord)
                            .font(DS.Fonts.data)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                caption(explanation)
            }

            switch state {
            case .notInstalled:
                HStack(spacing: 4) {
                    Button(isInstalling ? "Installing…" : "Install the browser helper") {
                        if canInstall { onInstall() } else { showsSteps = true }
                    }
                    .teachyButton(.primary, size: .compact)
                    .disabled(isInstalling)

                    if canInstall {
                        Button(showsSteps ? "Hide the steps" : "Do it by hand") { showsSteps.toggle() }
                            .teachyButton(.quiet, size: .compact)
                    }
                }
                if showsSteps || !canInstall {
                    steps(manualSteps)
                }

            case .waitingForChrome:
                steps([
                    "Get the extension: Teachy saves it to Downloads and shows you where to click.",
                    "Unzip it, then in chrome://extensions turn on Developer mode and Load unpacked.",
                    "This row shows Connected by itself. If it does not, restart the browser."
                ])
                HStack(spacing: 4) {
                    Button(isSavingExtension ? "Saving…" : "Get the extension", action: onGetExtension)
                        .teachyButton(.primary, size: .compact)
                        .disabled(isSavingExtension)
                    Button("Open chrome://extensions", action: onOpenExtensionsPage)
                        .teachyButton(.quiet, size: .compact)
                    Button("Check again", action: onCheckAgain)
                        .teachyButton(.quiet, size: .compact)
                    Button(isInstalling ? "Installing…" : "Reinstall the helper", action: onInstall)
                        .teachyButton(.quiet, size: .compact)
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
                    .font(DS.Fonts.caption)
                    .foregroundColor(messageIsProblem ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .lineSpacing(1.5)
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
            return "Agents work on websites for you in your own Chrome, Edge, Brave, Arc or Vivaldi, on the sites you are already signed in to, while you watch. This installs a small helper so the Teachy extension can reach this app; it talks to nothing else."
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

    /// An install that failed, or a bridge that could not listen.
    private var hasProblem: Bool {
        guard let message else { return false }
        return messageIsProblem && !message.isEmpty
    }

    /// The mark beside the status word. Connected wins; then an install that is
    /// running right now; then a problem; then the state as it stands.
    private var statusKind: TeachyStatusKind {
        if case .connected = state { return .done }
        if isInstalling { return .live }
        if hasProblem { return .failed }
        switch state {
        case .notInstalled: return .waiting
        case .waitingForChrome: return .live
        case .connected: return .done
        }
    }

    /// One or two words for the state, beside the mark.
    private var statusWord: String {
        if case .connected = state { return "Connected" }
        if isInstalling { return "Installing" }
        if hasProblem { return "Failed" }
        switch state {
        case .notInstalled: return "Not set up"
        case .waitingForChrome: return "Waiting"
        case .connected: return "Connected"
        }
    }

    // MARK: Pieces

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func steps(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 14, alignment: .leading)
                    Text(line)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func fact(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(DS.Fonts.sans(11, weight: .medium))
                .foregroundColor(DS.Colors.pointer)
                .frame(width: 16)
            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
