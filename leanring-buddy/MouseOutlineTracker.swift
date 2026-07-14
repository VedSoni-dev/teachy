//
//  MouseOutlineTracker.swift
//  leanring-buddy
//
//  Records the user's mouse path while push-to-talk is held so we can
//  chalk-outline what they circled on the screenshot sent to the model.
//

import AppKit
import Combine
import Foundation

@MainActor
final class MouseOutlineTracker: ObservableObject {
    /// Live trail shown on the overlay while the user holds push-to-talk.
    @Published private(set) var liveOutlinePointsInGlobalCoordinates: [CGPoint] = []

    private var finalizedOutlinePointsInGlobalCoordinates: [CGPoint] = []
    private var trackingTimer: Timer?

    private let minimumSampleDistanceInPoints: CGFloat = 6
    private let minimumMeaningfulOutlineLengthInPoints: CGFloat = 40

    func startTracking() {
        stopTrackingTimerOnly()
        liveOutlinePointsInGlobalCoordinates = []
        finalizedOutlinePointsInGlobalCoordinates = []

        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordCurrentMouseLocation()
            }
        }
        recordCurrentMouseLocation()
    }

    func stopTracking() {
        stopTrackingTimerOnly()
        finalizedOutlinePointsInGlobalCoordinates = liveOutlinePointsInGlobalCoordinates
        liveOutlinePointsInGlobalCoordinates = []
    }

    /// Returns the completed outline once, then clears it.
    func consumeFinalizedOutlinePoints() -> [CGPoint] {
        let outlinePoints = finalizedOutlinePointsInGlobalCoordinates
        finalizedOutlinePointsInGlobalCoordinates = []
        return outlinePoints
    }

    func hasMeaningfulOutline() -> Bool {
        outlinePathLength(for: finalizedOutlinePointsInGlobalCoordinates) >= minimumMeaningfulOutlineLengthInPoints
    }

    private func stopTrackingTimerOnly() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func recordCurrentMouseLocation() {
        let mouseLocation = NSEvent.mouseLocation

        guard let lastPoint = liveOutlinePointsInGlobalCoordinates.last else {
            liveOutlinePointsInGlobalCoordinates.append(mouseLocation)
            return
        }

        let distanceFromLastPoint = hypot(mouseLocation.x - lastPoint.x, mouseLocation.y - lastPoint.y)
        guard distanceFromLastPoint >= minimumSampleDistanceInPoints else { return }

        liveOutlinePointsInGlobalCoordinates.append(mouseLocation)
    }

    private func outlinePathLength(for points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }

        var totalLength: CGFloat = 0
        for pointIndex in 1..<points.count {
            let previousPoint = points[pointIndex - 1]
            let currentPoint = points[pointIndex]
            totalLength += hypot(currentPoint.x - previousPoint.x, currentPoint.y - previousPoint.y)
        }
        return totalLength
    }
}
