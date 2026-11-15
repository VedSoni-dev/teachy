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
    /// The state's colour, used for the symbol and the level bars: the tint
    /// while always-on is live, orange when it waits on the person, red when
    /// it cannot run, grey when it is off.
    var tint: Color
    /// Show the moving level bars (the microphone is open).
    var showsLevel: Bool
    /// A slow pulse on the symbol (waiting on something).
    var pulses: Bool

    static func make(for state: AlwaysOnState) -> AlwaysOnPillAppearance {
        switch state {
        case .off:
            return .init(icon: "waveform.slash", label: "Always-on off", tint: DS.Colors.textSecondary, showsLevel: false, pulses: false)
        case .listening:
            return .init(icon: "waveform", label: "Listening", tint: DS.Colors.pointer, showsLevel: true, pulses: false)
        case .hearing:
            return .init(icon: "waveform", label: "Hearing you", tint: DS.Colors.pointer, showsLevel: true, pulses: false)
        case .thinking:
            return .init(icon: "ellipsis", label: "Thinking", tint: DS.Colors.pointer, showsLevel: false, pulses: true)
        case .speaking:
            return .init(icon: "speaker.wave.2.fill", label: "Speaking", tint: DS.Colors.pointer, showsLevel: false, pulses: false)
        case .pausedForCall:
            return .init(icon: "phone.fill", label: "Paused for your call", tint: DS.Colors.warning, showsLevel: false, pulses: false)
        case .needsHeadphones:
            return .init(icon: "headphones", label: "Put on headphones", tint: DS.Colors.warning, showsLevel: false, pulses: false)
        case .unavailable(let reason):
            return .init(icon: "mic.slash.fill", label: reason, tint: DS.Colors.destructive, showsLevel: false, pulses: false)
        }
    }
}

struct AlwaysOnPill: View {
    let state: AlwaysOnState
    /// Input loudness, 0…1.
    var level: Float = 0

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let appearance = AlwaysOnPillAppearance.make(for: state)
        let symbolPulses = appearance.pulses && !reduceMotion
        HStack(spacing: 6) {
            Image(systemName: appearance.icon)
                .font(DS.Fonts.sans(11, weight: .medium))
                .foregroundColor(appearance.tint)
                .frame(width: 14, height: 14)
                .opacity(symbolPulses && isPulsing ? 0.45 : 1)
                .animation(symbolPulses ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)

            Text(appearance.label)
                .font(DS.Fonts.controlCompact)
                .foregroundColor(state == .off ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                .lineLimit(1)

            if appearance.showsLevel {
                AlwaysOnLevelBars(level: level, tint: appearance.tint)
                    .frame(width: 18, height: 12)
            }
        }
        // It sits on the notch panel beside the compact buttons, so it is a grey
        // capsule of their height, not glass.
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Capsule().fill(DS.Colors.fillSecondary))
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

/// How the pill answers the mouse: it dips on mouse-down like every other
/// Teachy button, and its fill lightens on hover.
private struct AlwaysOnPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AlwaysOnPillButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// A view (not just a style) so it can hold hover state.
private struct AlwaysOnPillButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @State private var isHovered = false

    var body: some View {
        label
            .overlay(Capsule().fill(isHovered ? DS.Colors.fillQuaternary : Color.clear).allowsHitTesting(false))
            .contentShape(Capsule())
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(DS.Motion.press, value: isPressed)
            .animation(DS.Motion.hover, value: isHovered)
            .onHover { hovering in isHovered = hovering }
    }
}

/// The pill wired to the live controller. Click to switch always-on on or off.
struct AlwaysOnPillView: View {
    @ObservedObject private var controller = VoiceModeController.shared
    /// Show the one-line reason under the pill (why it switched off, which mic took over).
    var showsNotice = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                controller.toggleAlwaysOn()
            } label: {
                AlwaysOnPill(state: controller.state, level: controller.level)
            }
            .buttonStyle(AlwaysOnPillButtonStyle())
            .pointerCursor()
            .help(helpText)

            if showsNotice, let notice = controller.notice {
                Text(notice)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
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
