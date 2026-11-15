//
//  ChatWindowView.swift
//  leanring-buddy
//
//  The contents of the chat window: a search field, the conversation grouped by
//  day (messages, drawings, agent jobs, notes), and a composer with attachment
//  chips and the "hold to talk" hint. Dark like the notch panel, with larger
//  type because this is a window you read in.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sizes and colours used only by the chat window.
enum ChatStyle {
    static let windowBackground = Color(hex: "#0B0C0F")
    static let headerBackground = Color(hex: "#0F1014")
    static let hairline = Color.white.opacity(0.07)
    static let cardFill = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.09)
    static let codeBackground = Color(hex: "#06070A")
    static let userBubble = Color(hex: "#1F5FD0")
    static let bodySize: CGFloat = 14.5
    static let bodyLineSpacing: CGFloat = 4.5
    static let columnWidth: CGFloat = 760
    static let headerHeight: CGFloat = 52
}

struct ChatWindowView: View {
    @ObservedObject var timeline: ChatTimeline
    @ObservedObject var shelf: AttachmentShelf
    /// The colour of Teachy's mark beside its replies (the person's cursor colour).
    var accentColor: Color
    /// The keys that are held to talk right now, e.g. ["control", "option"].
    var talkKeyLabels: () -> [String]
    /// Sends a typed question. Wired to `CompanionManager.submitSyntheticCompanionRequest`.
    var onSubmit: (String) -> Void
    /// Room on the left of the header for the window's close, minimise and zoom buttons.
    var leadingHeaderInset: CGFloat

    @State private var searchText = ""
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 22
    @State private var keyLabels: [String] = []
    @FocusState private var searchFocused: Bool

    init(
        timeline: ChatTimeline,
        shelf: AttachmentShelf? = nil,
        accentColor: Color = DS.Colors.overlayCursorBlue,
        talkKeyLabels: @escaping () -> [String] = { PushToTalkShortcutKeys.currentKeyCapsuleLabels },
        leadingHeaderInset: CGFloat = 84,
        initialSearchText: String = "",
        initialDraft: String = "",
        onSubmit: @escaping (String) -> Void
    ) {
        self.timeline = timeline
        self.shelf = shelf ?? .shared
        self.accentColor = accentColor
        self.talkKeyLabels = talkKeyLabels
        self.leadingHeaderInset = leadingHeaderInset
        self.onSubmit = onSubmit
        self._searchText = State(initialValue: initialSearchText)
        self._draft = State(initialValue: initialDraft)
        self._keyLabels = State(initialValue: talkKeyLabels())
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var shownItems: [ChatThreadItem] {
        ChatThread.filter(timeline.items, matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(2)
            Rectangle().fill(ChatStyle.hairline).frame(height: 1)
                .zIndex(2)
            thread
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            composerArea
                .zIndex(1)
        }
        .background(ChatStyle.windowBackground)
        .attachmentDropTarget(shelf: shelf, cornerRadius: 12)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: PushToTalkShortcutKeys.shortcutDidChangeNotification)) { _ in
            keyLabels = talkKeyLabels()
        }
        .onAppear { keyLabels = talkKeyLabels() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: max(0, leadingHeaderInset - 16), height: 1)

