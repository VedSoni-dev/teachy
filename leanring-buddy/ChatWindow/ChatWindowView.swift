//
//  ChatWindowView.swift
//  leanring-buddy
//
//  The contents of the chat window: a search field, the conversation grouped by
//  day (messages, drawings, agent jobs, notes), and a composer with attachment
//  chips and the "hold to talk" hint.
//
//  It reads like Messages: Teachy's replies are plain unboxed text on the left,
//  the person's own words are a bubble in their pointer colour on the right,
//  and jobs and drawings are rows of a grouped list. Colours, fonts and
//  controls come from the design system (docs/DESIGN.md).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sizes used only by the chat window. Colours and fonts come from the design system.
enum ChatStyle {
    /// The window is not part of the notch, so it is the macOS dark window grey, not pure black.
    static let windowBackground = DS.Colors.background
    /// The size of the conversation's text: Teachy's replies, the person's bubbles and the composer.
    static let bodySize: CGFloat = 13.5
    static let bodyLineSpacing: CGFloat = 4
    /// The size and line spacing of `DS.Fonts.voice`, for what a job answered. Kept
    /// as numbers because bold and inline code inside the answer are set from them.
    static let voiceSize: CGFloat = 13
    static let voiceLineSpacing: CGFloat = 3
    static let columnWidth: CGFloat = 760
    /// How wide a reply runs before it wraps.
    static let readingWidth: CGFloat = 600
    /// The margin left of the reading column. Teachy's pointer mark hangs in it.
    static let gutterWidth: CGFloat = 22
    static let headerHeight: CGFloat = 52
    /// The attach and send buttons at either end of the composer.
    static let composerButtonSideLength: CGFloat = 26
    /// Above and below the content of a job or drawing row in its group.
    static let groupedRowVerticalPadding: CGFloat = 11
}

struct ChatWindowView: View {
    @ObservedObject var timeline: ChatTimeline
    @ObservedObject var shelf: AttachmentShelf
    /// No longer read: Teachy's marks use `DS.Colors.pointer`, which follows the
    /// person's colour choice the next time the view is drawn. Kept because
    /// `ChatWindowController` passes it.
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
        accentColor: Color = DS.Colors.pointer,
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
            TeachyRule()
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
        HStack(spacing: 8) {
            Color.clear.frame(width: max(0, leadingHeaderInset - 16), height: 1)

            ChatTeachyMark(color: DS.Colors.pointer, size: 12)
            Text("Teachy")
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)

            Spacer(minLength: 12)

