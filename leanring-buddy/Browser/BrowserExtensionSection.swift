//
//  BrowserExtensionSection.swift
//  leanring-buddy
//
//  The Browser card, ready to mount: `BrowserExtensionSection()` anywhere in
//  settings. It shows whether the Chrome extension is connected and sets the
//  helper up. All drawing is in BrowserExtensionCard; this wires it to
//  BrowserBridge.
//

import SwiftUI

struct BrowserExtensionSection: View {
    @ObservedObject private var bridge = BrowserBridge.shared
    private let startsExpanded: Bool

    @State private var isInstalling = false
    @State private var isSavingExtension = false
    @State private var outcome: BrowserBridge.InstallOutcome?

    init(startsExpanded: Bool = false) {
        self.startsExpanded = startsExpanded
    }

    var body: some View {
        BrowserExtensionCard(
            state: bridge.state,
            browsersWithHelper: bridge.browsersWithHelper,
            canInstall: bridge.canInstallFromBundle,
            isInstalling: isInstalling,
            message: bridge.problem ?? outcome?.message,
            messageIsProblem: bridge.problem != nil || outcome?.succeeded == false,
            manualSteps: BrowserBridge.manualInstallSteps,
            startsExpanded: startsExpanded,
            onInstall: install,
            onOpenExtensionsPage: { BrowserBridge.openExtensionsPage() },
            onGetExtension: getExtension,
            isSavingExtension: isSavingExtension,
            onCheckAgain: {
                outcome = nil
                bridge.start()
            }
        )
        .task {
            // Starting is idempotent; this also re-reads what is installed each time settings opens.
            bridge.start()
        }
    }

    private func getExtension() {
        guard !isSavingExtension else { return }
        isSavingExtension = true
        Task {
            outcome = await bridge.getExtensionWithTeachyGuiding()
            isSavingExtension = false
        }
    }

    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            outcome = await bridge.installHelper()
            isInstalling = false
            bridge.start()
        }
    }
}
