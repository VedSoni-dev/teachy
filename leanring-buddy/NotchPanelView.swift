//
//  NotchPanelView.swift
//  leanring-buddy
//
//  Expanded notch body. Home is the only tab; setup and onboarding take its
//  place until they are done. Shell lives in ClickyNotchRootView.
//

import AVFoundation
import SwiftUI

enum NotchPanelTab: String, CaseIterable {
    case home
}

struct NotchPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    // "I'll set it up later" on the API key step — without this flag the setup
    // view would re-trap key-less users forever, and the Home tab (where the key
    // can be added later) would be unreachable.
    @AppStorage("teachyHasSkippedAPIKeySetup") private var hasSkippedAPIKeySetup = false
    @ObservedObject private var publikSession = TeachyPublikSession.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if publikSession.isReady {
                    PublikBillingBanner()
                }
                tabContent
                    .id(notchManager.selectedTab)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity
                        )
                    )
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .animation(.smooth(duration: 0.28), value: notchManager.selectedTab)
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
            switch notchManager.selectedTab {
            case .home:
                NotchHomeTabView(companionManager: companionManager, notchManager: notchManager)
            }
        }
    }
}
