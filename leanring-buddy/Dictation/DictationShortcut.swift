//
//  DictationShortcut.swift
//  leanring-buddy
//
//  The keys the person holds to dictate (double-tap for hands-free). Default is
//  Fn + Control, but many keyboards have no Fn key the Mac can see, so any of
//  these work: two or three modifier keys, a modifier plus one other key, or a
//  single function key (F1–F20). Pure logic: key codes as numbers, no AppKit.
//

import Foundation

nonisolated enum DictationShortcut {
    // macOS virtual key codes.
    static let controlKey: UInt16 = 59, optionKey: UInt16 = 58, shiftKey: UInt16 = 56
    static let commandKey: UInt16 = 55, functionKey: UInt16 = 63, escapeKey: UInt16 = 53
    private static let rightSideModifiers: [UInt16: UInt16] = [62: 59, 61: 58, 60: 56, 54: 55]
    private static let functionRowKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static let defaultKeyCodes: [UInt16] = [functionKey, controlKey]
    static let defaultsKey = "teachyDictationShortcutKeyCodes"
    static let didChangeNotification = Notification.Name("TeachyDictationShortcutDidChange")

    // MARK: - Stored value

    static func current(_ defaults: UserDefaults = .standard) -> [UInt16] {
        guard let stored = defaults.array(forKey: defaultsKey) as? [Int] else { return defaultKeyCodes }
        let codes = orderedForDisplay(stored.map { normalized(UInt16(truncatingIfNeeded: $0)) })
        return validationProblem(codes, pushToTalk: []) == nil ? codes : defaultKeyCodes
    }

    static func save(_ keyCodes: [UInt16], _ defaults: UserDefaults = .standard) {
        defaults.set(orderedForDisplay(keyCodes.map(normalized)).map { Int($0) }, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Keys

    /// Left and right versions of a modifier are the same key.
    static func normalized(_ keyCode: UInt16) -> UInt16 { rightSideModifiers[keyCode] ?? keyCode }

    static func isModifier(_ keyCode: UInt16) -> Bool {
        [controlKey, optionKey, shiftKey, commandKey, functionKey].contains(normalized(keyCode))
    }

    static func isFunctionRowKey(_ keyCode: UInt16) -> Bool { functionRowKeys.contains(keyCode) }

    /// Modifiers first (fn, control, option, shift, command), then the other key.
    static func orderedForDisplay(_ keyCodes: [UInt16]) -> [UInt16] {
        let order: [UInt16] = [functionKey, controlKey, optionKey, shiftKey, commandKey]
        var seen = Set<UInt16>()
        let unique = keyCodes.filter { seen.insert($0).inserted }
        return order.filter(unique.contains) + unique.filter { !order.contains($0) }
    }

    /// The modifier keys held, from a CGEventFlags raw value.
    static func heldModifiers(flagsRawValue: UInt64) -> Set<UInt16> {
        var held = Set<UInt16>()
        if flagsRawValue & DictationChord.controlMask != 0 { held.insert(controlKey) }
        if flagsRawValue & DictationChord.optionMask != 0 { held.insert(optionKey) }
        if flagsRawValue & DictationChord.shiftMask != 0 { held.insert(shiftKey) }
        if flagsRawValue & DictationChord.commandMask != 0 { held.insert(commandKey) }
        if flagsRawValue & DictationChord.functionMask != 0 { held.insert(functionKey) }
        return held
    }

    // MARK: - Rules

    /// Nil when `keyCodes` can be the dictation shortcut, otherwise what to tell the person.
    static func validationProblem(_ keyCodes: [UInt16], pushToTalk: [UInt16]) -> String? {
        let codes = Set(keyCodes.map(normalized))
        let modifiers = codes.filter(isModifier)
        let otherKeys = codes.subtracting(modifiers)

        if codes.isEmpty { return "No keys pressed. Try again." }
        if codes.contains(escapeKey) { return "Escape cancels dictation, so it can't be part of the shortcut." }
        if codes.count > 3 { return "That's a lot of keys. Use two or three." }
        if otherKeys.count > 1 { return "Use modifier keys plus at most one other key." }
        if otherKeys.isEmpty && modifiers.count < 2 {
            return "One modifier key on its own would fire all the time. Hold two, or use a function key."
        }
        if modifiers.isEmpty, let onlyKey = otherKeys.first, !isFunctionRowKey(onlyKey) {
            return "A letter or number on its own would stop you typing it. Add a modifier, or use a function key."
        }
        if !pushToTalk.isEmpty, codes == Set(pushToTalk.map(normalized)) {
            return "Those keys already start a voice question. Pick different ones."
        }
        return nil
    }

    /// True when exactly the shortcut is held: all of its keys, and no extra modifier
    /// (an extra modifier means the person is pressing some other shortcut).
    static func isHeld(shortcut: [UInt16], heldModifiers: Set<UInt16>, heldOtherKeys: Set<UInt16>) -> Bool {
        let codes = Set(shortcut.map(normalized))
        let wantedModifiers = codes.filter(isModifier)
        let wantedOtherKeys = codes.subtracting(wantedModifiers)
        return heldModifiers == wantedModifiers && wantedOtherKeys.isSubset(of: heldOtherKeys)
    }

    /// The non-modifier key of the shortcut, if it has one. Its key presses are kept
    /// away from the app in front while the shortcut's modifiers are held.
    static func otherKey(of shortcut: [UInt16]) -> UInt16? {
        shortcut.map(normalized).first { !isModifier($0) }
    }
}
