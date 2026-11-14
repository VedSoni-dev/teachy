//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Dock + menu bar companion app. Lives in the dock with a status item
//  in the menu bar. The notch panel at the top center of the screen is the
//  primary UI — clicking the menu bar icon or dock icon toggles it.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives in the dock + menu bar. The empty Settings scene satisfies
        // SwiftUI's requirement for at least one scene; clicking Settings… in the
        // app menu shows an empty window (no-op since preferences live in the panel).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var notchManager: NotchWindowManager?
    private let companionManager = CompanionManager()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Force regular activation policy so the app appears in the dock.
        // SwiftUI's @main with only a Settings scene defaults to .accessory
        // (menu bar only), which ignores LSUIElement=false in Info.plist.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        print("🎯 Teachy: Starting…")
        print("🎯 Teachy: Version \(version)")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // Sign in with publik runs before any Teachy screen. PUBLIK_SELF_TEST=1
        // makes it print its self-test line and exit here.
        TeachyPublikSession.shared.start()

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        notchManager = NotchWindowManager(companionManager: companionManager)
        menuBarPanelManager = MenuBarPanelManager(
            companionManager: companionManager,
            notchManager: notchManager!
        )
        companionManager.start()
        // Fn+Control dictation: waits for the publik gate and for the Accessibility
        // and Microphone permissions before it listens for the hotkey.
        DictationController.shared.startWhenReady()

        // Show the notch on launch so the user sees it right away
        notchManager?.show()

        registerAsLoginItemIfNeeded()
        TeachySoftwareUpdater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Called when the user clicks the dock icon while the app is running.
    /// Toggles the notch expansion.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notchManager?.toggleExpanded()
        return true
    }

    /// Handles `teachy://` deep links — the osu!-style install path from the
    /// Teachy Academy website. `teachy://install?url=<https course JSON URL>`
    /// installs the course into `~/.teachy/courses/` and opens the Courses tab
    /// so the user watches it land.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleTeachyDeepLink(url)
        }
    }

    private func handleTeachyDeepLink(_ deepLinkURL: URL) {
        guard deepLinkURL.scheme?.lowercased() == "teachy" else { return }
        guard deepLinkURL.host?.lowercased() == "install",
              let components = URLComponents(url: deepLinkURL, resolvingAgainstBaseURL: false),
              let courseURLString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let courseURL = URL(string: courseURLString),
              courseURL.scheme?.lowercased() == "https"
        else {
            print("⚠️ Teachy: Ignored malformed deep link: \(deepLinkURL)")
            return
        }

        notchManager?.selectedTab = .courses
        notchManager?.show()
        notchManager?.expand()
        companionManager.installCourseFromURL(courseURLString)
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Teachy: Registered as login item")
            } catch {
                print("⚠️ Teachy: Failed to register as login item: \(error)")
            }
        }
    }
}
