//
//  DocumentReader.swift
//  leanring-buddy
//
//  Reads a file into a ReadDocument, on this Mac:
//    PDF            PDFKit text per page; a page with no text layer is drawn
//                   and read with Vision text recognition.
//    Text, Markdown, code, JSON, CSV/TSV
//                   the first few megabytes, decoded as text. CSV gets a table preview.
//    RTF, Word (.docx/.doc), OpenDocument text
//                   through NSAttributedString.
//    HTML           tags stripped locally (no web view, nothing is fetched).
//    Images         Vision text recognition, and a downsized copy for the vision model.
//  Anything else throws a plain "can't read this kind yet" error.
//
//  Every kind has a size limit that is checked before anything is loaded, and
//  text files are read through a file handle that stops at the limit, so a
//  2 GB log is never pulled into memory.
//

import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

nonisolated enum DocumentReader {

    // MARK: - Entry points

    /// Reads the file off the main thread.
    static func read(url: URL) async throws -> ReadDocument {
        try await Task.detached(priority: .userInitiated) {
            try readSynchronously(url: url)
        }.value
    }

    /// An image that arrived without a file (dragged out of a browser or a screenshot tool).
    static func readImage(data: Data, title: String) async throws -> ReadDocument {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw DocumentReadError.unreadable(title)
            }
            return try imageDocument(source: source, title: title, sourceURL: nil)
        }.value
    }

    static func readSynchronously(url: URL) throws -> ReadDocument {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DocumentReadError.notFound(name)
        }
        let fileExtension = url.pathExtension.lowercased()
        if isDirectory.boolValue {
            if fileExtension == "rtfd" { return try richTextDocument(url: url, byteCount: 0) }
            if iWorkExtensions.contains(fileExtension) { throw DocumentReadError.needsExport(name) }
            throw DocumentReadError.isFolder(name)
        }
        if iWorkExtensions.contains(fileExtension) { throw DocumentReadError.needsExport(name) }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        switch kind(forExtension: fileExtension, url: url) {
        case .pdf:
            try checkSize(byteCount, limit: DocumentLimits.maximumPDFBytes, name: name)
            return try pdfDocument(url: url)
        case .image:
            try checkSize(byteCount, limit: DocumentLimits.maximumImageBytes, name: name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw DocumentReadError.unreadable(name) }
            return try imageDocument(source: source, title: name, sourceURL: url)
        case .richText:
            try checkSize(byteCount, limit: DocumentLimits.maximumRichTextBytes, name: name)
            return try richTextDocument(url: url, byteCount: byteCount)
        case .html:
            return try textDocument(url: url, kind: .html, byteCount: byteCount)
        case .csv:
            return try textDocument(url: url, kind: .csv, byteCount: byteCount)
        case .json:
            return try textDocument(url: url, kind: .json, byteCount: byteCount)
        case .markdown:
            return try textDocument(url: url, kind: .markdown, byteCount: byteCount)
        case .code:
            return try textDocument(url: url, kind: .code, byteCount: byteCount)
        case .text:
            return try textDocument(url: url, kind: .text, byteCount: byteCount)
        case .webPage, .none:
            // Unknown extension: accept it only if the start of the file is plainly text.
            if looksLikeText(url: url) { return try textDocument(url: url, kind: .text, byteCount: byteCount) }
            throw DocumentReadError.unsupportedKind(fileExtension.isEmpty ? "this kind of" : "." + fileExtension)
        }
    }

    // MARK: - Kinds

    private static let iWorkExtensions: Set<String> = ["pages", "numbers", "key"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    private static let richTextExtensions: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    private static let plainTextExtensions: Set<String> = ["txt", "text", "log", "srt", "vtt", "tex", "rst", "org", "adoc"]
    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm",
        "cs", "go", "rs", "rb", "php", "pl", "sh", "zsh", "bash", "fish", "ps1", "sql", "r", "scala", "lua", "dart", "ex",
        "exs", "erl", "hs", "clj", "vue", "svelte", "css", "scss", "less", "xml", "yaml", "yml", "toml", "ini", "cfg",
        "conf", "env", "gradle", "plist", "proto", "graphql", "tf", "dockerfile", "makefile", "cmake", "ipynb", "jsonl",
        "ndjson", "diff", "patch", "gitignore", "entitlements", "strings", "pbxproj", "xcconfig"
    ]

    static func kind(forExtension fileExtension: String, url: URL) -> DocumentKind? {
        let lowerName = url.lastPathComponent.lowercased()
        if fileExtension == "pdf" { return .pdf }
        if imageExtensions.contains(fileExtension) { return .image }
        if richTextExtensions.contains(fileExtension) { return .richText }
        if fileExtension == "html" || fileExtension == "htm" || fileExtension == "xhtml" { return .html }
        if fileExtension == "csv" || fileExtension == "tsv" { return .csv }
        if fileExtension == "json" || fileExtension == "geojson" { return .json }
        if markdownExtensions.contains(fileExtension) { return .markdown }
        if plainTextExtensions.contains(fileExtension) { return .text }
        if codeExtensions.contains(fileExtension) || ["dockerfile", "makefile", "gemfile", "podfile", "rakefile"].contains(lowerName) {
            return .code
        }
        if let type = UTType(filenameExtension: fileExtension) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
            if type.conforms(to: .plainText) { return .text }
        }
        return nil
    }

    private static func checkSize(_ byteCount: Int64, limit: Int64, name: String) throws {
        guard byteCount <= limit else {
            throw DocumentReadError.tooLarge(
                name: name,
                megabytes: Int(byteCount / (1024 * 1024)),
                limitMegabytes: Int(limit / (1024 * 1024))
            )
        }
    }

    // MARK: - Text files

    /// Reads at most `limit` bytes from the start of the file.
    static func readPrefix(of url: URL, limit: Int) throws -> (data: Data, reachedEnd: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        if data.count > limit { return (data.prefix(limit), false) }
        return (data, true)
    }

    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // A cut in the middle of a multi-byte character: drop up to three trailing bytes.
        for dropped in 1...3 where data.count > dropped {
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) { return text }
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if !data.prefix(4096).contains(0) { return String(data: data, encoding: .isoLatin1) }
        return nil
    }

    private static func looksLikeText(url: URL) -> Bool {
        guard let sample = try? readPrefix(of: url, limit: 4096).data, !sample.isEmpty, !sample.contains(0) else { return false }
        guard let text = decode(sample) else { return false }
        let printable = text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" || $0 == "\r" }.count
        return Double(printable) / Double(max(1, text.unicodeScalars.count)) > 0.95
    }

    private static func textDocument(url: URL, kind: DocumentKind, byteCount: Int64) throws -> ReadDocument {
        let name = url.lastPathComponent
        let (data, reachedEnd) = try readPrefix(of: url, limit: DocumentLimits.maximumTextBytes)
        guard var text = decode(data) else { throw DocumentReadError.unreadable(name) }
        if !reachedEnd, let lastBreak = text.lastIndex(of: "\n") {
            // Don't end on half a line.
            text = String(text[..<lastBreak])
        }
        var note: String?
        if !reachedEnd {
            let megabytes = max(1, Int(byteCount / (1024 * 1024)))
            note = "Only the first \(DocumentLimits.maximumTextBytes / (1024 * 1024)) MB of this \(megabytes) MB file was read."
        }
        if text.count > DocumentLimits.maximumCharacters {
            text = String(text.prefix(DocumentLimits.maximumCharacters))
            note = note ?? "Only the first \(DocumentLimits.maximumCharacters) characters were read."
        }

        var title = name
        var sections: [DocumentSection]
        switch kind {
        case .csv:
            let delimiter: Character? = url.pathExtension.lowercased() == "tsv" ? "\t" : nil
            sections = CSVTable.parse(text, delimiter: delimiter).sections(wasCutShort: note != nil)
        case .markdown:
            sections = DocumentTextTools.markdownSections(text)
        case .html:
            let page = DocumentTextTools.plainText(fromHTML: text)
            if let pageTitle = page.title { title = pageTitle }
            sections = DocumentTextTools.plainSections(page.text)
        default:
            sections = DocumentTextTools.lineRangeSections(text.replacingOccurrences(of: "\r\n", with: "\n"))
        }
        guard !sections.isEmpty else { throw DocumentReadError.empty(name) }
        return ReadDocument(
            title: title, kind: kind, sourceURL: url, sections: sections,
            isTruncated: note != nil, truncationNote: note
        )
    }

    // MARK: - RTF, Word and friends

    private static func richTextDocument(url: URL, byteCount: Int64) throws -> ReadDocument {
        let name = url.lastPathComponent
        var attributes: NSDictionary?
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: &attributes) else {
            throw DocumentReadError.unreadable(name)
        }
        var text = DocumentTextTools.tidy(attributed.string)
        var note: String?
        if text.count > DocumentLimits.maximumCharacters {
            text = String(text.prefix(DocumentLimits.maximumCharacters))
            note = "Only the first \(DocumentLimits.maximumCharacters) characters were read."
        }
        let sections = DocumentTextTools.plainSections(text)
        guard !sections.isEmpty else { throw DocumentReadError.empty(name) }
        let storedTitle = (attributes?[NSAttributedString.DocumentAttributeKey.title] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadDocument(
            title: (storedTitle?.isEmpty == false) ? storedTitle! : name,
            kind: .richText, sourceURL: url, sections: sections,
            isTruncated: note != nil, truncationNote: note
        )
    }

    // MARK: - PDF

    private static func pdfDocument(url: URL) throws -> ReadDocument {
        let name = url.lastPathComponent
        guard let pdf = PDFDocument(url: url) else { throw DocumentReadError.unreadable(name) }
        if pdf.isLocked { throw DocumentReadError.locked(name) }

        let totalPages = pdf.pageCount
        let pagesToRead = min(totalPages, DocumentLimits.maximumPages)
        var sections: [DocumentSection] = []
        var characters = 0
        var recognisedPages = 0
        var pagesWithoutText = 0
        var stoppedForLength = false

        for pageIndex in 0..<pagesToRead {
            // PDFKit keeps what it has drawn; the pool lets each page go before the next.
            let section: DocumentSection? = autoreleasepool {
                guard let page = pdf.page(at: pageIndex) else { return nil }
                var text = DocumentTextTools.tidy(page.string ?? "")
                var usedOCR = false
                if text.count < 16 {
                    if recognisedPages < DocumentLimits.maximumOCRPages, let image = render(page: page) {
                        recognisedPages += 1
                        let recognised = recogniseText(in: image)
                        if !recognised.isEmpty {
                            text = recognised
                            usedOCR = true
                        }
                    }
                    if text.isEmpty { pagesWithoutText += 1 }
                }
                return DocumentSection(number: pageIndex + 1, text: text, usedOCR: usedOCR)
            }
            guard let section else { continue }
            characters += section.text.count
            if characters > DocumentLimits.maximumCharacters {
                stoppedForLength = true
                break
            }
            sections.append(section)
        }

        guard sections.contains(where: { !$0.text.isEmpty }) else { throw DocumentReadError.empty(name) }

        var notes: [String] = []
        if stoppedForLength || totalPages > sections.count {
            notes.append("Only pages 1 to \(sections.count) of \(totalPages) were read.")
        }
        if pagesWithoutText > 0 {
            notes.append("\(pagesWithoutText) page\(pagesWithoutText == 1 ? " has" : "s have") no readable text (pictures or scans).")
        }
        let storedTitle = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadDocument(
            title: (storedTitle?.isEmpty == false) ? storedTitle! : name,
            kind: .pdf, sourceURL: url, sections: sections, pageCount: totalPages,
            isTruncated: stoppedForLength || totalPages > sections.count,
            truncationNote: notes.isEmpty ? nil : notes.joined(separator: " ")
        )
    }

    /// Draws a PDF page into a bitmap about 2000 pixels on its long side.
    private static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(3, 2000 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Images and text recognition

    /// Text in the picture, top to bottom. Empty when there is none or recognition fails.
    static func recogniseText(in image: CGImage) -> String {
        // The accurate recogniser can fail to start (seen from a command-line tool on
        // macOS 27: "e5rt … call failed"); the fast one has no such dependency.
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = DocumentTextTools.tidy(lines.joined(separator: "\n"))
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func imageDocument(source: CGImageSource, title: String, sourceURL: URL?) throws -> ReadDocument {
        // ImageIO decodes straight to the smaller size; the full picture is never held.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: DocumentLimits.maximumImagePixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DocumentReadError.unreadable(title)
        }
        let recognised = recogniseText(in: image)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        return ReadDocument(
            title: title, kind: .image, sourceURL: sourceURL,
            sections: recognised.isEmpty ? [] : [DocumentSection(number: 1, title: "text in the picture", text: recognised, usedOCR: true)],
            pageCount: 1,
            imageData: jpeg
        )
    }
}
