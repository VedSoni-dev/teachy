//
//  ImageRedactionTool.swift
//  leanring-buddy
//
//  `redact_image`: blurs the private parts of a picture before it goes anywhere
//  ("blur the client's face and post this on LinkedIn"). It finds faces and text
//  on this Mac with Apple's Vision framework (nothing is uploaded to do it),
//  blurs, pixelates or blacks out what was asked, and saves a NEW file in
//  Teachy's own output folder. The original is never changed.
//
//  What to cover, any mix of:
//    - faces: true            every face Vision finds
//    - text_matching: [...]   lines of text that contain any of these words
//                             (names, emails, amounts, a company)
//    - all_text: true         every line of text
//    - regions: [[x, y, w, h]] boxes as fractions of the image (0…1, top-left origin),
//                             for things only the model can point at
//    - keep_largest_face: true leave the biggest face clear (the user's own, usually)
//
//  The result comes back with the finished image, so the agent can look at it
//  and redact again if something still shows.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// The pure rules: which boxes get covered, in image-fraction space with a top-left origin.
enum ImageRedactionRules {
    enum Style: String {
        case blur
        case pixelate
        case black
    }

    /// A box Vision found (or the model gave), with what it is.
    struct Region: Equatable {
        enum Kind: Equatable {
            case face
            case text(String)
            case given
        }

        var rectInImageFractions: CGRect
        var kind: Kind
    }

    struct Request: Equatable {
        var coverFaces = false
        var keepLargestFace = false
        var coverAllText = false
        var textMatches: [String] = []
        var givenRegions: [CGRect] = []
        var style: Style = .blur

        var asksForAnything: Bool {
            coverFaces || coverAllText || !textMatches.isEmpty || !givenRegions.isEmpty
        }
    }

    /// Reads the tool's JSON arguments. Boxes outside 0…1 are clamped; empty boxes are dropped.
    static func request(from arguments: [String: Any]) -> Request {
        var request = Request()
        request.coverFaces = (arguments["faces"] as? Bool) ?? false
        request.keepLargestFace = (arguments["keep_largest_face"] as? Bool) ?? false
        request.coverAllText = (arguments["all_text"] as? Bool) ?? false
        request.textMatches = ((arguments["text_matching"] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        request.givenRegions = ((arguments["regions"] as? [Any]) ?? []).compactMap { regionValue in
            guard let numbers = regionValue as? [Any], numbers.count == 4 else { return nil }
            let values = numbers.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard values.count == 4 else { return nil }
            let clamped = clampedToImage(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            return clamped.isEmpty ? nil : clamped
        }
        if let styleName = arguments["style"] as? String, let style = Style(rawValue: styleName.lowercased()) {
            request.style = style
        }
        return request
    }

    /// Picks the boxes to cover from everything that was found.
    static func regionsToCover(found: [Region], request: Request) -> [Region] {
        var chosen: [Region] = []

        let faces = found.filter { $0.kind == .face }
        if request.coverFaces {
            let largestFace = faces.max { area($0.rectInImageFractions) < area($1.rectInImageFractions) }
            for face in faces {
                if request.keepLargestFace, let largestFace, face == largestFace { continue }
                chosen.append(face)
            }
        }

        let lowercasedMatches = request.textMatches.map { $0.lowercased() }
        for region in found {
            guard case .text(let line) = region.kind else { continue }
            let lowercasedLine = line.lowercased()
            if request.coverAllText || lowercasedMatches.contains(where: { lowercasedLine.contains($0) }) {
                chosen.append(region)
            }
        }

        for givenRect in request.givenRegions {
            chosen.append(Region(rectInImageFractions: givenRect, kind: .given))
        }

        // A little margin, so the edges of a face or a word do not peek out.
        return chosen.map { region in
            var padded = region
            padded.rectInImageFractions = clampedToImage(region.rectInImageFractions.insetBy(
                dx: -region.rectInImageFractions.width * 0.12 - 0.004,
                dy: -region.rectInImageFractions.height * 0.18 - 0.004
            ))
            return padded
        }
    }

    /// Vision reports boxes with a bottom-left origin; everything here uses top-left.
    static func topLeftRect(fromVisionRect visionRect: CGRect) -> CGRect {
        CGRect(x: visionRect.minX, y: 1 - visionRect.maxY, width: visionRect.width, height: visionRect.height)
    }

    static func clampedToImage(_ rect: CGRect) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clamped = rect.standardized.intersection(unit)
        return clamped.isNull ? .zero : clamped
    }

    /// The output name: the original's name with "-redacted" and a counter if needed.
    static func outputFileName(forInputName inputName: String, existingNames: Set<String>) -> String {
        let base = (inputName as NSString).deletingPathExtension
        var candidate = "\(base)-redacted.png"
        var counter = 2
        while existingNames.contains(candidate) {
            candidate = "\(base)-redacted-\(counter).png"
            counter += 1
        }
        return candidate
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}

/// Finds faces and text with Vision, then covers the chosen boxes with Core Image.
enum ImageRedactor {
    struct Outcome {
        let outputURL: URL
        let coveredRegions: [ImageRedactionRules.Region]
        let foundFaceCount: Int
        let foundTextLineCount: Int
        /// "reading text" / "finding faces" when Vision could not run; regions still work.
        let detectionFailures: [String]
        let pngData: Data
    }

    enum RedactionError: LocalizedError {
        case unreadableImage(String)
        case nothingRequested
        case couldNotWrite(String)

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let path): return "Couldn't open \(path) as an image."
            case .nothingRequested: return "Say what to cover: faces, text_matching, all_text or regions."
            case .couldNotWrite(let path): return "Couldn't save the redacted image to \(path)."
            }
        }
    }

