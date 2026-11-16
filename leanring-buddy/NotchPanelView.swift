//
//  NotchPanelView.swift
//  leanring-buddy
//
//  Expanded notch body with independently scrolling pages.
//  Setup and onboarding take its place until ready. Shell lives in ClickyNotchRootView.
//

import AVFoundation
import SwiftUI

struct NotchPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    // "I'll set it up later" on the API key step — without this flag the setup
    // view would re-trap key-less users forever, and the Home tab (where the key
    // can be added later) would be unreachable.
    @AppStorage("teachyHasSkippedAPIKeySetup") private var hasSkippedAPIKeySetup = false
    @ObservedObject private var publikSession = TeachyPublikSession.shared

    var body: some View {
        VStack(spacing: 0) {
            if publikSession.isReady { PublikBillingBanner() }
            if needsSetup {
                ScrollView {
                    NotchSetupOnboardingView(companionManager: companionManager, notchManager: notchManager)
                        .padding(20)
                }
            } else {
                switch notchManager.selectedTab {
                case .home:
                    NotchHomeTabView(companionManager: companionManager, notchManager: notchManager)
                case .chat:
                    NotchChatView(companionManager: companionManager, notchManager: notchManager)
                default:
                    TeachySettingsWorkspace(companionManager: companionManager, selection: $notchManager.settingsPage)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onChange(of: needsSetup, initial: true) { _, needed in notchManager.setSetupMode(needed) }
        .onChange(of: publikSession.billingNotice?.message, initial: true) { _, notice in
            if notice != nil && notchManager.selectedTab == .home { notchManager.selectedTab = .chat }
        }
    }

    private var needsSetup: Bool {
        !publikSession.isReady
            || !companionManager.allPermissionsGranted
            || (publikSession.choice == "own_key" && !TeachyAPIKeyStore.isConfigured && !hasSkippedAPIKeySetup)
            || !companionManager.hasCompletedOnboarding
    }

}
