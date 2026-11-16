import Combine
import CoreGraphics
import SwiftUI

// A deterministic camera substitute; these tests never request camera permission.
@MainActor final class CameraTrackingCapture: ObservableObject {
    @Published private(set) var sample = CameraTrackingSample.empty
    @Published private(set) var state = CameraTrackingState.idle
    func start() { state = .running }
    func stop() { sample = .empty; state = .idle }
    func feed(_ value: CameraTrackingSample) { sample = value }
}
struct CameraInputSetupView: View {
    var model: CameraInputController
    var body: some View { EmptyView() }
}