            searchField
        }
        .padding(.horizontal, 16)
        .frame(height: ChatStyle.headerHeight)
        .background(ChatStyle.windowBackground)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Fonts.sans(11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            TextField(
                "Search this chat",
                text: $searchText,
                prompt: Text("Search this chat").foregroundColor(DS.Colors.textQuaternary)
            )
            .textFieldStyle(.plain)
            .font(DS.Fonts.body)
            .foregroundColor(DS.Colors.textPrimary)
            .focused($searchFocused)
            if isSearching {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark")
                }
                .teachyIconButton(sideLength: 18)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, isSearching ? 5 : 9)
        .frame(height: 28)
        .frame(maxWidth: 230)
        .teachyWell()
        .overlay(
            // The well takes a tint edge while the field has the keyboard.
            RoundedRectangle(cornerRadius: DS.CornerRadius.well, style: .continuous)
                .strokeBorder(searchFocused ? DS.Colors.pointer : Color.clear, lineWidth: 1.5)
        )
        .animation(DS.Motion.hover, value: searchFocused)
        // Command+F from anywhere in the window.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
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
                                .font(DS.Fonts.data)
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.top, 16)
                        }
                        ForEach(ChatThread.days(items)) { day in
                            ChatDaySeparator(label: day.label)
                                .padding(.top, 22)
                                .padding(.bottom, 18)
                            let sections = ChatThreadSection.sections(for: day.items)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(sections.enumerated()), id: \.element.id) { positionInDay, section in
                                    let sectionAbove = positionInDay > 0 ? sections[positionInDay - 1] : nil
                                    Group {
                                        switch section {
                                        case .item(let item):
                                            ChatItemView(item: item, timeline: timeline)
                                        case .rowGroup(let groupedItems):
                                            ChatRowGroup(items: groupedItems, timeline: timeline)
                                        }
                                    }
                                    .padding(.top, ChatThreadSpacing.spaceAbove(section, below: sectionAbove))
                                }
                            }
                        }
                        if timeline.isWaitingForReply {
                            ChatThinkingRow()
                                .padding(.top, ChatThreadSpacing.betweenItems)
                        }
                        Color.clear.frame(height: 24).id("chat-bottom")
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

    /// One line that says what this surface is for, and one line under it.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if isSearching {
                Text("Nothing in this chat matches “\(searchText.trimmingCharacters(in: .whitespaces))”")
                    .font(DS.Fonts.display)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Ask Teachy anything")
                    .font(DS.Fonts.display)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Type below, hold your talk keys, or drop a file here to ask about it.")
                    .font(DS.Fonts.body)
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
        VStack(alignment: .leading, spacing: 8) {
            // The chips sit above the field, not inside it: no box inside a box.
            AttachmentChipsView(shelf: shelf)

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip")
                }
                .teachyIconButton(sideLength: ChatStyle.composerButtonSideLength)
                .help("Attach a file")
                .accessibilityLabel("Attach a file")

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask Teachy…")
                            .font(DS.Fonts.sans(ChatStyle.bodySize))
                            .foregroundColor(DS.Colors.textQuaternary)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                    ChatComposerTextView(text: $draft, height: $composerHeight, fontSize: ChatStyle.bodySize, onSubmit: send)
                        .frame(height: composerHeight)
                }
                .padding(.vertical, 2)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(ChatSendButtonStyle())
                .disabled(!canSend)
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .teachyWell(cornerRadius: 16, isEdged: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    talkHint
                    Spacer(minLength: 16)
                    sendHint
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
            Text("Hold")
            ForEach(Array(keyLabels.enumerated()), id: \.offset) { _, label in
                KeyboardKeyLabel(text: label)
            }
            Text("to talk")
        }
        .font(DS.Fonts.caption)
        .foregroundColor(DS.Colors.textSecondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold \(keyLabels.joined(separator: " and ")) to talk")
    }

    private var sendHint: some View {
        HStack(spacing: 5) {
            KeyboardKeyLabel(text: "return")
            Text("to send")
                .padding(.trailing, 7)
            KeyboardKeyLabel(text: "shift")
            KeyboardKeyLabel(text: "return")
            Text("for a new line")
        }
        .font(DS.Fonts.caption)
        .foregroundColor(DS.Colors.textSecondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return to send  ·  Shift + Return for a new line")
    }
}

// MARK: - Thread layout

private extension ChatThreadItem {
    /// An agent job or a drawing: a row of a grouped list, not a message.
    var isGroupedRow: Bool {
        if case .row(let row) = content { return row.kind == .job || row.kind == .drawing }
        return false
    }

    var isNote: Bool {
        if case .row(let row) = content { return row.kind == .note }
        return false
    }
}

/// One stretch of a day's thread: a message or a note on its own, or the jobs
/// and drawings that follow one another, which share one grouped container.
private enum ChatThreadSection: Identifiable {
    case item(ChatThreadItem)
    case rowGroup([ChatThreadItem])

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .rowGroup(let groupedItems): return "row-group-" + (groupedItems.first?.id ?? "")
        }
    }

    var isNote: Bool {
        if case .item(let item) = self { return item.isNote }
        return false
    }

    /// Folds neighbouring jobs and drawings into one group. Everything else stays on its own.
    static func sections(for items: [ChatThreadItem]) -> [ChatThreadSection] {
        var sections: [ChatThreadSection] = []
        for item in items {
            guard item.isGroupedRow else {
                sections.append(.item(item))
                continue
            }
            if case .rowGroup(let groupedItems) = sections.last {
                sections[sections.count - 1] = .rowGroup(groupedItems + [item])
            } else {
                sections.append(.rowGroup([item]))
            }
        }
        return sections
    }
}

