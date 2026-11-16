//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum ClickyCursorColor: String, CaseIterable, Identifiable {
    case red
    case blue
    case yellow
    case green

    var id: String { rawValue }

    var displayColor: Color {
        // The hex values live in the design system, which also reads the chosen
        // colour for the marks in the panel, so the two cannot drift apart.
        DS.Colors.pointerColor(named: rawValue)
    }
}

private func companionManagerInitialModelID() -> String {
    // One-time upgrade for bring-your-own-key users: a stored "google/gemini-2.5-flash"
    // is indistinguishable from "never touched the picker" (it was the old default), so
    // migrate it once to the key-aware default. The flag makes an explicit re-pick of
    // Flash stick afterward instead of re-migrating on every launch.
    let claudeDefaultMigrationFlagKey = "teachy_model_default_migrated_to_claude"

    for userDefaultsKey in ["selectedModel", "selectedAgentModel", "selectedChatModel"] {
        if let storedModelID = UserDefaults.standard.string(forKey: userDefaultsKey) {
            var sanitizedModelID = OpenRouterModelOption.sanitizedModelID(storedModelID)
            if sanitizedModelID != storedModelID {
                print("🔄 Reset unknown model \(storedModelID) → \(sanitizedModelID)")
            }
            if !UserDefaults.standard.bool(forKey: claudeDefaultMigrationFlagKey),
               TeachyAPIKeyStore.isConfigured,
               sanitizedModelID == "google/gemini-2.5-flash" {
                sanitizedModelID = OpenRouterModelOption.defaultModelID
                UserDefaults.standard.set(true, forKey: claudeDefaultMigrationFlagKey)
                print("🔄 Upgraded default tutor model → \(sanitizedModelID)")
            }
            UserDefaults.standard.set(sanitizedModelID, forKey: "selectedModel")
            return sanitizedModelID
        }
    }
    let defaultModelID = OpenRouterModelOption.defaultModelID
    UserDefaults.standard.set(defaultModelID, forKey: "selectedModel")
    UserDefaults.standard.set(true, forKey: claudeDefaultMigrationFlagKey)
    return defaultModelID
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasSpeechRecognitionPermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Chalk draw instruction from a [DRAW:...] model tag — rendered on the overlay.
    @Published var activeScreenDrawInstruction: ScreenGridDrawInstruction?

    let mouseOutlineTracker = MouseOutlineTracker()

    // MARK: - Beside-cursor video (onboarding intro)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?
    /// When true, push-to-talk is ignored while the onboarding intro video plays.
    private var besideCursorVideoBlocksPushToTalk = false
    private var besideCursorVideoFadeOutTask: Task<Void, Never>?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?
    /// Short one-shots (page turns, moments) — separate from the under-score so music keeps playing.
    private var teachyUISoundPlayer: AVAudioPlayer?

    /// Set after the mid-tour live screen-proof demo finishes, so reopening the notch can advance the tour.
    @Published var teachyScreenProofDidPlay: Bool = false
    private var teachyScreenProofTask: Task<Void, Never>?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let backgroundAgentSideDockManager = BackgroundAgentSideDockManager()
    let composioConnectionManager = ComposioConnectionManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Teachy proxy (local dev or Cloudflare Worker).
    private static var workerBaseURL: String { ClickyWorkerConfiguration.workerBaseURL }

    lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: ClickyWorkerConfiguration.chatEndpointURL, model: selectedModel)
    }()

    lazy var speechSynthesizer: LocalSpeechSynthesizer = {
        return LocalSpeechSynthesizer()
    }()

    lazy var backgroundAgentManager: BackgroundAgentManager = {
        let manager = BackgroundAgentManager(
            proxyURL: ClickyWorkerConfiguration.agentCompletionsEndpointURL,
            selectedModel: selectedModel
        )
        return manager
    }()

    /// The AX element list captured during the most recent pointing turn. Populated in
    /// `buildLabeledAnnotatedImages` (off-main-thread, concurrent with screenshot). The
    /// model references elements by their `ax:ID`; `applyPointingFromResponse` looks them
    /// up here to resolve the true global AppKit coordinate, bypassing screenshot-pixel math.
    private var currentAXElementRegistry: [DetectedAXElement] = []

    /// OpenRouter model for voice agent. Persisted to UserDefaults.
    @Published var selectedModel: String = companionManagerInitialModelID()

    var isBackgroundAgentActivelyRunning: Bool {
        switch backgroundAgentManager.status {
        case .reasoning, .running:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    func setSelectedModel(_ model: String) {
        let sanitizedModelID = OpenRouterModelOption.sanitizedModelID(model)
        selectedModel = sanitizedModelID
        UserDefaults.standard.set(sanitizedModelID, forKey: "selectedModel")
        backgroundAgentManager.selectedModel = sanitizedModelID
        claudeAPI.model = sanitizedModelID
    }

    /// Conversation history so companion chat remembers prior exchanges within a session.
    /// Starts from the last few exchanges saved on disk, so a relaunch doesn't wipe the thread.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] =
        CompanionManager.restoredConversationHistory()

    private static func restoredConversationHistory() -> [(userTranscript: String, assistantResponse: String)] {
        let messages = BrainStore.shared.recentMessages(limit: 20)
        var exchanges: [(userTranscript: String, assistantResponse: String)] = []
        var pendingUserText: String?
        for message in messages {
            switch message.role {
            case .user: pendingUserText = message.text
            case .assistant:
                if let userText = pendingUserText {
                    exchanges.append((userTranscript: userText, assistantResponse: message.text))
                    pendingUserText = nil
                }
            }
        }
        return Array(exchanges.suffix(6))
    }

    /// An in-progress, fully ephemeral step-by-step walkthrough happening inside
    /// a normal voice turn (no tab, no HUD, no persistence). Started/continued/
    /// ended entirely by the model tagging `[GUIDE: short title]` on its own replies —
    /// see `sendCompanionChatResponse` and `guidedTaskPromptSection()`.
    @Published private(set) var activeGuidedTask: CompanionGuidedTask?

    /// Set for the duration of a single companion turn when a guided-task step was just
    /// vision-verified, so `guidedTaskPromptSection()` can weave the result into that
    /// turn's answer. Cleared once the prompt for that turn has been built.
    private var pendingGuidedTaskVerificationResult: GuidedStepCheckResult?

    /// The frontmost browser's active tab (URL + title) captured for this turn —
    /// refreshed in `buildLabeledAnnotatedImages` at capture time, consumed by
    /// `buildCompanionVoiceResponseSystemPrompt`, cleared after the prompt is built.
    private var currentBrowserTabContext: String?

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var dictationErrorCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var composioConnectionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var lastLoggedUntrustedAccessibilityBundlePath: String?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all required permissions are granted.
    var allPermissionsGranted: Bool {
        let hasRequiredSpeechRecognitionPermission = !requiresSpeechRecognitionPermission || hasSpeechRecognitionPermission
        return hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasRequiredSpeechRecognitionPermission
    }

    /// Apple Speech needs macOS Speech Recognition permission; cloud providers do not.
    var requiresSpeechRecognitionPermission: Bool {
        buddyDictationManager.requiresSpeechRecognitionPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Teachy cursor should be shown.
    /// When off (the default), the cursor stays hidden until the next
    /// interaction and fades in only for it (transient cursor mode).
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    /// The color of the on-screen cursor triangle. Persisted to UserDefaults.
    @Published var selectedCursorColor: ClickyCursorColor = {
        let stored = UserDefaults.standard.string(forKey: "selectedCursorColor") ?? ClickyCursorColor.blue.rawValue
        return ClickyCursorColor(rawValue: stored) ?? .blue
    }()

    var overlayCursorColor: Color {
        selectedCursorColor.displayColor
    }

    func setSelectedCursorColor(_ cursorColor: ClickyCursorColor) {
        selectedCursorColor = cursorColor
        UserDefaults.standard.set(cursorColor.rawValue, forKey: "selectedCursorColor")
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has finished the Teachy product tour at least once.
    /// Persisted so the Home tab shows on later launches.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    private static let defaultVoiceKeyterms = [
        "agent",
        "background agent",
        "start background agent",
        "teachy agent",
        "clicky agent",
        "build me",
        "create me",
        "make me",
        "open tab",
        "automate",
    ]

    func start() {
        refreshAllPermissions()
        print("🔑 Teachy start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), speech: \(hasSpeechRecognitionPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        buddyDictationManager.updateContextualKeyterms(Self.defaultVoiceKeyterms)
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Hands-free mode: each finished utterance runs through the normal voice turn.
        VoiceModeController.shared.onUtterance = { [weak self] text in
            self?.lastTranscript = text
            self?.submitSyntheticCompanionRequest(text)
        }
        VoiceModeController.shared.onBargeIn = { [weak self] in self?.currentResponseTask?.cancel() }
        // Walkthroughs speak through the same voice and look at the screen under the cursor.
        WalkthroughCenter.shared.speak = { [weak self] line in
            guard let self else { return }
            await self.speechSynthesizer.finishStream()
            try? await self.speechSynthesizer.speakText(line)
        }
        WalkthroughCenter.shared.captureScreen = {
            guard let shot = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: { $0.isCursorScreen }) else { return nil }
            return (shot.imageData, shot.screenshotWidthInPixels, shot.screenshotHeightInPixels, shot.displayFrame)
        }
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        composioConnectionCancellable = composioConnectionManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        composioConnectionManager.startMonitoring(companionManager: self)
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Marks the in-panel Teachy product tour as done so the Home tab shows
    /// without requiring the beside-cursor intro video.
    func completeTeachyProductOnboarding() {
        hasCompletedOnboarding = true
        teachyScreenProofTask?.cancel()
        teachyScreenProofTask = nil
        ClickyAnalytics.trackOnboardingStarted()
        fadeOutOnboardingMusic()

        if isClickyCursorEnabled {
            // Skip welcome + intro video — the panel tour already explained Teachy.
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Triggers the beside-cursor intro video sequence — dismisses the panel
    /// and restarts the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at low volume, fade out after 1m 30s
        startOnboardingMusic(forceRestart: true)

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic(forceRestart: true)
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    /// Soft Besaid-style under-score for Teachy first-run + demo replay.
    /// Pass `forceRestart: true` to restart from the top (intro video / replay).
    func startOnboardingMusic(forceRestart: Bool = false) {
        if !forceRestart, onboardingMusicPlayer?.isPlaying == true { return }
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Teachy: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.28
            player.numberOfLoops = 0
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Teachy: Failed to play onboarding music: \(error)")
        }
    }

    func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    enum TeachyUISound {
        /// Soft UI chirp for page advances / confirms (`enter.mp3`).
        case pageAdvance
        /// Brighter sting for celebrations (`eshop.mp3`).
        case celebration
    }

    func playTeachyUISound(_ sound: TeachyUISound) {
        let resourceName: String
        let volume: Float
        switch sound {
        case .pageAdvance:
            resourceName = "enter"
            volume = 0.32
        case .celebration:
            resourceName = "eshop"
            volume = 0.38
        }

        guard let soundURL = Bundle.main.url(forResource: resourceName, withExtension: "mp3") else {
            print("⚠️ Teachy: \(resourceName).mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.volume = volume
            player.play()
            teachyUISoundPlayer = player
        } catch {
            print("⚠️ Teachy: Failed to play \(resourceName).mp3: \(error)")
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Teachy proof beat: collapse the panel, say we can see the screen, then fly to something real.
    func beginTeachyScreenProofDemo() {
        teachyScreenProofTask?.cancel()
        teachyScreenProofDidPlay = false

        startOnboardingMusic()
        playTeachyUISound(.pageAdvance)

        // Skip video welcome path — this is Teachy's own live proof.
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true

        teachyScreenProofTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.streamOnboardingCursorPrompt("hey — i can see your screen")
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }

            self.performOnboardingDemoInteraction()

            // Let the fly + bubble land before nudging them back to the notch.
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }

            await self.streamOnboardingCursorPrompt("hover the notch when you’re ready")
            self.teachyScreenProofDidPlay = true
        }
    }

    /// Character-by-character cursor prompt (same feel as the intro nudge).
    @MainActor
    private func streamOnboardingCursorPrompt(_ message: String) async {
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.35)) {
            onboardingPromptOpacity = 1.0
        }

        for character in message {
            guard !Task.isCancelled else { return }
            onboardingPromptText.append(character)
            try? await Task.sleep(for: .milliseconds(28))
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func clearActiveScreenDrawInstruction() {
        activeScreenDrawInstruction = nil
    }

    func cancelAIForAccountChange() {
        buddyDictationManager.cancelCurrentDictation()
        currentResponseTask?.cancel()
        currentResponseTask = nil
        backgroundAgentManager.cancelTask()
        clearDetectedElementLocation()
        clearActiveScreenDrawInstruction()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        backgroundAgentSideDockManager.hide()
        backgroundAgentManager.cancelTask()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadSpeechRecognition = hasSpeechRecognitionPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            lastLoggedUntrustedAccessibilityBundlePath = nil
            if !globalPushToTalkShortcutMonitor.isEventTapActive {
                globalPushToTalkShortcutMonitor.start()
            }
        } else {
            globalPushToTalkShortcutMonitor.stop()
            let runningBundlePath = WindowPositionManager.runningApplicationBundlePath()
            if lastLoggedUntrustedAccessibilityBundlePath != runningBundlePath {
                lastLoggedUntrustedAccessibilityBundlePath = runningBundlePath
                if WindowPositionManager.isRunningFromXcodeDerivedDataBuild() {
                    let stableInstallPath = WindowPositionManager.stableDevelopmentInstallURL().path
                    print("🔑 Accessibility not trusted for DerivedData build: \(runningBundlePath)")
                    print("🔑 Tip: grant Accessibility to the stable install at \(stableInstallPath), or set your Development Team in Xcode Signing.")
                } else {
                    print("🔑 Accessibility not trusted: \(runningBundlePath)")
                }
            }
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        hasSpeechRecognitionPermission = WindowPositionManager.hasSpeechRecognitionPermission()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadSpeechRecognition != hasSpeechRecognitionPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), speech: \(hasSpeechRecognitionPermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadSpeechRecognition && hasSpeechRecognitionPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "speech_recognition")
        }

        // ScreenCaptureKit uses the same screen-recording TCC grant — never auto-probe
        // SCShareableContent on a timer; that re-triggers the system picker in a loop.
        syncScreenContentPermissionWithScreenRecording()

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Screen content shares the screen-recording permission for ScreenCaptureKit.
    /// Keep the published flag for legacy UI state, but never poll SCShareableContent.
    private func syncScreenContentPermissionWithScreenRecording() {
        if hasScreenContentPermission { return }

        if UserDefaults.standard.bool(forKey: "hasScreenContentPermission") {
            hasScreenContentPermission = true
            return
        }

        if hasScreenRecordingPermission {
            hasScreenContentPermission = true
            UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
        }
    }

    /// No-op kept for call sites — screen recording grant is sufficient.
    func requestScreenContentPermission() {
        syncScreenContentPermissionWithScreenRecording()
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        // Voice-input failures previously set `lastErrorMessage` and nothing
        // anywhere read it — push-to-talk could fail in complete silence. Speak
        // each new error once so the user knows what happened and what to do.
        dictationErrorCancellable = buddyDictationManager.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] dictationErrorMessage in
                guard let self else { return }
                self.speakErrorMessage(dictationErrorMessage)
            }

        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing.
            guard !(showOnboardingVideo && besideCursorVideoBlocksPushToTalk) else { return }
            // Pressing the talk key always gets a spoken answer, and pauses hands-free listening.
            SpokenOutputGate.shared.noteTalkKeyPressed()
            VoiceModeController.shared.suspend(reason: "talkKey")

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress companion response and TTS. Background agent tasks
            // keep running until the user starts a new agent task.
            currentResponseTask?.cancel()
            speechSynthesizer.stopPlayback()
            SceneDirector.shared.stop()
            clearDetectedElementLocation()
            clearActiveScreenDrawInstruction()
            mouseOutlineTracker.startTracking()
            PaintTrailPresenter.shared.begin()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.routeVoiceTranscript(finalTranscript)
                    },
                    submitWhenTranscriptEmpty: false
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            VoiceModeController.shared.resume(reason: "talkKey")
            mouseOutlineTracker.stopTracking()
            PaintTrailPresenter.shared.end()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - AI Response Pipeline

    /// Returns the display name of the frontmost app if it is a known AI coding tool
    /// (Cursor, VS Code, Xcode, or a terminal that likely hosts Claude Code or similar),
    /// or nil when the user is in any other app.
    ///
    /// Matching is intentionally permissive: a false positive just adds a harmless
    /// INTERPRETER MODE section to the prompt, while a false negative silently drops
    /// the feature. Bundle-ID prefix matching is the primary signal; a localizedName
    /// fallback catches unsigned or renamed builds of the same tools.
    private func frontmostCodingToolName() -> String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = frontmostApplication.bundleIdentifier ?? ""
        let appName = frontmostApplication.localizedName ?? ""

        // Known bundle ID prefixes for coding tools and terminals.
        // Cursor's bundle ID is the Todesktop-packaged Electron app ID.
        let codingToolBundleIDPrefixes = [
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.microsoft.VSCode",            // VS Code (stable)
            "com.microsoft.VSCodeInsiders",    // VS Code Insiders
            "com.apple.dt.Xcode",             // Xcode
            "com.apple.Terminal",             // macOS Terminal
            "com.googlecode.iterm2",          // iTerm2
            "dev.warp.Warp-Stable",           // Warp
            "com.mitchellh.ghostty",          // Ghostty
            "net.kovidgoyal.kitty"            // kitty
        ]

        if codingToolBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return appName
        }

        // Fallback: name-based matching catches unsigned builds, rebranded forks,
        // or bundle IDs that drift with new releases (e.g. Cursor beta channels).
        let codingToolNameSubstrings = ["Cursor", "VS Code", "Visual Studio Code", "Xcode",
                                        "Terminal", "iTerm", "Warp", "Ghostty", "kitty",
                                        "Claude Code"]
        if codingToolNameSubstrings.contains(where: { appName.contains($0) }) {
            return appName
        }

        return nil
    }

    /// Builds the system prompt for one voice turn: a general assistant that answers
    /// what they asked about their screen, points and draws when that helps, and does
    /// the task (or offers to) when they want it done. The bracket-tag contracts below
    /// ([POINT:], [SHOW:], [JOB:], [DO:], [GUIDE:], [CLIPBOARD:], [REMEMBER:]) are what
    /// `sendCompanionChatResponse` parses — keep their wording in sync with that code.
    private func buildCompanionVoiceResponseSystemPrompt(depth: VoiceTurnDepth = .quick) -> String {
        // Situational awareness: tell the model the frontmost app/window by name,
        // not just from screenshot pixels — this is what lets "I have Claude open,
        // what's cowork?" work without the user having to say what app they're in.
        let frontmostAppSection = AccessibilityElementDetector.frontmostApplicationContext()
            .map { "\n\nRight now they're in: \($0)." } ?? ""

        // Fuller situational awareness beyond just the frontmost app — lets the model
        // reason about things like "switch to Slack and paste this" without the user
        // having to name every app themselves.
        let allOpenApplicationsSection = AccessibilityElementDetector.allOpenApplicationsContext()
            .map { "\n\n\($0)." } ?? ""

        // The exact page they're on, when the frontmost app is a browser — window
        // titles alone often omit the URL entirely.
        let browserTabSection = currentBrowserTabContext
            .map { "\n\nThe browser tab they're on right now: \($0)." } ?? ""

        let guidedTaskSection = guidedTaskPromptSection()
        let languageSection = "\n\n" + TeachySettingsStorage.replyLanguagePromptSentence()
        // What Teachy knows about the app or site in front, and any walkthrough in progress.
        let appSkillText = SkillLibrary.shared.promptSection(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            browserTabContext: currentBrowserTabContext
        )
        let walkthroughText = WalkthroughCenter.shared.promptSection()
        let skillAndWalkthroughSection = (appSkillText.isEmpty ? "" : "\n\n" + appSkillText)
            + (walkthroughText.isEmpty ? "" : "\n\n" + walkthroughText)
        let walkRule = """


        - When they ask HOW to do something in an app or on a site and would rather do it themselves ("show me how to…", "walk me through…", "where do I change…") and it takes more than one click, add [WALK: the goal in one plain sentence, with every detail they gave] at the end and SAY one short line that you'll walk them through it. Teachy then takes over: it works out the steps, rings each control on screen, and moves on by itself when they click it. Do not list the steps yourself and do not add [POINT:] in the same reply. If it is one click away, just point. If they want it done for them, that is [JOB:] or [DO:], not [WALK:]. [WALK:] replaces [GUIDE:]: never use [GUIDE:].
        """

        // What Teachy remembers about this person (PROFILE.md / VOLATILE.md, editable by
        // them). Without this the model "remembered" facts that never came back to it.
        let rememberedContext = BrainStore.shared.promptContext()
        let brainSection = rememberedContext.isEmpty ? "" : """


        WHAT YOU REMEMBER ABOUT THEM (use it naturally; follow "How I like answers" exactly):
        \(rememberedContext)
        """

        // Present only when a coding tool (Cursor, VS Code, Xcode, a terminal running Claude Code,
        // etc.) is the frontmost app — they are likely driving an AI coding agent.
        let interpreterModeSection: String
        if let codingToolName = frontmostCodingToolName() {
            interpreterModeSection = """


            INTERPRETER MODE — they're in \(codingToolName), likely working with an AI coding agent:
            - When they say what they want changed ("make the header blue", "add a contact form"), don't explain how to code it. Write the instruction the coding agent needs — name the file or feature area if visible on screen, state what should be true when it's done, say what not to touch — and hand it over with [CLIPBOARD: the instruction]. Tell them it's ready to paste into the agent.
            - After the agent runs and they ask what happened (or you can see the result on screen), say WHAT CHANGED in one or two plain sentences — no code speak — then the ONE thing they should check.
            - If an error is visible on screen, read its first line in plain words and write the paste-back instruction for the agent via [CLIPBOARD:].
            """
        } else {
            interpreterModeSection = ""
        }

        // Teaching, explaining, debugging: more room and an explicit "go further" brief.
        let depthSection: String
        switch depth {
        case .deep:
            depthSection = """

        THIS ONE DESERVES A REAL ANSWER (they want to understand, decide or fix something):
        - Think it through before you speak, then teach it the way a brilliant friend would: the core idea in plain words first, then the one or two things that make it click (why it works, a concrete example, a vivid comparison), then what to do or look at next. Four to seven spoken sentences is fine; never pad.
        - Use the screen. If the thing they asked about, or the parts that explain it, are visible, mark them with [MARK:] so the explanation happens on their screen. If it is not on screen and a picture would help, use [SHOW:].
        - Bring the best resource. If a doc page, a video, a reference or a search would genuinely help them go further, open it with [OPEN: url] and say so in a few words.
        - Anticipate the follow-up. End with the one next step or question they would most likely ask, answered or offered, not a generic "anything else?".
        """
        case .quick:
            depthSection = ""
        }

        return """
        You are Teachy: a brilliant, warm friend sitting next to them at their Mac, looking at the same screen, who knows a lot and loves getting things done.
        They just asked you something out loud. Your reply is spoken, so talk like that friend in the room:
        direct, a little playful, never like Siri, never like a help article, never like a corporate bot.

        HOW YOU WORK (the same instincts as a great coding agent, aimed at everyday life):
        - Own the outcome, not just the literal question. Work out what they are really trying to do and help with THAT: answer what they asked, then take the obvious next step for them (point at it, mark it, open it, write it, or do it) without asking permission for things that are clearly wanted and easy to undo.
        - Bias to action. If they want something done and you can do it, do it ([DO:], [JOB:], [WRITE:], [OPEN:]) and say in one short line that you are on it. Only ask a question when the answer really changes what you would do, and then ask one, specific.
        - Ground everything in what you see. Name the real button, tab, file, error line or number on their screen. Never guess at something you could read off the screenshot.
        - Go a step beyond, with taste. One genuinely useful extra (the shortcut they did not know, the mistake about to bite them, the better way, the link that answers the next question) beats three generic tips. Skip the extra when it would only be noise.
        - Be honest. If you are not sure, say what you would check. Never invent a button, a fact or a link.

        WHAT YOU CAN DO IN A REPLY (tags are stripped before speaking; combine them when it helps):
        - Answer what they actually asked in the first sentence. Quick asks: one or two short sentences. Bigger asks: as long as it takes to be genuinely useful, and no longer.
        - When they should look somewhere, POINT at it with [POINT:...] so your cursor goes there,
          and say "here" / "right here" / "this one" ONLY when you're including that [POINT:...] tag
          in the same reply. If you can't confidently identify a specific, pointable target, describe it
          in words instead: saying "here" with nothing behind it is worse than not pointing at all.
        \(SceneDirector.voicePromptRules)
        - Proactively mark the screen: when your answer is about things that are visible (the parts of a diagram, the fields of a form, the lines of an error, the settings that matter), use [MARK:] even if they did not ask you to circle anything. That is what makes you feel like you are really looking with them.
        - Open links: [OPEN: https://…] opens a page in their browser while you talk: the right docs page, a tutorial or video, a search (e.g. https://www.google.com/search?q=… or https://www.youtube.com/results?search_query=…), a site they named. At most two. Only real, well-known URLs or searches; never guess a deep link you are not sure exists, use a search instead. Never open anything to buy, send or sign in for them.
        - When they want it DONE, do it rather than explain it: [DO:] for a single native command, [JOB:] for real multi-step work (it can browse the web in a real browser, use the mouse and keyboard, and work across apps), [WALK:] when they'd rather click through it themselves. If it's unclear whether they want you to do it, answer, then offer in one short line ("want me to just do it?").
        - When they want real multi-step work DONE for them (research something on the web, fill something in, sort or rename files, build or change something, anything across several apps or their connected services) add [JOB: the whole task in one clear sentence, with every detail they gave and anything you can see that it needs] and SAY one short line that you're on it. A job runs in the background, shows its plan, and asks them before anything risky. Don't use [JOB:] for a single native command (that's [DO:]).
        \(WritingPrompt.voicePromptRule)
        - If they share something personal (their job, an interest, a joke, a life detail) tag it [REMEMBER: the fact] in your reply. This is stripped before speaking, never shown to them.\(depthSection)

        How you sound (spoken aloud):
        - Natural sentences. Contractions. Short pauses implied with commas, not stage directions.
        - No emojis, no markdown, no bullet lists, no "as an AI".
        - Never say "simply", "certainly", "I'd be happy to help", or "great question".
        - Don't read code aloud — say what it does in plain words.
        - If something's confusing, empathize in half a breath, then give the next move.\(brainSection)\(frontmostAppSection)\(allOpenApplicationsSection)\(browserTabSection)
        \(guidedTaskSection)\(interpreterModeSection)\(skillAndWalkthroughSection)\(walkRule)\(languageSection)

        You can natively operate the Mac — open, quit, activate, or hide apps, and open, close, or switch browser tabs and windows — without ever simulating a click. When someone gives you a DIRECT native-Mac command ("open Spotify", "close this tab", "switch to Safari", "quit Slack"), say a short spoken heads-up ("Opening Spotify for you") and tag the action with [DO: precise action description] in your reply. The tag is stripped before speaking and executed immediately — the user never sees it.
        - Compound direct commands are fine ("close all my tabs and open Figma") — emit one [DO:] tag per action, in order. They execute as one sequence.
        - Use [DO:] only for direct, reversible native commands (app open/quit/activate/hide, tab/window open/close/switch — including "close all tabs" / "close the other tabs").
        - For tasks they want to do themselves step by step with you, use [WALK:]; for multi-step work they want done for them, use [JOB:] — not [DO:].
        - NEVER tag [DO:] for anything that deletes user data, spends money, sends an email or message on their behalf, or cannot be easily undone. For those, explain and let them act.
        - Examples of safe [DO:] use: "Opening Spotify for you. [DO: open app Spotify]" — "Sure, closing this tab. [DO: close active browser tab]" — "Switching over to Arc. [DO: activate app Arc]".

        PROMPT CONCIERGE:
        When they want to use an AI tool (ChatGPT, Claude, Midjourney, anything) for a task, don't just point them at it — a bland two-word prompt gets bland results. If the goal is vague, ask 1–2 quick questions first (what's it for, who's it for, what style or constraints). Then WRITE the strong prompt FOR them — specific, contextual, with the details a pro would include — and hand it over with [CLIPBOARD: the full prompt]. The tag is stripped from speech and its contents land on their clipboard. Tell them it's on the clipboard ready to paste, in one short sentence. Pair with [DO: open ...] when the tool isn't already open. Don't use ] inside the clipboard text, and never put secrets in it.
        \(ScreenGridAnnotationUtility.modelInstructions)
        """
    }

    /// Feeds a typed or synthesized request into the normal voice flow — exactly as if
    /// the user had spoken it (guided tasks, capture, speech, all of it). Used by the
    /// text box, scene follow-up questions, and onboarding seeds.
    func submitSyntheticCompanionRequest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        routeVoiceTranscript(trimmed)
    }

    /// Every transcript goes through the one general voice turn.
    private func routeVoiceTranscript(_ transcript: String) {
        // "next", "back", "I'm stuck", "stop" belong to a running walkthrough.
        if WalkthroughCenter.shared.handleSpoken(transcript) {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }
        sendCompanionChatResponse(transcript: transcript)
    }

    /// Quick companion chat with vision, conversation memory, and spoken replies.
    private func sendCompanionChatResponse(transcript: String) {
        currentResponseTask?.cancel()
        speechSynthesizer.stopPlayback()
        SceneDirector.shared.stop()

        currentResponseTask = Task {
            voiceState = .processing
            ChatTimeline.shared.userAsked(transcript)

            let screenCaptures: [CompanionScreenCapture]
            let mouseOutlineContext: CompanionMouseOutlineContext?

            do {
                screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let outlineGlobalPoints = mouseOutlineTracker.consumeFinalizedOutlinePoints()
                if let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) {
                    mouseOutlineContext = CompanionMouseOutlineContext.build(
                        globalOutlinePoints: outlineGlobalPoints,
                        screenCapture: cursorScreenCapture
                    )
                } else {
                    mouseOutlineContext = nil
                }
            } catch {
                print("⚠️ Companion screen capture failed: \(error.localizedDescription)")
                if WindowPositionManager.handleScreenCaptureFailure(error) {
                    refreshAllPermissions()
                }
                speakErrorMessage(Self.screenCaptureFailureUtterance())
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                return
            }

            guard !Task.isCancelled else { return }

            // Safety-net: a guided task that's gone quiet for a long while (user
            // walked away, started doing something else) shouldn't resurface oddly
            // much later — this is a backstop, not the primary exit mechanism (that's
            // the model simply not tagging [GUIDE:...] anymore, handled below).
            if let activeGuidedTask, Date().timeIntervalSince(activeGuidedTask.lastActivityAt) > 2700 {
                self.activeGuidedTask = nil
            }

            // Layer 2: if the current guided-task step is tagged `.act`, Teachy announces
            // and then executes it via the agent tool loop rather than coaching. The act
            // path produces its own spoken result and returns early from this turn; only
            // `.coach` steps fall through to the normal analyze-image-streaming below.
            //
            // We check for an existing task with steps (not newly-started — the plan-intro
            // turn already narrates step 1; the NEXT turn is when we act on `.act` steps)
            // and specifically for the `.act` execution mode on the current step.
            if let currentGuidedStepForActing = self.activeGuidedTask?.currentStep,
               currentGuidedStepForActing.executionMode == .act,
               !self.activeGuidedTask!.steps.isEmpty {

                let actingResult = await executeActStep(
                    currentGuidedStep: currentGuidedStepForActing,
                    screenCaptures: screenCaptures,
                    transcript: transcript
                )

                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: actingResult.spokenText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                ClickyAnalytics.trackAIResponseReceived(response: actingResult.spokenText)

                if !actingResult.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voiceState = .responding
                    do {
                        try await speechSynthesizer.speakText(actingResult.spokenText)
                    } catch {
                        print("⚠️ Companion TTS error (act step): \(error)")
                    }
                }

                if !Task.isCancelled {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
                return
            }

            // Coach path: check the current step against the screenshot we already captured
            // for this turn (no separate capture) BEFORE building this turn's answer, so the
            // reply can honestly reference what's actually on screen right now.
            pendingGuidedTaskVerificationResult = nil
            if let currentGuidedStep = self.activeGuidedTask?.currentStep,
               let cursorScreenCaptureForVerification = screenCaptures.first(where: { $0.isCursorScreen }) {
                let verificationResult = await GuidedStepScreenChecker.checkStep(
                    doneWhenDescription: currentGuidedStep.goal.doneWhen ?? currentGuidedStep.goal.goal,
                    screenCapture: cursorScreenCaptureForVerification,
                    claudeAPI: claudeAPI
                )
                pendingGuidedTaskVerificationResult = verificationResult

                if verificationResult.status == .pass {
                    self.activeGuidedTask?.currentStepIndex += 1
                } else {
                    // Layer 3: coach-path divergence. If the verification was off-track
                    // (user hit an obstacle, wrong screen, unexpected state), call the
                    // reasoning model to revise the remaining plan — so Teachy adapts
                    // instead of blindly repeating the same stuck step.
                    // Skip reflection on `.partial` (still in progress — not diverged yet)
                    // and on clean `.pass` (cost control). Also respect the per-task cap.
                    if verificationResult.status == .offTrack,
                       let taskForReflection = self.activeGuidedTask,
                       taskForReflection.reflectionRevisionCount < CompanionGuidedTask.maximumReflectionRevisionsPerTask {
                        let whatWentWrongDescription = "Coach-path verification was off-track. \(verificationResult.whatsGood). Still missing: \(verificationResult.whatsMissing ?? "unknown")."
                        await reflectAndReplaceRemainingSteps(
                            task: taskForReflection,
                            whatWentWrong: whatWentWrongDescription,
                            freshScreenCapture: cursorScreenCaptureForVerification
                        )
                    }
                }
            }

            var labeledImages = await buildLabeledAnnotatedImages(
                screenCaptures: screenCaptures,
                mouseOutlineContext: mouseOutlineContext
            )

            var transcriptWithSpatialHint = transcript
            if let spatialContextLabel = mouseOutlineContext?.spatialContextLabel {
                transcriptWithSpatialHint += "\n\n[\(spatialContextLabel) — the user circled this region on screen while asking.]"
            }

            // Attached files, or the document/page in front when the question is about it.
            let documentContext = await DocumentTurnContext.forVoiceTurn(question: transcript)
            if !documentContext.text.isEmpty { transcriptWithSpatialHint += "\n\n" + documentContext.text }
            labeledImages += documentContext.images

            let historyForAPI = conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }

            do {
                // Built once into a local so `pendingGuidedTaskVerificationResult` (read
                // by `guidedTaskPromptSection()` inside this call) can be cleared right
                // after — it's only meant to influence this single turn's prompt.
                // Teaching / explaining / debugging gets more thought and more room; commands stay instant.
                let turnDepth = VoiceTurnDepth.classify(transcript)
                let systemPromptForThisTurn = buildCompanionVoiceResponseSystemPrompt(depth: turnDepth)
                pendingGuidedTaskVerificationResult = nil
                currentBrowserTabContext = nil

                // Speech starts on the first complete sentence while the rest of the
                // answer is still streaming, instead of after the whole reply.
                let streamingSpeech = StreamingSpeechFeeder(synthesizer: speechSynthesizer) { [weak self] in
                    self?.voiceState = .responding
                }
                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptForThisTurn,
                    conversationHistory: historyForAPI,
                    userPrompt: transcriptWithSpatialHint,
                    job: .voice,
                    reasoningEffort: turnDepth.reasoningEffort,
                    maxTokens: turnDepth.maxTokens,
                    onTextChunk: { accumulatedText in
                        streamingSpeech.feed(accumulatedText)
                        ChatTimeline.shared.streamingReply(text: accumulatedText, isFinal: false)
                    }
                )

                guard !Task.isCancelled else { return }
                streamingSpeech.finish(fullResponseText)
                ChatTimeline.shared.streamingReply(text: fullResponseText, isFinal: true)

                // [SHOW: …] draws and explains something aloud while it builds; [MARK: …] draws on
                // what is on their screen right now. The drawing narrates itself in Teachy's voice.
                SceneDirector.shared.onFollowUpQuestion = { [weak self] question in
                    self?.submitSyntheticCompanionRequest(question)
                }
                // Answers given on the drawing itself (a tapped part, "zoom in on…") skip the
                // voice turn, so they are added to the conversation here.
                SceneDirector.shared.onRefinementAnswered = { [weak self] question, spokenAnswer in
                    guard let self else { return }
                    self.conversationHistory.append((userTranscript: question, assistantResponse: spokenAnswer))
                    BrainStore.shared.appendMessage(role: .user, text: question)
                    BrainStore.shared.appendMessage(role: .assistant, text: spokenAnswer)
                    if self.conversationHistory.count > 10 {
                        self.conversationHistory.removeFirst(self.conversationHistory.count - 10)
                    }
                }
                SceneDirector.shared.speak = { [weak self] sentence in
                    guard let self else { return }
                    await self.speechSynthesizer.finishStream()            // let the one-line reply finish
                    try? await self.speechSynthesizer.speakText(sentence)  // returns when the sentence has played
                }
                SceneDirector.shared.cancelSpeech = { [weak self] in self?.speechSynthesizer.stopPlayback() }
                if let showRequest = SceneDirector.extractShowRequest(from: fullResponseText).request {
                    SceneDirector.shared.show(showRequest)
                } else if let markRequest = SceneDirector.extractMarkRequest(from: fullResponseText).request,
                          let markCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first {
                    SceneDirector.shared.annotate(question: markRequest, screenshotJPEG: markCapture.imageData, displayFrame: markCapture.displayFrame)
                }

                // [JOB: …] hands real multi-step work to a background agent job: it shows its
                // plan under the notch, asks before anything risky, and speaks when it's done.
                let (replyWithoutJobTag, agentJobRequest) = VoiceTag.extract("JOB", from: fullResponseText)
                if let agentJobRequest {
                    backgroundAgentManager.onTaskFinished = { [weak self] spokenResult in
                        self?.speakErrorMessage(spokenResult)
                    }
                    backgroundAgentManager.runTask(
                        transcript: agentJobRequest,
                        screenCaptures: screenCaptures,
                        mouseOutlineContext: mouseOutlineContext
                    )
                }

                // [OPEN: url] opens a link worth seeing (a doc page, a video, a search) in their
                // browser while Teachy is still talking. Web links only, two at most.
                let (replyWithoutOpenTags, linksToOpen) = VoiceOpenLinks.extract(from: replyWithoutJobTag)
                for link in linksToOpen {
                    NSWorkspace.shared.open(link)
                }

                // [WRITE: …] drafts text from what's on screen, in their voice, and types it
                // into the field they have focused.
                let (replyWithoutWriteTag, writeInstruction) = VoiceTag.extract("WRITE", from: replyWithoutOpenTags)
                if let writeInstruction {
                    Task { @MainActor [weak self] in
                        let outcome = await ScreenAwareWriter.shared.writeAndInsert(instruction: writeInstruction, screenshots: labeledImages)
                        await self?.speechSynthesizer.finishStream()
                        self?.speakErrorMessage(outcome.spokenLine)
                    }
                }

                // [WALK: …] starts a step-by-step walkthrough: Teachy rings each control and
                // moves on when they click it.
                let (replyWithoutWalkTag, walkGoal) = VoiceTag.extract("WALK", from: replyWithoutWriteTag)
                if let walkGoal {
                    let cursorShot = screenCaptures.first(where: { $0.isCursorScreen })
                    WalkthroughCenter.shared.start(
                        goal: walkGoal,
                        screenshot: cursorShot.map { ($0.imageData, $0.screenshotWidthInPixels, $0.screenshotHeightInPixels, $0.displayFrame) }
                    )
                }

                let parseResult = Self.parsePointingCoordinates(from: SceneDirector.extractMarkRequest(from: SceneDirector.extractShowRequest(from: replyWithoutWalkTag).text).text)
                // Strip [REMEMBER: ...] tags before this ever reaches speech/history; the
                // facts go straight into the Brain (PROFILE.md "About me").
                let (spokenTextWithoutMemoryTags, rememberedFacts) = CompanionRememberTagParser.extractFactsAndStrip(from: parseResult.spokenText)
                for fact in rememberedFacts {
                    BrainStore.shared.remember(fact, kind: .aboutMe)
                }

                // Strip [GUIDE: short title] the same way REMEMBER is stripped above,
                // and use its presence/absence this turn to drive the ephemeral guided
                // walkthrough lifecycle (start / continue / naturally end).
                let (spokenTextWithoutGuideTags, guideTaskTitleThisTurn) = CompanionGuideTagParser.extractTitleAndStrip(from: spokenTextWithoutMemoryTags)

                // Phase L: strip [DO: action] — the model's one-shot native-action tag.
                // This runs after REMEMBER and GUIDE so all three tags are removed from
                // the final spoken text. The extracted action string drives the fast lane
                // below; the cleaned text is what TTS actually speaks.
                let (spokenTextWithoutActionTags, directNativeActionThisTurn) = CompanionActionTagParser.extractActionAndStrip(from: spokenTextWithoutGuideTags)

                // Prompt concierge: [CLIPBOARD: crafted prompt] — an independent side
                // effect like REMEMBER, not a fourth exclusive lane. Set BEFORE any
                // [DO:] executes so "open ChatGPT + prompt on clipboard" arrives ready
                // to paste the moment the tool opens.
                let (spokenText, clipboardTextThisTurn) = CompanionClipboardTagParser.extractClipboardTextAndStrip(from: spokenTextWithoutActionTags)
                if let clipboardTextThisTurn, !clipboardTextThisTurn.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clipboardTextThisTurn, forType: .string)
                    print("📋 Concierge prompt placed on clipboard (\(clipboardTextThisTurn.count) chars)")
                }

                let lifecycleOutcome = applyGuidedTaskLifecycle(guideTaskTitleThisTurn: guideTaskTitleThisTurn)

                // Phase L — one-shot native-action fast lane.
                // Conditions for taking it: a [DO:] action was tagged AND no guided task is
                // newly starting this turn AND there is no existing active guided task that
                // this turn is continuing. This keeps the three lanes mutually exclusive:
                //   1. [DO:] + no active/starting guided task → executeDirectNativeAction
                //   2. [GUIDE:] newlyStarted → presentGuidedTaskPlan (plan-then-execute)
                //   3. everything else → normal spoken answer
                // The model's spoken text (the heads-up, e.g. "Opening Spotify for you")
                // is already in `spokenText` — it gets spoken first, then the action runs.
                if let nativeActionDescription = directNativeActionThisTurn,
                   !nativeActionDescription.isEmpty,
                   lifecycleOutcome != .newlyStarted,
                   activeGuidedTask == nil {

                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: spokenText
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }
                    ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                    // The heads-up is already being spoken by the stream (announce-before-act);
                    // let it finish, then run the action.
                    await speechSynthesizer.finishStream()

                    guard !Task.isCancelled else { return }

                    await executeDirectNativeAction(
                        actionDescription: nativeActionDescription,
                        screenCaptures: screenCaptures
                    )
                    // executeDirectNativeAction resets voiceState to .idle on completion.
                    return
                }

                // Plan-then-execute: a brand-new guided task discards this turn's quick
                // first-call answer (it couldn't reference steps that didn't exist yet)
                // in favor of synchronously generating the plan and asking a second time
                // so the spoken answer actually enumerates it — explicit user tradeoff of
                // added latency on this one turn for a real plan instead of a vague guess.
                let finalSpokenText: String
                let finalFullResponseText: String
                if lifecycleOutcome == .newlyStarted {
                    // Pass the cursor screen capture so the reasoning planner can see what's
                    // actually on screen when decomposing the task — this is what makes the
                    // plan screen-grounded rather than a blind guess.
                    let cursorScreenCaptureForPlanning = screenCaptures.first(where: { $0.isCursorScreen })
                    let planResult = await presentGuidedTaskPlan(
                        images: labeledImages,
                        historyForAPI: historyForAPI,
                        cursorScreenCapture: cursorScreenCaptureForPlanning,
                        fallbackSpokenText: spokenText,
                        fallbackFullResponseText: fullResponseText
                    )
                    finalSpokenText = planResult.spokenText
                    finalFullResponseText = planResult.fullResponseText
                } else {
                    finalSpokenText = spokenText
                    finalFullResponseText = fullResponseText
                }

                if let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) {
                    applyPointingFromResponse(finalFullResponseText, screenCapture: cursorScreenCapture)
                }

                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: finalSpokenText
                ))
                // Kept on disk too, so tomorrow's conversation remembers today's.
                BrainStore.shared.appendMessage(role: .user, text: transcript)
                BrainStore.shared.appendMessage(role: .assistant, text: finalSpokenText)
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                ClickyAnalytics.trackAIResponseReceived(response: finalSpokenText)

                // The streamed answer is already being spoken; wait for it to finish.
                await speechSynthesizer.finishStream()
                // A brand-new guided task then reads out its plan, which was generated
                // after the first answer (skip when planning fell back to that answer).
                if lifecycleOutcome == .newlyStarted,
                   finalSpokenText != spokenText,
                   !finalSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Task.isCancelled {
                    voiceState = .responding
                    do {
                        try await speechSynthesizer.speakText(finalSpokenText)
                    } catch {
                        print("⚠️ Companion TTS error: \(error)")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakErrorMessage(companionAPIErrorUtterance(for: error))
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Ephemeral guided walkthroughs (companion Q&A only — see CompanionGuidedTask.swift)

    /// Outcome of a single `applyGuidedTaskLifecycle` call — lets the caller decide whether
    /// this turn needs the plan-then-execute treatment (`.newlyStarted`) or can just use the
    /// answer it already generated (every other case).
    private enum GuidedTaskLifecycleOutcome {
        case notActive   // no task active, tag absent this turn — nothing to do
        case newlyStarted // task just created this turn — caller must generate + present its plan
        case continuing  // existing task, still tagged this turn
        case ended       // task existed, tag absent this turn — concluded
    }

    /// Drives the ephemeral guided-task lifecycle purely from this turn's `[GUIDE: ...]`
    /// tag presence/absence — no separate start/end tags needed. Called once per companion
    /// turn, right after the tag has been extracted and stripped from the spoken text.
    ///
    /// Step generation is NOT performed here anymore — "plan first, then execute, like a
    /// coding agent" (explicit user direction) means the caller must synchronously generate
    /// and present the plan on `.newlyStarted` via `presentGuidedTaskPlan` before this turn's
    /// answer is finalized, rather than firing it off in the background after the fact.
    private func applyGuidedTaskLifecycle(guideTaskTitleThisTurn: String?) -> GuidedTaskLifecycleOutcome {
        guard let guideTaskTitleThisTurn, !guideTaskTitleThisTurn.isEmpty else {
            // Tag absent this turn — a task that was active has naturally concluded
            // (wrapped up, or the conversation moved on). No lingering state.
            if let endingTask = activeGuidedTask {
                print("🧭 Guided task ended: \(endingTask.title)")
                activeGuidedTask = nil
                return .ended
            }
            return .notActive
        }

        if activeGuidedTask != nil {
            // Continuing an in-progress task. Deliberately keep the original title
            // (it's used as the race guard in `presentGuidedTaskPlan`) rather than
            // overwriting it with whatever the model tagged this turn.
            activeGuidedTask?.lastActivityAt = Date()
            return .continuing
        }

        // Starting a brand-new guided task. Steps start empty — the caller generates
        // them synchronously via `presentGuidedTaskPlan` before this turn's answer is
        // finalized, trading a beat of latency for an answer that actually enumerates
        // the plan instead of guessing at steps that don't exist yet.
        activeGuidedTask = CompanionGuidedTask(title: guideTaskTitleThisTurn)
        print("🧭 Guided task started: \(guideTaskTitleThisTurn)")

        // Recommended-tool registry: if this task's title matches a known go-to tool
        // (e.g. "set up a phone agent" → Vapi), remember it on the task so every later
        // turn stays grounded in real knowledge about that tool, and open its site now.
        let matchedTool = TeachyRecommendedToolRegistry.match(forText: guideTaskTitleThisTurn)
        if let matchedTool {
            activeGuidedTask?.recommendedTool = matchedTool
            Self.openRecommendedToolSite(matchedTool.url)
        }

        return .newlyStarted
    }

    /// Opens a recommended tool's site in the default browser ("vapi.ai" → https://vapi.ai).
    private static func openRecommendedToolSite(_ urlString: String) {
        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else { return }
        let lowercasedURLString = trimmedURLString.lowercased()
        let normalizedURLString = (lowercasedURLString.hasPrefix("http://") || lowercasedURLString.hasPrefix("https://"))
            ? trimmedURLString
            : "https://\(trimmedURLString)"
        guard let siteURL = URL(string: normalizedURLString) else { return }
        NSWorkspace.shared.open(siteURL)
    }

    /// Generates the guided-task's step plan SYNCHRONOUSLY — accepting added latency
    /// for this turn — then makes a second model call so the spoken answer actually
    /// enumerates the plan in Teachy's own natural voice, instead of the quick first-call
    /// guess (discarded) that couldn't reference steps that didn't exist yet.
    ///
    /// Uses the screen-grounded reasoning planner first, and falls back to the fast
    /// text-only planner if that call fails, so a guided task always gets steps.
    private func presentGuidedTaskPlan(
        images: [(data: Data, label: String)],
        historyForAPI: [(userPlaceholder: String, assistantResponse: String)],
        cursorScreenCapture: CompanionScreenCapture?,
        fallbackSpokenText: String,
        fallbackFullResponseText: String
    ) async -> (spokenText: String, fullResponseText: String) {
        guard let task = activeGuidedTask else { return (fallbackSpokenText, fallbackFullResponseText) }

        do {
            let plannedSteps: [AgenticStep]
            do {
                plannedSteps = try await GuidedTaskPlanner.planSteps(
                    taskDescription: task.title,
                    screenCapture: cursorScreenCapture,
                    groundingKnowledge: task.recommendedTool?.knowledgeBrief,
                    apiClient: claudeAPI
                )
                print("🧭 Screen-grounded plan ready (\(plannedSteps.count)): \(task.title)")
            } catch {
                print("⚠️ Reasoning planner failed (\(error)), falling back to fast planner: \(task.title)")
                plannedSteps = try await GuidedTaskPlanner.planStepsWithoutScreen(
                    taskDescription: task.title,
                    groundingKnowledge: task.recommendedTool?.knowledgeBrief,
                    apiClient: claudeAPI
                )
                print("🧭 Fast-fallback plan ready (\(plannedSteps.count)): \(task.title)")
            }

            // Race guard: the task may have ended or been superseded while planning was in flight.
            guard activeGuidedTask?.title == task.title else { return (fallbackSpokenText, fallbackFullResponseText) }
            activeGuidedTask?.steps = plannedSteps

            // The tool's site was just auto-opened — the images captured at turn start
            // predate it, so the reply couldn't see the page it opened. Give the page a
            // beat to load, then re-capture so the plan intro guides step 1 against what's
            // ACTUALLY on screen now. The re-capture also refreshes the AX element registry
            // and browser tab context for the new page, so pointing resolves against it.
            var planIntroImages = images
            if task.recommendedTool != nil {
                try? await Task.sleep(for: .milliseconds(2500))
                if let freshScreenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() {
                    planIntroImages = await buildLabeledAnnotatedImages(
                        screenCaptures: freshScreenCaptures,
                        mouseOutlineContext: nil
                    )
                }
            }

            let stepSummary = plannedSteps.enumerated()
                .map { "\($0.offset + 1). \($0.element.goal.title) — \($0.element.goal.goal)" }
                .joined(separator: "; ")

            let toolOpenAddendum = task.recommendedTool == nil ? "" : """


            The tool's site was just opened for them — their screen shows it right now. Walk them \
            through step 1 against what's ACTUALLY on that page, pointing at the first real thing to \
            look at or click. If what you remember says they're new to this tool, start with signup \
            or onboarding — don't assume an account. Keep guiding turn after turn until this is done; \
            never open a door and just stand there.
            """

            let planIntroPrompt = """
            You just figured out the plan for "\(task.title)": \(stepSummary).

            Give a short, warm, SPOKEN run-through of this plan in your own natural voice — not a
            bullet list, just talk through it like you would out loud ("first we'll..., then...").
            Then go straight into step 1. Only say "here"/"right here" if you're including a
            [POINT:...] tag with it — if you can't confidently point at something specific yet,
            describe it in words instead. Tag [GUIDE: \(task.title)] to keep guidance going.\(toolOpenAddendum)
            """

            let (planResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: planIntroImages,
                systemPrompt: buildCompanionVoiceResponseSystemPrompt(),
                conversationHistory: historyForAPI,
                userPrompt: planIntroPrompt,
                onTextChunk: { _ in }
            )

            let planParseResult = Self.parsePointingCoordinates(from: planResponseText)
            let (planTextWithoutMemoryTags, planRememberedFacts) = CompanionRememberTagParser.extractFactsAndStrip(from: planParseResult.spokenText)
            for fact in planRememberedFacts {
                BrainStore.shared.remember(fact, kind: .aboutMe)
            }
            let (planSpokenText, _) = CompanionGuideTagParser.extractTitleAndStrip(from: planTextWithoutMemoryTags)
            activeGuidedTask?.lastActivityAt = Date()

            return (planSpokenText, planResponseText)
        } catch {
            print("⚠️ Guided task plan generation failed: \(error)")
            // Degrade to the original quick answer rather than dead silence — and don't
            // leave the task stuck in a permanent "steps.isEmpty" state.
            activeGuidedTask = nil
            return (fallbackSpokenText, fallbackFullResponseText)
        }
    }

    /// Additive system-prompt block for the current guided-task state.
    /// When no task is active, tells the model when it's appropriate to start one.
    private func guidedTaskPromptSection() -> String {
        guard let activeGuidedTask else {
            return """

            If they want to do something themselves that genuinely needs several concrete steps (not just an
            explanation, and not something you could simply do for them), and you know what "done" looks like
            for the first step, tag your reply [GUIDE: short title] and you'll walk them through it step by step.
            A quick factual question doesn't need it. If you don't have enough context yet (what they need it FOR
            changes the right steps), just ask — but check what you already remember about them first.
            \(Self.recommendedToolRegistrySummaryLine())
            """
        }

        if activeGuidedTask.steps.isEmpty {
            // Steps are still being planned from the turn that started this.
            return """

            You're mid-way through walking them through: "\(activeGuidedTask.title)" — you're still pulling
            together the exact steps behind the scenes, so keep the conversation going naturally on this topic.
            Keep tagging [GUIDE: \(activeGuidedTask.title)] while you're still actively helping with this.
            """
        }

        if activeGuidedTask.isComplete {
            return """

            You just finished walking them through the last step of "\(activeGuidedTask.title)". Wrap this up
            warmly and naturally — no more step numbers, no more [GUIDE:...] tag, just a normal close.
            """
        }

        guard let currentStep = activeGuidedTask.currentStep else { return "" }

        let stepNumber = activeGuidedTask.currentStepIndex + 1
        let totalSteps = activeGuidedTask.steps.count
        var lines = [
            "",
            "You're mid-way through walking them through: \"\(activeGuidedTask.title)\" (step \(stepNumber) of \(totalSteps))."
        ]
        if let verification = pendingGuidedTaskVerificationResult {
            var verificationLine = "Just checked their screen: \(verification.status.rawValue) — \(verification.whatsGood)."
            if let whatsMissing = verification.whatsMissing, !whatsMissing.isEmpty {
                verificationLine += " Still missing: \(whatsMissing)."
            }
            lines.append(verificationLine)

            // An error on screen is where people give up — get them through it calmly.
            if let errorSummary = verification.visibleErrorSummary, !errorSummary.isEmpty {
                lines.append("""
                AN ERROR IS VISIBLE ON THEIR SCREEN: \(errorSummary). Get them through it: (1) half a sentence \
                that errors are normal and fixable; (2) say what the FIRST line of the error means, in plain \
                words; (3) if they're working with an AI tool, write the paste-back message for it with \
                [CLIPBOARD: ...] — the error verbatim plus one line about what they were trying to do; \
                (4) after the fix, check the screen before moving on.
                """)
            }
        }
        lines.append("Current step: \(currentStep.goal.goal)")
        lines.append("Match their familiarity — if memory says they're new to this tool, treat signup/onboarding as real steps, not assumed prerequisites.")

        // An `.act` step is one Teachy does itself with tools; the reply should narrate it,
        // not tell them to do it.
        if currentStep.executionMode == .act {
            lines.append("This step is MECHANICAL SETUP — Teachy is handling it automatically with tools. Acknowledge it, say briefly what's happening, then move on to the next point. Do NOT tell them to do this step themselves.")
        }

        // If the plan was just revised, let the model know so it doesn't reference steps
        // that no longer exist.
        if activeGuidedTask.reflectionRevisionCount > 0 {
            lines.append("Note: the plan was just updated based on what happened — go with the current step above, not any earlier version of the plan you may have referenced.")
        }

        if let recommendedTool = activeGuidedTask.recommendedTool {
            lines.append("Real knowledge about \(recommendedTool.displayName), so your guidance stays grounded turn after turn: \(recommendedTool.knowledgeBrief)")
        }
        lines.append("If they're still actively working through this, tag your reply [GUIDE: \(activeGuidedTask.title)] again so guidance continues; stop tagging it once this naturally wraps up.")
        return lines.joined(separator: "\n")
    }

    /// Builds one line per `TeachyRecommendedToolRegistry` entry so a plain "what's a good
    /// tool for X" question can surface a recommendation even before any guided task starts —
    /// the registry text goes straight to the model, so its own semantic matching (not just
    /// the narrower Swift-side `match()` used for the deterministic auto-open/grounding
    /// side-effect) does most of the conversational recommending. Built dynamically from
    /// the registry so adding a future entry doesn't require touching this prompt text.
    private static func recommendedToolRegistrySummaryLine() -> String {
        guard !TeachyRecommendedToolRegistry.all.isEmpty else { return "" }

        let perToolLines = TeachyRecommendedToolRegistry.all.map { tool in
            "for \(tool.displayName) (\(tool.url)) — recommend it if asked about \(tool.triggerKeywords.joined(separator: ", ")), or similar."
        }

        return """

        Known go-to tools Teachy recommends — mention these by name when relevant even in a quick answer, not just when guiding a walkthrough:
        \(perToolLines.joined(separator: "\n"))
        """
    }

    // MARK: - Layer 2: Acting on `.act` steps

    /// The result of an `.act` step execution — text to speak and whether the step was
    /// completed successfully (so the caller knows whether the step index was advanced).
    private struct ActStepExecutionResult {
        let spokenText: String
        let stepAdvanced: Bool
    }

    /// Executes a guided-task step tagged `.act` — announces, runs the tool loop, verifies
    /// on the post-action screen, and advances or falls back to coaching.
    ///
    /// Flow:
    /// 1. Speak a brief announcement so the user is never surprised by cursor movement.
    /// 2. Build a step-scoped acting system prompt that:
    ///    a. Scopes the agent to this single step's goal only.
    ///    b. Explicitly forbids destructive, financial, irreversible, or account-deleting actions.
    ///    c. If such an action would be required, the model must STOP and explain instead of acting.
    /// 3. Run `backgroundAgentManager.runScopedToolTurn` (existing tool loop, up to 10 iterations).
    /// 4. Capture a fresh screenshot after tools so pointing reflects the new screen state.
    /// 5. Verify the post-action screen against the step's `doneWhen` criterion.
    /// 6. On `.pass`: advance `activeGuidedTask.currentStepIndex`, compose a brief "done, now..." reply.
    /// 7. On failure or tool-loop error: fall back to coaching (tell user what was attempted, guide them).
    ///    Then trigger Layer 3 reflection so the plan adapts.
    private func executeActStep(
        currentGuidedStep: AgenticStep,
        screenCaptures: [CompanionScreenCapture],
        transcript: String
    ) async -> ActStepExecutionResult {
        guard let taskSnapshot = self.activeGuidedTask else {
            // Task was cleared mid-flight — nothing to act on.
            return ActStepExecutionResult(spokenText: "", stepAdvanced: false)
        }

        let stepGoalDescription = currentGuidedStep.goal.goal
        let stepCoachAsk = currentGuidedStep.goal.coachAsk
        let stepDoneWhen = currentGuidedStep.goal.doneWhen ?? stepGoalDescription

        // Step 1: Announce before any cursor movement. Speak inline here so the
        // announcement always precedes the tool loop — never out of order.
        let announcementText = "Alright, I'll set this part up for you — one sec."
        voiceState = .responding
        do {
            try await speechSynthesizer.speakText(announcementText)
        } catch {
            print("⚠️ Companion act-step announcement TTS error: \(error)")
        }
        voiceState = .processing

        // Step 2: Build the step-scoped acting system prompt.
        // Safety rail: destructive/financial/irreversible actions must never be auto-executed.
        let actingSystemPrompt = """
        You are Teachy's action arm — an agent that executes a single, clearly mechanical step
        on the user's Mac so they can focus on the parts that actually need them.

        Your current task: \(stepGoalDescription)
        What Teachy would tell them about this step: \(stepCoachAsk)
        You are done when: \(stepDoneWhen)

        STRICT SAFETY RULES — read these before acting:
        - Execute ONLY the specific mechanical step described above. Do nothing else.
        - NEVER perform any action that is destructive, irreversible, or financial in nature.
          This includes: deleting files or data, submitting payments or purchases, accepting
          charges, deleting accounts, sending emails on the user's behalf without showing them
          the draft, or any action that cannot be easily undone.
        - If completing this step would require ANY destructive or financial action, STOP
          immediately, do NOT proceed, and explain in plain language what you were trying to do
          and why you stopped — then guide the user to do it themselves safely.
        - Prefer navigation and read-only actions over writes. Use the drive_ tools only for presses
          and typed text that are clearly part of the step above.
        - After finishing, report what you did in one short, natural sentence.
        """

        // Step 3: Run the tool loop, limited to the guided-step toolset.
        var toolLoopResultText: String? = nil
        var toolLoopError: Error? = nil
        do {
            toolLoopResultText = try await backgroundAgentManager.runScopedToolTurn(
                userPrompt: "Please complete this step now: \(stepGoalDescription)",
                systemPrompt: actingSystemPrompt,
                conversationHistory: [],
                screenCaptures: screenCaptures,
                mouseOutlineContext: nil
            )
            print("🤖 Act step tool loop finished for: \(currentGuidedStep.goal.title)")
        } catch {
            toolLoopError = error
            print("⚠️ Act step tool loop error: \(error)")
        }

        guard !Task.isCancelled else {
            return ActStepExecutionResult(spokenText: "", stepAdvanced: false)
        }

        // Step 4: Fresh capture after tools so post-action verification and pointing
        // reflect the screen the user sees NOW (not what it looked like before acting).
        let postActionScreenCaptures: [CompanionScreenCapture]
        if let freshCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() {
            postActionScreenCaptures = freshCaptures
        } else {
            // Fall back to the pre-action captures rather than leaving verification blind.
            postActionScreenCaptures = screenCaptures
        }
        let postActionCursorCapture = postActionScreenCaptures.first(where: { $0.isCursorScreen })
            ?? screenCaptures.first(where: { $0.isCursorScreen })

        // Step 5: Verify the post-action screen against the step's doneWhen criterion.
        // If the tool loop itself errored, skip to the fallback-to-coach path directly.
        var postActVerificationResult: GuidedStepCheckResult? = nil
        if toolLoopError == nil, let postActionCapture = postActionCursorCapture {
            postActVerificationResult = await GuidedStepScreenChecker.checkStep(
                doneWhenDescription: stepDoneWhen,
                screenCapture: postActionCapture,
                claudeAPI: claudeAPI
            )
        }

        let actStepSucceeded = postActVerificationResult?.status == .pass

        if actStepSucceeded {
            // Step 6: Advance the step index — same logic the coach path uses on `.pass`.
            // Race guard: confirm the task is still the same one we started with.
            guard self.activeGuidedTask?.title == taskSnapshot.title else {
                return ActStepExecutionResult(spokenText: "", stepAdvanced: false)
            }
            self.activeGuidedTask?.currentStepIndex += 1
            self.activeGuidedTask?.lastActivityAt = Date()

            // Apply pointing to the post-action screen so the cursor flies to the
            // right place on the new screen state when the agent mentions a location.
            let toolLoopSpokenText = BackgroundAgentManager.formatFinalResponseForSpeech(
                Self.parsePointingCoordinates(from: toolLoopResultText ?? "").spokenText
            )
            if let postActionCapture = postActionCursorCapture {
                applyPointingFromResponse(toolLoopResultText ?? "", screenCapture: postActionCapture)
            }

            // Compose the spoken result: what was done + transition to the next step.
            let nextStep = self.activeGuidedTask?.currentStep
            let transitionPhrase: String
            if let nextStep {
                transitionPhrase = " Now, \(nextStep.goal.coachAsk)"
            } else {
                transitionPhrase = " And that's the last mechanical part sorted."
            }

            let resultSummary = toolLoopSpokenText.isEmpty
                ? "Done — got that set up for you."
                : toolLoopSpokenText
            let spokenResult = resultSummary + transitionPhrase

            print("✅ Act step completed and verified: \(currentGuidedStep.goal.title)")
            return ActStepExecutionResult(spokenText: spokenResult, stepAdvanced: true)

        } else {
            // Step 7: Fallback — tell the user what was attempted, walk them through doing it.
            let whatWasAttempted = currentGuidedStep.goal.goal
            let verificationDetail = postActVerificationResult.map {
                " The screen shows: \($0.whatsGood). Still missing: \($0.whatsMissing ?? "the expected state")."
            } ?? ""
            let toolErrorNote = toolLoopError != nil ? " (The automation hit an error trying to do this.)" : ""

            let fallbackSpokenText = "Hmm, I tried to \(whatWasAttempted.lowercased()) but couldn't quite get there.\(toolErrorNote)\(verificationDetail) Let me walk you through it instead — \(currentGuidedStep.goal.coachAsk)"

            // Layer 3: trigger reflection since acting diverged. The reasoning model
            // will see what went wrong and revise the remaining steps accordingly.
            if let taskForReflection = self.activeGuidedTask,
               taskForReflection.reflectionRevisionCount < CompanionGuidedTask.maximumReflectionRevisionsPerTask,
               let reflectionScreenCapture = postActionCursorCapture {
                let whatWentWrongDescription: String
                if let toolError = toolLoopError {
                    whatWentWrongDescription = "The act step automation errored out: \(toolError.localizedDescription). Goal was: \(whatWasAttempted)."
                } else {
                    let verificationSummary = postActVerificationResult.map { "Post-act verification: \($0.status.rawValue). \($0.whatsGood). Missing: \($0.whatsMissing ?? "unknown")." } ?? "Post-act verification was unavailable."
                    whatWentWrongDescription = "The act step ran but did not achieve the goal. \(verificationSummary) Goal was: \(whatWasAttempted)."
                }
                await reflectAndReplaceRemainingSteps(
                    task: taskForReflection,
                    whatWentWrong: whatWentWrongDescription,
                    freshScreenCapture: reflectionScreenCapture
                )
            }

            print("⚠️ Act step fell back to coaching: \(currentGuidedStep.goal.title)")
            return ActStepExecutionResult(spokenText: fallbackSpokenText, stepAdvanced: false)
        }
    }

    // MARK: - Layer 3: Reflection and replanning

    /// Calls the reasoning model to reflect on what went wrong and revise the remaining
    /// steps of the living plan. Splices the revised steps into `activeGuidedTask`,
    /// keeping already-completed steps intact. A spoken cue is appended to the task so
    /// the coach's next response acknowledges the adaptation naturally.
    ///
    /// Called only on genuine divergence (`.offTrack` or act-step failure) — NEVER on a
    /// clean `.pass` (cost control). Respects `CompanionGuidedTask.maximumReflectionRevisionsPerTask`.
    private func reflectAndReplaceRemainingSteps(
        task: CompanionGuidedTask,
        whatWentWrong: String,
        freshScreenCapture: CompanionScreenCapture
    ) async {
        print("🔄 Reflection triggered for '\(task.title)': \(whatWentWrong)")

        do {
            let revisedRemainingSteps = try await GuidedTaskPlanner.replanRemainingSteps(
                taskTitle: task.title,
                allSteps: task.steps,
                currentStepIndex: task.currentStepIndex,
                whatWentWrong: whatWentWrong,
                screenCapture: freshScreenCapture,
                apiClient: claudeAPI
            )

            // Race guard: confirm the task is still active and unchanged before splicing.
            guard self.activeGuidedTask?.title == task.title else {
                print("🔄 Reflection skipped — task changed during reflection for '\(task.title)'")
                return
            }

            // Splice: keep completed steps (indices < currentStepIndex), replace
            // current-and-remaining steps with the reasoned revision.
            let completedSteps = Array(task.steps.prefix(task.currentStepIndex))
            let splicedSteps = completedSteps + revisedRemainingSteps

            self.activeGuidedTask?.steps = splicedSteps
            // currentStepIndex stays the same — the revised steps start at the same index,
            // but now they represent the model's best new plan for what to do next.
            self.activeGuidedTask?.reflectionRevisionCount += 1
            self.activeGuidedTask?.lastActivityAt = Date()

            print("🔄 Plan revised for '\(task.title)': \(revisedRemainingSteps.count) new remaining steps (revision #\(self.activeGuidedTask?.reflectionRevisionCount ?? 0))")
        } catch {
            // Replanning failed — keep guiding the existing step. The plan stays
            // frozen at the diverged step rather than breaking the task entirely.
            print("⚠️ Reflection failed for '\(task.title)': \(error.localizedDescription) — continuing with existing plan")
        }
    }

    // MARK: - Phase L: One-shot native-action fast lane

    /// Executes a direct single native Mac action — lighter sibling of `executeActStep`.
    ///
    /// The caller (`sendCompanionChatResponse`) has already spoken the model's heads-up
    /// text (announce-before-act invariant), so this function's job is:
    /// 1. Flip to `.processing` state so the UI shows activity.
    /// 2. Run the agent tool loop scoped to the requested native action with a
    ///    permissive-but-safety-bounded system prompt.
    /// 3. Speak a short confirmation only if it meaningfully adds to the heads-up.
    /// 4. Reset to `.idle` regardless of success or failure.
    ///
    /// There is no doneWhen verification, no step advancement, and no guided-task
    /// state changes — this is a completely standalone one-shot path.
    private func executeDirectNativeAction(
        actionDescription: String,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        voiceState = .processing

        // Safety-bounded but permissive system prompt for direct native commands.
        // The user explicitly chose max-capability with spoken heads-up only (no confirmation).
        let nativeActionSystemPrompt = """
        You are Teachy's native Mac action arm. The user has asked you to perform a direct, \
        single native Mac operation. Execute it immediately and efficiently using the available tools.

        Requested action: \(actionDescription)

        ALLOWED: Opening, activating, quitting, or hiding any application. Opening, closing, or \
        switching browser tabs and windows. Navigating to a URL in a new tab. These are all \
        reversible and are exactly what the user asked for — do them without hesitation.

        STRICTLY FORBIDDEN — do NOT execute, stop and explain instead:
        - Deleting user files, folders, emails, messages, contacts, or any data.
        - Making payments, purchases, or any financial transactions.
        - Deleting accounts or cancelling subscriptions.
        - Sending emails, messages, or posts on the user's behalf without showing them a draft first.
        - Any action that cannot be easily undone or that destroys data.
        If the action falls into any of the above categories, STOP, do not proceed, and explain \
        clearly in one sentence what you would have done and why you stopped — then guide the user \
        to do it themselves.

        Tool preference: use control_app for app open/activate/quit/hide; use control_browser for \
        tab/window operations in the frontmost browser. Prefer these purpose-built native tools over \
        the drive_ tools wherever they cover the need.

        When done, report what you did in one short, natural sentence. No markdown, no bullet points.
        """

        do {
            let toolLoopResultText = try await backgroundAgentManager.runScopedToolTurn(
                userPrompt: "Do this now: \(actionDescription)",
                systemPrompt: nativeActionSystemPrompt,
                conversationHistory: [],
                screenCaptures: screenCaptures,
                mouseOutlineContext: nil,
                toolset: .nativeControl
            )

            guard !Task.isCancelled else { return }

            // Speak a short confirmation only when the tool loop's final line meaningfully
            // differs from the heads-up already spoken. If the result is empty or just
            // echoes the action description, skip it to avoid double-speaking.
            let confirmationText = BackgroundAgentManager.formatFinalResponseForSpeech(toolLoopResultText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let confirmationIsSubstantive = !confirmationText.isEmpty
                && confirmationText.lowercased() != actionDescription.lowercased()

            if confirmationIsSubstantive {
                voiceState = .responding
                do {
                    try await speechSynthesizer.speakText(confirmationText)
                } catch {
                    print("⚠️ Companion TTS error (direct action confirmation): \(error)")
                }
            }

        } catch {
            guard !Task.isCancelled else { return }

            // Brief natural error message — same tone as the rest of companion voice.
            let errorUtterance = "Hmm, that didn't go through — you may want to do that one manually."
            print("⚠️ Direct native action failed (\(actionDescription)): \(error.localizedDescription)")
            voiceState = .responding
            do {
                try await speechSynthesizer.speakText(errorUtterance)
            } catch {
                print("⚠️ Companion TTS error (direct action error speech): \(error)")
            }
        }

        if !Task.isCancelled {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Builds the labeled image array for model requests, and also populates
    /// `currentAXElementRegistry` with actionable elements from the frontmost app.
    ///
    /// AX detection runs off the main thread inside a `Task.detached` block so it
    /// doesn't block the screenshot-to-API pipeline. We await it here so the element
    /// list is ready before the model request fires (adding no serial latency — the
    /// detection budget is 250ms and the image encoding typically takes longer).
    ///
    /// The element block is appended only to the cursor screen's label, not secondary
    /// screens, so the model isn't confused by elements from an off-focus display.
    private func buildLabeledAnnotatedImages(
        screenCaptures: [CompanionScreenCapture],
        mouseOutlineContext: CompanionMouseOutlineContext?
    ) async -> [(data: Data, label: String)] {
        // Detect AX elements concurrently with image annotation (off main thread).
        // We guard on the instance-level hasAccessibilityPermission property which
        // mirrors the live AXIsProcessTrusted() state and is refreshed periodically.
        let detectedAXElements: [DetectedAXElement]
        if hasAccessibilityPermission {
            detectedAXElements = await Task.detached(priority: .userInitiated) {
                AccessibilityElementDetector.detectActionableElements()
            }.value
        } else {
            detectedAXElements = []
        }

        // Store in the registry so applyPointingFromResponse can look up by id.
        currentAXElementRegistry = detectedAXElements

        // Refresh the active browser-tab context (URL + title) for this turn while
        // we're already doing capture-time work. Nil when the frontmost app isn't a
        // browser or Automation isn't granted; consumed by the companion prompt
        // builder and cleared after the prompt is built (same transient-per-turn
        // hygiene as pendingGuidedTaskVerificationResult).
        currentBrowserTabContext = await BrowserActiveTabReader.activeTabContext()
        // One line of screen memory per turn, so "that page I had open earlier" can be answered.
        ScreenMemory.shared.noteCurrentScreen(browserTabContext: currentBrowserTabContext)

        // Build a compact text block the model can reference to pick an element by ax:ID.
        // Only built when the list is non-empty.
        let axElementBlock: String? = {
            guard !detectedAXElements.isEmpty else { return nil }
            let simplifiedRole: (String) -> String = { role in
                switch role {
                case "AXButton", "AXMenuButton": return "button"
                case "AXLink": return "link"
                case "AXTextField": return "textfield"
                case "AXTextArea": return "textarea"
                case "AXCheckBox": return "checkbox"
                case "AXRadioButton": return "radio"
                case "AXPopUpButton": return "popup"
                case "AXMenuItem", "AXMenuBarItem": return "menuitem"
                case "AXTab", "AXTabButton": return "tab"
                case "AXSlider": return "slider"
                case "AXCell": return "cell"
                case "AXImage": return "image"
                case "AXStaticText": return "text"
                default: return role.replacingOccurrences(of: "AX", with: "").lowercased()
                }
            }
            let lines = detectedAXElements.map { element in
                "[ax:\(element.id)] \(simplifiedRole(element.role)) \"\(element.label)\""
            }.joined(separator: "\n")
            return """
            On-screen elements you can point at precisely (prefer these — they resolve to exact positions):
            \(lines)
            """
        }()

        return screenCaptures.map { screenCapture in
            let outlinePointsForCapture = screenCapture.isCursorScreen
                ? (mouseOutlineContext?.outlinePointsInScreenshotSpace ?? [])
                : []
            let highlightedCellsForCapture = screenCapture.isCursorScreen
                ? (mouseOutlineContext?.touchedGridCellLabels ?? [])
                : []

            var dimensionInfo = " (image dimensions: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) pixels, grid overlay: columns A-X, rows 1-16; prefer [POINT:ax:ID:label] when target is in the elements list, otherwise [POINT:x,y:label] pixels or [POINT:cell:label])"
            if let spatialContextLabel = mouseOutlineContext?.spatialContextLabel,
               screenCapture.isCursorScreen {
                dimensionInfo += "; \(spatialContextLabel)"
            }

            // Append the AX element block only to the cursor screen label
            var fullLabel = screenCapture.label + dimensionInfo
            if screenCapture.isCursorScreen, let axBlock = axElementBlock {
                fullLabel += "\n\n" + axBlock
            }

            let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
                originalJPEGData: screenCapture.imageData,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels,
                mouseOutlinePointsInScreenshotSpace: outlinePointsForCapture,
                highlightedGridCellLabels: highlightedCellsForCapture
            ) ?? screenCapture.imageData

            return (data: annotatedImageData, label: fullLabel)
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Teachy" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while speechSynthesizer.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while activeScreenDrawInstruction != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    private static func screenCaptureFailureUtterance() -> String {
        "i can't see your screen right now. open system settings, screen recording, remove teachy and add it back, then restart the app."
    }

    /// Spoken error lines a NON-developer can act on. Key users and proxy/dev
    /// users get different guidance — "run npm run local" means nothing to
    /// someone who downloaded a DMG, and "check your internet" is wrong advice
    /// for a developer whose local proxy just isn't running.
    private func companionAPIErrorUtterance(for error: Error) -> String {
        if let billingError = error as? TeachyAIBillingError {
            // The panel shows publik's message with its one top-up link.
            return "\(billingError.message.lowercased()) i put the link in the Teachy panel."
        }
        if error is TeachyAINotReadyError {
            return "sign in with publik in the Teachy panel first, then try again."
        }

        let errorDescription = error.localizedDescription.lowercased()
        let userHasOwnKey = TeachyAIRouter.isReadyForAI

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return userHasOwnKey
                    ? "i can't reach the internet right now — check your connection and try again."
                    : "sign in with publik in the Teachy panel, then try again."
            case .timedOut:
                return "that took too long — the AI service might be slow right now. try again in a moment."
            default:
                break
            }
        }

        if errorDescription.contains("image input") || errorDescription.contains("no endpoints found") {
            return "sorry, i couldn't read your screen that time. try again in a moment."
        }

        if errorDescription.contains("429") || errorDescription.contains("rate-limit") || errorDescription.contains("rate limit") {
            return "the AI is busy right now. wait a minute and try again."
        }

        if errorDescription.contains("401") || errorDescription.contains("403") || errorDescription.contains("invalid api key") || errorDescription.contains("unauthorized") {
            return "publik signed this Mac out. open the Teachy panel and sign in again."
        }

        if errorDescription.contains("insufficient") || errorDescription.contains("quota") || errorDescription.contains("credits") {
            return "your publik balance looks empty. open the Teachy panel to top it up."
        }

        return "sorry, something went wrong talking to the AI. try again in a moment."
    }

    private func speakErrorMessage(_ message: String) {
        // Route through the shared synthesizer (the old throwaway
        // NSSpeechSynthesizer deallocated mid-sentence, cutting errors off) and
        // ALWAYS land voiceState back at idle — the old version left the
        // responding spinner stuck forever after any error.
        speechSynthesizer.stopPlayback()
        Task {
            voiceState = .responding
            do {
                try await speechSynthesizer.speakText(message)
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            } catch is CancellationError {
                // Superseded by a newer interaction — it owns voiceState now.
            } catch {
                print("⚠️ Error-message TTS failed: \(error)")
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
        /// Grid cell label when the model used [POINT:E4:label] instead of raw pixels.
        let gridCellLabel: String?
        /// AX element id when the model used [POINT:ax:ID:label] — highest-priority path.
        /// When set, coordinate and gridCellLabel are nil; the true position is resolved
        /// from `currentAXElementRegistry` in `applyPointingFromResponse`.
        let axElementID: Int?
    }

    /// Parses pointing info from a model response — structured [POINT:...] tags (anywhere in text),
    /// or a fallback grid-cell mention in prose when the model says "cell E4" without the tag.
    ///
    /// Priority order:
    /// 1. [POINT:ax:ID:label] — AX element reference (most accurate, exact bounds known)
    /// 2. [POINT:cell:E4:label] / [POINT:E4:label] — grid cell fallback
    /// 3. [POINT:842,310:label] — raw pixel coordinate fallback
    /// 4. [POINT:none] — explicit no-op
    /// 5. Prose mentions of a grid cell (last-resort)
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

        // MOST ACCURATE: AX element reference — checked first
        if let axResult = findAXPointingTag(in: trimmedResponse) {
            return axResult
        }

        if let gridResult = findGridCellPointingTag(in: trimmedResponse) {
            return gridResult
        }

        if let pixelResult = findPixelPointingTag(in: trimmedResponse) {
            return pixelResult
        }

        if findNonePointingTag(in: trimmedResponse) {
            let spokenText = trimmedResponse.replacingOccurrences(
                of: #"\[POINT:\s*none\s*\]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil,
                gridCellLabel: nil,
                axElementID: nil
            )
        }

        if let proseGridResult = findMentionedGridCell(in: trimmedResponse) {
            return proseGridResult
        }

        return PointingParseResult(
            spokenText: trimmedResponse,
            coordinate: nil,
            elementLabel: nil,
            screenNumber: nil,
            gridCellLabel: nil,
            axElementID: nil
        )
    }

    /// Finds [POINT:ax:ID:optional label] anywhere in the response.
    /// This is the highest-priority pointing format — the model references an element
    /// by its ax:ID from the on-screen elements list, giving us exact AX bounds.
    private static func findAXPointingTag(in responseText: String) -> PointingParseResult? {
        let axPattern = #"\[POINT:\s*ax:\s*(\d+)\s*(?::\s*([^\]]*?))?\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: axPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let idRange = Range(match.range(at: 1), in: responseText),
              let axID = Int(responseText[idRange]) else {
            return nil
        }

        let spokenText = responseTextByRemovingPointingTag(
            from: responseText,
            tagRange: Range(match.range, in: responseText)!
        )

        var elementLabel: String? = nil
        if match.numberOfRanges >= 3, let labelRange = Range(match.range(at: 2), in: responseText) {
            let rawLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            if !rawLabel.isEmpty {
                elementLabel = rawLabel
            }
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: nil,
            elementLabel: elementLabel,
            screenNumber: nil,
            gridCellLabel: nil,
            axElementID: axID
        )
    }

    /// Finds [POINT:E4:label] or [POINT:cell:E4:label] anywhere in the response.
    private static func findGridCellPointingTag(in responseText: String) -> PointingParseResult? {
        let gridPattern = #"\[POINT:(?:cell:)?\s*(\#(ScreenGridAnnotationUtility.gridCellRegexFragment))\s*(?::\s*([^\]:\s][^\]:]*?))?(?::screen(\d+))?\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: gridPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let cellRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }

        let spokenText = responseTextByRemovingPointingTag(from: responseText, tagRange: Range(match.range, in: responseText)!)
        let cellLabel = String(responseText[cellRange]).uppercased()

        var elementLabel: String? = nil
        if match.numberOfRanges >= 3, let labelRange = Range(match.range(at: 2), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 4, let screenRange = Range(match.range(at: 3), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: nil,
            elementLabel: elementLabel,
            screenNumber: screenNumber,
            gridCellLabel: cellLabel,
            axElementID: nil
        )
    }

    /// Finds [POINT:123,456:label] anywhere in the response.
    private static func findPixelPointingTag(in responseText: String) -> PointingParseResult? {
        let pixelPattern = #"\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::\s*([^\]:\s][^\]:]*?))?(?::screen(\d+))?\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pixelPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return nil
        }

        let spokenText = responseTextByRemovingPointingTag(from: responseText, tagRange: Range(match.range, in: responseText)!)

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber,
            gridCellLabel: nil,
            axElementID: nil
        )
    }

    private static func findNonePointingTag(in responseText: String) -> Bool {
        let nonePattern = #"\[POINT:\s*none\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: nonePattern, options: [.caseInsensitive]) else {
            return false
        }
        return regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) != nil
    }

    /// Fallback when the model mentions a grid cell in speech ("cell E4", "grid e4") without a POINT tag.
    private static func findMentionedGridCell(in responseText: String) -> PointingParseResult? {
        let prosePattern = #"(?i)(?:cell|grid|tile|spot)\s*(\#(ScreenGridAnnotationUtility.gridCellRegexFragment))\b"#
        if let regex = try? NSRegularExpression(pattern: prosePattern, options: []),
           let match = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)).last,
           let cellRange = Range(match.range(at: 1), in: responseText) {
            let cellLabel = String(responseText[cellRange]).uppercased()
            return PointingParseResult(
                spokenText: responseText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil,
                gridCellLabel: cellLabel,
                axElementID: nil
            )
        }

        // No bare-cell fallback: matching any "M4" / "F5" / "H1" in ordinary speech moved
        // the cursor to a random spot. A cell only counts inside a [POINT:] tag or after
        // an explicit "cell"/"grid" word (handled above).
        return nil
    }

    private static func responseTextByRemovingPointingTag(from responseText: String, tagRange: Range<String.Index>) -> String {
        var spokenText = responseText
        spokenText.removeSubrange(tagRange)
        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies a parsed POINT tag to the cursor overlay using the given screen capture for coordinate mapping.
    ///
    /// Priority:
    /// 1. **AX element hit** (`parseResult.axElementID` is set): look up the element in
    ///    `currentAXElementRegistry`, convert its global CG center to AppKit coordinates using
    ///    `AccessibilityElementDetector.globalAppKitPoint`, set `detectedElementDisplayFrame`
    ///    from `appKitDisplayFrame(containingGlobalCGFrame:)`. Bypasses all screenshot-pixel
    ///    math — the AX frame is already global truth. If the id no longer resolves (stale
    ///    registry), falls through to the grid/pixel path below.
    /// 2. **Grid/pixel fallback** (no AX hit): resolves via `resolvedScreenshotCoordinate` +
    ///    `globalAppKitCoordinate` as before, then runs `performZoomRefinementIfNeeded` for
    ///    grid-cell results (Part 2 two-stage zoom refinement).
    func applyPointingFromResponse(
        _ responseText: String,
        screenCapture: CompanionScreenCapture
    ) {
        let parseResult = Self.parsePointingCoordinates(from: responseText)

        // --- Part 1: AX element hit (most accurate path) ---
        if let axID = parseResult.axElementID {
            if let resolvedElement = currentAXElementRegistry.first(where: { $0.id == axID }) {
                // Compute the element center in global CG space
                let cgCenter = CGPoint(
                    x: resolvedElement.globalCGFrame.midX,
                    y: resolvedElement.globalCGFrame.midY
                )
                // Flip to global AppKit coordinates (bottom-left primary-screen origin)
                let globalAppKitLocation = AccessibilityElementDetector.globalAppKitPoint(
                    fromGlobalCGPoint: cgCenter
                )
                // Find the display frame (AppKit) for the element's screen so
                // OverlayWindow.isDisplayFrameOnThisScreen fires on the correct overlay.
                let targetDisplayFrame = AccessibilityElementDetector.appKitDisplayFrame(
                    containingGlobalCGFrame: resolvedElement.globalCGFrame
                ) ?? screenCapture.displayFrame

                applyBubbleText(from: parseResult, fallbackResponseText: responseText)

                // Publish nil → value transition
                detectedElementScreenLocation = nil
                detectedElementDisplayFrame = nil
                DispatchQueue.main.async { [weak self] in
                    self?.detectedElementDisplayFrame = targetDisplayFrame
                    self?.detectedElementScreenLocation = globalAppKitLocation
                }

                print("🎯 AX pointing ax:\(axID) → \(Int(cgCenter.x)),\(Int(cgCenter.y)) CG → AppKit \(Int(globalAppKitLocation.x)),\(Int(globalAppKitLocation.y)) — \"\(resolvedElement.label)\"")
                return
            }
            // Stale ax:ID — fall through to grid/pixel path (model may have included a fallback tag)
            print("🎯 AX id \(axID) not found in registry (\(currentAXElementRegistry.count) elements) — falling through to grid/pixel")
        }

        // --- Part 2 + legacy: grid/pixel fallback ---
        // The zoom refinement runs asynchronously for grid-cell results (which are coarse).
        // For pixel results the model was already confident, so we use the coordinate directly.
        guard let coarseScreenshotCoordinate = Self.resolvedScreenshotCoordinate(
            parseResult: parseResult,
            screenCapture: screenCapture
        ) else {
            print("🎯 No pointing target parsed from response: \(responseText.prefix(200))")
            return
        }

        applyBubbleText(from: parseResult, fallbackResponseText: responseText)

        // For grid-cell results, attempt one zoom-refinement round to tighten accuracy.
        // For pixel results (model was confident), or when the app is offline, skip refinement.
        let isGridCellResult = parseResult.gridCellLabel != nil
        if isGridCellResult {
            // Kick off refinement asynchronously so TTS can start immediately
            Task { [weak self] in
                guard let self else { return }
                let refinedCoordinate = await self.performZoomRefinementIfNeeded(
                    coarseScreenshotCoordinate: coarseScreenshotCoordinate,
                    screenCapture: screenCapture
                )
                let finalCoordinate = refinedCoordinate ?? coarseScreenshotCoordinate
                let globalLocation = ScreenGridAnnotationUtility.globalAppKitCoordinate(
                    screenshotPixelCoordinate: finalCoordinate,
                    screenCapture: screenCapture
                )
                let coordinateDescription = refinedCoordinate != nil
                    ? "zoom-refined \(Int(finalCoordinate.x)),\(Int(finalCoordinate.y))"
                    : (parseResult.gridCellLabel ?? "\(Int(finalCoordinate.x)),\(Int(finalCoordinate.y))")
                print("🎯 Pointing at \(coordinateDescription) — \"\(parseResult.elementLabel ?? "element")\"")

                self.detectedElementScreenLocation = nil
                self.detectedElementDisplayFrame = nil
                DispatchQueue.main.async { [weak self] in
                    self?.detectedElementDisplayFrame = screenCapture.displayFrame
                    self?.detectedElementScreenLocation = globalLocation
                }
            }
        } else {
            // Pixel coordinate — publish immediately without refinement
            let globalLocation = ScreenGridAnnotationUtility.globalAppKitCoordinate(
                screenshotPixelCoordinate: coarseScreenshotCoordinate,
                screenCapture: screenCapture
            )
            detectedElementScreenLocation = nil
            detectedElementDisplayFrame = nil
            DispatchQueue.main.async { [weak self] in
                self?.detectedElementDisplayFrame = screenCapture.displayFrame
                self?.detectedElementScreenLocation = globalLocation
            }
            print("🎯 Pointing at pixel \(Int(coarseScreenshotCoordinate.x)),\(Int(coarseScreenshotCoordinate.y)) — \"\(parseResult.elementLabel ?? "element")\"")
        }
    }

    /// Shared helper: sets `detectedElementBubbleText` from a parse result.
    /// Strips [REMEMBER:...], [GUIDE:...], [DO:...], and [CLIPBOARD:...] tags so raw
    /// structured tags never reach the speech bubble. This path re-parses the raw
    /// response text independently of `sendCompanionChatResponse`, so it needs the
    /// same defense-in-depth stripping for every tag type.
    private func applyBubbleText(from parseResult: PointingParseResult, fallbackResponseText: String) {
        detectedElementBubbleText = {
            let spokenText = parseResult.spokenText.isEmpty ? fallbackResponseText : parseResult.spokenText
            let (spokenTextWithoutMemoryTags, _) = CompanionRememberTagParser.extractFactsAndStrip(from: spokenText)
            // [GUIDE:...] is a structured lifecycle tag like [REMEMBER:...] — same leak
            // risk here (this bubble-text path re-parses the raw response independently
            // of the REMEMBER/GUIDE stripping already done in `sendCompanionChatResponse`),
            // so it needs the same defense-in-depth stripping.
            let (spokenTextWithoutGuideTags, _) = CompanionGuideTagParser.extractTitleAndStrip(from: spokenTextWithoutMemoryTags)
            // [DO:...] is the Phase L one-shot action tag — same defense-in-depth strip
            // so the raw action instruction never surfaces in the speech bubble.
            let (spokenTextWithoutActionTags, _) = CompanionActionTagParser.extractActionAndStrip(from: spokenTextWithoutGuideTags)
            // [CLIPBOARD:...] carries the full crafted prompt — definitely not bubble text.
            let (spokenTextWithoutClipboardTags, _) = CompanionClipboardTagParser.extractClipboardTextAndStrip(from: spokenTextWithoutActionTags)
            let cleanedSpokenText = BackgroundAgentManager.formatFinalResponseForSpeech(spokenTextWithoutClipboardTags)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedSpokenText.isEmpty else { return nil }
            return cleanedSpokenText
        }()
    }

    /// Part 2 — two-stage vision zoom refinement.
    ///
    /// Takes a coarse grid-cell screenshot coordinate, crops + upscales a neighborhood
    /// around it, burns a fine local grid, and makes a single tight model call to pin
    /// down the exact clickable control within that region. Maps the result back to
    /// full-image screenshot-pixel space.
    ///
    /// Returns the refined coordinate, or nil if refinement failed or timed out
    /// (caller falls back to the coarse coordinate — never worse than today).
    ///
    /// Skipped entirely for AX hits (already exact) and pixel-coordinate results
    /// (model was already confident). Only runs for grid-cell fallback results.
    private func performZoomRefinementIfNeeded(
        coarseScreenshotCoordinate: CGPoint,
        screenCapture: CompanionScreenCapture
    ) async -> CGPoint? {
        // Build a magnified crop around the coarse guess
        guard let zoomRegion = ScreenGridAnnotationUtility.annotatedRegionForZoomRefinement(
            originalJPEGData: screenCapture.imageData,
            fullImageWidthInPixels: screenCapture.screenshotWidthInPixels,
            fullImageHeightInPixels: screenCapture.screenshotHeightInPixels,
            coarsePointInFullImagePixels: coarseScreenshotCoordinate
        ) else {
            return nil
        }

        // One-image, one-line model call — no history, no TTS, bounded to ~8s
        let refinementPrompt = "Point at the exact clickable control in this magnified view using [POINT:cell:label] where cell uses local columns a-f rows 1-6, or [POINT:x,y:label] in this image's pixel coordinates."
        let refinementImages = [(data: zoomRegion.annotatedData, label: "magnified region — local grid a-f columns, 1-6 rows, row 1 at top")]

        do {
            let (refinementResponse, _) = try await withThrowingTaskGroup(of: (String, TimeInterval).self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.claudeAPI.analyzeImageStreaming(
                        images: refinementImages,
                        systemPrompt: "You are a pointing assistant. Reply with only a [POINT:...] tag and a short label. No other text.",
                        conversationHistory: [],
                        userPrompt: refinementPrompt,
                        onTextChunk: { _ in }
                    )
                }
                // 8-second wall-clock cap — if refinement takes too long, cancel it
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }

            // Parse the refined response — accept grid-cell or pixel, reject AX (no registry for this crop)
            let refinedParseResult = Self.parsePointingCoordinates(from: refinementResponse)

            if let localGridCell = refinedParseResult.gridCellLabel {
                // The local grid is 6 columns × 6 rows over the upscaled crop image
                let localColumnCount = 6
                let localRowCount = 6
                let upscaledWidth = zoomRegion.cropSize.width * zoomRegion.usedUpscaleFactor
                let upscaledHeight = zoomRegion.cropSize.height * zoomRegion.usedUpscaleFactor
                let localCellWidth = upscaledWidth / CGFloat(localColumnCount)
                let localCellHeight = upscaledHeight / CGFloat(localRowCount)

                // Parse local grid label: column a-f (0-5), row 1-6
                let label = localGridCell.lowercased()
                guard label.count >= 2,
                      let colChar = label.first,
                      colChar >= "a" && colChar <= "f",
                      let rowNumber = Int(String(label.dropFirst())),
                      rowNumber >= 1, rowNumber <= localRowCount else {
                    print("🔍 Zoom: local cell \(localGridCell) out of range — using coarse")
                    return nil
                }
                let localColIdx = Int(colChar.asciiValue! - 97) // a=0
                let localRowIdx = rowNumber - 1 // 0-based
                let localCenterX = (CGFloat(localColIdx) + 0.5) * localCellWidth
                let localCenterY = (CGFloat(localRowIdx) + 0.5) * localCellHeight
                let localPoint = CGPoint(x: localCenterX, y: localCenterY)

                let fullImagePoint = ScreenGridAnnotationUtility.fullImagePixelCoordinate(
                    fromLocalZoomPoint: localPoint,
                    cropOrigin: zoomRegion.cropOrigin,
                    upscaleFactor: zoomRegion.usedUpscaleFactor
                )
                print("🔍 Zoom refined: local \(localGridCell) → full-image \(Int(fullImagePoint.x)),\(Int(fullImagePoint.y))")
                return fullImagePoint

            } else if let localPixelCoord = refinedParseResult.coordinate {
                // Model returned pixel coords in the upscaled crop image space
                let fullImagePoint = ScreenGridAnnotationUtility.fullImagePixelCoordinate(
                    fromLocalZoomPoint: localPixelCoord,
                    cropOrigin: zoomRegion.cropOrigin,
                    upscaleFactor: zoomRegion.usedUpscaleFactor
                )
                print("🔍 Zoom refined (pixel): \(Int(localPixelCoord.x)),\(Int(localPixelCoord.y)) → full-image \(Int(fullImagePoint.x)),\(Int(fullImagePoint.y))")
                return fullImagePoint
            }

        } catch {
            // Refinement timed out or failed — not an error, just use coarse coordinate
            print("🔍 Zoom refinement skipped/failed: \(error.localizedDescription)")
        }

        return nil
    }

    /// Soft cap only for pathological model dumps — normal coaching lines stay intact.
    static func truncateTextForPointingBubble(_ text: String, maxCharacters: Int = 220) -> String {
        let collapsedWhitespace = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsedWhitespace.count > maxCharacters else { return collapsedWhitespace }

        let truncated = String(collapsedWhitespace.prefix(maxCharacters))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "…"
        }
        return truncated + "…"
    }

    private func publishScreenDrawInstruction(gridCellLabels: [String], displayFrame: CGRect) {
        activeScreenDrawInstruction = nil
        let drawInstruction = ScreenGridDrawInstruction(
            gridCellLabels: gridCellLabels,
            displayFrame: displayFrame
        )

        DispatchQueue.main.async { [weak self] in
            self?.activeScreenDrawInstruction = drawInstruction
        }
    }

    /// Resolves grid-cell or pixel POINT tags into screenshot pixel coordinates.
    static func resolvedScreenshotCoordinate(
        parseResult: PointingParseResult,
        screenCapture: CompanionScreenCapture
    ) -> CGPoint? {
        if let gridCellLabel = parseResult.gridCellLabel {
            return ScreenGridAnnotationUtility.screenshotPixelCoordinate(
                forCellLabel: gridCellLabel,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
            )
        }

        return parseResult.coordinate
    }

    // MARK: - Beside-cursor video (onboarding intro)

    /// Onboarding clip — fades in beside Teachy, demos at 40s, then prompts to talk.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        besideCursorVideoBlocksPushToTalk = true

        beginBesideCursorVideo(
            url: videoURL,
            onFinished: { [weak self] in
                guard let self else { return }
                ClickyAnalytics.trackOnboardingVideoCompleted()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        )

        // At 40 seconds into the video, trigger the onboarding demo where
        // Teachy flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = onboardingVideoPlayer?.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }
    }

    private func beginBesideCursorVideo(url: URL, onFinished: @escaping () -> Void) {
        tearDownOnboardingVideo(resetOpacityImmediately: true)

        let player = AVPlayer(url: url)
        player.isMuted = false
        player.volume = 0.0
        onboardingVideoPlayer = player
        showOnboardingVideo = true
        onboardingVideoOpacity = 0.0

        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.onboardingVideoPlayer === player else { return }
            self.onboardingVideoOpacity = 1.0
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.finishBesideCursorVideo(animated: true, onFinished: onFinished)
        }
    }

    private func finishBesideCursorVideo(animated: Bool, onFinished: @escaping () -> Void) {
        besideCursorVideoFadeOutTask?.cancel()

        let completeTeardown = { [weak self] in
            self?.tearDownOnboardingVideo(resetOpacityImmediately: true)
            onFinished()
        }

        if animated {
            onboardingVideoOpacity = 0.0
            besideCursorVideoFadeOutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                completeTeardown()
            }
        } else {
            completeTeardown()
        }
    }

    func tearDownOnboardingVideo() {
        tearDownOnboardingVideo(resetOpacityImmediately: true)
    }

    private func tearDownOnboardingVideo(resetOpacityImmediately: Bool) {
        showOnboardingVideo = false
        if resetOpacityImmediately {
            onboardingVideoOpacity = 0.0
        }
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
        besideCursorVideoBlocksPushToTalk = false
    }

    private func startOnboardingPromptStream() {
        let message = "press \(PushToTalkShortcutKeys.currentShortcutDisplayText) and say hey"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're teachy, a little blue buddy on their screen. onboarding demo — find ONE specific thing to point at: an app icon, a button label, a tab title, some readable text. be specific, not vague.

    say something short and playful about it — 3 to 6 words max. no emojis. don't quote what's on screen, just react. all lowercase. teachy-energy: warm, cheeky, lovable.

    the screenshot has a hidden grid (columns A-X, rows 1-16). pick a center cell on your target. respond with ONLY your quip plus [POINT:E4:label].

    \(ScreenGridAnnotationUtility.modelInstructions)
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels, grid overlay: columns A-X, rows 1-16)"
                let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
                    originalJPEGData: cursorScreenCapture.imageData,
                    screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                ) ?? cursorScreenCapture.imageData
                let labeledImages = [(data: annotatedImageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                applyPointingFromResponse(fullResponseText, screenCapture: cursorScreenCapture)
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }

}
