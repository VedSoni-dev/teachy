//
//  AlwaysOnPillView.swift
//  leanring-buddy
//
//  The small pill that shows what always-on mode is doing: listening, hearing you,
//  thinking, speaking, paused for a call, or asking for headphones. Mount
//  `AlwaysOnPillView()` anywhere; it watches `VoiceModeController.shared` and
//  clicking it switches always-on on or off. `AlwaysOnPill` is the drawing on its
//  own, given a state, for previews and tests.
//

import SwiftUI

/// What the pill needs to draw. Kept apart from the controller so it renders anywhere.
struct AlwaysOnPillAppearance: Equatable {
    var icon: String
    var label: String
    var tint: Color
    /// Show the moving level bars (the microphone is open).
    var showsLevel: Bool
    /// A slow pulse on the dot (waiting on something).
    var pulses: Bool

    static func make(for state: AlwaysOnState) -> AlwaysOnPillAppearance {
        switch state {
        case .off:
            return .init(icon: "waveform.slash", label: "Always-on off", tint: DS.Colors.textTertiary, showsLevel: false, pulses: false)
        case .listening:
            return .init(icon: "waveform", label: "Listening", tint: DS.Colors.success, showsLevel: true, pulses: false)
        case .hearing:
            return .init(icon: "waveform", label: "Hearing you", tint: DS.Colors.success, showsLevel: true, pulses: false)
        case .thinking:
            return .init(icon: "ellipsis", label: "Thinking", tint: DS.Colors.info, showsLevel: false, pulses: true)
        case .speaking:
            return .init(icon: "speaker.wave.2.fill", label: "Speaking", tint: DS.Colors.info, showsLevel: false, pulses: false)
        case .pausedForCall:
            return .init(icon: "phone.fill", label: "Paused for your call", tint: DS.Colors.warning, showsLevel: false, pulses: false)
        case .needsHeadphones:
            return .init(icon: "headphones", label: "Put on headphones", tint: DS.Colors.warning, showsLevel: false, pulses: false)
        case .unavailable(let reason):
            return .init(icon: "mic.slash.fill", label: reason, tint: DS.Colors.destructiveText, showsLevel: false, pulses: false)
        }
    }
}

struct AlwaysOnPill: View {
    let state: AlwaysOnState
    /// Input loudness, 0…1.
    var level: Float = 0

    @State private var isPulsing = false

    var body: some View {
        let appearance = AlwaysOnPillAppearance.make(for: state)
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(appearance.tint.opacity(0.18))
                    .frame(width: 20, height: 20)
                Image(systemName: appearance.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(appearance.tint)
            }
            .opacity(appearance.pulses && isPulsing ? 0.45 : 1)
            .animation(appearance.pulses ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)

            Text(appearance.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            if appearance.showsLevel {
                AlwaysOnLevelBars(level: level, tint: appearance.tint)
                    .frame(width: 18, height: 12)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(DS.Colors.surface2))
        .overlay(Capsule().strokeBorder(state == .off ? Color.white.opacity(0.1) : appearance.tint.opacity(0.5), lineWidth: 1))
        .onAppear { isPulsing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Always-on mode: \(appearance.label)")
    }
}

/// Four bars that rise with the input level; the outer ones lag the inner ones.
private struct AlwaysOnLevelBars: View {
    let level: Float
    let tint: Color
    private static let weights: [CGFloat] = [0.55, 1.0, 0.8, 0.45]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Self.weights.count, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: 3,
                            height: max(3, geometry.size.height * CGFloat(min(1, max(0, level))) * Self.weights[index])
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            .animation(.linear(duration: 0.08), value: level)
        }
    }
}

/// The pill wired to the live controller. Click to switch always-on on or off.
struct AlwaysOnPillView: View {
    @ObservedObject private var controller = VoiceModeController.shared
    /// Show the one-line reason under the pill (why it switched off, which mic took over).
    var showsNotice = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                controller.toggleAlwaysOn()
            } label: {
                AlwaysOnPill(state: controller.state, level: controller.level)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(helpText)

            if showsNotice, let notice = controller.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var helpText: String {
        switch controller.state {
        case .off: return "Switch on always-on mode (or press Control three times). Teachy listens without a key held."
        case .needsHeadphones: return "On speakers Teachy would hear itself. Always-on starts when headphones are connected."
        case .pausedForCall: return "Always-on is paused while you're on a call. It comes back when the call ends."
        case .speaking where controller.canInterruptBySpeaking: return "Just start talking to interrupt. Click to switch always-on off."
        default: return "Click to switch always-on off (or press Control three times)."
        }
    }
}
