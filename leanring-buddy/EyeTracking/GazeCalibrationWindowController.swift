//
//  GazeCalibrationWindowController.swift
//  leanring-buddy
//
//  Eye-tracking calibration. A full-screen window shows one dot at a time at
//  nine places; the person follows it with their eyes. For each dot the first
//  moment is skipped (the eyes are still travelling), then eye features are
//  collected. A `GazeRegressionModel` is fitted from features to dot positions
//  and saved through `GazeTracker`. Escape cancels and keeps the old calibration.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class GazeCalibrationWindowController {
    static let shared = GazeCalibrationWindowController()

    private var calibrationWindow: NSWindow?
    private var calibrationRun: GazeCalibrationRun?

    /// The screen with the menu bar: the one the built-in or main camera usually sits above.
    private var calibrationScreen: NSScreen? { NSScreen.screens.first }

    func start() {
        guard calibrationWindow == nil, let screen = calibrationScreen else { return }
        let run = GazeCalibrationRun(screenFrame: screen.frame) { [weak self] in self?.close() }
        calibrationRun = run

        let window = KeyableBorderlessWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: GazeCalibrationView(run: run))
        window.onEscape = { [weak run] in run?.cancel() }
        window.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        calibrationWindow = window
        run.begin()
    }

    private func close() {
        calibrationWindow?.orderOut(nil)
        calibrationWindow = nil
        calibrationRun = nil
    }

    /// Borderless windows refuse key status by default; this one needs it for Escape.
    private final class KeyableBorderlessWindow: NSWindow {
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
    }
}

/// Drives one calibration: dot timing, feature collection, fitting.
@MainActor
final class GazeCalibrationRun: ObservableObject {
    enum Phase: Equatable {
        case intro
        case followingDot(index: Int)
        case finished(averageErrorInPoints: Double)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .intro
    /// Where the current dot is, 0…1 across and down.
    @Published private(set) var dotPosition = CGPoint(x: 0.5, y: 0.5)
    /// True while samples are being recorded for the current dot (the dot shrinks).
    @Published private(set) var isRecordingCurrentDot = false

    private let screenFrame: CGRect
    private let onClose: () -> Void
    private var samples: [GazeRegressionModel.TrainingSample] = []
    private var runTask: Task<Void, Never>?

    /// The eyes need a moment to land on a new dot before samples mean anything.
    private static let settleTimeInSeconds = 0.9
    private static let recordTimeInSeconds = 1.3
    /// Too few usable frames per dot means the camera could not see the eyes.
    private static let minimumSamplesPerDot = 8

    init(screenFrame: CGRect, onClose: @escaping () -> Void) {
        self.screenFrame = screenFrame
        self.onClose = onClose
    }

    func begin() {
        runTask = Task { await runCalibration() }
    }

    func cancel() {
        runTask?.cancel()
        GazeTracker.shared.endCalibrationCapture(saving: nil)
        onClose()
    }

    func closeAfterResult() { onClose() }

    func retry() {
        samples.removeAll()
        phase = .intro
        begin()
    }

    private func runCalibration() async {
        let cameraStarted = await GazeTracker.shared.beginCalibrationCapture { [weak self] features in
            guard let self, self.isRecordingCurrentDot else { return }
            self.samples.append(.init(features: features.values, screenPosition: self.dotPosition))
        }
        guard cameraStarted else {
            phase = .failed(message: GazeTracker.shared.stateDescription)
            GazeTracker.shared.endCalibrationCapture(saving: nil)
            return
        }

        // Give the person a moment to read the instruction and the camera to adjust exposure.
        try? await Task.sleep(for: .seconds(2.2))
        for (dotIndex, targetPosition) in GazeCalibrationTargets.positions.enumerated() {
            guard !Task.isCancelled else { return }
            let samplesBeforeThisDot = samples.count
            withAnimation(DS.Motion.standard) {
                dotPosition = targetPosition
                phase = .followingDot(index: dotIndex)
            }
            try? await Task.sleep(for: .seconds(Self.settleTimeInSeconds))
            isRecordingCurrentDot = true
            try? await Task.sleep(for: .seconds(Self.recordTimeInSeconds))
            isRecordingCurrentDot = false
            if samples.count - samplesBeforeThisDot < Self.minimumSamplesPerDot {
                finishWithFailure("Teachy couldn't see your eyes clearly. Face the camera in good light and try again.")
                return
            }
        }
        guard !Task.isCancelled else { return }

        guard let model = GazeRegressionModel.fit(samples: samples) else {
            finishWithFailure("Calibration didn't fit. Try again and keep your head still while following the dot.")
            return
        }
        let averageErrorInPoints = Self.averageErrorInPoints(model: model, samples: samples, screenFrame: screenFrame)
        GazeTracker.shared.endCalibrationCapture(saving: .init(
            model: model, screenFrame: screenFrame, calibratedAt: Date(), averageErrorInPoints: averageErrorInPoints
        ))
        DS.Haptics.stateChanged()
        phase = .finished(averageErrorInPoints: averageErrorInPoints)
    }

