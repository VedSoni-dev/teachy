//
//  AttachmentShelf.swift
//  leanring-buddy
//
//  The files the person has given Teachy for the current conversation: up to
//  five, added by dropping them on the notch or the chat window (or with the
//  paperclip), shown as chips, and handed to the model with the next question.
//
//  Three parts:
//    AttachmentShelf        the list (`AttachmentShelf.shared`)
//    AttachmentChipsView    the chips
//    .attachmentDropTarget  a view modifier that accepts dropped files and images
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The list

/// One attached file and how far reading it has got.
struct AttachmentItem: Identifiable {
    enum State {
        case reading
        case ready(ReadDocument)
        case failed(String)
    }

    let id: UUID
    var title: String
    var url: URL?
    var kind: DocumentKind?
    var state: State

    var document: ReadDocument? {
        if case .ready(let document) = state { return document }
        return nil
    }

    /// The small line under the name: "30 pages", "Reading…", or what went wrong.
    var detail: String {
        switch state {
        case .reading: return "Reading…"
        case .ready(let document): return document.sizeDescription + (document.isTruncated ? ", partly read" : "")
        case .failed(let message): return message
        }
    }

    /// The first sentence of `detail`, for the chip. The whole message is its tooltip.
    var shortDetail: String {
        guard isFailed, let end = detail.range(of: ". ") else { return detail }
        return String(detail[..<end.lowerBound]) + "."
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

enum AttachmentAddOutcome: Equatable {
    case added
    /// The same file is already attached.
    case alreadyAttached
    /// Five files are attached already.
    case full
}

/// The rules for what may join the list. Pure, so it is tested without files.
nonisolated enum AttachmentRules {
    static let maximumCount = 5

    /// Two URLs that are the same file compare equal after this.
    static func key(for url: URL) -> String {
        url.isFileURL ? url.resolvingSymlinksInPath().standardizedFileURL.path : url.absoluteString
    }

    static func outcome(adding url: URL, to existing: [URL], maximumCount: Int = maximumCount) -> AttachmentAddOutcome {
        let newKey = key(for: url)
        if existing.contains(where: { key(for: $0) == newKey }) { return .alreadyAttached }
        if existing.count >= maximumCount { return .full }
        return .added
    }
}

@MainActor
final class AttachmentShelf: ObservableObject {
    static let shared = AttachmentShelf()

    @Published private(set) var items: [AttachmentItem] = []
    /// A short message for the person ("Up to 5 files at a time."). Cleared on the next change.
    @Published private(set) var notice: String?

    private let reader: @Sendable (URL) async throws -> ReadDocument
    private var readTasks: [UUID: Task<Void, Never>] = [:]

    init(reader: @escaping @Sendable (URL) async throws -> ReadDocument = { try await DocumentReader.read(url: $0) }) {
        self.reader = reader
    }

    var isEmpty: Bool { items.isEmpty }
    var documents: [ReadDocument] { items.compactMap(\.document) }
    var isReading: Bool { items.contains { if case .reading = $0.state { return true } else { return false } } }

    // MARK: Adding and removing

    @discardableResult
    func add(url: URL) -> AttachmentAddOutcome {
        let outcome = AttachmentRules.outcome(adding: url, to: items.compactMap(\.url))
        switch outcome {
        case .alreadyAttached:
            notice = "\(url.lastPathComponent) is already attached."
            return outcome
        case .full:
            notice = "Up to \(AttachmentRules.maximumCount) files at a time. Remove one first."
            return outcome
        case .added:
            notice = nil
        }
        let fileExtension = url.pathExtension.lowercased()
        let item = AttachmentItem(
            id: UUID(), title: url.lastPathComponent, url: url,
            kind: DocumentReader.kind(forExtension: fileExtension, url: url), state: .reading
        )
        items.append(item)
        startReading(item.id) { [reader] in try await reader(url) }
        return .added
    }

    func add(urls: [URL]) {
        for url in urls { add(url: url) }
    }

    /// An image with no file behind it (dragged from a browser, pasted).
    @discardableResult
    func add(imageData: Data, title: String = "Image") -> AttachmentAddOutcome {
        guard items.count < AttachmentRules.maximumCount else {
            notice = "Up to \(AttachmentRules.maximumCount) files at a time. Remove one first."
            return .full
        }
        notice = nil
        let item = AttachmentItem(id: UUID(), title: title, url: nil, kind: .image, state: .reading)
        items.append(item)
        startReading(item.id) { try await DocumentReader.readImage(data: imageData, title: title) }
        return .added
    }

    /// A document that is already read (the front app's page, for example).
    @discardableResult
    func add(document: ReadDocument) -> AttachmentAddOutcome {
        if let url = document.sourceURL {
            let outcome = AttachmentRules.outcome(adding: url, to: items.compactMap(\.url))
            guard outcome == .added else { return outcome }
        } else if items.count >= AttachmentRules.maximumCount {
            return .full
        }
        items.append(AttachmentItem(id: UUID(), title: document.title, url: document.sourceURL, kind: document.kind, state: .ready(document)))
        return .added
    }

    func remove(id: UUID) {
        readTasks[id]?.cancel()
        readTasks[id] = nil
        items.removeAll { $0.id == id }
        notice = nil
    }

    func clear() {
        readTasks.values.forEach { $0.cancel() }
        readTasks = [:]
        items = []
        notice = nil
    }

    private func startReading(_ id: UUID, _ read: @escaping @Sendable () async throws -> ReadDocument) {
        readTasks[id] = Task { [weak self] in
            let state: AttachmentItem.State
            do {
                let document = try await read()
                state = .ready(document)
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't read this file.")
            }
            guard !Task.isCancelled, let self, let position = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[position].state = state
            if case .ready(let document) = state {
                self.items[position].kind = document.kind
                if document.sourceURL == nil { self.items[position].title = document.title }
            }
            self.readTasks[id] = nil
        }
    }

    /// Waits until nothing is still being read, or until `timeout` seconds pass.
    func waitUntilRead(timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isReading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    // MARK: For the model

    /// What to add to the next question: the documents' text (whole, or the parts
    /// that match the question; see DocumentContext) and any attached pictures.
    /// Files still being read are left out; `waitUntilRead()` first if you can wait.
    func contextForNextTurn(
        question: String,
        budgetCharacters: Int = DocumentContext.defaultBudgetCharacters
    ) -> (text: String, images: [(data: Data, label: String)]) {
        Self.context(question: question, documents: documents, budgetCharacters: budgetCharacters)
    }

    nonisolated static let maximumImages = 3

    nonisolated static func context(
        question: String,
        documents: [ReadDocument],
        budgetCharacters: Int
    ) -> (text: String, images: [(data: Data, label: String)]) {
        guard !documents.isEmpty else { return ("", []) }
        let text = DocumentContext.build(for: question, documents: documents, budgetCharacters: budgetCharacters)
        let images = documents.compactMap { document -> (data: Data, label: String)? in
            guard let data = document.imageData else { return nil }
            return (data, "attached picture \"\(document.title)\" (given by the person, not their screen)")
        }
        return (text, Array(images.prefix(maximumImages)))
    }
}

// MARK: - Chips

/// The attached files as a row of chips. `compact` is for the notch panel;
/// the regular size is for the chat window.
struct AttachmentChipsView: View {
    @ObservedObject var shelf: AttachmentShelf
    var compact: Bool

    /// `shelf: nil` means `AttachmentShelf.shared`.
    init(shelf: AttachmentShelf? = nil, compact: Bool = false) {
        self.shelf = shelf ?? .shared
        self.compact = compact
    }

    var body: some View {
        if !shelf.items.isEmpty || shelf.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !shelf.items.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: compact ? 6 : 8) {
                            ForEach(shelf.items) { item in
                                AttachmentChip(item: item, compact: compact) { shelf.remove(id: item.id) }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                if let notice = shelf.notice {
                    Text(notice)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.warningText)
                }
            }
        }
    }
}

/// One attached file: a chip with a symbol for the kind of file, its name, and
/// how much of it there is ("30 pages").
struct AttachmentChip: View {
    let item: AttachmentItem
    var compact: Bool
    let onRemove: () -> Void