    /// Where finished images go: Teachy's own folder, never next to the user's original.
    static var outputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teachy/agents/output", isDirectory: true)
    }

    static func redact(imageAt inputURL: URL, request: ImageRedactionRules.Request) throws -> Outcome {
        guard request.asksForAnything else { throw RedactionError.nothingRequested }
        guard let sourceImage = NSImage(contentsOf: inputURL),
              let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw RedactionError.unreadableImage(inputURL.path) }

        let detection = findRegions(in: cgImage, needsFaces: request.coverFaces, needsText: request.coverAllText || !request.textMatches.isEmpty)
        let found = detection.regions
        let regionsToCover = ImageRedactionRules.regionsToCover(found: found, request: request)
        let pngData = try cover(regionsToCover, in: cgImage, style: request.style)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let existingNames = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])
        let outputName = ImageRedactionRules.outputFileName(forInputName: inputURL.lastPathComponent, existingNames: existingNames)
        let outputURL = outputDirectory.appendingPathComponent(outputName)
        do {
            try pngData.write(to: outputURL, options: .atomic)
        } catch {
            throw RedactionError.couldNotWrite(outputURL.path)
        }

        return Outcome(
            outputURL: outputURL,
            coveredRegions: regionsToCover,
            foundFaceCount: found.filter { $0.kind == .face }.count,
            foundTextLineCount: found.filter { if case .text = $0.kind { return true } else { return false } }.count,
            detectionFailures: detection.failures,
            pngData: pngData
        )
    }

    /// Each kind of detection runs on its own, so a failure in one (text recognition can fail
    /// on some Macs) still leaves the others. Text tries the accurate model, then the fast one.
    private static func findRegions(in cgImage: CGImage, needsFaces: Bool, needsText: Bool) -> (regions: [ImageRedactionRules.Region], failures: [String]) {
        var regions: [ImageRedactionRules.Region] = []
        var failures: [String] = []

        if needsFaces {
            let faceRequest = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest])
                for face in faceRequest.results ?? [] {
                    regions.append(.init(rectInImageFractions: ImageRedactionRules.topLeftRect(fromVisionRect: face.boundingBox), kind: .face))
                }
            } catch {
                failures.append("finding faces")
            }
        }

        if needsText {
            var textLines: [VNRecognizedTextObservation]?
            for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = level
                textRequest.usesLanguageCorrection = false
                if (try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest])) != nil {
                    textLines = textRequest.results ?? []
                    break
                }
            }
            if let textLines {
                for line in textLines {
                    guard let text = line.topCandidates(1).first?.string else { continue }
                    regions.append(.init(rectInImageFractions: ImageRedactionRules.topLeftRect(fromVisionRect: line.boundingBox), kind: .text(text)))
                }
            } else {
                failures.append("reading text")
            }
        }
        return (regions, failures)
    }

    private static func cover(_ regions: [ImageRedactionRules.Region], in cgImage: CGImage, style: ImageRedactionRules.Style) throws -> Data {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let source = CIImage(cgImage: cgImage)

        // One fully covered copy of the picture; each box is cut out of it and laid on top.
        let coveredCopy: CIImage
        switch style {
        case .blur:
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = source.clampedToExtent()
            blur.radius = Float(max(width, height) / 45)
            coveredCopy = (blur.outputImage ?? source).cropped(to: source.extent)
        case .pixelate:
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = source.clampedToExtent()
            pixellate.scale = Float(max(width, height) / 60)
            coveredCopy = (pixellate.outputImage ?? source).cropped(to: source.extent)
        case .black:
            coveredCopy = CIImage(color: CIColor.black).cropped(to: source.extent)
        }

        var result = source
        for region in regions {
            // Core Image's origin is bottom-left.
            let fraction = region.rectInImageFractions
            let pixelRect = CGRect(
                x: fraction.minX * width,
                y: (1 - fraction.maxY) * height,
                width: fraction.width * width,
                height: fraction.height * height
            ).integral
            guard pixelRect.width > 0, pixelRect.height > 0 else { continue }
            result = coveredCopy.cropped(to: pixelRect).composited(over: result)
        }

        let context = CIContext()
        guard let outputCGImage = context.createCGImage(result, from: source.extent),
              let pngData = NSBitmapImageRep(cgImage: outputCGImage).representation(using: .png, properties: [:])
        else { throw RedactionError.couldNotWrite("memory") }
        return pngData
    }
}

