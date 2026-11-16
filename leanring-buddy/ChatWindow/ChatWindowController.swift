//
//  ChatWindowController.swift
//  leanring-buddy
//
//  The chat window: a normal macOS window (title bar buttons, resizable,
//  minimisable) that remembers where it was, and opens with Control+Command+A
//  from anywhere or with `ChatWindowController.shared.show()`.
//
//  Setup, once, from the app delegate:
//      ChatWindowController.shared.install(onSubmit: { companionManager.submitSyntheticCompanionRequest($0) })
//
//  The hotkey is a Carbon hot key (RegisterEventHotKey). It needs no
//  Accessibility or Input Monitoring permission, and it only ever sees this one
//  key combination.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    static let shared = ChatWindowController()

    static let frameAutosaveName = "TeachyChatWindow"
    static let defaultSize = NSSize(width: 780, height: 760)
    static let minimumSize = NSSize(width: 440, height: 420)

    /// Where typed questions go. Set by `install(onSubmit:)`.
    var onSubmit: (String) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    /// The person's cursor colour. The view no longer reads it (its marks use
    /// `DS.Colors.pointer`, which follows a new colour choice); kept because the app sets it.
    var accentColor: Color = DS.Colors.pointer

    let composerDraft = ChatComposerDraft()

    private var window: NSWindow?
    private var isWatching = false
    private let hotkey = ChatWindowHotkey()

    var isVisible: Bool { window?.isVisible ?? false }

    /// Wires the composer and registers Control+Command+A.
    func install(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        hotkey.register { [weak self] in self?.toggle() }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !isWatching {
            isWatching = true
            ChatTimeline.shared.startWatching()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusComposer()
    }

    func close() {
        window?.performClose(nil)
    }

    /// The hotkey: bring the window forward, or close it when it is already in front.
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            window.performClose(nil)
        } else {
            show()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.contentView = Self.contentView(for: ChatWindowView(
            timeline: ChatTimeline.shared,
            accentColor: accentColor,
            composerDraft: composerDraft,
            onOpenSettings: { [weak self] in self?.onOpenSettings() },
            onSubmit: { [weak self] text in self?.onSubmit(text) }
        ))
        Self.style(window)
        window.center()
        // Restores the last position and size, and saves them from now on.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        return window
    }

    /// The content drawn under the transparent title bar, edge to edge.
    static func contentView(for view: ChatWindowView) -> NSView {
        let hostingView = NSHostingView(rootView: view.ignoresSafeArea())
        // The window's own minimum size applies, not one derived from the content.
        hostingView.sizingOptions = []
        return hostingView
    }

    /// The window's look, shared with the screenshot renderer.
    static func style(_ window: NSWindow) {
        window.title = "Teachy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(ChatSurfacePalette.sidebar)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        // The traffic lights sit centred in the 52-point header drawn by the content.
        let toolbar = NSToolbar(identifier: "TeachyChatToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    private func focusComposer() {
        guard let window, let contentView = window.contentView else { return }
        func find(in view: NSView) -> ChatComposerNSTextView? {
            if let textView = view as? ChatComposerNSTextView { return textView }
            for subview in view.subviews {
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        DispatchQueue.main.async {
            if let textView = find(in: contentView) { window.makeFirstResponder(textView) }
        }
    }

    // MARK: NSWindowDelegate

    /// SwiftUI's hosting view clears the window's minimum size on its first layout,
    /// so the minimum is enforced here, where nothing can reset it.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        Self.clamped(frameSize)
    }

    static func clamped(_ size: NSSize) -> NSSize {
        NSSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    func windowWillClose(_ notification: Notification) {
        guard isWatching else { return }
        isWatching = false
        ChatTimeline.shared.stopWatching()
    }
}

// MARK: - Hotkey

/// Control+Command+A through the Carbon hot key API.
@MainActor
final class ChatWindowHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static let signature: OSType = 0x5443_4857 // "TCHW"
    private let identifier: UInt32 = 1

    /// The last registration result: `noErr` when the hotkey is active.
    private(set) var status: OSStatus = OSStatus(eventNotHandledErr)

    var isRegistered: Bool { hotKeyRef != nil }

    @discardableResult
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_A),
        modifiers: UInt32 = UInt32(controlKey | cmdKey),
        action: @escaping () -> Void
    ) -> Bool {
        unregister()
        Self.handlers[identifier] = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == 0x5443_4857 else { return OSStatus(eventNotHandledErr) }
            let pressed = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ChatWindowHotkey.handlers[pressed]?() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else {
            status = installStatus
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            print("⚠️ Chat window hotkey not registered (status \(status)); another app may own Control+Command+A")
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        Self.handlers[identifier] = nil
    }
}