/// How far apart the things in the thread sit.
private enum ChatThreadSpacing {
    static let betweenItems: CGFloat = 20
    /// A note is one small line, so it sits closer to its neighbours.
    static let aroundNote: CGFloat = 12

    static func spaceAbove(_ section: ChatThreadSection, below sectionAbove: ChatThreadSection?) -> CGFloat {
        guard let sectionAbove else { return 0 }
        if section.isNote || sectionAbove.isNote { return aroundNote }
        return betweenItems
    }
}

// MARK: - Small pieces

/// Teachy's pointer, drawn small. Grey beside a finished reply; the person's
/// pointer colour in the header and where Teachy is live.
struct ChatTeachyMark: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        TeachyPointerShape()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The pointer in the person's colour: Teachy is thinking or still writing.
/// It breathes slowly while there is nothing else moving (thinking); beside a
/// reply that is arriving it holds still, because the caret after the text
/// already blinks. Always still when Reduce Motion is on.
struct ChatLivePointerMark: View {
    var size: CGFloat = 11
    var isBreathing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        TeachyPointerShape()
            .fill(DS.Colors.pointer)
            .frame(width: size, height: size)
            .opacity(isDimmed ? 0.4 : 1)
            .onAppear {
                guard isBreathing, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDimmed = true }
            }
            .accessibilityLabel("Teachy is answering")
    }
}

/// The send button, as in Messages: a circle in the person's pointer colour
/// with an arrow. Grey while there is nothing to send.
private struct ChatSendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatSendButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// A view (not just a style) so it can read whether the button is enabled.
private struct ChatSendButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(DS.Fonts.sans(12, weight: .bold))
            .foregroundColor(isEnabled ? DS.Colors.onPointer : DS.Colors.textQuaternary)
            .frame(width: ChatStyle.composerButtonSideLength, height: ChatStyle.composerButtonSideLength)
            .background(Circle().fill(isEnabled ? DS.Colors.pointer : DS.Colors.fillSecondary))
            .contentShape(Circle())
            // Feedback starts on mouse-down, like the other Teachy buttons.
            .opacity(isPressed ? 0.8 : 1)
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(DS.Motion.press, value: isPressed)
            .animation(DS.Motion.hover, value: isEnabled)
            .pointerCursor(isEnabled: isEnabled)
    }
}

/// The day a stretch of the conversation happened on, centred above it.
struct ChatDaySeparator: View {
    let label: String

    var body: some View {
        Text(label)
            .font(DS.Fonts.caption)
            .fontWeight(.semibold)
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
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

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
        } label: {
            if showsLabel {
                Text(didCopy ? "Copied" : "Copy")
            } else {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        // Grey, not the tint: it repeats under every reply, so it should recede.
        .teachyLinkButton(color: DS.Colors.textSecondary)
        .accessibilityLabel("Copy")
    }
}

// MARK: - One item in the thread

struct ChatItemView: View {
    let item: ChatThreadItem
    let timeline: ChatTimeline

