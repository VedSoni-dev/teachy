import Foundation
import CoreGraphics

enum CameraTrackingState: Equatable {
    case idle, requestingPermission, starting, running
    case unavailable(String)
}

/// Ephemeral landmarks in the mirrored preview's top-left coordinate system.
/// Camera frames and calibration are never written to disk or sent to a service.
struct CameraTrackingSample {
    var handPoint: CGPoint?
    var thumbPoint: CGPoint?
    var pinchRatio: Double?
    var eyeFeature: CGPoint?
    var faceBounds: CGRect?
    var timestamp: TimeInterval
    static let empty = CameraTrackingSample(timestamp: 0)
}
