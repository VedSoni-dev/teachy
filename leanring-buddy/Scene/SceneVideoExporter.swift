//
//  SceneVideoExporter.swift
//  leanring-buddy / Scene
//
//  Saves a drawing as an MP4. Nothing is captured from the screen: the saved log
//  is played into an off-screen scene and every frame is drawn in-process
//  (SceneKit's own renderer for the 3D model, SwiftUI's ImageRenderer for cards,
//  controls and on-screen marks), then written with AVAssetWriter. Time comes
//  from the frame number, not the wall clock, so the same log always gives the
//  same video.
//
//  The narration is included when the host handed its audio to the session
//  (`SceneSession.appendNarrationAudio`); otherwise the video is silent.
//

import AppKit
import AVFoundation
import SwiftUI

struct SceneVideoOptions {
    /// Pixels. 1080p by default.
    var size = CGSize(width: 1920, height: 1080)
    var framesPerSecond = 30
    /// Seconds the finished drawing is held (and keeps moving) after the last line appears.
    var tail = 3.0
    /// Longer scenes are cut here.
    var maximumDuration = 180.0
    var backdrop = NSColor(srgbRed: 0.957, green: 0.949, blue: 0.925, alpha: 1)
    /// How long to wait for a card's photo before drawing the frame without it.
    var photoWait = 4.0
}

enum SceneExportError: LocalizedError {
    case emptyScene
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .emptyScene: return "There is nothing in this drawing to save."
        case .cannotWrite(let reason): return "The video could not be saved: \(reason)"
        }
    }
}

@MainActor
enum SceneVideoExporter {

    // MARK: Export

