//
//  MicrophoneSettingsSection.swift
//  leanring-buddy
//
//  Home tab card: which microphone Teachy hears, a picker to change it, and a live
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
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
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
                Text("Your chosen microphone isn't connected, so Teachy is using \(activeName).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failover = watcher.liveOverride {
                Text("That microphone isn't working, so Teachy is listening with \(failover.name).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if watcher.live?.isBluetooth == true {
                MicrophoneNotice(icon: "exclamationmark.triangle.fill", text: MicrophoneCenter.bluetoothWarning)
            }

            HStack(spacing: 10) {
                Button {
                    if isTesting { stopTest() } else { startTest() }
                } label: {
                    Text(isTesting ? "Stop test" : "Test microphone")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if isTesting {
                    MicrophoneLevelBar(level: meter.level)
                        .frame(height: 8)
                }
            }

            if isTesting {
                Text(meter.problem ?? "Say something. Hearing \(meter.listeningToName ?? activeName). Nothing is recorded or sent during this test.")
                    .font(.system(size: 11))
                    .foregroundColor(meter.problem == nil ? DS.Colors.textTertiary : DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func microphoneRow(title: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? DS.Colors.learnAccent : DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DS.Colors.learnAccent.opacity(0.14) : Color.white.opacity(0.04))
            )
            .contentShape(Rectangle())
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

/// An amber line with an icon, for things worth knowing about the live microphone.
struct MicrophoneNotice: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.warning.opacity(0.1)))
    }
}

/// A simple horizontal level meter: green, turning amber when loud.
private struct MicrophoneLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(level > 0.85 ? DS.Colors.warning : DS.Colors.learnAccent)
                    .frame(width: max(4, geometry.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}
