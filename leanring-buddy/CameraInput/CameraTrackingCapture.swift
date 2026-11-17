import AVFoundation
import Combine
import CoreImage
import QuartzCore
import Vision

/// An explicitly started, local-only camera session. Nothing is recorded or uploaded.
@MainActor
final class CameraTrackingCapture: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var sample: CameraTrackingSample = .empty
    @Published private(set) var state: CameraTrackingState = .idle
    @Published private(set) var cameraName = ""

    private var generation = 0
    private var worker: CameraTrackingWorker?

    func start() {
        guard worker == nil, state != .requestingPermission, state != .starting else { return }
        generation += 1
        let requestedGeneration = generation
        frame = nil
        sample = .empty
        cameraName = ""
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginCapture(generation: requestedGeneration)
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.generation == requestedGeneration else { return }
                    if allowed { self.beginCapture(generation: requestedGeneration) }
                    else { self.state = .unavailable("Camera access is off. Allow Teachy in System Settings → Privacy & Security → Camera, then try again.") }
                }
            }
        case .denied, .restricted:
            state = .unavailable("Camera access is off. Allow Teachy in System Settings → Privacy & Security → Camera, then try again.")
        @unknown default:
            state = .unavailable("This Mac could not determine camera permission. Try again in System Settings.")
        }
    }

    func stop() {
        generation += 1
        worker?.stop()
        worker = nil
        frame = nil
        sample = .empty
        state = .idle
        cameraName = ""
    }

    private func beginCapture(generation requestedGeneration: Int) {
        guard generation == requestedGeneration else { return }
        state = .starting
        let worker = CameraTrackingWorker { [weak self] event in
            // Worker deliveries are coalesced and always arrive on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.generation == requestedGeneration else { return }
                switch event {
                case .started(let name):
                    self.cameraName = name
                    self.state = .running
                case .frame(let image, let sample):
                    self.frame = image
                    self.sample = sample
                case .failed(let message):
                    self.generation += 1
                    self.worker = nil
                    self.frame = nil
                    self.sample = .empty
                    self.state = .unavailable(message)
                }
            }
        }
        self.worker = worker
        worker.start()
    }

    deinit { worker?.stop() }
}

private enum CameraTrackingEvent {
    case started(String)
    case frame(CGImage, CameraTrackingSample)
    case failed(String)
}

