import SwiftUI

/// Settings → Touch & Eyes: tap the screen to talk, and webcam eye tracking.
struct TeachyTouchAndGazeSettingsPage: View {
    @ObservedObject private var settings = TeachySettings.shared
    @ObservedObject private var screenTapController = ScreenTapController.shared
    @ObservedObject private var gazeTracker = GazeTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageGroup(title: "Tap the screen") {
                SettingsToggleRow(
                    title: "Tap beside the camera to talk",
                    caption: "Tap the screen once next to the camera to start talking, and again to send. Teachy feels the tap with your MacBook's light and motion sensors.",
                    // Reads off on a Mac without the sensors, whatever was saved.
                    isOn: Binding(
                        get: { settings.screenTapEnabled && screenTapController.isSupportedOnThisMac },
                        set: { settings.screenTapEnabled = $0 }
                    )
                )
                .disabled(!screenTapController.isSupportedOnThisMac)
                TeachyRule()
                HStack(spacing: 10) {
                    TeachyStatusMark(kind: screenTapStatusKind)
                    Text(screenTapController.statusDescription)
                        .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let lastTapDate = screenTapController.lastRecognizedTapDate {
                        Text("Last tap \(lastTapDate.formatted(date: .omitted, time: .standard))")
                            .font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
                    }
                }
                if settings.screenTapEnabled && screenTapController.isSupportedOnThisMac {
                    TeachyRule()
                    HStack(spacing: 12) {
                        SettingsPageLabel(title: "Sensitivity", caption: "Use Firm tap if Teachy starts listening when you didn't tap.")
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            ForEach(ScreenTapSensitivity.allCases) { sensitivity in
                                let isSelected = settings.screenTapSensitivity == sensitivity
                                Button {
                                    settings.screenTapSensitivity = sensitivity
                                } label: {
                                    Text(sensitivity.displayName)
                                        .font(DS.Fonts.controlCompact)
                                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                                        .padding(.horizontal, 10)
                                        .frame(height: 26)
                                        .teachyOption(isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                            }
                        }
                    }
                }
            }

            SettingsPageGroup(title: "Eye tracking") {
                SettingsToggleRow(
                    title: "Use where I'm looking",
                    caption: "While you ask, Teachy notes roughly where on the screen you're looking, so \"what's this?\" means what you're looking at. The camera stays on while this is on; video never leaves your Mac.",
                    isOn: $settings.eyeTrackingEnabled
                )
                TeachyRule()
                HStack(spacing: 10) {
                    TeachyStatusMark(kind: gazeStatusKind)
                    Text(gazeTracker.stateDescription)
                        .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                TeachyRule()
                HStack(spacing: 12) {
                    SettingsPageLabel(title: "Calibration", caption: calibrationCaption)
                    Spacer(minLength: 8)
                    if gazeTracker.isCalibrated {
                        Button("Forget") { gazeTracker.forgetCalibration() }
                            .teachyLinkButton(color: DS.Colors.textSecondary)
                            .pointerCursor()
                    }
                    Button(gazeTracker.isCalibrated ? "Recalibrate" : "Calibrate") {
                        GazeCalibrationWindowController.shared.start()
                    }
                    .teachyButton(gazeTracker.isCalibrated ? .secondary : .primary, size: .compact)
                }
            }
        }
    }

    private var calibrationCaption: String {
        guard let calibration = gazeTracker.calibration else {
            return "Follow a dot around the screen for about 20 seconds."
        }
        let accuracy = Int(calibration.averageErrorInPoints.rounded())
        return "Calibrated \(calibration.calibratedAt.formatted(date: .abbreviated, time: .omitted)), accurate to about \(accuracy) points."
    }

    private var screenTapStatusKind: TeachyStatusKind {
        guard screenTapController.isSupportedOnThisMac else { return .stopped }
        switch screenTapController.status {
        case .ready: return .live
        case .starting, .settling: return .waiting
        case .unavailable: return .failed
        case .stopped: return .stopped
        }
    }

    private var gazeStatusKind: TeachyStatusKind {
        switch gazeTracker.state {
        case .tracking: return .live
        case .starting, .calibrating, .lookingForFace: return .waiting
        case .needsCalibration, .needsCameraPermission: return .needsYou
        case .noCamera: return .failed
        case .off: return .stopped
        }
    }
}