    private func finishWithFailure(_ message: String) {
        GazeTracker.shared.endCalibrationCapture(saving: nil)
        phase = .failed(message: message)
    }

    /// Average distance between each dot and the model's prediction for the frames recorded at it.
    nonisolated static func averageErrorInPoints(model: GazeRegressionModel, samples: [GazeRegressionModel.TrainingSample], screenFrame: CGRect) -> Double {
        let distances = samples.compactMap { sample -> Double? in
            guard let predicted = model.predictScreenPosition(features: sample.features) else { return nil }
            return Double(hypot((predicted.x - sample.screenPosition.x) * screenFrame.width,
                                (predicted.y - sample.screenPosition.y) * screenFrame.height))
        }
        guard !distances.isEmpty else { return .infinity }
        return distances.reduce(0, +) / Double(distances.count)
    }
}

struct GazeCalibrationView: View {
    @ObservedObject var run: GazeCalibrationRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DS.Colors.workspaceBackground.ignoresSafeArea()
                switch run.phase {
                case .intro, .followingDot:
                    calibrationDot
                        .position(x: run.dotPosition.x * geometry.size.width, y: run.dotPosition.y * geometry.size.height)
                    if case .intro = run.phase { instruction }
                case .finished(let averageErrorInPoints):
                    resultCard(
                        title: "Eye tracking is calibrated",
                        detail: "Teachy can tell where you look to within about \(Int(averageErrorInPoints.rounded())) points. Recalibrate if you move the Mac or your seat.",
                        succeeded: true
                    )
                case .failed(let message):
                    resultCard(title: "Calibration didn't finish", detail: message, succeeded: false)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var calibrationDot: some View {
        ZStack {
            Circle().fill(DS.Colors.pointer.opacity(0.25))
                .frame(width: run.isRecordingCurrentDot ? 22 : 54, height: run.isRecordingCurrentDot ? 22 : 54)
            Circle().fill(DS.Colors.pointer).frame(width: 10, height: 10)
        }
        .animation(reduceMotion ? DS.Motion.reduced : DS.Motion.standard, value: run.isRecordingCurrentDot)
        .accessibilityHidden(true)
    }

    private var instruction: some View {
        VStack(spacing: 8) {
            Text("Follow the dot with your eyes").font(DS.Fonts.display).foregroundColor(DS.Colors.textPrimary)
            Text("Keep your head comfortable and still. Press Escape to stop.")
                .font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
        }
        .offset(y: 90)
    }

    private func resultCard(title: String, detail: String, succeeded: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: succeeded ? "eye" : "eye.slash")
                .font(DS.Fonts.sans(28, weight: .medium))
                .foregroundColor(succeeded ? DS.Colors.pointer : DS.Colors.warning)
            Text(title).font(DS.Fonts.display).foregroundColor(DS.Colors.textPrimary)
            Text(detail).font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(succeeded ? "Calibrate again" : "Try again") { run.retry() }
                    .teachyButton(.secondary)
                Button("Done") { run.closeAfterResult() }
                    .teachyButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .teachyTile()
    }
}
