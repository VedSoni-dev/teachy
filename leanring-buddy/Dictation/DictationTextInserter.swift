//
//  DictationTextInserter.swift
//  leanring-buddy
//
//  Puts dictated text into the focused field of the app in front.
//  1. Accessibility: set the focused element's selected text (inserts at the caret
//     or replaces the selection), then re-read the field to check it changed.
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
            if let focusedElement, isSelectedTextSettable,
               let outcome = await insertWithAccessibility(text, into: focusedElement) {
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

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Returns nil when the insertion can't be confirmed, so the caller pastes.
    /// Many Chromium and Electron fields accept the call and change nothing.
    private static func insertWithAccessibility(_ text: String, into element: AXUIElement) async -> DictationInsertionOutcome? {
        let valueBefore = stringAttribute(element, kAXValueAttribute)
        let countBefore = characterCount(element)
        let rangeBefore = selectedRange(element)
        // Without a way to read the field back there is no way to check the
        // insertion, and guessing wrong means the text lands twice or not at all.
        guard valueBefore != nil || countBefore != nil else { return nil }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return nil
        }

        // Some fields trim the trailing space, so the check looks for the words.
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let insertedLength = (text as NSString).length
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 60_000_000) }
            if let valueBefore {
                guard let valueAfter = stringAttribute(element, kAXValueAttribute),
                      valueAfter != valueBefore, valueAfter.contains(needle)
                else { continue }
                var insertedRange: NSRange?
                let after = valueAfter as NSString
                if let rangeBefore, rangeBefore.location + insertedLength <= after.length,
                   after.substring(with: NSRange(location: rangeBefore.location, length: insertedLength)) == text {
                    insertedRange = NSRange(location: rangeBefore.location, length: insertedLength)
                } else {
                    let found = after.range(of: needle, options: .backwards)
                    if found.location != NSNotFound { insertedRange = found }
                }
                return .accessibility(element: element, baseline: valueAfter, insertedRange: insertedRange)
            } else if let countBefore, let countAfter = characterCount(element), countAfter != countBefore {
                return .accessibility(element: element, baseline: nil, insertedRange: nil)
            }
        }
        return nil
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
