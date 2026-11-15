//
//  DictationTextInserter.swift
//  leanring-buddy
//
//  Puts dictated text into the focused field of the app in front.
//  1. Accessibility: set the focused element's selected text (inserts at the caret
//     or replaces the selection), then re-read the field to check it changed.
//     The paste below happens only when the field showed no change at all for the
//     whole (bounded) wait, so the text can't land twice. Apps that ignore the
//     Accessibility edit are remembered for a week and pasted into directly.
//  2. Paste: save the clipboard, write the text marked transient and concealed so
//     clipboard managers skip it, press Command+V using the key that types "v" in
//     the current keyboard layout, then put the old clipboard back.
//  3. No text field in focus: leave the text on the clipboard.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum DictationInsertionOutcome {
    /// Inserted through Accessibility. `baseline` is the field right after the
    /// insertion and `insertedRange` where the text sits in it (UTF-16), when known.
    case accessibility(element: AXUIElement, baseline: String?, insertedRange: NSRange?)
    case pasted
    case copiedToClipboard
    case failed

    var historyLabel: String {
        switch self {
        case .accessibility: return "accessibility"
        case .pasted: return "paste"
        case .copiedToClipboard: return "clipboard"
        case .failed: return "none"
        }
    }
}

enum DictationTextInserter {
    /// Apps that are busy shouldn't hang dictation; the default AX timeout is 6 s.
    private static let accessibilityTimeoutSeconds: Float = 0.6
    /// How long after Command+V before the old clipboard returns. Slow apps read
    /// the clipboard late; restoring sooner makes them paste the old contents.
    private static let clipboardRestoreDelaySeconds: TimeInterval = 0.4
    /// Clipboards bigger than this are not copied aside (it would stall the paste).
    private static let maximumClipboardSnapshotBytes = 50_000_000

    static func insert(_ text: String) async -> DictationInsertionOutcome {
        guard !text.isEmpty else { return .failed }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let focusedElement = focusedElement()
        let role = focusedElement.flatMap { stringAttribute($0, kAXRoleAttribute) }
        let isSelectedTextSettable = focusedElement.map { isSettable($0, kAXSelectedTextAttribute) } ?? false

        switch DictationFocusKind.classify(
            hasFrontmostApp: frontmostApp != nil,
            role: role,
            isSelectedTextSettable: isSelectedTextSettable
        ) {
        case .notText:
            copyToClipboard(text)
            return .copiedToClipboard
        case .textField:
            let bundleIdentifier = frontmostApp?.bundleIdentifier
            if let focusedElement, isSelectedTextSettable,
               !DictationInsertRouteMemory().ignoresAccessibilityInsert(bundleIdentifier: bundleIdentifier),
               let outcome = await insertWithAccessibility(text, into: focusedElement, bundleIdentifier: bundleIdentifier) {
                return outcome
            }
            return await paste(text) ? .pasted : .failed
        case .unknown:
            return await paste(text) ? .pasted : .failed
        }
    }