            ChatTeachyMark(color: accentColor, size: 13)
            Text("Teachy")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("Search this chat", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($searchFocused)
                if isSearching {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: 230)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(searchFocused ? 0.09 : 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(searchFocused ? DS.Colors.blue400.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1)
            )
            // Command+F from anywhere in the window.
            .background(
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )
        }
        .padding(.horizontal, 16)
        .frame(height: ChatStyle.headerHeight)
        .background(ChatStyle.headerBackground)
    }

    // MARK: Thread

    @ViewBuilder
    private var thread: some View {
        let items = shownItems
        if items.isEmpty && !timeline.isWaitingForReply {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if isSearching {
                            Text("\(items.count) \(items.count == 1 ? "match" : "matches") for “\(searchText.trimmingCharacters(in: .whitespaces))”")
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.top, 16)
                        }
                        ForEach(ChatThread.days(items)) { day in
                            ChatDaySeparator(label: day.label)
                                .padding(.top, 18)
                                .padding(.bottom, 14)
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(day.items) { item in
                                    ChatItemView(item: item, accentColor: accentColor, timeline: timeline)
                                }
                            }
                        }
                        if timeline.isWaitingForReply {
                            ChatThinkingRow(accentColor: accentColor)
                                .padding(.top, 18)
                        }
                        Color.clear.frame(height: 20).id("chat-bottom")
                    }
                    .frame(maxWidth: ChatStyle.columnWidth, alignment: .leading)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(isSearching ? .top : .bottom)
                .onChange(of: timeline.items.last?.id) { _, _ in
                    guard !isSearching else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if isSearching {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Nothing in this chat matches “\(searchText.trimmingCharacters(in: .whitespaces))”")
                    .font(.system(size: 14))
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                ChatTeachyMark(color: accentColor, size: 26)
                    .padding(.bottom, 6)
                Text("Ask Teachy anything")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Type below, hold your talk keys, or drop a file here to ask about it.")
                    .font(.system(size: 13.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        searchText = ""
        timeline.userAsked(question)
        onSubmit(question)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to ask Teachy about"
        panel.prompt = "Attach"
        if panel.runModal() == .OK { shelf.add(urls: panel.urls) }
    }

    private var composerArea: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                AttachmentChipsView(shelf: shelf)

                HStack(alignment: .bottom, spacing: 10) {
                    Button(action: chooseFiles) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Attach a file")
                    .accessibilityLabel("Attach a file")

                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ask Teachy…")
                                .font(.system(size: ChatStyle.bodySize))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                        ChatComposerTextView(text: $draft, height: $composerHeight, fontSize: ChatStyle.bodySize, onSubmit: send)
                            .frame(height: composerHeight)
                    }
                    .padding(.vertical, 3)

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(canSend ? .white : DS.Colors.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(canSend ? ChatStyle.userBubble : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor(isEnabled: canSend)
                    .disabled(!canSend)
                    .help("Send (Return)")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.11), lineWidth: 1))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    talkHint
                    Spacer(minLength: 16)
                    Text("Return to send  ·  Shift + Return for a new line")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 0) {
                    talkHint
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: ChatStyle.columnWidth)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(ChatStyle.windowBackground)
    }

    private var talkHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Hold")
            ForEach(Array(keyLabels.enumerated()), id: \.offset) { position, label in
                if position > 0 {
                    Text("+").foregroundColor(DS.Colors.textTertiary)
                }
                ChatKeyCap(text: label)
            }
            Text("to talk")
        }
        .font(.system(size: 11.5))
        .foregroundColor(DS.Colors.textTertiary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold \(keyLabels.joined(separator: " and ")) to talk")
    }
}

// MARK: - Small pieces

/// Teachy's pointer triangle, as it appears beside the notch.
struct ChatTeachyMark: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        ChatTriangle()
            .fill(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(-35))
            .shadow(color: color.opacity(0.55), radius: size * 0.3)
            .frame(width: size * 1.35, height: size * 1.35)
            .accessibilityHidden(true)
    }
}

