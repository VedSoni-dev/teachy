//
//  DriveCoordinates.swift
//  leanring-buddy
//
//  Pure geometry for Drive. The model only ever sees a downscaled screenshot,
//  so a point it names is in THAT image's pixels. This file turns such a point
//  into the global coordinate a click needs, for any display size, Retina
//  scale and monitor arrangement.
//
//  Three spaces:
//  - screenshot pixels: origin top-left of one capture, y down
//  - global AppKit points: origin bottom-left of the PRIMARY display, y up
//    (NSScreen.frame, NSEvent.mouseLocation)
//  - global CG points: origin top-left of the PRIMARY display, y down
//    (CGEvent, Accessibility frames)
//
//  Retina never enters the maths: screens are measured in points on both
//  sides, and the screenshot's own pixel size is whatever it was scaled to.
//

import CoreGraphics
import Foundation

/// Everything needed to map one screenshot back onto its display.
struct DriveCaptureGeometry: Equatable {
    /// The id the model quotes back ("cap-3").
    let captureID: String
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// The display's frame in global AppKit points (NSScreen.frame).
    let displayFrameInAppKitPoints: CGRect
    /// Height of the primary display in points: the constant that flips AppKit y to CG y.
    let primaryDisplayHeightInPoints: CGFloat
}

enum DriveCoordinates {
    /// Screenshot pixel → global CG point. Nil when the point is outside the image.
    static func globalCGPoint(
        screenshotX: Double,
        screenshotY: Double,
        in capture: DriveCaptureGeometry
    ) -> CGPoint? {
        let width = Double(capture.screenshotWidthInPixels)
        let height = Double(capture.screenshotHeightInPixels)
        guard width > 0, height > 0 else { return nil }
        guard screenshotX >= 0, screenshotY >= 0, screenshotX <= width, screenshotY <= height else { return nil }

        let frame = capture.displayFrameInAppKitPoints
        // 1. screenshot pixels → points inside the display (top-left origin)
        let pointsFromLeft = screenshotX * Double(frame.width) / width
        let pointsFromTop = screenshotY * Double(frame.height) / height
        // 2. → global AppKit (bottom-left origin, y up)
        let appKitX = Double(frame.minX) + pointsFromLeft
        let appKitY = Double(frame.maxY) - pointsFromTop
        // 3. → global CG (top-left origin of the primary display, y down)
        return CGPoint(x: appKitX, y: Double(capture.primaryDisplayHeightInPoints) - appKitY)
    }

    /// Global CG point → screenshot pixel. Nil when the point is not on that display.
    static func screenshotPoint(fromGlobalCG point: CGPoint, in capture: DriveCaptureGeometry) -> CGPoint? {
        let frame = capture.displayFrameInAppKitPoints
        guard frame.width > 0, frame.height > 0 else { return nil }
        let appKitY = capture.primaryDisplayHeightInPoints - point.y
        let pointsFromLeft = point.x - frame.minX
        let pointsFromTop = frame.maxY - appKitY
        guard pointsFromLeft >= 0, pointsFromTop >= 0, pointsFromLeft <= frame.width, pointsFromTop <= frame.height else { return nil }
        return CGPoint(
            x: pointsFromLeft * CGFloat(capture.screenshotWidthInPixels) / frame.width,
            y: pointsFromTop * CGFloat(capture.screenshotHeightInPixels) / frame.height
        )
    }

    /// A display's AppKit frame → its frame in global CG coordinates.
    static func globalCGRect(fromAppKit frame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Key combos

/// "cmd+shift+s" → a key code and modifier set. Pure, so the table is tested.
struct DriveKeyCombo: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
        static let function = Modifiers(rawValue: 1 << 4)
    }

    let keyCode: UInt16
    let modifiers: Modifiers
    /// How it reads back: "cmd+shift+s".
    let display: String

    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "plus": 24, "minus": 27, "comma": 43, "period": 47, "slash": 44
    ]

    static func parse(_ text: String) -> DriveKeyCombo? {
        let cleaned = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        // "cmd++" means command and the plus key.
        var parts = cleaned.components(separatedBy: "+")
        if cleaned.hasSuffix("++") {
            parts = Array(parts.dropLast(2)) + ["plus"]
        } else if cleaned == "+" {
            parts = ["plus"]
        }
        guard !parts.contains("") else { return nil }

        var modifiers: Modifiers = []
        var keyName: String?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘", "meta", "super": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "fn", "function": modifiers.insert(.function)
            default:
                guard keyName == nil else { return nil } // two non-modifier keys
                keyName = part
            }
        }
        guard let keyName, let keyCode = keyCodes[keyName] else { return nil }

        var names: [String] = []
        if modifiers.contains(.control) { names.append("ctrl") }
        if modifiers.contains(.option) { names.append("opt") }
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.command) { names.append("cmd") }
        if modifiers.contains(.function) { names.append("fn") }
        names.append(keyName)
        return DriveKeyCombo(keyCode: keyCode, modifiers: modifiers, display: names.joined(separator: "+"))
    }
}