    /// Writes `log` to `url` as H.264 MP4. `progress` goes from 0 to 1.
    static func export(log: SceneReplayLog, narration: SceneNarrationAudio = SceneNarrationAudio(), to url: URL,
                       options: SceneVideoOptions = SceneVideoOptions(), photoFetcher: ((String) async -> ScenePhoto?)? = nil,
                       progress: ((Double) -> Void)? = nil) async throws {
        guard !log.isEmpty else { throw SceneExportError.emptyScene }
        let width = Int(options.size.width.rounded()) / 2 * 2, height = Int(options.size.height.rounded()) / 2 * 2
        guard width >= 64, height >= 64 else { throw SceneExportError.cannotWrite("the picture size is too small") }
        let fps = max(options.framesPerSecond, 1)
        let duration = min(max(log.duration, narration.duration) + options.tail, options.maximumDuration)
        let frameCount = max(Int((duration * Double(fps)).rounded(.up)), 1)

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw SceneExportError.cannotWrite(error.localizedDescription) }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(width * height * 3, 1_000_000)],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(video) else { throw SceneExportError.cannotWrite("this Mac can't encode the video") }
        writer.add(video)

        var audio: AVAssetWriterInput?
        let track = narration.mixed()
        if !track.isEmpty, narration.sampleRate > 0 {
            let supported: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: supported.contains(narration.sampleRate) ? narration.sampleRate : 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }

        guard writer.startWriting() else { throw SceneExportError.cannotWrite(writer.error?.localizedDescription ?? "the file could not be opened") }
        writer.startSession(atSourceTime: .zero)

        let session = SceneSession()
        session.photoFetcher = photoFetcher
        session.beginHeadless(log: log, size: CGSize(width: width, height: height))
        var composer = Composer(options: options, width: width, height: height)
        defer { session.clear() }
        // The writer interleaves the two tracks: if the picture runs far ahead of the sound it
        // stops accepting frames. So the voice is fed a little ahead of the picture, all the way through.
        var feeder = audio.map { AudioFeeder(track: track, sampleRate: narration.sampleRate, limit: Double(frameCount) / Double(fps), input: $0) }

        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let time = Double(frame) / Double(fps)
            session.advance(to: time)
            await waitForPhotos(in: session, limit: options.photoWait)
            feeder?.feed(upTo: time + 1)
            var waited = 0.0
            while !video.isReadyForMoreMediaData {
                if writer.status != .writing { throw SceneExportError.cannotWrite(writer.error?.localizedDescription ?? "the encoder stopped") }
                feeder?.feed(upTo: time + 1)
                try await Task.sleep(nanoseconds: 4_000_000)
                waited += 0.004
                if waited > 20 { throw SceneExportError.cannotWrite("the encoder stopped taking frames") }
            }
            guard let pool = adaptor.pixelBufferPool else { throw SceneExportError.cannotWrite("no frame buffers") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw SceneExportError.cannotWrite("no frame buffer") }
            composer.draw(session: session, into: buffer)
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) {
                throw SceneExportError.cannotWrite(writer.error?.localizedDescription ?? "a frame was refused")
            }
            if frame % 6 == 0 {
                progress?(Double(frame) / Double(frameCount))
                await Task.yield()
            }
        }
        video.markAsFinished()

        if audio != nil {
            var waited = 0.0
            while let pending = feeder, !pending.isDone, writer.status == .writing, waited < 20 {
                feeder?.feed(upTo: .greatestFiniteMagnitude)
                if feeder?.isDone == false {
                    try await Task.sleep(nanoseconds: 4_000_000)
                    waited += 0.004
                }
            }
            feeder?.finish()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw SceneExportError.cannotWrite(writer.error?.localizedDescription ?? "the file could not be finished") }
        progress?(1)
    }

    /// The finished drawing as one picture (for a thumbnail), without showing anything on screen.
    static func poster(log: SceneReplayLog, size: CGSize = CGSize(width: 640, height: 360), photoFetcher: ((String) async -> ScenePhoto?)? = nil) async -> NSImage? {
        guard !log.isEmpty else { return nil }
        let session = SceneSession()
        session.photoFetcher = photoFetcher
        session.beginHeadless(log: log, size: size)
        defer { session.clear() }
        // Step through so motion and physics have somewhere to be, then hold a moment.
        let end = log.duration + 1.2
        var time = 0.0
        while time < end {
            session.advance(to: time)
            time += 0.1
        }
        session.advance(to: end)
        await waitForPhotos(in: session, limit: 2)
        var options = SceneVideoOptions()
        options.size = size
        var composer = Composer(options: options, width: Int(size.width), height: Int(size.height))
        return composer.image(session: session)
    }

    /// One frame of a scene that is already on screen or headless, drawn at `size`.
    static func picture(of session: SceneSession, size: CGSize) -> NSImage? {
        var options = SceneVideoOptions()
        options.size = size
        var composer = Composer(options: options, width: Int(size.width), height: Int(size.height))
        return composer.image(session: session)
    }

    private static func waitForPhotos(in session: SceneSession, limit: Double) async {
        guard session.cards.contains(where: { $0.model.pendingPhotos > 0 }) else { return }
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline, session.cards.contains(where: { $0.model.pendingPhotos > 0 }) {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: Frames

    /// Lays the surfaces of a scene out on one picture: the 3D model on the left (or across
    /// the whole frame when there are no cards), cards down the right, on-screen marks over everything.
    struct Composer {
        let options: SceneVideoOptions
        let width: Int
        let height: Int
        private var cardImages: [ObjectIdentifier: (revision: Int, image: CGImage)] = [:]

        init(options: SceneVideoOptions, width: Int, height: Int) {
            self.options = options
            self.width = width
            self.height = height
        }

        @MainActor
        mutating func image(session: SceneSession) -> NSImage? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            draw(session: session, in: context)
            guard let cgImage = context.makeImage() else { return nil }
            return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
        }

        @MainActor
        mutating func draw(session: SceneSession, into buffer: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            draw(session: session, in: context)
        }

        /// `context` has its origin at the bottom left, like every CGContext.
        @MainActor
        mutating func draw(session: SceneSession, in context: CGContext) {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(options.backdrop.cgColor)
            context.fill(frame)
            let margin = CGFloat(height) * 0.035
            let hasModel = session.modelWindow != nil
            let cards = session.cards

            // Cards: a column on the right beside a model, or centred side by side on their own.
            var cardPictures: [CGImage] = []
            for card in cards {
                let key = ObjectIdentifier(card)
                if let cached = cardImages[key], cached.revision == card.model.revision {
                    cardPictures.append(cached.image)
                } else if let picture = card.snapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    cardImages[key] = (card.model.revision, picture)
                    cardPictures.append(picture)
                }
            }
            var modelArea = frame.insetBy(dx: margin, dy: margin)
            if !cardPictures.isEmpty {
                let column = hasModel ? CGFloat(width) * 0.34 : CGFloat(width) - margin * 2
                let area = CGRect(x: CGFloat(width) - margin - column, y: margin, width: column, height: CGFloat(height) - margin * 2)
                if hasModel { modelArea.size.width = area.minX - margin * 2 }
                drawCards(cardPictures, in: area, sideBySide: !hasModel, context: context)
            }

            if let window = session.modelWindow, let picture = window.snapshot(backdrop: .clear)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let scale = min(modelArea.width / CGFloat(picture.width), modelArea.height / CGFloat(picture.height))
                let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                context.interpolationQuality = .high
                context.draw(picture, in: CGRect(x: modelArea.midX - size.width / 2, y: modelArea.midY - size.height / 2, width: size.width, height: size.height))
            }

            if !session.overlayModel.isEmpty {
                // Marks are sized in points; draw them as on a display two thirds the frame's size.
                let scale: CGFloat = max(CGFloat(width) / 1280, 0.5)
                let view = SceneOverlayView(model: session.overlayModel, frozenAt: session.overlayModel.clock())
                    .frame(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
                let renderer = ImageRenderer(content: view)
                renderer.scale = scale
                renderer.isOpaque = false
                if let picture = renderer.cgImage { context.draw(picture, in: frame) }
            }
        }

        private func drawCards(_ pictures: [CGImage], in area: CGRect, sideBySide: Bool, context: CGContext) {
            let gap = area.height * 0.03
            context.interpolationQuality = .high
            if sideBySide {
                let total = pictures.map { CGFloat($0.width) }.reduce(0, +)
                let tallest = pictures.map { CGFloat($0.height) }.max() ?? 1
                // Never blow a card up past its natural size on screen.
                let scale = min((area.width - gap * CGFloat(pictures.count - 1)) / total, area.height / tallest, CGFloat(height) / 900)
                let used = total * scale + gap * CGFloat(pictures.count - 1)
                var x = area.midX - used / 2
                for picture in pictures {
                    let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                    drawCard(picture, in: CGRect(x: x, y: area.maxY - size.height - max((area.height - tallest * scale) / 2, 0), width: size.width, height: size.height), context: context)
                    x += size.width + gap
                }
            } else {
                let total = pictures.map { CGFloat($0.height) }.reduce(0, +)
                let widest = pictures.map { CGFloat($0.width) }.max() ?? 1
                let scale = min(area.width / widest, (area.height - gap * CGFloat(pictures.count - 1)) / total)
                var top = area.maxY - max((area.height - total * scale - gap * CGFloat(pictures.count - 1)) / 2, 0)
                for picture in pictures {
                    let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                    drawCard(picture, in: CGRect(x: area.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), context: context)
                    top -= size.height + gap
                }
            }
        }

        private func drawCard(_ picture: CGImage, in rect: CGRect, context: CGContext) {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.008), blur: rect.height * 0.03, color: CGColor(gray: 0, alpha: 0.22))
            context.draw(picture, in: rect)
            context.restoreGState()
        }
    }

    // MARK: Audio

    /// Hands the voice track to the writer half a second at a time, as far as asked and as far as the writer will take.
    struct AudioFeeder {
        let track: [Int16]
        let sampleRate: Double
        let input: AVAssetWriterInput
        private let total: Int
        private var offset = 0
        private var description: CMAudioFormatDescription?

        init(track: [Int16], sampleRate: Double, limit: Double, input: AVAssetWriterInput) {
            self.track = track
            self.sampleRate = sampleRate
            self.input = input
            total = min(track.count, Int(limit * sampleRate))
            var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                     mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &description)
        }

        var isDone: Bool { offset >= total || description == nil }
        private var closed = false

        /// Tells the writer no more sound is coming. Without this it holds video frames back,
        /// waiting to interleave them with audio that will never arrive (the voice ends before the picture does).
        private mutating func closeIfDone() {
            guard isDone, !closed else { return }
            closed = true
            input.markAsFinished()
        }

        mutating func finish() {
            offset = total
            closeIfDone()
        }

        mutating func feed(upTo time: Double) {
            defer { closeIfDone() }
            guard let description else { return }
            let wanted = time >= Double(total) / sampleRate ? total : min(total, Int(time * sampleRate))
            let chunk = max(Int(sampleRate / 2), 1)
            while offset < wanted, input.isReadyForMoreMediaData {
                let count = min(chunk, total - offset)
                let byteCount = count * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
                guard let block else { offset = total; return }
                let start = offset
                track.withUnsafeBufferPointer { samples in
                    _ = CMBlockBufferReplaceDataBytes(with: samples.baseAddress! + start, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
                }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
                                                                     sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
                                                                     packetDescriptions: nil, sampleBufferOut: &sample)
                guard let sample, input.append(sample) else { offset = total; return }
                offset += count
            }
        }
    }
}
