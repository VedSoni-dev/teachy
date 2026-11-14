//
//  PushToTalkShortcutKeys.swift
//  leanring-buddy
//
//  The two keys the person holds to talk to Teachy. Any two keys work:
//  modifiers (control, option, shift, command, fn) or regular keys (letters,
//  numbers, space, F-keys…). Stored in UserDefaults as macOS virtual key codes.
//

import AppKit
import Carbon.HIToolbox
import Foundation

enum PushToTalkShortcutKeys {
    static let numberOfKeysInShortcut = 2
    static let defaultShortcutKeyCodes: [UInt16] = [UInt16(kVK_Control), UInt16(kVK_Option)]
    static let shortcutDidChangeNotification = Notification.Name("PushToTalkShortcutKeysDidChange")
    private static let userDefaultsKey = "pushToTalkShortcutKeyCodes"

    // MARK: - Stored shortcut

    /// The saved shortcut, already normalized (right-side modifiers map to left-side).
    static var currentShortcutKeyCodes: [UInt16] {
        guard let storedKeyCodes = UserDefaults.standard.array(forKey: userDefaultsKey) as? [Int] else {
            return defaultShortcutKeyCodes
        }
        let normalizedKeyCodes = storedKeyCodes.map { normalizedKeyCode(UInt16($0)) }
        let hasTwoDistinctKeys = Set(normalizedKeyCodes).count == numberOfKeysInShortcut
            && normalizedKeyCodes.count == numberOfKeysInShortcut
        return hasTwoDistinctKeys ? normalizedKeyCodes : defaultShortcutKeyCodes
    }

    static func saveShortcutKeyCodes(_ shortcutKeyCodes: [UInt16]) {
        UserDefaults.standard.set(shortcutKeyCodes.map { Int($0) }, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: shortcutDidChangeNotification, object: nil)
    }

    static func resetToDefaultShortcut() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        NotificationCenter.default.post(name: shortcutDidChangeNotification, object: nil)
    }

    static var isUsingDefaultShortcut: Bool {
        currentShortcutKeyCodes == defaultShortcutKeyCodes
    }

    /// Short labels for key capsules in the UI, e.g. ["control", "option"].
    static var currentKeyCapsuleLabels: [String] {
        currentShortcutKeyCodes.map { displayName(forKeyCode: $0) }
    }

    /// Compact form for inline instructions and spoken prompts, e.g. "ctrl+option".
    static var currentShortcutDisplayText: String {
        currentShortcutKeyCodes.map { compactDisplayName(forKeyCode: $0) }.joined(separator: "+")
    }

    // MARK: - Modifier keys

    /// Left and right versions of a modifier count as the same key, so a person
    /// who records left-control can also hold right-control.
    static func normalizedKeyCode(_ keyCode: UInt16) -> UInt16 {
        switch Int(keyCode) {
        case kVK_RightControl: return UInt16(kVK_Control)
        case kVK_RightOption: return UInt16(kVK_Option)
        case kVK_RightShift: return UInt16(kVK_Shift)
        case kVK_RightCommand: return UInt16(kVK_Command)
        default: return keyCode
        }
    }

    /// The modifier flag a modifier key sets while held, or nil for regular keys.
    /// Caps Lock is left out on purpose: it toggles instead of being held.
    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch Int(normalizedKeyCode(keyCode)) {
        case kVK_Control: return .control
        case kVK_Option: return .option
        case kVK_Shift: return .shift
        case kVK_Command: return .command
        case kVK_Function: return .function
        default: return nil
        }
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        modifierFlag(forKeyCode: keyCode) != nil
    }

    // MARK: - Display names

    static func displayName(forKeyCode keyCode: UInt16) -> String {
        switch Int(normalizedKeyCode(keyCode)) {
        case kVK_Control: return "control"
        case kVK_Option: return "option"
        case kVK_Shift: return "shift"
        case kVK_Command: return "command"
        case kVK_Function: return "fn"
        default: return regularKeyDisplayName(forKeyCode: keyCode)
        }
    }

    static func compactDisplayName(forKeyCode keyCode: UInt16) -> String {
        switch Int(normalizedKeyCode(keyCode)) {
        case kVK_Control: return "ctrl"
        case kVK_Command: return "cmd"
        default: return displayName(forKeyCode: keyCode)
        }
    }

    private static let namedRegularKeys: [Int: String] = [
        kVK_Space: "space", kVK_Return: "return", kVK_Tab: "tab", kVK_Delete: "delete",
        kVK_ForwardDelete: "fwd delete", kVK_Escape: "esc", kVK_CapsLock: "caps lock",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "home", kVK_End: "end", kVK_PageUp: "page up", kVK_PageDown: "page down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Uses the person's current keyboard layout so "A" shows as the letter on their
    /// keyboard, not the US-layout letter for that key position.
    private static func regularKeyDisplayName(forKeyCode keyCode: UInt16) -> String {
        if let namedKey = namedRegularKeys[Int(keyCode)] {
            return namedKey
        }
        if let layoutCharacter = characterFromCurrentKeyboardLayout(forKeyCode: keyCode) {
            return layoutCharacter.uppercased()
        }
        return "key \(keyCode)"
    }

    private static func characterFromCurrentKeyboardLayout(forKeyCode keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var typedCharacters = [UniChar](repeating: 0, count: 4)
        var typedCharacterCount = 0

        let translateStatus = layoutData.withUnsafeBytes { rawLayoutBytes -> OSStatus in
            guard let keyboardLayout = rawLayoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                typedCharacters.count,
                &typedCharacterCount,
                &typedCharacters
            )
        }

        guard translateStatus == noErr, typedCharacterCount > 0 else { return nil }
        let translatedText = String(utf16CodeUnits: typedCharacters, count: typedCharacterCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return translatedText.isEmpty ? nil : translatedText
    }
}
