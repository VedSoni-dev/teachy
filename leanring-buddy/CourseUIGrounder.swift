//
//  CourseUIGrounder.swift
//  leanring-buddy
//
//  Soft course helpers: open a start URL, capture the cursor screen.
//  Teaching itself uses the companion vision path — no hardcoded UI targets.
//

import AppKit
import Foundation

@MainActor
enum CourseUIGrounder {

    static func openSetupURLIfNeeded(_ urlString: String?) async {
        guard let rawURLString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURLString.isEmpty else {
            return
        }

        let normalizedURLString: String
        if rawURLString.lowercased().hasPrefix("http://")
            || rawURLString.lowercased().hasPrefix("https://") {
            normalizedURLString = rawURLString
        } else {
            normalizedURLString = "https://\(rawURLString)"
        }

        guard let setupURL = URL(string: normalizedURLString) else {
            print("⚠️ Course startURL invalid: \(rawURLString)")
            return
        }

        let didOpen = NSWorkspace.shared.open(setupURL)
        print("📚 Course start opened \(normalizedURLString) → \(didOpen)")
    }

    static func captureCursorScreen() async throws -> CompanionScreenCapture {
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
            throw NSError(
                domain: "CourseUIGrounder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No cursor screen capture available"]
            )
        }
        return cursorScreenCapture
    }
}