    var body: some View {
        switch item.content {
        case .userMessage(let text):
            ChatUserBubble(text: text, date: item.date)
        case .assistantMessage(let text):
            ChatAssistantMessage(text: text, date: item.date, isStreaming: false)
        case .streamingReply(let text):
            ChatAssistantMessage(text: text, date: item.date, isStreaming: true)
        case .row(let row):
            switch row.kind {
            case .drawing, .job:
                // On its own, a job or a drawing is a group of one row.
                ChatRowGroup(items: [item], timeline: timeline)
            case .note:
                ChatNoteRow(text: row.title)
            }
        }
    }
}

/// Jobs and drawings that follow one another, as one grouped list: each is a
/// row of the same rounded container, with a divider between rows.
struct ChatRowGroup: View {
    let items: [ChatThreadItem]
    let timeline: ChatTimeline

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { positionInGroup, item in
                if positionInGroup > 0 { TeachyRule() }
                rowView(for: item)
            }
        }
        .teachyGroup()
        .frame(maxWidth: ChatStyle.readingWidth, alignment: .leading)
        // Lines the container up with the text of Teachy's replies.
        .padding(.leading, ChatStyle.gutterWidth)
    }

    @ViewBuilder
    private func rowView(for item: ChatThreadItem) -> some View {
        if case .row(let row) = item.content {
            switch row.kind {
            case .drawing:
                ChatDrawingRow(row: row, date: item.date) { timeline.onOpenDrawing?(String(row.id.dropFirst("drawing-".count))) }
            case .job:
                ChatJobRow(row: row, date: item.date) { timeline.onOpenJob?(String(row.id.dropFirst("job-".count))) }
            case .note:
                EmptyView()
            }
        }
    }
}

/// What the person said: a bubble in their pointer colour, on the right.
struct ChatUserBubble: View {
    let text: String
    let date: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(DS.Fonts.sans(ChatStyle.bodySize))
                .lineSpacing(ChatStyle.bodyLineSpacing - 1)
                .foregroundColor(DS.Colors.onPointer)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.pointer))
                .frame(maxWidth: 520, alignment: .trailing)
            Text(ChatTimeFormat.time.string(from: date))
                .font(DS.Fonts.data)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

/// What Teachy said: plain text, unboxed, in a column narrow enough to read.
struct ChatAssistantMessage: View {
    let text: String
    let date: Date
    var isStreaming: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When this reply started to be shown, so the caret's blink starts lit.
    @State private var caretBlinkStartDate = Date()

    private static let caretBlinkInterval: TimeInterval = 0.55

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if isStreaming {
                    ChatLivePointerMark(isBreathing: false)
                } else {
                    ChatTeachyMark(color: DS.Colors.textTertiary, size: 11)
                }
            }
            .frame(width: ChatStyle.gutterWidth, alignment: .leading)
            // Sits the mark on the middle of the first line of text.
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 12) {
                if isStreaming && !reduceMotion {
                    TimelineView(.periodic(from: caretBlinkStartDate, by: Self.caretBlinkInterval)) { timelineContext in
                        replyBlocks(streamingCaretColor: caretColor(at: timelineContext.date))
                    }
                } else {
                    replyBlocks(streamingCaretColor: isStreaming ? DS.Colors.pointer : nil)
                }

                if !isStreaming {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(ChatTimeFormat.time.string(from: date))
                            .font(DS.Fonts.data)
                            .foregroundColor(DS.Colors.textTertiary)
                        ChatCopyButton(text: text)
                    }
                }
            }
            .frame(maxWidth: ChatStyle.readingWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The caret after the last word is lit for one interval, then faint for the next.
    private func caretColor(at date: Date) -> Color {
        let intervalsSinceStart = Int(date.timeIntervalSince(caretBlinkStartDate) / Self.caretBlinkInterval)
        return intervalsSinceStart.isMultiple(of: 2) ? DS.Colors.pointer : DS.Colors.pointer.opacity(0.25)
    }

    /// The reply's paragraphs and code blocks. `streamingCaretColor` is nil for a finished reply.
    private func replyBlocks(streamingCaretColor: Color?) -> some View {
        let blocks = ChatReplyText.blocks(text)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { blockPosition, block in
                switch block {
                case .paragraph(let paragraph):
                    ChatProseView(
                        text: paragraph,
                        fontSize: ChatStyle.bodySize,
                        lineSpacing: ChatStyle.bodyLineSpacing,
                        // Only the last block is still being written.
                        streamingCaretColor: blockPosition == blocks.count - 1 ? streamingCaretColor : nil
                    )
                case .code(let language, let code):
                    ChatCodeBlock(language: language, code: code)
                }
            }
        }
    }
}

