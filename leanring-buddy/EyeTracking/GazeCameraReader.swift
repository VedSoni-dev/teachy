//
//  GazeCameraReader.swift
//  leanring-buddy
//
//  Reads the camera and turns each frame into `GazeEyeFeatures` with Apple's
//  Vision face landmarks (pupils, eye outlines) and head pose. Frames are
//  processed on a private queue and dropped when processing falls behind;
//  nothing is stored or sent anywhere. Only the numbers leave this file.
//

import AVFoundation
import CoreGraphics
import Foundation
import Vision

nonisolated final class GazeCameraReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum StartFailure: Error, Equatable {
        case cameraPermissionDenied
        case noCamera
        case cameraCouldNotOpen
    }

    /// Called on the camera queue for each processed frame. Nil features means no usable face in that frame.
    var onFrame: (@Sendable (_ features: GazeEyeFeatures?, _ timeInSeconds: Double) -> Void)?

    private let captureSession = AVCaptureSession()
    private let frameQueue = DispatchQueue(label: "teachy.gaze.camera", qos: .userInitiated)
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isConfigured = false

    /// Starts the camera, asking for permission the first time.
    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw StartFailure.cameraPermissionDenied }
        default:
            throw StartFailure.cameraPermissionDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            frameQueue.async { [self] in
                do {
                    if !isConfigured { try configureSession() }
                    if !captureSession.isRunning { captureSession.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        frameQueue.async { [self] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    /// Prefers the Mac's own camera (it sits right above the screen being looked at);
    /// falls back to any camera, such as Continuity Camera.
    private static func preferredCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        )
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? discovery.devices.first
            ?? AVCaptureDevice.default(for: .video)
    }

    private func configureSession() throws {
        guard let camera = Self.preferredCamera() else { throw StartFailure.noCamera }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        // Pupils are only a few pixels wide; 720p gives Vision enough to find them.
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        guard let cameraInput = try? AVCaptureDeviceInput(device: camera), captureSession.canAddInput(cameraInput) else {
            throw StartFailure.cameraCouldNotOpen
        }
        captureSession.addInput(cameraInput)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard captureSession.canAddOutput(videoOutput) else { throw StartFailure.cameraCouldNotOpen }
        captureSession.addOutput(videoOutput)
        isConfigured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(eyeFeatures(in: pixelBuffer), frameTime)
    }

    /// Face rectangles first (revision 3 adds head yaw and pitch), then landmarks
    /// for that face, which include the pupils.
    private func eyeFeatures(in pixelBuffer: CVPixelBuffer) -> GazeEyeFeatures? {
        let faceRectanglesRequest = VNDetectFaceRectanglesRequest()
        faceRectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3

        let detectedFace: VNFaceObservation
        do {
            try sequenceHandler.perform([faceRectanglesRequest], on: pixelBuffer, orientation: .up)
            // The largest face is the person at the keyboard.
            guard let face = faceRectanglesRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
            detectedFace = face
            landmarksRequest.inputFaceObservations = [face]
            try sequenceHandler.perform([landmarksRequest], on: pixelBuffer, orientation: .up)
        } catch {
            return nil
        }

        guard let landmarkedFace = landmarksRequest.results?.first,
              let landmarks = landmarkedFace.landmarks,
              let leftPupil = landmarks.leftPupil, let rightPupil = landmarks.rightPupil,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye else { return nil }

        // A 1×1 image size turns face-relative landmark points into 0…1 image coordinates.
        let normalizedImageSize = CGSize(width: 1, height: 1)
        guard let leftPupilPoint = leftPupil.pointsInImage(imageSize: normalizedImageSize).first,
              let rightPupilPoint = rightPupil.pointsInImage(imageSize: normalizedImageSize).first else { return nil }

        return GazeEyeFeatures.make(
            leftPupil: leftPupilPoint, leftEyeOutline: leftEye.pointsInImage(imageSize: normalizedImageSize),
            rightPupil: rightPupilPoint, rightEyeOutline: rightEye.pointsInImage(imageSize: normalizedImageSize),
            headYawInRadians: (landmarkedFace.yaw ?? detectedFace.yaw)?.doubleValue ?? 0,
            headPitchInRadians: (landmarkedFace.pitch ?? detectedFace.pitch)?.doubleValue ?? 0,
            faceBoundingBox: landmarkedFace.boundingBox
        )
    }
}
