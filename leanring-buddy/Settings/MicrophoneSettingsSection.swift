//
//  MicrophoneSettingsSection.swift
//  leanring-buddy
//
//  Home tab row: which microphone Teachy hears, a picker to change it, and a live
//  level meter so people can see it is picking them up. It follows devices as they
//  are plugged in and removed (`MicrophoneDeviceWatcher`), names the microphone that
//  is really live after a failover, and warns when that one is a Bluetooth mic.
//

import SwiftUI

struct MicrophoneSettingsSection: View {
    @StateObject private var meter = MicrophoneLevelMeter()
    @ObservedObject private var watcher = MicrophoneDeviceWatcher.shared
    @State private var devices: [MicrophoneDevice] = []
    @State private var selectedUID: String? = MicrophoneCenter.selectedUID
    @State private var activeName: String = MicrophoneCenter.activeDevice()?.name ?? "No microphone"
    @State private var systemDefaultName: String = MicrophoneCenter.systemDefaultInput()?.name ?? "none"
    @State private var isTesting = false
    private let startsExpanded: Bool

    /// The sign in front of a notice about the live microphone.
    private let noticeIcon = "exclamationmark.triangle.fill"

    init(startsExpanded: Bool = false) {
        self.startsExpanded = startsExpanded
    }

    var body: some View {
        SettingsDisclosureCard(
            icon: "mic.fill",
            title: "Microphone",
            summary: activeName,
            startsExpanded: startsExpanded
        ) {
            Text("Teachy only listens while you hold a talk or dictation key, or while always-on mode is on. This is the microphone it uses.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                microphoneRow(
                    title: "Follow the Mac's input",
                    detail: "Currently \(systemDefaultName)",
                    isSelected: selectedUID == nil
                ) { choose(nil) }

                ForEach(devices) { device in
                    microphoneRow(
                        title: device.name,
                        detail: nil,
                        isSelected: selectedUID == device.uid
                    ) { choose(device.uid) }
                }
            }

            if MicrophoneCenter.isSelectedDeviceMissing {
                MicrophoneNotice(icon: noticeIcon, text: "Your chosen microphone isn't connected, so Teachy is using \(activeName).")
            } else if let failover = watcher.liveOverride {
                MicrophoneNotice(icon: noticeIcon, text: "That microphone isn't working, so Teachy is listening with \(failover.name).")
            }

            if watcher.live?.isBluetooth == true {
                MicrophoneNotice(icon: noticeIcon, text: MicrophoneCenter.bluetoothWarning)
            }

            HStack(spacing: 12) {
                Button(isTesting ? "Stop test" : "Test microphone") {
                    if isTesting { stopTest() } else { startTest() }
                }
                .teachyButton(.secondary, size: .compact)

                if isTesting {
                    MicrophoneLevelBar(level: meter.level)
                        .frame(height: 4)
                }
            }

            if isTesting {
                if let meterProblem = meter.problem {
                    Text(meterProblem)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.warningText)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Say something.")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Hearing \(meter.listeningToName ?? activeName). Nothing is recorded or sent during this test.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onDisappear { stopTest() }
        // A device was plugged in, removed, or the Mac's input changed.
        .onReceive(NotificationCenter.default.publisher(for: MicrophoneDeviceWatcher.didChangeNotification)) { _ in
            refresh()
            if isTesting { meter.start() }
        }
    }

    /// One microphone to choose: its name, and a fact about it at the far end.
    /// `.teachyOption` marks the chosen one.
    private func microphoneRow(title: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .teachyOption(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func refresh() {
        devices = MicrophoneCenter.inputDevices()
        selectedUID = MicrophoneCenter.selectedUID
        activeName = (watcher.liveOverride ?? MicrophoneCenter.activeDevice())?.name ?? "No microphone"
        systemDefaultName = MicrophoneCenter.systemDefaultInput()?.name ?? "none"
    }

    private func choose(_ uid: String?) {
        MicrophoneCenter.selectedUID = uid
        watcher.refresh()
        refresh()
        if isTesting { meter.start() }
    }

    private func startTest() {
        refresh()
        isTesting = true
        meter.start()
    }

    private func stopTest() {
        isTesting = false
        meter.stop()
    }
}

/// An orange sign and a line of text, for things worth knowing about the live microphone.
struct MicrophoneNotice: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(DS.Fonts.sans(10.5, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin horizontal level meter. The microphone is open, so it is drawn in the
/// tint; it turns orange when the input is loud.
private struct MicrophoneLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.fillSecondary)
                Capsule()
                    .fill(level > 0.85 ? DS.Colors.warning : DS.Colors.pointer)
                    .frame(width: max(4, geometry.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}