/// A paragraph of a reply. Bulleted and numbered lines get a hanging indent;
/// everything else flows as text.
struct ChatProseView: View {
    let text: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    /// Set while the reply is still arriving: a caret in this colour follows the last word.
    var streamingCaretColor: Color? = nil

    var body: some View {
        // Blank lines separate groups; a group is text and list items that belong together.
        let groups = text.components(separatedBy: "\n\n")
        VStack(alignment: .leading, spacing: fontSize * 0.75) {
            ForEach(Array(groups.enumerated()), id: \.offset) { groupPosition, group in
                let pieces = ChatProse.pieces(group)
                VStack(alignment: .leading, spacing: lineSpacing + 2) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { piecePosition, piece in
                        let isLastPieceOfReply = groupPosition == groups.count - 1 && piecePosition == pieces.count - 1
                        switch piece {
                        case .text(let body):
                            styled(Text(attributedText(body, endsWithCaret: isLastPieceOfReply)), color: DS.Colors.textPrimary)
                        case .listItem(let marker, let body):
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                styled(Text(marker), color: DS.Colors.textTertiary)
                                    .frame(width: markerColumnWidth(for: marker), alignment: .leading)
                                styled(Text(attributedText(body, endsWithCaret: isLastPieceOfReply)), color: DS.Colors.textPrimary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every marker gets the same column, so the text of each item starts on one
    /// line and wraps under itself. Numbers ("12.") need a wider column than a bullet.
    private func markerColumnWidth(for marker: String) -> CGFloat {
        marker == "•" ? fontSize * 1.05 : fontSize * 1.6
    }

    private func attributedText(_ body: String, endsWithCaret: Bool) -> AttributedString {
        var attributed = ChatProse.attributed(body, fontSize: fontSize)
        if endsWithCaret, let streamingCaretColor {
            // A thin bar, like the text system's insertion point.
            var caret = AttributedString(" \u{258F}")
            caret.foregroundColor = streamingCaretColor
            attributed.append(caret)
        }
        return attributed
    }

    private func styled(_ text: Text, color: Color) -> some View {
        text
            .font(DS.Fonts.sans(fontSize))
            .lineSpacing(lineSpacing)
            .foregroundColor(color)
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

    /// `fontSize` is the size the text will be set in: bold becomes semibold at
    /// that size, and inline code becomes mono a little smaller.
    static func attributed(_ paragraph: String, fontSize: CGFloat = ChatStyle.bodySize) -> AttributedString {
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
        for run in attributed.runs {
            guard let presentationIntent = run.inlinePresentationIntent else { continue }
            if presentationIntent.contains(.code) {
                // Mono looks larger than the text around it at the same size.
                attributed[run.range].font = DS.Fonts.mono(fontSize - 1)
                attributed[run.range].foregroundColor = DS.Colors.textPrimary
            } else if presentationIntent.contains(.stronglyEmphasized) {
                // The weight is set here, so the "bold" intent is taken off the run:
                // left on, it would be applied on top and give a heavier weight than semibold.
                attributed[run.range].font = DS.Fonts.sans(fontSize, weight: .semibold)
                attributed[run.range].inlinePresentationIntent = presentationIntent.subtracting(.stronglyEmphasized)
            }
        }
        return attributed
    }
}

/// A block of code in a reply: mono, in a well, with its language and a Copy link.
struct ChatCodeBlock: View {
    let language: String?
    let code: String

    private var wellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.well, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(language ?? "code")
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                ChatCopyButton(text: code)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(DS.Fonts.mono(12.5))
                    .lineSpacing(3.5)
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 13)
            }
        }
        .teachyWell()
        // Long lines scroll sideways; this keeps them inside the well's corners.
        .clipShape(wellShape)
    }
}

/// Shown between a question and the first words of its answer.
struct ChatThinkingRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ChatLivePointerMark()
                .frame(width: ChatStyle.gutterWidth, alignment: .leading)
            Text("Thinking")
                .font(DS.Fonts.data)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

// MARK: - Rows from other parts of the app

/// A drawing Teachy made, as a row of a grouped list: its picture, its name and
/// when. The whole row opens the drawing.
struct ChatDrawingRow: View {
    let row: ChatTimelineRow
    let date: Date
    let onOpen: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private var thumbnailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    thumbnailShape.fill(DS.Colors.fillTertiary)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "scribble.variable")
                            .font(DS.Fonts.sans(18, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .frame(width: 84, height: 56)
                .clipShape(thumbnailShape)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(DS.Fonts.itemTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Drawing · \(ChatTimeFormat.time.string(from: date))")
                        .font(DS.Fonts.data)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                // Drawn like `.teachyLinkButton()` (tint, brighter on hover), but it is
                // not a button of its own: the whole row is the button.
                HStack(spacing: 3) {
                    Text("Open")
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                }
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.pointer)
                .brightness(isHovering ? 0.12 : 0)
            }
            .padding(.vertical, ChatStyle.groupedRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(DS.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .task(id: row.thumbnailPath) {
            guard let path = row.thumbnailPath else { thumbnail = nil; return }
            thumbnail = NSImage(contentsOfFile: path)
        }
        .accessibilityLabel("Drawing: \(row.title)")
    }
}

/// An agent job in the conversation, as a row of a grouped list: a status
/// mark, the job's name, its state and time, what it answered, and "Open job".
struct ChatJobRow: View {
    let row: ChatTimelineRow
    let date: Date
    let onOpen: () -> Void
    @State private var isExpanded = false

    private var status: ChatJobStatus { row.status ?? .running }

    /// The symbol says the state; see `TeachyStatusMark`.
    private var statusMarkKind: TeachyStatusKind {
        switch status {
        case .running: return .live
        case .waitingForYou: return .needsYou
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    /// Long answers start folded to six lines with a "Show all" button.
    private func isLong(_ answer: String) -> Bool {
        answer.count > 420 || answer.filter { $0 == "\n" }.count >= 7
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            TeachyStatusMark(kind: statusMarkKind)
                // Drops the symbol so it sits level with the job's name.
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] - 2.5 }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(DS.Fonts.itemTitle)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(status.label)
                                .foregroundColor(DS.Colors.textSecondary)
                            Text(" · \(ChatTimeFormat.time.string(from: date))")
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .font(DS.Fonts.data)
                    }
                    Spacer(minLength: 8)
                    ChatTextButton(title: "Open job", systemImage: "arrow.up.right", action: onOpen)
                }

                if let answer = row.answer, !answer.isEmpty {
                    if isLong(answer) && !isExpanded {
                        Text(ChatProse.attributed(answer, fontSize: ChatStyle.voiceSize))
                            .font(DS.Fonts.voice)
                            .lineSpacing(ChatStyle.voiceLineSpacing)
                            .foregroundColor(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ChatProseView(text: answer, fontSize: ChatStyle.voiceSize, lineSpacing: ChatStyle.voiceLineSpacing)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        ChatCopyButton(text: answer)
                        if isLong(answer) {
                            ChatTextButton(title: isExpanded ? "Show less" : "Show all") { isExpanded.toggle() }
                        }
                    }
                }
            }
        }
        .padding(.vertical, ChatStyle.groupedRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent job \(row.title), \(status.label)")
    }
}

/// A text button in the thread ("Open job", "Show all").
struct ChatTextButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
            }
        }
        .teachyLinkButton()
    }
}

/// Something that happened ("Attached report.pdf"): one small centred line.
struct ChatNoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
