import AppKit
import SwiftUI

/// The compact conversation inside the notch. Its draft follows the user into the chat window.
struct NotchChatView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject private var timeline = ChatTimeline.shared
    @ObservedObject private var shelf = AttachmentShelf.shared
    @ObservedObject private var composerDraft = ChatWindowController.shared.composerDraft
    @ObservedObject private var dictationManager: BuddyDictationManager
    @State private var microphoneTask: Task<Void, Never>?
    @State private var isAtBottom = true
    @FocusState private var composerFocused: Bool
    @State private var isVisible = false
    @State private var isChoosingFiles = false

    init(companionManager: CompanionManager, notchManager: NotchWindowManager) {
        self.companionManager = companionManager
        self.notchManager = notchManager
        self.dictationManager = companionManager.buddyDictationManager
    }

    var body: some View {
        VStack(spacing: 0) {
            thread
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            composer
        }
        .background {
            DS.Colors.workspaceBackground
            Canvas { context, size in
                for x in stride(from: CGFloat(12), to: size.width, by: 16) {
                    for y in stride(from: CGFloat(12), to: size.height, by: 16) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.06)))
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            isVisible = true
            updateInteractionPin()
            timeline.startWatching()
            notchManager.makePanelKey()
        }
        .onChange(of: composerFocused) { _, _ in updateInteractionPin() }
        .onChange(of: composerDraft.text) { _, _ in updateInteractionPin() }
        .onChange(of: dictationManager.isDictationInProgress) { _, _ in updateInteractionPin() }
        .onDisappear {
            isVisible = false
            notchManager.setInteractionPinned(false)
            timeline.stopWatching()
            microphoneTask?.cancel()
            if dictationManager.isMicrophoneButtonSessionBusy {
                dictationManager.stopPersistentDictationFromMicrophoneButton()
            }
        }
    }

    private var thread: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        if timeline.items.isEmpty && !timeline.isWaitingForReply {
                            VStack(spacing: DS.Spacing.sm) {
                                Text("What’s on your mind?")
                                    .font(DS.Fonts.title)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                Text("Ask Teachy, or add a file to talk about.")
                                    .font(DS.Fonts.body)
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.xxxl)
                        }
                        ForEach(timeline.items) { item in
                            ChatItemView(item: item, timeline: timeline)
                        }
                        if timeline.isWaitingForReply { ChatThinkingRow() }
                        Color.clear.frame(height: 1)
                            .id("notch-chat-bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ChatBottomPositionKey.self,
                                                       value: geometry.frame(in: .named("notch-chat-scroll")).maxY)
                            })
                    }
                    .padding(DS.Spacing.md)
                }
                .coordinateSpace(name: "notch-chat-scroll")
                .onPreferenceChange(ChatBottomPositionKey.self) { bottom in
                    isAtBottom = bottom <= viewport.size.height + 36
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: timeline.items) { _, _ in
                    if isAtBottom { proxy.scrollTo("notch-chat-bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        Button {
                            proxy.scrollTo("notch-chat-bottom", anchor: .bottom)
                        } label: { Image(systemName: "arrow.down") }
                            .teachyIconButton(sideLength: 30)
                            .background(DS.Colors.surface3, in: Circle())
                            .padding(DS.Spacing.md)
                            .help("Jump to latest reply")
                            .accessibilityLabel("Jump to latest reply")
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let error = dictationManager.lastErrorMessage {
                Text(error).font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText).lineLimit(2)
            }
            if dictationManager.isMicrophoneButtonSessionBusy {
                Text(dictationManager.isFinalizingTranscript ? "Finishing dictation…" : "Listening… click the microphone to stop")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            AttachmentChipsView(shelf: shelf)
            HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
                Button(action: toggleMicrophone) {
                    Image(systemName: dictationManager.isMicrophoneButtonSessionBusy ? "stop.fill" : "mic.fill")
                }
                .teachyIconButton(sideLength: 40)
                .background(DS.Colors.pointer, in: Circle())
                .foregroundStyle(DS.Colors.onPointer)
                .disabled(dictationManager.isKeyboardShortcutSessionActiveOrFinalizing || dictationManager.isFinalizingTranscript)
                .help("Dictate a message")
                .accessibilityLabel(dictationManager.isMicrophoneButtonSessionBusy ? "Stop dictation" : "Dictate a message")

                HStack(alignment: .bottom, spacing: DS.Spacing.xs) {
                    Button(action: chooseFiles) { Image(systemName: "plus") }
                        .teachyIconButton(sideLength: 28)
                        .help("Attach files")
                        .accessibilityLabel("Attach files")
                    TextField("Ask Teachy", text: $composerDraft.text,
                              prompt: Text("Ask Teachy…").foregroundColor(DS.Colors.textTertiary))
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.sans(ChatStyle.bodySize))
                        .foregroundColor(DS.Colors.textPrimary)
                        .focused($composerFocused)
                        .onSubmit(send)
                        .frame(height: 22)
                        .accessibilityLabel("Ask Teachy")
                    .padding(.vertical, 3)
                    Button { companionManager.speechSynthesizer.stopPlayback() } label: {
                        Image(systemName: "speaker.slash")
                    }
                    .teachyIconButton(sideLength: 28)
                    .help("Stop spoken reply")
                    .accessibilityLabel("Stop spoken reply")
                    Button(action: send) { Image(systemName: "arrow.up") }
                        .teachyIconButton(sideLength: 28)
                        .background(canSend ? DS.Colors.pointer : DS.Colors.fillSecondary, in: Circle())
                        .disabled(!canSend)
                        .help("Send (Return)")
                        .accessibilityLabel("Send message")
                }
                .padding(5)
                .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(composerFocused ? DS.Colors.pointer : DS.Colors.hairlineStrong, lineWidth: composerFocused ? 2 : 1).allowsHitTesting(false))

                Button {
                    notchManager.collapse()
                    ChatWindowController.shared.show()
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .teachyIconButton(sideLength: 30)
                    .padding(.bottom, 5)
                    .help("Open chat window")
                    .accessibilityLabel("Open chat window")
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface1)
    }

    private func updateInteractionPin() {
        notchManager.setInteractionPinned(isVisible && (composerFocused || !composerDraft.text.isEmpty || dictationManager.isDictationInProgress || isChoosingFiles))
    }

    private var canSend: Bool {
        !composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !dictationManager.isDictationInProgress
            && !shelf.items.contains { if case .reading = $0.state { return true }; return false }
    }

    private func send() {
        guard canSend else { return }
        let question = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        companionManager.submitSyntheticCompanionRequest(question)
        timeline.userAsked(question)
        composerDraft.text = ""
        isAtBottom = true
        notchManager.makePanelKey()
    }

    private func chooseFiles() {
        isChoosingFiles = true
        updateInteractionPin()
        defer {
            isChoosingFiles = false
            updateInteractionPin()
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        if panel.runModal() == .OK { shelf.add(urls: panel.urls) }
        notchManager.makePanelKey()
    }

    private func toggleMicrophone() {
        if dictationManager.isMicrophoneButtonSessionBusy {
            microphoneTask?.cancel()
            dictationManager.stopPersistentDictationFromMicrophoneButton()
            return
        }
        guard !dictationManager.isDictationInProgress else { return }
        microphoneTask = Task {
            await dictationManager.startPersistentDictationFromMicrophoneButton(
                currentDraftText: composerDraft.text,
                updateDraftText: { composerDraft.text = $0 },
                submitDraftText: { composerDraft.text = $0 }
            )
        }
    }
}

private struct ChatBottomPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
