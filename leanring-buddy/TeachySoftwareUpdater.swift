//
//  TeachySoftwareUpdater.swift
//  leanring-buddy
//
//  Sparkle auto-update controller for free Teachy builds distributed via
//  GitHub Releases. Feed URL + public EdDSA key live in Info.plist.
//

import Foundation
import Combine
import Sparkle

@MainActor
final class TeachySoftwareUpdater: ObservableObject {
    static let shared = TeachySoftwareUpdater()

    @Published private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    private init() {}

    var shortVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var buildNumberString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    func start() {
        guard updaterController == nil else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller

        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }

        do {
            try controller.updater.start()
            print("🎯 Teachy: Sparkle updater started")
        } catch {
            print("⚠️ Teachy: Sparkle updater failed to start: \(error)")
        }
    }

    func checkForUpdates() {
        guard let updaterController else {
            print("⚠️ Teachy: Sparkle updater is not started yet")
            return
        }
        updaterController.checkForUpdates(nil)
    }
}