struct ImageRedactionTool: BackgroundAgentTool {
    let name = "redact_image"
    let description = """
    Blur, pixelate or black out private parts of an image file before it is shared or posted \
    (faces, names, emails, amounts, a client's details). Finds faces and text on this Mac. \
    Saves a NEW PNG in Teachy's output folder and returns its path plus the finished image so \
    you can check it; the original file is never changed. Use the returned path for uploads. \
    Screenshots from the request are already saved as files (their paths are in the request).
    """
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The image file to redact (PNG, JPEG, HEIC…)."],
            "faces": ["type": "boolean", "description": "Cover every face found."],
            "keep_largest_face": ["type": "boolean", "description": "With faces: leave the biggest face clear (usually the user's own)."],
            "text_matching": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Cover lines of text containing any of these words (names, emails, company, amounts).",
            ],
            "all_text": ["type": "boolean", "description": "Cover every line of text."],
            "regions": [
                "type": "array",
                "items": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4],
                "description": "Extra boxes as [x, y, width, height] fractions of the image (0-1, top-left origin).",
            ],
            "style": ["type": "string", "enum": ["blur", "pixelate", "black"], "description": "Default blur."],
        ],
        "required": ["path"],
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        try await executeReturningRichResult(arguments: arguments).text
    }

    func executeReturningRichResult(arguments: [String: Any]) async throws -> AgentToolResult {
        let path = (arguments["path"] as? String) ?? ""
        let inputURL = AgentToolPaths.url(for: path)
        let request = ImageRedactionRules.request(from: arguments)

        // Vision and Core Image are slow on big screenshots: keep them off the main actor.
        let outcome = try await Task.detached(priority: .userInitiated) {
            try ImageRedactor.redact(imageAt: inputURL, request: request)
        }.value

        var lines = ["Saved the redacted image to \(outcome.outputURL.path) (the original is unchanged)."]
        lines.append("Covered \(outcome.coveredRegions.count) area(s) with \(request.style.rawValue). Found \(outcome.foundFaceCount) face(s) and \(outcome.foundTextLineCount) line(s) of text.")
        let coveredText = outcome.coveredRegions.compactMap { region -> String? in
            if case .text(let line) = region.kind { return line } else { return nil }
        }
        if !coveredText.isEmpty {
            lines.append("Covered text: " + coveredText.prefix(12).map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if !outcome.detectionFailures.isEmpty {
            lines.append("This Mac couldn't finish \(outcome.detectionFailures.joined(separator: " or ")) in the image. Cover those parts with regions (boxes you can see in the image) instead.")
        }
        if outcome.coveredRegions.isEmpty {
            lines.append("Nothing matched, so nothing was covered. Try regions with boxes you can see in the image.")
        }
        lines.append("Look at the result below; if anything private still shows, call redact_image again on the new file with regions.")

        // The model sees a JPEG of the result to check it.
        let previewJPEG = NSBitmapImageRep(data: outcome.pngData)?.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        return AgentToolResult(
            text: lines.joined(separator: "\n"),
            visionImageJPEGData: previewJPEG,
            visionImageLabel: "The redacted image as saved"
        )
    }
}

/// Saves the screenshots a job was started with as real files, so the job can blur, attach or
/// upload them (a screenshot sent to the model as pixels is not a file it can use). When the user
/// circled something while asking, the circled area is saved on its own as well.
enum JobRequestScreenshotFiles {
    struct Saved {
        let screenshotPath: String
        let circledAreaPath: String?
    }

    /// The pixel box around the circle, padded a little and kept inside the screenshot.
    static func circledAreaPixelRect(outlinePoints: [CGPoint], screenshotWidth: Int, screenshotHeight: Int) -> CGRect? {
        guard outlinePoints.count >= 3 else { return nil }
        let xs = outlinePoints.map(\.x)
        let ys = outlinePoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard box.width >= 8, box.height >= 8 else { return nil }
        let padded = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: screenshotWidth, height: screenshotHeight)).integral
        return clamped.isNull || clamped.isEmpty ? nil : clamped
    }

    static func save(
        imageData: Data,
        jobID: String,
        screenIndex: Int,
        outlinePoints: [CGPoint],
        screenshotWidth: Int,
        screenshotHeight: Int
    ) -> Saved? {
        let directory = ImageRedactor.outputDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let safeJobID = jobID.replacingOccurrences(of: "/", with: "-")
        let screenshotURL = directory.appendingPathComponent("request-\(safeJobID)-screen-\(screenIndex + 1).jpg")
        guard (try? imageData.write(to: screenshotURL, options: .atomic)) != nil else { return nil }

        var circledAreaPath: String?
        if let pixelRect = circledAreaPixelRect(outlinePoints: outlinePoints, screenshotWidth: screenshotWidth, screenshotHeight: screenshotHeight),
           let image = NSImage(data: imageData),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // CGImage cropping uses pixel coordinates with a top-left origin, like the outline.
            let scaleX = CGFloat(cgImage.width) / CGFloat(max(screenshotWidth, 1))
            let scaleY = CGFloat(cgImage.height) / CGFloat(max(screenshotHeight, 1))
            let cropRect = CGRect(x: pixelRect.minX * scaleX, y: pixelRect.minY * scaleY, width: pixelRect.width * scaleX, height: pixelRect.height * scaleY).integral
            if let cropped = cgImage.cropping(to: cropRect),
               let pngData = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) {
                let circledURL = directory.appendingPathComponent("request-\(safeJobID)-circled.png")
                if (try? pngData.write(to: circledURL, options: .atomic)) != nil {
                    circledAreaPath = circledURL.path
                }
            }
        }
        return Saved(screenshotPath: screenshotURL.path, circledAreaPath: circledAreaPath)
    }
}
