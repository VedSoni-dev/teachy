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
        VStack(alignment: .leading, spacing: 12) {
            if let screen = gate.screen {
                VStack(alignment: .leading, spacing: 6) {
                    Text(screen.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(screen.body)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note = screen.note {
                        Text(note)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.learnAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(Array(screen.buttons.enumerated()), id: \.offset) { index, button in
                        Button {
                            gate.press(button.action)
                        } label: {
                            Text(button.label)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(index == 0 ? DS.Colors.learnAccent : Color.white.opacity(0.08))
                                )
                                .foregroundColor(index == 0 ? .white : DS.Colors.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Connecting to publik…")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                    Text(notice.message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if notice.topUpURL != nil {
                    Button {
                        session.openTopUp()
                    } label: {
                        Text("Add credit on publik")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: DS.Colors.warning)
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
struct PublikAccountSection: View {
    @ObservedObject private var session = TeachyPublikSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(summaryLine)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Teachy picks the right model for each moment — quick checks, coaching, and planning each get their own tier.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    session.changePaymentChoice()
                } label: {
                    Text("Change how I pay for AI")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if session.choice == "publik", let wallet = session.wallet, let url = URL(string: wallet.topUpURL) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("publik wallet")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .task { await session.refreshWallet() }
    }

    private var summaryLine: String {
        let who = session.wallet?.handle.map { "Signed in to publik as @\($0)." } ?? "Signed in to publik."
        guard session.choice == "publik" else {
            return "\(who) AI runs on your own OpenRouter key."
        }
        guard let wallet = session.wallet else { return "\(who) AI runs on publik." }
        if wallet.planKind == "plan" {
            return "\(who) AI runs on your publik plan (\(wallet.planLabel ?? "publik"))."
        }
        return "\(who) AI runs on publik. Balance: " + String(format: "$%.2f.", Double(wallet.balanceMicros) / 1_000_000)
    }
}
