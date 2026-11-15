//
//  DocumentModel.swift
//  leanring-buddy
//
//  What Teachy knows about a file, a web page or an image once it has been
//  read: its title, its kind, and its text split into numbered pages (PDF) or
//  sections (everything else). Pure data, no AppKit.
//

import Foundation

nonisolated enum DocumentKind: String, Codable, Sendable {
    case pdf
    case text
    case markdown
    case code
    case json
    case csv
    case richText
    case html
    case image
    case webPage

    /// Short name for chips and for the header handed to the model.
    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .text: return "Text"
        case .markdown: return "Markdown"
        case .code: return "Code"
        case .json: return "JSON"
        case .csv: return "Table"
        case .richText: return "Document"
        case .html: return "HTML"
        case .image: return "Image"
        case .webPage: return "Web page"
        }
    }
}

/// One page of a PDF, or one section of anything else.
nonisolated struct DocumentSection: Equatable, Sendable {
    /// 1-based. For a PDF this is the real page number, so an answer can say "on page 12".
    var number: Int
    /// A heading, a line range ("lines 1–80") or a row range ("rows 1–100") when there is one.
    var title: String?
    var text: String
    /// True when the text came from recognising a picture of the page.
    var usedOCR: Bool

    init(number: Int, title: String? = nil, text: String, usedOCR: Bool = false) {
        self.number = number
        self.title = title
        self.text = text
        self.usedOCR = usedOCR
    }
}

nonisolated struct ReadDocument: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var kind: DocumentKind
    /// The file or page this came from. Nil for an image dropped without a file.
    var sourceURL: URL?
    /// Pages or sections that were read, in order. May be fewer than `pageCount`.
    var sections: [DocumentSection]
    /// How many pages or sections the whole thing has.
    var pageCount: Int
    /// True when a limit stopped the read before the end.
    var isTruncated: Bool
    /// One plain sentence saying what was left out, for the model and the chip.
    var truncationNote: String?
    /// For images: a downsized JPEG to send to the vision model.
    var imageData: Data?

    init(
        title: String,
        kind: DocumentKind,
        sourceURL: URL? = nil,
        sections: [DocumentSection],
        pageCount: Int? = nil,
        isTruncated: Bool = false,
        truncationNote: String? = nil,
        imageData: Data? = nil
    ) {
        self.title = title
        self.kind = kind
        self.sourceURL = sourceURL
        self.sections = sections
        self.pageCount = pageCount ?? sections.count
        self.isTruncated = isTruncated
        self.truncationNote = truncationNote
        self.imageData = imageData
    }

    /// "page" for PDFs, "section" for everything else.
    var unitName: String { kind == .pdf ? "page" : "section" }

    var characterCount: Int { sections.reduce(0) { $0 + $1.text.count } }

    var hasText: Bool { sections.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// "30 pages", "1 section", "Image".
    var sizeDescription: String {
        if kind == .image { return hasText ? "Image with text" : "Image" }
        return "\(pageCount) \(unitName)\(pageCount == 1 ? "" : "s")"
    }
}

/// Hard limits so a huge file can never be loaded whole.
nonisolated enum DocumentLimits {
    /// PDFs are read page by page from disk, so the file itself may be large.
    static let maximumPDFBytes: Int64 = 400 * 1024 * 1024
    /// Plain text, code, JSON, CSV: only this much is read from the start of the file.
    static let maximumTextBytes = 4 * 1024 * 1024
    /// RTF, Word and similar are parsed whole, so the file must be small.
    static let maximumRichTextBytes: Int64 = 40 * 1024 * 1024
    static let maximumImageBytes: Int64 = 80 * 1024 * 1024
    /// Pages read from one PDF.
    static let maximumPages = 400
    /// Pages without a text layer that get text recognition.
    static let maximumOCRPages = 40
    /// Characters kept from one document.
    static let maximumCharacters = 1_500_000
    /// Longest side of an image sent to the vision model.
    static let maximumImagePixels = 1600
}

nonisolated enum DocumentReadError: LocalizedError, Equatable {
    case notFound(String)
    case isFolder(String)
    case unsupportedKind(String)
    /// Pages, Numbers and Keynote files: a folder or archive only those apps can read.
    case needsExport(String)
    case tooLarge(name: String, megabytes: Int, limitMegabytes: Int)
    case locked(String)
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "\(name) isn't there any more."
        case .isFolder(let name):
            return "\(name) is a folder. Drop the files inside it instead."
        case .unsupportedKind(let description):
            return "Teachy can't read \(description) files yet. PDF, text, Markdown, code, CSV, JSON, Word, RTF, HTML and images work."
        case .needsExport(let name):
            return "Export \(name) as PDF first. Teachy can't read Pages, Numbers or Keynote files yet."
        case .tooLarge(let name, let megabytes, let limitMegabytes):
            return "\(name) is \(megabytes) MB. The limit for this kind of file is \(limitMegabytes) MB."
        case .locked(let name):
            return "\(name) needs a password. Unlock it and save a copy first."
        case .unreadable(let name):
            return "\(name) couldn't be read."
        case .empty(let name):
            return "\(name) has no text in it."
        }
    }
}