    private var isReading: Bool {
        if case .reading = item.state { return true }
        return false
    }

    /// A plain symbol for the kind of file, drawn in the tint (never a coloured icon square).
    private var kindSymbolName: String {
        switch item.kind {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .csv: return "tablecells"
        case .code, .json: return "chevron.left.forwardslash.chevron.right"
        case .webPage, .html: return "globe"
        case .markdown, .text, .richText, .none: return "doc.text"
        }
    }

    /// The picture itself, when the attachment is one that has been read.
    private var thumbnailImage: NSImage? {
        guard case .ready(let document) = item.state, let data = document.imageData else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        HStack(spacing: compact ? 6 : 9) {
            leadingMark

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(item.title)
                    .font(compact ? DS.Fonts.sans(11.5, weight: .medium) : DS.Fonts.bodyEmphasized)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact || item.isFailed {
                    detailLine
                }
            }
            .frame(maxWidth: item.isFailed ? (compact ? 220 : 280) : (compact ? 130 : 180), alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .teachyIconButton(sideLength: 18)
            .accessibilityLabel("Remove \(item.title)")
        }
        .padding(.leading, compact ? 7 : 8)
        .padding(.trailing, compact ? 4 : 6)
        .padding(.vertical, compact ? 3 : 6)
        .teachyOption(isSelected: false)
        .help(item.isFailed ? item.detail : (item.url?.path ?? item.title))
    }

