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
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if publikSession.isReady { PublikBillingBanner() }
                    tabContent
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .id(notchManager.selectedTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var needsSetup: Bool {
        !publikSession.isReady
            || !companionManager.allPermissionsGranted
            || (publikSession.choice == "own_key" && !TeachyAPIKeyStore.isConfigured && !hasSkippedAPIKeySetup)
            || !companionManager.hasCompletedOnboarding
    }

    @ViewBuilder
    private var tabContent: some View {
        // Permissions + intro come first, before the Home tab is reachable.
        if needsSetup {
            NotchSetupOnboardingView(companionManager: companionManager, notchManager: notchManager)
        } else {
            NotchHomeTabView(companionManager: companionManager, notchManager: notchManager)
        }
    }
}
