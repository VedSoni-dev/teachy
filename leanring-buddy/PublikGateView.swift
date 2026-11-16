//
//  PublikGateView.swift
//  leanring-buddy
//
//  The notch panel's view of publik: the sign-in gate (first screen, before
//  anything else in Teachy), the 402 banner with publik's one top-up link,
//  and the Home tab's account section. The gate's words come from Publik.swift.
//

import SwiftUI

/// Draws whatever screen publik's gate is asking for and returns the pressed button.
struct PublikGateView: View {
    @ObservedObject var gate: GateModel
    @ObservedObject private var session = TeachyPublikSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.isSwitchingAccount {
                Text("You’re logged out of Teachy. To use a different Publik account, sign out of Publik in your browser before signing in again.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let screen = gate.screen {
                VStack(alignment: .leading, spacing: 10) {
                    TeachySetupStepHeader(headline: screen.title, explanation: screen.body)

                    // publik's note is always about something it is waiting on the
                    // person for (finishing sign-in or a plan in the browser).
                    if let note = screen.note {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            TeachyStatusMark(kind: .needsYou)
                            Text(note)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // publik's first button is the way forward; any other is a way round it.
                HStack(spacing: 6) {
                    ForEach(Array(screen.buttons.enumerated()), id: \.offset) { buttonIndex, button in
                        Button(button.label) {
                            gate.press(button.action)
                        }
                        .teachyButton(buttonIndex == 0 ? .primary : .quiet)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting to publik…")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// publik answered 402: its message plus exactly one link.
struct PublikBillingBanner: View {
    @ObservedObject private var session = TeachyPublikSession.shared

    var body: some View {
        if let notice = session.billingNotice {
            HStack(alignment: .center, spacing: 10) {
                TeachyStatusMark(kind: .needsYou, sideLength: 16)

                Text(notice.message)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                if notice.topUpURL != nil {
                    Button("Add credit on publik") {
                        session.openTopUp()
                    }
                    .teachyLinkButton(color: DS.Colors.warningText)
                }
            }
            .padding(.vertical, 11)
            .teachyGroup()
            // The same inset as the Home tab under it, so the two share one left edge.
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .task {
                // Clears itself once credit lands.
                while !Task.isCancelled && session.billingNotice != nil {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await session.refreshWallet()
                }
            }
        }
    }
}

/// Home tab: who is signed in, how AI is paid for, and a way to change it.
/// The first row of Home's settings group, closed until clicked like the rows
/// under it.
struct PublikAccountSection: View {
    @ObservedObject private var session = TeachyPublikSession.shared

    var body: some View {
        SettingsDisclosureCard(
            icon: "person.crop.circle",
            title: "Account",
            summary: howAIIsPaidFor.rowSummary
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(signedInFact)
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(howAIIsPaidFor.fact)
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Text("Teachy picks the right model for each moment: quick checks, coaching and planning each get their own tier.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Change how I pay for AI") {
                    session.changePaymentChoice()
                }
                .teachyButton(.secondary, size: .compact)

                if session.choice == "publik", let wallet = session.wallet, let url = URL(string: wallet.topUpURL) {
                    Button("publik wallet") {
                        NSWorkspace.shared.open(url)
                    }
                    .teachyLinkButton()
                }
            }

            Button("Log out") {
                session.logOut()
            }
            .teachyLinkButton(color: DS.Colors.destructive)
            .disabled(!session.canLogOut)
            .accessibilityHint("Return to sign-in to use a different Publik account")

            if !session.canLogOut {
                Text("To switch accounts, remove PUBLIK_API_KEY from the launch environment and restart Teachy.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let accountError = session.accountError {
                Text(accountError)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await session.refreshWallet() }
    }

    /// Who publik says is signed in, with the handle when it has given one.
    private var signedInFact: String {
        session.wallet?.handle.map { "Signed in to publik as @\($0)" } ?? "Signed in to publik"
    }

    /// What pays for AI: the person's own OpenRouter key, their publik plan, or
    /// their publik balance. `rowSummary` is the few words shown at the end of
    /// the row while it is closed; `fact` is the line inside the opened row.
    private var howAIIsPaidFor: (rowSummary: String, fact: String) {
        guard session.choice == "publik" else {
            return ("Own OpenRouter key", "AI runs on your own OpenRouter key")
        }
        guard let wallet = session.wallet else {
            return ("publik", "AI runs on publik")
        }
        if wallet.planKind == "plan" {
            let planLabel = wallet.planLabel ?? "publik"
            return ("publik plan \u{00B7} \(planLabel)", "AI runs on your publik plan (\(planLabel))")
        }
        let balanceLeft = String(format: "$%.2f left", Double(wallet.balanceMicros) / 1_000_000)
        return ("publik \u{00B7} \(balanceLeft)", "AI runs on publik \u{00B7} \(balanceLeft)")
    }
}