/// Session lifecycle and Vision processing share one serial queue. Only the newest
/// processed frame waits for UI delivery, so a busy main thread cannot build a backlog.
nonisolated private final class CameraTrackingWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "teachy.camera-input.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let onEvent: (CameraTrackingEvent) -> Void
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var lastFrameTime: TimeInterval = -.infinity
    private var visionFailures = 0
    private var isStopped = false

    private let deliveryLock = NSLock()
    private var latestFrame: CameraTrackingEvent?
    private var deliveryPending = false

    init(onEvent: @escaping (CameraTrackingEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
        handRequest.maximumHandCount = 1
    }

    func start() {
        queue.async { [self] in configureAndStart() }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            tearDown()
        }
    }

    private func configureAndStart() {
        guard !isStopped else { return }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            fail("No camera was found. Connect a camera and try again.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            self.session = session
            session.beginConfiguration()
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                fail("This camera cannot be opened. Close another camera app and try again.")
                return
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                fail("This camera does not provide a compatible video feed.")
                return
            }
            session.addOutput(output)
            self.output = output
            // Mirroring happens once in our image conversion, with the same transform
            // applied to landmark coordinates; never inherit automatic camera mirroring.
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            observeSession(session, device: device)
            session.startRunning()
            guard session.isRunning else {
                fail("The camera did not start. Close another camera app and try again.")
                return
            }
            publish(.started(device.localizedName))
        } catch {
            fail("Could not open the camera: \(error.localizedDescription)")
        }
    }

    private func observeSession(_ session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The camera stopped unexpectedly."
            self?.queue.async { [weak self] in self?.fail("\(detail) Stop and restart the camera to try again.") }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.fail("The camera was interrupted. Close other camera apps, then start it again.") }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.fail("The camera was disconnected. Reconnect it and try again.") }
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isStopped, session?.isRunning == true else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 0.1, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now
        autoreleasepool {
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                try handler.perform([handRequest, faceRequest])
                visionFailures = 0
                var sample = CameraTrackingSample(timestamp: now)
                if let hand = handRequest.results?.first {
                    let joints = try hand.recognizedPoints(.all)
                    if let index = joints[.indexTip], index.confidence >= 0.5 {
                        sample.handPoint = mirroredPoint(index.location)
                    }
                    if let thumb = joints[.thumbTip], thumb.confidence >= 0.5 {
                        sample.thumbPoint = mirroredPoint(thumb.location)
                    }
                    if let index = joints[.indexTip], let thumb = joints[.thumbTip],
                       let wrist = joints[.wrist], let middle = joints[.middleMCP],
                       [index, thumb, wrist, middle].allSatisfy({ $0.confidence >= 0.5 }) {
                        let aspect = CGFloat(CVPixelBufferGetWidth(buffer)) / CGFloat(CVPixelBufferGetHeight(buffer))
                        let palm = hypot((wrist.location.x - middle.location.x) * aspect, wrist.location.y - middle.location.y)
                        if palm > 0.025 {
                            sample.pinchRatio = Double(hypot((index.location.x - thumb.location.x) * aspect, index.location.y - thumb.location.y) / palm)
                        }
                    }
                }
                if let face = faceRequest.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }), face.confidence >= 0.65 {
                    let bounds = face.boundingBox
                    sample.faceBounds = CGRect(x: 1 - bounds.maxX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height)
                    sample.eyeFeature = eyeFeature(face)
                }
                let image = CIImage(cvPixelBuffer: buffer).oriented(.upMirrored)
                guard let preview = context.createCGImage(image, from: image.extent) else { return }
                publishFrame(.frame(preview, sample))
            } catch {
                visionFailures += 1
                if visionFailures >= 5 { fail("Camera tracking could not process the video. Stop and restart the camera to try again.") }
            }
        }
    }

    private func eyeFeature(_ face: VNFaceObservation) -> CGPoint? {
        guard abs(face.yaw?.doubleValue ?? 0) < 0.6,
              abs(face.roll?.doubleValue ?? 0) < 0.45,
              let landmarks = face.landmarks, landmarks.confidence >= 0.5,
              let left = pupilOffset(eye: landmarks.leftEye, pupil: landmarks.leftPupil),
              let right = pupilOffset(eye: landmarks.rightEye, pupil: landmarks.rightPupil) else { return nil }
        return CGPoint(x: -(left.x + right.x) / 2, y: -(left.y + right.y) / 2)
    }

    private func pupilOffset(eye: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let eye, eye.pointCount >= 4, let pupil, pupil.pointCount > 0 else { return nil }
        let points = eye.normalizedPoints
        let left = points.map(\.x).min() ?? 0
        let right = points.map(\.x).max() ?? 0
        let bottom = points.map(\.y).min() ?? 0
        let top = points.map(\.y).max() ?? 0
        let width = right - left
        // Very narrow eye openings are usually blinks; discard instead of letting
        // the estimated pupil jump and contaminate calibration.
        guard width > 0.01, (top - bottom) / width > 0.12 else { return nil }
        let position = pupil.normalizedPoints[0]
        let offset = CGPoint(x: (position.x - (left + right) / 2) / width,
                             y: (position.y - (bottom + top) / 2) / width)
        guard offset.x.isFinite, offset.y.isFinite, abs(offset.x) < 0.8, abs(offset.y) < 0.5 else { return nil }
        return offset
    }

    private func mirroredPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.x, y: 1 - point.y)
    }

    private func publish(_ event: CameraTrackingEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent(event) }
    }

    private func publishFrame(_ event: CameraTrackingEvent) {
        deliveryLock.lock()
        latestFrame = event
        let shouldSchedule = !deliveryPending
        deliveryPending = true
        deliveryLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock()
            let latest = self.latestFrame
            self.latestFrame = nil
            self.deliveryPending = false
            self.deliveryLock.unlock()
            if let latest { self.onEvent(latest) }
        }
    }

    private func fail(_ message: String) {
        guard !isStopped else { return }
        isStopped = true
        tearDown()
        publish(.failed(message))
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        if let session {
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
        output = nil
        session = nil
        deliveryLock.lock()
        latestFrame = nil
        deliveryLock.unlock()
    }
}
