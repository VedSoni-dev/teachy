//
//  NotchPanelView.swift
//  leanring-buddy
//
//  Expanded notch body (Courses / Home). Agents UI is retained but hidden —
//  teaching stays the primary product. Shell lives in ClickyNotchRootView.
//

import AVFoundation
import SwiftUI

enum NotchPanelTab: String, CaseIterable {
    case home
    case courses
    case portfolio
    case skills
    case agents
}

struct NotchPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
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
        .sheet(isPresented: $companionManager.showCustomCourseBuilder) {
            NotchCustomCourseBuilderSheet(companionManager: companionManager)
        }
    }

    private var needsSetup: Bool {
        !companionManager.allPermissionsGranted || !TeachyAPIKeyStore.isConfigured || !companionManager.hasCompletedOnboarding
    }

    @ViewBuilder
    private var tabContent: some View {
        // Permissions + intro must show even when Courses is the default tab.
        if needsSetup {
            NotchSetupOnboardingView(companionManager: companionManager, notchManager: notchManager)
        } else {
            switch notchManager.selectedTab {
            case .home:
                NotchHomeTabView(companionManager: companionManager, notchManager: notchManager)
            case .courses:
                NotchCoursesTabView(companionManager: companionManager, notchManager: notchManager)
            case .portfolio:
                NotchPortfolioTabView(companionManager: companionManager)
            case .skills:
                NotchSkillsTabView(companionManager: companionManager)
            case .agents:
                NotchCoursesTabView(companionManager: companionManager, notchManager: notchManager)
            }
        }
    }
}