private struct ChatTriangle: Shape {
    /// Same equilateral triangle as the cursor in the notch (`Triangle` in OverlayWindow.swift).
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

struct ChatKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

struct ChatDaySeparator: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(ChatStyle.hairline).frame(height: 1)
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize()
            Rectangle().fill(ChatStyle.hairline).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

enum ChatTimeFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// "Copy" that turns into "Copied" for a moment.
struct ChatCopyButton: View {
    let text: String
    var showsLabel = true
    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                if showsLabel {
                    Text(didCopy ? "Copied" : "Copy")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundColor(didCopy ? DS.Colors.success : (isHovering ? DS.Colors.textPrimary : DS.Colors.textTertiary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(isHovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .accessibilityLabel("Copy")
    }
}

// MARK: - One item in the thread

struct ChatItemView: View {
    let item: ChatThreadItem
    var accentColor: Color
    let timeline: ChatTimeline

    var body: some View {
        switch item.content {
        case .userMessage(let text):
            ChatUserBubble(text: text, date: item.date)
        case .assistantMessage(let text):
            ChatAssistantMessage(text: text, date: item.date, isStreaming: false, accentColor: accentColor)
        case .streamingReply(let text):
            ChatAssistantMessage(text: text, date: item.date, isStreaming: true, accentColor: accentColor)
        case .row(let row):
            switch row.kind {
            case .drawing:
                ChatDrawingRow(row: row, date: item.date) { timeline.onOpenDrawing?(String(row.id.dropFirst("drawing-".count))) }
            case .job:
                ChatJobRow(row: row, date: item.date) { timeline.onOpenJob?(String(row.id.dropFirst("job-".count))) }
            case .note:
                ChatNoteRow(text: row.title)
            }
        }
    }
}

struct ChatUserBubble: View {
    let text: String
    let date: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(size: ChatStyle.bodySize))
                .lineSpacing(ChatStyle.bodyLineSpacing - 1)
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 17, bottomLeadingRadius: 17, bottomTrailingRadius: 5, topTrailingRadius: 17,
                        style: .continuous
                    )
                    .fill(ChatStyle.userBubble)
                )
                .frame(maxWidth: 520, alignment: .trailing)
            Text(ChatTimeFormat.time.string(from: date))
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

struct ChatAssistantMessage: View {
    let text: String
    let date: Date
    var isStreaming: Bool
    var accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChatTeachyMark(color: accentColor, size: 12)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ChatReplyText.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let paragraph):
                        ChatProseView(text: paragraph, fontSize: ChatStyle.bodySize, lineSpacing: ChatStyle.bodyLineSpacing, opacity: 0.94)
                    case .code(let language, let code):
                        ChatCodeBlock(language: language, code: code)
                    }
                }

                HStack(spacing: 6) {
                    if isStreaming {
                        ChatTypingDots(color: accentColor)
                    } else {
                        Text(ChatTimeFormat.time.string(from: date))
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textTertiary)
                        ChatCopyButton(text: text)
                    }
                }
                .padding(.top, -3)
            }
            .frame(maxWidth: 640, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A paragraph of a reply. Bulleted and numbered lines get a hanging indent;
/// everything else flows as text.
struct ChatProseView: View {
    let text: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var opacity: Double

    var body: some View {
        // Blank lines separate groups; a group is text and list items that belong together.
        VStack(alignment: .leading, spacing: fontSize * 0.75) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: lineSpacing + 2) {
                    ForEach(Array(ChatProse.pieces(group).enumerated()), id: \.offset) { _, piece in
                        switch piece {
                        case .text(let body):
                            styled(Text(ChatProse.attributed(body)))
                        case .listItem(let marker, let body):
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                styled(Text(marker)).foregroundColor(DS.Colors.textSecondary)
                                styled(Text(ChatProse.attributed(body)))
                            }
                            .padding(.leading, 2)
                        }
                    }
                }
            }
        }
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .foregroundColor(DS.Colors.textPrimary.opacity(opacity))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Light Markdown for replies: **bold**, *italic*, `code`, links, "- " bullets and "#" headings.
enum ChatProse {
    enum Piece: Equatable {
        case text(String)
        case listItem(marker: String, body: String)
    }

    /// Splits a paragraph into runs of plain lines and single list items ("- x", "* x", "3. x").
    static func pieces(_ paragraph: String) -> [Piece] {
        var pieces: [Piece] = []
        var plainLines: [String] = []
        func flush() {
            let joined = plainLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { pieces.append(.text(joined)) }
            plainLines = []
        }
        for line in paragraph.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush()
                pieces.append(.listItem(marker: "•", body: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let number = trimmed.range(of: #"^\d{1,3}[.)] +"#, options: .regularExpression) {
                flush()
                let marker = trimmed[number].trimmingCharacters(in: .whitespaces)
                pieces.append(.listItem(marker: marker, body: String(trimmed[number.upperBound...])))
            } else {
                plainLines.append(line)
            }
        }
        flush()
        return pieces
    }

    static func attributed(_ paragraph: String) -> AttributedString {
        let lines = paragraph.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = trimmed.range(of: #"^#{1,6} +"#, options: .regularExpression) {
                return "**" + trimmed[heading.upperBound...].replacingOccurrences(of: "**", with: "") + "**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(line.prefix { $0 == " " })
                return indent + "•  " + trimmed.dropFirst(2)
            }
            return line
        }
        let prepared = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: prepared, options: options) else {
            return AttributedString(prepared)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: ChatStyle.bodySize - 1, design: .monospaced)
            attributed[run.range].foregroundColor = DS.Colors.codeText
        }
        return attributed
    }
}

