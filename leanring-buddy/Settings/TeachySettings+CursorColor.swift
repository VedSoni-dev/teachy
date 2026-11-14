//
//  TeachySettings+CursorColor.swift
//  leanring-buddy
//
//  The cursor colour as its real type. Kept out of TeachySettings.swift so that
//  file stays free of SwiftUI and can be unit-tested on its own.
//

import AppKit
import SwiftUI

extension TeachySettings {
    var cursorColor: ClickyCursorColor {
        get { ClickyCursorColor(rawValue: cursorColorName) ?? .blue }
        set { cursorColorName = newValue.rawValue }
    }

    /// The colour as saved right now. `CompanionManager` writes the same key, so
    /// this is read fresh instead of from the published copy.
    static var currentCursorDisplayColor: Color {
        (ClickyCursorColor(rawValue: TeachySettingsStorage.cursorColorName()) ?? .blue).displayColor
    }

    static var currentCursorNSColor: NSColor {
        NSColor(currentCursorDisplayColor).usingColorSpace(.sRGB) ?? .systemBlue
    }
}