    /// What sits before the name: the picture itself, the state while the file
    /// is being read or could not be, and otherwise a symbol for its kind.
    @ViewBuilder
    private var leadingMark: some View {
        let leadingMarkSideLength: CGFloat = compact ? 16 : 28
        if let thumbnailImage {
            let thumbnailShape = RoundedRectangle(cornerRadius: compact ? 3 : DS.CornerRadius.key, style: .continuous)
            Image(nsImage: thumbnailImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: leadingMarkSideLength, height: leadingMarkSideLength)
                .clipShape(thumbnailShape)
                .overlay(thumbnailShape.strokeBorder(DS.Colors.hairline, lineWidth: 1))
        } else {
            Group {
                if isReading {
                    TeachyStatusMark(kind: .live)
                } else if item.isFailed {
                    TeachyStatusMark(kind: .needsYou)
                } else {
                    Image(systemName: kindSymbolName)
                        .font(DS.Fonts.sans(compact ? 11 : 15, weight: .medium))
                        .foregroundColor(DS.Colors.pointer)
                }
            }
            .frame(width: compact ? leadingMarkSideLength : 22, height: leadingMarkSideLength)
        }
    }

    /// The line under the name. A file that could not be read says what to do
    /// about it, in amber, because that needs the person.
    private var detailLine: some View {
        Text(item.shortDetail)
            .font(item.isFailed ? DS.Fonts.caption : DS.Fonts.data)
            .foregroundColor(item.isFailed ? DS.Colors.warningText : DS.Colors.textSecondary)
            .lineLimit(1)
    }
}

// MARK: - Drop target

extension View {
    /// Accepts files and images dropped on this view and attaches them.
    /// While something is dragged over it, a "Drop to attach" highlight is shown
    /// and `onTargetedChange` is called (the notch uses it to open itself).
    func attachmentDropTarget(
        shelf: AttachmentShelf? = nil,
        cornerRadius: CGFloat = 14,
        showsHighlight: Bool = true,
        onTargetedChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(AttachmentDropModifier(
            shelf: shelf ?? .shared, cornerRadius: cornerRadius, showsHighlight: showsHighlight, onTargetedChange: onTargetedChange
        ))
    }
}

struct AttachmentDropModifier: ViewModifier {
    let shelf: AttachmentShelf
    var cornerRadius: CGFloat
    var showsHighlight: Bool
    var onTargetedChange: ((Bool) -> Void)?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted && showsHighlight {
                    AttachmentDropHighlight(cornerRadius: cornerRadius)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(DS.Motion.hover, value: isTargeted)
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                AttachmentDropHandler.handle(providers, shelf: shelf)
            }
            .onChange(of: isTargeted) { _, targeted in onTargetedChange?(targeted) }
    }
}

/// What is shown over a drop target while a file is held above it: what is
/// underneath dims, and a dashed edge and a faint fill in the tint mark where
/// the file will land.
struct AttachmentDropHighlight: View {
    var cornerRadius: CGFloat = 14

    /// How far the dashed edge sits inside the edge of the target.
    private static let dashedEdgeInset: CGFloat = 6

    private var dashedEdgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(cornerRadius - Self.dashedEdgeInset, 0), style: .continuous)
    }

    var body: some View {
        ZStack {
            // Dims what is underneath so the words can be read. Black, so the notch
            // stays the hardware's black.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DS.Colors.notchBlack.opacity(0.72))
            dashedEdgeShape
                .fill(DS.Colors.pointer.opacity(0.12))
                .padding(Self.dashedEdgeInset)
            dashedEdgeShape
                .strokeBorder(DS.Colors.pointer, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [7, 5]))
                .padding(Self.dashedEdgeInset)
            VStack(spacing: 5) {
                Text("Drop to attach")
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("PDF, text, code, tables, Word, images. Up to \(AttachmentRules.maximumCount).")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
    }
}

enum AttachmentDropHandler {
    /// Returns true when at least one dropped item is something that can be attached.
    static func handle(_ providers: [NSItemProvider], shelf: AttachmentShelf) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in shelf.add(url: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let suggestedName = provider.suggestedName ?? "Image"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in shelf.add(imageData: data, title: suggestedName) }
                }
            }
        }
        return accepted
    }
}
