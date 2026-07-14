//
//  WindowPositionManager.swift
//  leanring-buddy
//
//  Manages positioning the app window on the right edge of the screen
//  and shrinking overlapping windows from other apps via the Accessibility API.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import Speech

enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

@MainActor
class WindowPositionManager {
    private static var hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = false
    private static var hasAttemptedSpeechRecognitionSystemPromptDuringCurrentLaunch = false
    private static var hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = false
    private static let hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    /// Returns true when the Mac currently has more than one connected display.
    /// Uses AppKit's screen list, which is available without ScreenCaptureKit's
    /// shareable-content permission prompt.
    static func currentMacHasMultipleDisplays() -> Bool {
        NSScreen.screens.count > 1
    }

    // MARK: - Accessibility Permission

    /// Returns true if the app has Accessibility permission.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Presents exactly one permission path per tap: the system prompt on the first
    /// attempt, then System Settings on later attempts after macOS has already shown
    /// its one-time alert.
    @discardableResult
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt: hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemSettings:
            openAccessibilitySettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Accessibility pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stable install path used by the Xcode "Install Dev App" build phase.
    /// Granting Accessibility here survives rebuilds better than DerivedData paths.
    static func stableDevelopmentInstallURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Teachy.app")
    }

    /// True when this process is running from the stable ~/Applications install.
    static func isRunningFromStableDevelopmentInstall() -> Bool {
        Bundle.main.bundleURL.standardizedFileURL.path
            == stableDevelopmentInstallURL().standardizedFileURL.path
    }

    /// True when Xcode is running the app straight from DerivedData.
    static func isRunningFromXcodeDerivedDataBuild() -> Bool {
        Bundle.main.bundleURL.path.contains("/DerivedData/")
    }

    static func runningApplicationBundlePath() -> String {
        Bundle.main.bundleURL.path
    }

    /// Reveals the running app bundle in Finder so the user can drag it into
    /// the Accessibility list if it doesn't appear automatically.
    static func revealAppInFinder() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Speech Recognition Permission

    /// Returns true if the app has Speech Recognition permission.
    static func hasSpeechRecognitionPermission() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Opens System Settings to the Speech Recognition pane.
    static func openSpeechRecognitionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings to the Dictation toggle (required for Apple Speech).
    static func openDictationSettings() {
        if let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(keyboardSettingsURL)
            return
        }

        guard let legacyKeyboardURL = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") else { return }
        NSWorkspace.shared.open(legacyKeyboardURL)
    }

    /// Shown when Apple Speech fails because system Dictation is still off.
    static func presentDictationRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Turn On Dictation"
        alert.informativeText = """
        Teachy has Speech Recognition permission, but macOS Dictation is still off.

        1. Open Keyboard settings (click the button below).
        2. Turn Dictation ON.
        3. Quit Teachy (Cmd+Q) and relaunch from Xcode.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Dictation Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openDictationSettings()
        }
    }

    static func isDictationDisabledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kLSRErrorDomain" && nsError.code == 201
    }

    /// Presents the system speech recognition prompt on first attempt, then
    /// opens System Settings on later attempts.
    @discardableResult
    static func requestSpeechRecognitionPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasSpeechRecognitionPermission(),
            hasAttemptedSystemPrompt: hasAttemptedSpeechRecognitionSystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedSpeechRecognitionSystemPromptDuringCurrentLaunch = true
            SFSpeechRecognizer.requestAuthorization { _ in }
        case .systemSettings:
            openSpeechRecognitionSettings()
        }

        return presentationDestination
    }

    // MARK: - Screen Recording Permission

    private static let screenCaptureFailureIndicators = [
        "declined tcc",
        "tcc",
        "not authorized",
        "permission",
        "user denied"
    ]

    /// Live TCC check — use this for UI and before capture. Do not rely on cached UserDefaults alone.
    static func hasScreenRecordingPermission() -> Bool {
        let hasScreenRecordingPermissionNow = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermissionNow {
            UserDefaults.standard.set(true, forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        }
        return hasScreenRecordingPermissionNow
    }

    /// Call immediately before ScreenCaptureKit capture. Prompts once if needed.
    static func ensureScreenCaptureAccessBeforeCapture() throws {
        if CGPreflightScreenCaptureAccess() {
            return
        }

        _ = CGRequestScreenCaptureAccess()

        if CGPreflightScreenCaptureAccess() {
            UserDefaults.standard.set(true, forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
            return
        }

        throw NSError(
            domain: "WindowPositionManager",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: """
                Screen Recording is not active for this Teachy build.

                In System Settings → Privacy & Security → Screen Recording:
                1. Remove Teachy (−) if it is listed.
                2. Click + and add the Teachy.app you are running now (use Find App in the panel).
                3. Quit Teachy (Cmd+Q) and relaunch from Xcode.
                """
            ]
        )
    }

    /// Clears a stale cached grant after ScreenCaptureKit rejects this binary. Returns true when handled.
    @discardableResult
    static func handleScreenCaptureFailure(_ error: Error) -> Bool {
        guard isScreenCaptureAccessDeniedError(error) else { return false }
        clearPreviouslyConfirmedScreenRecordingPermission()
        print("🔑 Screen capture failed for this build — clear Screen Recording and re-add Teachy: \(runningApplicationBundlePath())")
        return true
    }

    static func isScreenCaptureAccessDeniedError(_ error: Error) -> Bool {
        let errorDescription = error.localizedDescription.lowercased()
        if screenCaptureFailureIndicators.contains(where: { errorDescription.contains($0) }) {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return true
        }

        return false
    }

    /// Opens Screen Recording settings and reveals this app bundle for re-adding after an Xcode rebuild.
    static func fixScreenRecordingAfterRebuild() {
        revealAppInFinder()
        openScreenRecordingSettings()

        let alert = NSAlert()
        alert.messageText = "Re-add Teachy for Screen Recording"
        alert.informativeText = """
        Settings may show Teachy as ON, but this Xcode build needs a fresh entry.

        1. In Screen Recording, select Teachy and click − to remove it.
        2. Click + and choose Teachy.app from the Finder window that opened.
        3. Turn Teachy ON, then quit (Cmd+Q) and relaunch from Xcode.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Returns true when the app should proceed with session launch without showing
    /// the permission gate again. This intentionally falls back to the last known
    /// granted state because CGPreflightScreenCaptureAccess() can sometimes return a
    /// false negative even though the user has already approved the app.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() -> Bool {
        shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: hasScreenRecordingPermission(),
            hasPreviouslyConfirmedScreenRecordingPermission: UserDefaults.standard.bool(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        )
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }

    static func clearPreviouslyConfirmedScreenRecordingPermission() {
        UserDefaults.standard.removeObject(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
    }

    /// Prompts the system dialog for Screen Recording permission.
    /// Uses the system prompt once, then opens System Settings on later attempts so
    /// the user never gets the prompt and the Settings pane at the same time.
    @discardableResult
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt: hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = true
            _ = CGRequestScreenCaptureAccess()
        case .systemSettings:
            openScreenRecordingSettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }

        if hasAttemptedSystemPrompt {
            return .systemSettings
        }

        return .systemPrompt
    }

    // MARK: - Window Positioning

    /// Positions the app's main window pinned to the right edge of the screen
    /// that contains the given display ID, vertically centered.
    static func pinMainWindowToRight(onDisplayID displayID: CGDirectDisplayID?) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }

        // Find the NSScreen matching the selected display, or fall back to the screen
        // the window is currently on, or finally the main screen.
        let targetScreen: NSScreen
        if let displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            targetScreen = matchingScreen
        } else if let currentScreen = mainWindow.screen {
            targetScreen = currentScreen
        } else if let mainScreen = NSScreen.main {
            targetScreen = mainScreen
        } else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = mainWindow.frame.size

        let x = visibleFrame.maxX - windowSize.width
        let y = visibleFrame.minY + (visibleFrame.height - windowSize.height) / 2.0

        mainWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Shrink Overlapping Windows

    /// Checks if the frontmost (non-self) app's focused window overlaps our app window
    /// on the same monitor and, if so, shrinks it so it no longer overlaps.
    /// Only operates if both windows are on the same screen as `targetDisplayID`.
    static func shrinkOverlappingFocusedWindow(targetDisplayID: CGDirectDisplayID?) {
        guard hasAccessibilityPermission() else { return }
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        guard let mainScreen = mainWindow.screen else { return }

        // Only operate if the main window is on the target display
        if let targetDisplayID, mainScreen.displayID != targetDisplayID {
            return
        }

        // Get the frontmost application that isn't us
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused window of the front app
        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        guard focusedResult == .success, let focusedWindow = focusedWindowValue else { return }

        // Get position and size of the focused window
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return
        }

        var otherPosition = CGPoint.zero
        var otherSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &otherPosition),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &otherSize) else {
            return
        }

        // The other window's frame in screen coordinates (top-left origin from AX API).
        // Convert to check if it's on the same screen as our window.
        let otherRight = otherPosition.x + otherSize.width
        let ourLeft = mainWindow.frame.origin.x

        // Check that the other window is on the same screen by verifying its origin
        // falls within the target screen's bounds.
        let screenFrame = mainScreen.frame
        let otherCenterX = otherPosition.x + otherSize.width / 2
        // AX uses top-left origin, NSScreen uses bottom-left. Convert AX Y to NSScreen Y.
        let otherNSScreenY = screenFrame.maxY - otherPosition.y - otherSize.height
        let otherCenterY = otherNSScreenY + otherSize.height / 2
        let otherCenter = NSPoint(x: otherCenterX, y: otherCenterY)

        guard screenFrame.contains(otherCenter) else { return }

        // If the other window's right edge extends past our window's left edge, shrink it.
        if otherRight > ourLeft {
            let newWidth = ourLeft - otherPosition.x
            guard newWidth > 200 else { return } // Don't shrink too small

            var newSize = CGSize(width: newWidth, height: otherSize.height)
            guard let newSizeValue = AXValueCreate(.cgSize, &newSize) else { return }
            AXUIElementSetAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, newSizeValue)
        }
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