struct ChatCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                ChatCopyButton(text: code)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background(Color.white.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(3.5)
                    .foregroundColor(Color(hex: "#D6DEEB"))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
            }
        }
        .background(ChatStyle.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatStyle.cardStroke, lineWidth: 1))
    }
}

struct ChatTypingDots: View {
    var color: Color
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(0.9))
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.7)))
            }
        }
        .frame(height: 16)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
        .accessibilityLabel("Teachy is answering")
    }
}

struct ChatThinkingRow: View {
    var accentColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ChatTeachyMark(color: accentColor, size: 12)
            ChatTypingDots(color: accentColor)
            Text("Thinking")
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

// MARK: - Rows from other parts of the app

struct ChatDrawingRow: View {
    let row: ChatTimelineRow
    let date: Date
    let onOpen: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: "#F4F1E8"))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(Color(hex: "#3B4252"))
                    }
                }
                .frame(width: 104, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil.and.outline")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Drawing")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.floatingGradientOrange)
                    Text(row.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(ChatTimeFormat.time.string(from: date))
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Open")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .bold))
                }
                .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.trailing, 6)
            }
            .padding(8)
            .frame(maxWidth: 480, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(isHovering ? 0.07 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ChatStyle.cardStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .padding(.leading, 26)
        .task(id: row.thumbnailPath) {
            guard let path = row.thumbnailPath else { thumbnail = nil; return }
            thumbnail = NSImage(contentsOfFile: path)
        }
        .accessibilityLabel("Drawing: \(row.title)")
    }
}

struct ChatJobRow: View {
    let row: ChatTimelineRow
    let date: Date
    let onOpen: () -> Void
    @State private var isExpanded = false

    private var status: ChatJobStatus { row.status ?? .running }

    private var tint: Color {
        switch status {
        case .running: return DS.Colors.blue400
        case .waitingForYou: return DS.Colors.warning
        case .done: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .stopped: return DS.Colors.textSecondary
        }
    }

    /// Long answers start folded to six lines with a "Show all" button.
    private func isLong(_ answer: String) -> Bool {
        answer.count > 420 || answer.filter { $0 == "\n" }.count >= 7
    }

    private var iconName: String {
        switch status {
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingForYou: return "hand.raised.fill"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .stopped: return "stop.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tint)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Agent job")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                    Text(row.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(status.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }

            if let answer = row.answer, !answer.isEmpty {
                if isLong(answer) && !isExpanded {
                    Text(ChatProse.attributed(answer))
                        .font(.system(size: 13.5))
                        .lineSpacing(3.5)
                        .foregroundColor(DS.Colors.textPrimary.opacity(0.88))
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ChatProseView(text: answer, fontSize: 13.5, lineSpacing: 3.5, opacity: 0.88)
                }
            }

            HStack(spacing: 6) {
                Text(ChatTimeFormat.time.string(from: date))
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.textTertiary)
                if let answer = row.answer, !answer.isEmpty {
                    ChatCopyButton(text: answer)
                    if isLong(answer) {
                        ChatTextButton(title: isExpanded ? "Show less" : "Show all") { isExpanded.toggle() }
                    }
                }
                Spacer()
                ChatTextButton(title: "Open job", systemImage: "arrow.up.right", action: onOpen)
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ChatStyle.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ChatStyle.cardStroke, lineWidth: 1))
        .padding(.leading, 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent job \(row.title), \(status.label)")
    }
}

struct ChatTextButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(isHovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
    }
}

struct ChatNoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, -4)
    }
}