    // MARK: - Accessibility

    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, accessibilityTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, accessibilityTimeoutSeconds)
        return element
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// One checked Accessibility insertion into `field`. Never pastes.
    static func insertWithAccessibilityOnly(_ text: String, into field: DictationAXField) async -> DictationVerifiedInsert.Outcome {
        await DictationVerifiedInsert.insert(text, into: field) { milliseconds in
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    /// The focused element as an editable field, when dictation can type into it
    /// through Accessibility: a text field whose selected text can be set, in an
    /// app that is not known to ignore such edits, and not a password field.
    static func focusedEditableField() -> DictationAXField? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication, let element = focusedElement() else { return nil }
        guard isSettable(element, kAXSelectedTextAttribute) else { return nil }
        if stringAttribute(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }
        if DictationInsertionRules.isTerminal(bundleIdentifier: frontmostApp.bundleIdentifier) { return nil }
        if DictationInsertRouteMemory().ignoresAccessibilityInsert(bundleIdentifier: frontmostApp.bundleIdentifier) { return nil }
        return DictationAXField(element: element, bundleIdentifier: frontmostApp.bundleIdentifier)
    }

    /// Paste, for callers that already know Accessibility can't be used here.
    static func pasteOnly(_ text: String) async -> DictationInsertionOutcome {
        guard !text.isEmpty else { return .failed }
        return await paste(text) ? .pasted : .failed
    }

    /// Returns nil only when pasting cannot double the text: the field showed no
    /// change at all for the whole wait, or nothing about it could be read (and
    /// then no insertion was tried). A field that changed in any way counts as
    /// inserted, checked or not.
    private static func insertWithAccessibility(
        _ text: String, into element: AXUIElement, bundleIdentifier: String?
    ) async -> DictationInsertionOutcome? {
        let field = DictationAXField(element: element, bundleIdentifier: bundleIdentifier)
        switch await insertWithAccessibilityOnly(text, into: field) {
        case .inserted(let value, let range):
            return .accessibility(element: element, baseline: value, insertedRange: range)
        case .changedUnverified:
            print("⚠️ Dictation: the field changed but the insertion couldn't be checked; not pasting")
            return .accessibility(element: element, baseline: nil, insertedRange: nil)
        case .noEffect:
            DictationInsertRouteMemory().markIgnoresAccessibilityInsert(bundleIdentifier: bundleIdentifier)
            return nil
        case .cannotCheck:
            return nil
        }
    }

    // MARK: - Clipboard

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]]? {
        var total = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maximumClipboardSnapshotBytes { return nil }
                contents[type] = data
            }
            if !contents.isEmpty { items.append(contents) }
        }
        return items
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, transientType, concealedType], owner: nil)
        guard pasteboard.setString(text, forType: .string) else { return false }
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
        let ourChangeCount = pasteboard.changeCount

        guard pressCommandV() else { return false }

        // Put the old clipboard back, but only if nobody copied something else
        // in the meantime. When the old clipboard was too big to set aside, the
        // dictated text simply stays on the clipboard.
        if let saved {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(clipboardRestoreDelaySeconds * 1_000_000_000))
                guard pasteboard.changeCount == ourChangeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
        return true
    }

    // MARK: - Layout-aware Command+V

    private static func pressCommandV() -> Bool {
        let keyCode = CGKeyCode(pasteKeyCode())
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        for event in [keyDown, keyUp] {
            // Only Command, whatever modifiers the person is still holding.
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: DictationHotkeyMonitor.syntheticEventMarker)
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// The key code that types "v" for Command shortcuts in the current layout
    /// (Dvorak, Colemak, AZERTY...), else in the ASCII-capable layout, else ANSI V.
    static func pasteKeyCode() -> UInt16 {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        return DictationPasteKey.keyCodeForV(inLayouts: sources.compactMap { $0 }.map { keyCandidates(in: $0) })
    }

    private static func keyCandidates(in inputSource: TISInputSource) -> [DictationPasteKey.Candidate] {
        guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return [] }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let commandModifierState = UInt32(cmdKey >> 8) & 0xFF

        return layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [DictationPasteKey.Candidate] in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return [] }
            func character(_ keyCode: UInt16, modifiers: UInt32) -> String {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
                )
                guard status == noErr, length > 0 else { return "" }
                return String(utf16CodeUnits: characters, count: length)
            }
            return (0..<UInt16(128)).map { keyCode in
                DictationPasteKey.Candidate(
                    keyCode: keyCode,
                    plain: character(keyCode, modifiers: 0),
                    withCommand: character(keyCode, modifiers: commandModifierState)
                )
            }
        }
    }
}

/// A focused text element, read and edited through Accessibility.
nonisolated final class DictationAXField: DictationEditableField, @unchecked Sendable {
    let element: AXUIElement
    let bundleIdentifier: String?

    init(element: AXUIElement, bundleIdentifier: String?) {
        self.element = element
        self.bundleIdentifier = bundleIdentifier
    }

    func value() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func characterCount() -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    func selectedRange() -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func setSelectedRange(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func setSelectedText(_ text: String) -> DictationFieldSetResult {
        switch AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) {
        case .success: return .accepted
        case .cannotComplete: return .timedOut
        default: return .refused
        }
    }
}
