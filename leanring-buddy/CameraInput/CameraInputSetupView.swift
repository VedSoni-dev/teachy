import AppKit
import SwiftUI

struct CameraInputSetupView: View {
    @ObservedObject var model: CameraInputController
    @ObservedObject private var capture: CameraTrackingCapture

    init(model: CameraInputController) {
        self.model = model
        self.capture = model.capture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hands & eyes").font(DS.Fonts.sans(26, weight: .semibold))
                    Text("Try camera input in a practice area.")
                        .font(DS.Fonts.body).foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
                Button(capture.state == .running ? "Stop camera" : "Start camera") {
                    if capture.state == .running { model.stop() } else { model.start() }
                }
                .teachyButton(.primary)
                .disabled(capture.state == .requestingPermission || capture.state == .starting)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                        .frame(width: 300, height: 225)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Label(statusText, systemImage: capture.state == .running ? "camera.fill" : "camera")
                        .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .unavailable = capture.state {
                        Button("Camera permissions…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                        }.teachyButton(.secondary, size: .compact)
                    }
                    instruction("hand.point.up.left", title: "Point with your index finger",
                                detail: "Move your hand in the camera view. The blue dot follows it in the practice area.")
                    instruction("hand.pinch", title: "Pinch to tap",
                                detail: "Bring your thumb and index finger together, then open them. Each pinch counts once.")
                    HStack {
                        Label("Practice taps", systemImage: "hand.tap")
                        Spacer()
                        Text("\(model.pinchCount)").monospacedDigit()
                    }.font(DS.Fonts.bodyEmphasized)
                        .padding(16).background(DS.Colors.workspaceCard, in: RoundedRectangle(cornerRadius: 14))
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(model.targetIndex == nil ? "Practice area" : "Eye calibration")
                            .font(DS.Fonts.bodyEmphasized)
                        Spacer()
                        Text(capture.state == .running ? (model.eyesVisible ? "Eyes detected" : "Eyes not detected") : "Camera off")
                            .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                    }
                    practiceArea.frame(height: 350)
                    Text(model.calibrationMessage)
                        .font(DS.Fonts.body).foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 52, alignment: .topLeading)
                    HStack {
                        if model.targetIndex != nil {
                            Button("Cancel calibration") { model.cancelCalibration() }
                                .teachyButton(.secondary)
                        } else {
                            Button(model.isCalibrated ? "Recalibrate eyes" : "Calibrate eyes") { model.calibrate() }
                                .teachyButton(.secondary)
                                .disabled(capture.state != .running || !model.eyesVisible)
                        }
                        Spacer()
                        Label("Experimental", systemImage: "sparkle")
                            .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Local processing · No camera recordings · Stops when you close this window")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Text("This setup only moves practice dots. It does not click other apps or turn your display into a touchscreen.")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textTertiary)
            }
        }
        .padding(28)
        .frame(width: 940, height: 700)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.workspaceBackground)
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        ZStack {
            DS.Colors.notchBlack
            if let frame = capture.frame {
                Image(decorative: frame, scale: 1).resizable().scaledToFit()
                GeometryReader { geometry in
                    if let point = capture.sample.handPoint {
                        Circle().fill(DS.Colors.pointer).frame(width: 12, height: 12)
                            .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                    }
                    if let point = capture.sample.thumbPoint {
                        Circle().stroke(DS.Colors.textPrimary, lineWidth: 2).frame(width: 10, height: 10)
                            .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                    }
                }.allowsHitTesting(false)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera").font(DS.Fonts.sans(28))
                    Text("Camera preview").font(DS.Fonts.body)
                }.foregroundStyle(DS.Colors.textTertiary)
            }
        }
        .accessibilityLabel("Mirrored camera preview")
    }

    private var practiceArea: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.workspaceCard)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(DS.Colors.workspaceBorder, lineWidth: 1)
                if let index = model.targetIndex {
                    let target = model.targets[index]
                    Circle().stroke(DS.Colors.pointer.opacity(0.3), lineWidth: 8)
                        .overlay(Circle().fill(DS.Colors.pointer).padding(6))
                        .frame(width: 28, height: 28)
                        .overlay(alignment: .bottom) {
                            Text(model.isSampling ? "Hold your gaze" : "Look here")
                                .font(DS.Fonts.caption).fixedSize().offset(y: 24)
                        }
                    .position(x: target.x * geometry.size.width, y: target.y * geometry.size.height)
                    .accessibilityLabel("Calibration target \(index + 1) of 9")
                } else {
                    if model.handPoint == nil && model.gazePoint == nil {
                        Text(capture.state == .running ? "Raise your hand into view" : "Start the camera to try it")
                            .font(DS.Fonts.body).foregroundStyle(DS.Colors.textTertiary)
                    }
                    if let point = model.handPoint {
                        marker(point, color: DS.Colors.pointer, label: "Hand", size: geometry.size)
                    }
                    if let point = model.gazePoint {
                        marker(point, color: DS.Colors.success, label: "Gaze", size: geometry.size)
                    }
                }
            }
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera input practice area")
    }

    private func marker(_ point: CGPoint, color: Color, label: String, size: CGSize) -> some View {
        Circle().fill(color).frame(width: 16, height: 16)
            .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 8))
            .position(x: min(max(point.x * size.width, 14), size.width - 14),
                      y: min(max(point.y * size.height, 14), size.height - 14))
            .accessibilityLabel("\(label) pointer")
    }
    private func instruction(_ icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(DS.Fonts.bodyEmphasized)
            Text(detail).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var statusText: String {
        switch capture.state {
        case .idle: return "Camera off"
        case .requestingPermission: return "Waiting for camera permission…"
        case .starting: return "Starting camera…"
        case .running: return capture.cameraName
        case .unavailable(let message): return message
        }
    }
}

struct CameraInputSettingsPage: View {
    var body: some View {
        SettingsPageGroup(title: "Camera input · Experimental") {
            SettingsPageLabel(title: "Use your Mac's camera", caption: "Try hand pointing, pinch gestures, and calibrated eye tracking. Processing stays on this Mac.")
            Button("Open camera setup") { CameraInputWindowController.shared.show() }
                .teachyButton(.primary)
            Text("Start with a practice area to check accuracy. Camera input is off until you start it, and stops when setup closes.")
                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
        }
    }
}
